import Foundation
import SensingCore
import SensingProto
import SensingStorage

/// Starts and stops adapters, stamps samples, batches them and writes them to the store. Sensor callbacks only reach
/// `Intake`; everything else happens here on a 500 ms tick.
///
/// It's an actor on its own serial queue with **no suspension point inside**, so it can't hit the re-entrancy bug class
/// Android's engine hit, where a loop over batchers crossed a suspension point and crashed. `scripts/check.sh` fails if
/// `await` appears in this folder. File I/O here is synchronous, which is fine on a dedicated queue.
public actor CollectionEngine {
    public struct Options: Sendable {
        public var tickMs: Int64 = 500
        public var clockEventMs: Int64 = 15 * 60 * 1000
        public var maxBatchBytes: Int64 = 64 * 1024
        public var maxBatchAgeMs: Int64 = 2000
        /// Waiting samples that mean the disk isn't keeping up, and the point at which samples are dropped. The watch
        /// uses lower figures than Android's, to fit its memory.
        public var highWater: Int64 = 50_000
        public var hardCeiling: Int = 200_000
        public var chunkLimits = ChunkWriter.Limits()
        public var policy = RetentionPolicy()
        public var retentionMode = RetentionMode.stopWhenFull
        public var retentionCheckMs: Int64 = 30_000
        /// `device.health heartbeat`: how A3 and A6 measure CPU and battery.
        public var heartbeatMs: Int64 = 60_000
        public var heartbeatExtras: (@Sendable () -> [String: String])?
        /// A tick this late means the process didn't run, or the device slept.
        public var stallThresholdMs: Int64 = 5000
        /// Failed batches held for a retry before they're given up as a recorded gap.
        public var maxRetryBytes: Int64 = 64 * 1024 * 1024
        public var deviceKind: Sensorlog_V1_DeviceKind = .phone
        /// Tests drive `tick()` themselves.
        public var manualTick = false
        public var freeBytes: (@Sendable () -> Int64)?

        public init() {}
    }

    public struct StreamLive: Sendable, Equatable {
        public var count: Int64 = 0
        /// From the samples' own timestamps, over the last few seconds.
        public var hz: Double = 0
        public var lastTsMonoNs: Int64 = 0
    }

    public struct Stats: Sendable, Equatable {
        public var running = false
        public var sessionId: String?
        public var totalSamples: Int64 = 0
        public var streams: [String: StreamLive] = [:]
        public var pending: Int64 = 0
        public var dropped: Int64 = 0
        public var adapterFailures: Int64 = 0
        public var activeAdapters: Int64 = 0
        public var storage = ChunkStore.Status(bytesOnDisk: 0, quotaBytes: 0, freeBytes: 0)
        public var lastStopReason: String?
    }

    private final class AdapterRun {
        let adapter: any SensorAdapter
        let settings: [SensorID: SensorSetting]
        var running = false
        var backoffMs: Int64 = 1000
        var retryAtMs: Int64 = 0

        init(adapter: any SensorAdapter, settings: [SensorID: SensorSetting]) {
            self.adapter = adapter
            self.settings = settings
        }
    }

    private struct Window {
        var count: Int64 = 0
        var firstMono: Int64 = 0
        var lastMono: Int64 = 0
    }

    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let deviceId: String
    private let clock: any EngineClock
    private let options: Options
    private let intake: Intake
    private let store: ChunkStore
    private let onStopped: @Sendable (String) -> Void

    private var sessionId: String?
    private var names: [String] = []
    private var slots: [String: Int32] = [:]
    private var batchers: [Int32: Batcher] = [:]
    private var runs: [AdapterRun] = []
    private var timer: DispatchSourceTimer?
    private var spare: [Intake.Stamped] = []
    private var retries: [EncodedBatch] = []
    private var retryBytes: Int64 = 0

    private var counts: [Int32: Int64] = [:]
    private var live: [Int32: StreamLive] = [:]
    private var windows: [Int32: Window] = [:]
    private var gapThresholdNs: [Int32: Int64] = [:]
    private var lastMono: [Int32: Int64] = [:]
    private var total: Int64 = 0
    private var adapterFailures: Int64 = 0
    private var overHighWater = false
    private var lastClockEventMs: Int64 = 0
    private var lastRetentionMs: Int64 = 0
    private var lastWindowMs: Int64 = 0
    private var lastHeartbeatMs: Int64 = 0
    private var sessionStartMs: Int64 = 0
    private var lastTickMono: Int64 = 0
    private var lastOffset: Int64 = 0
    private var emittedEvictions: Set<String> = []
    private var lastStopReason: String?
    private var stopping = false

    /// `onStopped` hears about a stop the engine decided on itself, such as a full disk.
    public init(root: StorageRoot, deviceId: String, clock: any EngineClock = SystemClock(), options: Options = Options(),
                onStopped: @escaping @Sendable (String) -> Void = { _ in }) {
        queue = DispatchSerialQueue(label: "sensing.engine", qos: .userInitiated)
        self.deviceId = deviceId
        self.clock = clock
        self.options = options
        self.onStopped = onStopped
        intake = Intake(ceiling: options.hardCeiling)
        store = ChunkStore(root: root, limits: options.chunkLimits, policy: options.policy, mode: options.retentionMode,
                           nowMonoMs: { clock.monoNs() / 1_000_000 }, freeBytes: options.freeBytes)
        store.neverEvict = Set([SensorIDs.session, SensorIDs.clock, SensorIDs.gap, SensorIDs.health, SensorIDs.storageEvicted, SensorIDs.label].map(\.value))
    }

    public var isRunning: Bool { sessionId != nil }

    /// Once per process, before the first session: seals what a dead process left behind.
    @discardableResult
    public func recover() -> ChunkRecovery.Result { store.recover() }

    /// Starts a session and returns its id. `attrs` are additive attributes on `device.session start`, such as the
    /// platform: the envelope has no field for it.
    @discardableResult
    public func start(_ config: CollectionConfig, adapters: [any SensorAdapter], reason: String = "engine_start", attrs: [String: String] = [:]) -> String? {
        guard sessionId == nil else { return nil }
        let session = UUID().uuidString.lowercased()
        sessionId = session
        stopping = false
        store.openSession(session)
        names = []
        slots = [:]
        batchers = [:]
        runs = []
        retries = []
        retryBytes = 0
        counts = [:]
        live = [:]
        windows = [:]
        lastMono = [:]
        gapThresholdNs = [:]
        total = 0
        adapterFailures = 0
        overHighWater = false
        emittedEvictions = []
        intake.open(slots: 0)
        let nowMs = clock.monoNs() / 1_000_000
        lastClockEventMs = nowMs
        lastRetentionMs = nowMs
        lastWindowMs = nowMs
        lastHeartbeatMs = nowMs
        sessionStartMs = nowMs
        lastTickMono = clock.monoNs()
        lastOffset = clock.monoNs() - clock.uptimeNs()

        var startAttrs = attrs
        startAttrs["reason"] = reason
        emit(SensorIDs.session, "start", startAttrs)
        emitClock()
        emitHeartbeat(nowMs: nowMs, reason: "session_start")

        // A sensor that was asked for but can't run is said out loud, once per session.
        var claimed: Set<SensorID> = []
        for adapter in adapters {
            var settings: [SensorID: SensorSetting] = [:]
            for sensor in adapter.sensors {
                guard let setting = config.sensors[sensor], claimed.insert(sensor).inserted else { continue }
                let availability = adapter.availability(of: sensor)
                guard availability == .available else {
                    emit(SensorIDs.health, "adapter_unavailable", ["sensor": sensor.value, "reason": availability.reason])
                    continue
                }
                settings[sensor] = setting
            }
            if !settings.isEmpty { runs.append(AdapterRun(adapter: adapter, settings: settings)) }
        }
        for sensor in config.sensors.keys.sorted(by: { $0.value < $1.value }) where !claimed.contains(sensor) {
            emit(SensorIDs.health, "adapter_unavailable", ["sensor": sensor.value, "reason": Availability.missingHardware.reason])
        }
        for run in runs { startAdapter(run, nowMs: nowMs) }
        startTimer()
        return session
    }

    /// Stops in Android's order: nothing new arrives, the last words go in, what's queued drains, batches close, and chunks
    /// seal.
    public func stop(reason: String = "engine_stop") {
        guard sessionId != nil else { return }
        stopping = true
        timer?.cancel()
        timer = nil
        for run in runs where run.running { run.adapter.stop() }
        emitHeartbeat(nowMs: clock.monoNs() / 1_000_000, reason: "session_end")
        emit(SensorIDs.session, "end", ["reason": reason])
        // Draining can raise events of its own (a late stream's gap, a failed write), and those have to land too.
        repeat {
            drainWaiting()
            for batcher in batchers.values {
                if let batch = batcher.flush() { write(batch) }
            }
            retryFailedWrites()
        } while intake.pending > 0
        intake.close()
        do {
            try store.sealAll()
            if !emittedEvictions.isEmpty {
                try? store.evictions.remove(emittedEvictions)
                emittedEvictions = []
            }
        } catch {
            // The .tmp files stay, and recovery seals them next time.
            emitLost(detail: String(describing: error))
        }
        lastStopReason = reason
        sessionId = nil
        runs = []
    }

    /// Records an event from another layer, such as a label. Returns false when no session is open, so a caller that
    /// mustn't lose the event keeps it and tries again.
    @discardableResult
    public func emit(_ sensor: SensorID, _ kind: String, _ attrs: [String: String] = [:]) -> Bool {
        guard sessionId != nil else { return false }
        let slot = slot(for: sensor)
        var e = Sensorlog_V1_EventPayload()
        e.kind = kind
        e.attributes = attrs
        intake.push(slot: slot, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs(), accuracy: .unspecified, payload: .message(.event(e)))
        return true
    }

    /// Seals open chunks without stopping. The next batch opens a fresh chunk.
    public func sealNow() {
        guard sessionId != nil else { return }
        drainWaiting()
        for batcher in batchers.values {
            if let batch = batcher.flush() { write(batch) }
        }
        try? store.sealAll()
    }

    /// One tick: public so tests can drive it. The real timer calls this every 500 ms.
    public func tick() {
        guard sessionId != nil, !stopping else { return }
        let mono = clock.monoNs()
        let nowMs = mono / 1_000_000
        noteStall(mono: mono)
        restartFailedAdapters(nowMs: nowMs)
        drainIntake()
        for batcher in batchers.values {
            if let batch = batcher.flushIfDue(nowMonoMs: nowMs) { write(batch) }
        }
        retryFailedWrites()
        do {
            try store.tick()
        } catch {
            noteStorage(error)
        }
        if nowMs - lastClockEventMs >= options.clockEventMs {
            emitClock()
            lastClockEventMs = nowMs
        }
        if nowMs - lastRetentionMs >= options.retentionCheckMs {
            lastRetentionMs = nowMs
            checkStorage(reason: "tick")
        }
        if nowMs - lastHeartbeatMs >= options.heartbeatMs {
            lastHeartbeatMs = nowMs
            emitHeartbeat(nowMs: nowMs, reason: "periodic")
        }
        rollWindows(nowMs: nowMs)
        if !retries.isEmpty, store.status.freeBytes <= 0 { stopItself("disk_full") }
    }

    public func stats() -> Stats {
        var streams: [String: StreamLive] = [:]
        for (slot, value) in live where Int(slot) < names.count {  // int-ok: a small index
            streams[names[Int(slot)]] = value  // int-ok: a small index
        }
        return Stats(running: sessionId != nil, sessionId: sessionId, totalSamples: total, streams: streams, pending: intake.pending,
                     dropped: intake.dropped, adapterFailures: adapterFailures,
                     activeAdapters: Int64(runs.filter(\.running).count), storage: store.status, lastStopReason: lastStopReason)
    }

    public func chunks() -> [ChunkRecord] { store.sealedChunks }
    public func fileURL(for record: ChunkRecord) -> URL { store.fileURL(for: record) }
    public func delete(_ record: ChunkRecord) { store.delete(record) }
    public func adopt(_ record: ChunkRecord) { store.adopt(record) }
    public func storageStatus() -> ChunkStore.Status { store.status }

    // MARK: - The ingest path

    /// Until nothing's waiting, including what draining itself raised.
    private func drainWaiting() {
        repeat { drainIntake() } while intake.pending > 0
    }

    private func drainIntake() {
        let drained = intake.drain(spare: spare)
        for run in drained.drops { recordDrop(run) }
        let nowMs = clock.monoNs() / 1_000_000
        for sample in drained.samples { ingest(sample, nowMs: nowMs) }
        spare = drained.samples
        let waiting = intake.pending + Int64(drained.samples.count)
        if waiting > options.highWater, !overHighWater {
            overHighWater = true
            emit(SensorIDs.health, "persist_backlog", ["pending": String(waiting)])
        } else if waiting < options.highWater / 2 {
            overHighWater = false
        }
    }

    private func ingest(_ s: Intake.Stamped, nowMs: Int64) {
        guard let session = sessionId else { return }
        let index = Int(s.slot)  // int-ok: a small index
        guard index < names.count else { return }
        let name = names[index]
        noteDelivery(s, name: name)
        var message = Sensorlog_V1_SensorSample()
        message.deviceID = deviceId
        message.sessionID = session
        message.sensorID = name
        message.seq = UInt64(truncatingIfNeeded: s.seq)
        message.tsMonoNs = s.tsMonoNs
        message.tsWallMs = s.tsWallMs
        message.schemaVersion = 1
        message.accuracy = s.accuracy
        message.deviceKind = options.deviceKind
        switch s.payload {
        case let .vec3(x, y, z):
            message.vec3 = .with {
                $0.x = x
                $0.y = y
                $0.z = z
            }
        case let .quat(x, y, z, w, heading):
            message.quat = .with {
                $0.x = x
                $0.y = y
                $0.z = z
                $0.w = w
                $0.headingAccuracy = heading
            }
        case let .scalar(v):
            message.scalar = .with { $0.value = v }
        case let .message(payload):
            message.payload = payload
        }
        guard let bytes = try? message.serializedData() else { return }
        let batcher = batchers[s.slot] ?? makeBatcher(s.slot, name: name)
        if let batch = batcher.add(sample: bytes, deviceId: deviceId, seq: s.seq, tsMonoNs: s.tsMonoNs, tsWallMs: s.tsWallMs, nowMonoMs: nowMs) {
            write(batch)
        }
    }

    private func makeBatcher(_ slot: Int32, name: String) -> Batcher {
        let b = Batcher(sensorId: name, maxBytes: options.maxBatchBytes, maxAgeMs: options.maxBatchAgeMs)
        batchers[slot] = b
        return b
    }

    private func write(_ batch: EncodedBatch) {
        do {
            try store.write(batch)
        } catch {
            noteStorage(error)
            retries.append(batch)
            retryBytes += Int64(batch.bytes.count)
            while retryBytes > options.maxRetryBytes, !retries.isEmpty {
                let lost = retries.removeFirst()
                retryBytes -= Int64(lost.bytes.count)
                emit(SensorIDs.gap, "storage_error", ["sensor": lost.sensorId, "seq": String(lost.firstSeq), "last_seq": String(lost.lastSeq)])
            }
        }
    }

    private func retryFailedWrites() {
        guard !retries.isEmpty else { return }
        let waiting = retries
        retries = []
        retryBytes = 0
        for batch in waiting { write(batch) }
    }

    private func noteStorage(_ error: Error) {
        emit(SensorIDs.health, "storage_error", ["error": String(describing: error)])
        if case let StorageError.io(_, code) = error, code == ENOSPC { stopItself("disk_full") }
    }

    private func emitLost(detail: String) {
        // After the session's last write there's nowhere to put this but the next session's stream.
        lastStopReason = detail
    }

    // MARK: - Bookkeeping

    private func slot(for sensor: SensorID) -> Int32 {
        if let s = slots[sensor.value] { return s }
        let s = intake.addSlot()
        slots[sensor.value] = s
        names.append(sensor.value)
        return s
    }

    private func emitClock() {
        emit(SensorIDs.clock, "clock", ["mono_ns": String(clock.monoNs()), "wall_ms": String(clock.wallMs())])
    }

    private func emitHeartbeat(nowMs: Int64, reason: String) {
        let storage = store.status
        var attrs = ["reason": reason, "samples_total": String(total), "pending_persist": String(intake.pending), "dropped": String(intake.dropped),
                     "adapter_failures": String(adapterFailures), "storage_bytes": String(storage.bytesOnDisk), "storage_quota_bytes": String(storage.quotaBytes),
                     "uptime_ms": String(nowMs - sessionStartMs), "cpu_ms": String(ProcessCPU.milliseconds())]
        for (key, value) in options.heartbeatExtras?() ?? [:] { attrs[key] = value }
        emit(SensorIDs.health, "heartbeat", attrs)
    }

    private func recordDrop(_ run: Intake.DropRun) {
        let index = Int(run.slot)  // int-ok: a small index
        guard index < names.count else { return }
        // Android writes one event per dropped sample, which adds load at the worst moment. The required fields match.
        emit(SensorIDs.gap, "buffer_ceiling", ["sensor": names[index], "seq": String(run.firstSeq), "pending": String(run.pending),
                                               "last_seq": String(run.lastSeq), "count": String(run.count)])
    }

    /// A stream went quiet for much longer than its period. A sample's own timestamp decides, never arrival time.
    private func noteDelivery(_ s: Intake.Stamped, name: String) {
        total += 1
        counts[s.slot, default: 0] += 1
        var w = windows[s.slot] ?? Window(firstMono: s.tsMonoNs)
        w.count += 1
        w.lastMono = s.tsMonoNs
        windows[s.slot] = w
        var l = live[s.slot] ?? StreamLive()
        l.count += 1
        l.lastTsMonoNs = s.tsMonoNs
        live[s.slot] = l
        if let threshold = gapThresholdNs[s.slot], let last = lastMono[s.slot], s.tsMonoNs - last > threshold {
            emit(SensorIDs.gap, "delivery_gap", ["sensor": name, "from_mono_ns": String(last), "to_mono_ns": String(s.tsMonoNs)])
        }
        lastMono[s.slot] = s.tsMonoNs
    }

    /// A tick much later than asked means the process didn't run, or the device slept.
    private func noteStall(mono: Int64) {
        let late = mono - lastTickMono
        let offset = mono - clock.uptimeNs()
        if late > options.stallThresholdMs * 1_000_000 {
            emit(SensorIDs.gap, "process_stall", ["from_mono_ns": String(lastTickMono), "to_mono_ns": String(mono), "sleep_ns": String(max(0, offset - lastOffset))])
        }
        lastTickMono = mono
        lastOffset = offset
    }

    private func rollWindows(nowMs: Int64) {
        guard nowMs - lastWindowMs >= 2000 else { return }
        lastWindowMs = nowMs
        for (slot, w) in windows {
            let seconds = Double(w.lastMono - w.firstMono) / 1e9
            live[slot]?.hz = seconds > 0 ? Double(w.count - 1) / seconds : 0
            windows[slot] = Window(firstMono: w.lastMono)
        }
    }

    private func checkStorage(reason: String) {
        switch options.retentionMode {
        case .stopWhenFull:
            if store.status.isOverQuota { stopItself("quota_reached") }
        case .evictOldest:
            _ = try? store.enforceRetention(reason: reason)
            // From the persisted outbox, so a loss can't go unrecorded.
            for e in store.evictions.pending() where !emittedEvictions.contains(e.chunkId) {
                emittedEvictions.insert(e.chunkId)
                emit(SensorIDs.storageEvicted, e.reason, ["chunk": e.chunkId, "sensor": e.sensorId, "first_seq": String(e.firstSeq),
                                                          "last_seq": String(e.lastSeq), "bytes": String(e.bytes)])
            }
        }
    }

    private func stopItself(_ reason: String) {
        guard sessionId != nil, !stopping else { return }
        stop(reason: reason)
        onStopped(reason)
    }

    // MARK: - Adapters

    private func startAdapter(_ run: AdapterRun, nowMs: Int64) {
        var sinks: [SensorID: SampleSink] = [:]
        for sensor in run.settings.keys {
            let s = slot(for: sensor)
            sinks[sensor] = SampleSink(intake: intake, slot: s)
            // Only streams meant to run continuously can have a delivery gap.
            if let period = run.settings[sensor]?.samplingPeriodUs, period <= 1_000_000 {
                gapThresholdNs[s] = max(period * 10_000, 1_000_000_000)
            }
        }
        do {
            try run.adapter.start(run.settings, sinks: sinks, clock: clock)
            run.running = true
            run.backoffMs = 1000
        } catch {
            // One bad sensor never stops the others.
            adapterFailures += 1
            let sensors = run.settings.keys.map(\.value).sorted().joined(separator: ",")
            emit(SensorIDs.health, "adapter_failure", ["sensor": sensors, "error": String(describing: error)])
            run.retryAtMs = nowMs + run.backoffMs
            run.backoffMs = min(run.backoffMs * 2, 60_000)
        }
    }

    private func restartFailedAdapters(nowMs: Int64) {
        for run in runs where !run.running && nowMs >= run.retryAtMs { startAdapter(run, nowMs: nowMs) }
    }

    private func startTimer() {
        guard !options.manualTick else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(numericCast(options.tickMs)), repeating: .milliseconds(numericCast(options.tickMs)), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.tick() }
        }
        t.resume()
        timer = t
    }
}

/// The bookkeeping streams, the same ids as Android's.
public enum SensorIDs {
    public static let session = SensorID(known: "device.session")
    public static let clock = SensorID(known: "device.clock")
    public static let gap = SensorID(known: "device.gap")
    public static let health = SensorID(known: "device.health")
    public static let storageEvicted = SensorID(known: "device.storage_evicted")
    public static let label = SensorID(known: "label.session")
}
