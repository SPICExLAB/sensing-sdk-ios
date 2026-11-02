import Foundation
import SensingCore
import SensingEngine
import SensingLink
import SensingProto
import SensingStorage
import XCTest

final class FakeClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var mono: Int64 = 1_000_000_000_000
    private var wall: Int64 = 1_793_000_000_000

    func monoNs() -> Int64 { lock.withLock { mono } }
    func uptimeNs() -> Int64 { monoNs() }
    func wallMs() -> Int64 { lock.withLock { wall } }

    func advance(ms: Int64) {
        lock.withLock {
            mono += ms * 1_000_000
            wall += ms
        }
    }
}

final class FakeAdapter: SensorAdapter, @unchecked Sendable {
    let sensors: [SensorID]
    private let lock = NSLock()
    private var stored: [SensorID: SampleSink] = [:]

    init(_ sensors: SensorID...) { self.sensors = sensors }

    func availability(of sensor: SensorID) -> Availability { .available }

    func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        lock.withLock { stored = sinks }
    }

    func stop() { lock.withLock { stored = [:] } }

    func push(_ sensor: SensorID, clock: any EngineClock) {
        lock.withLock { stored[sensor] }?.vec3(1, 2, 3, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
    }
}

final class FakeKeepAlive: WatchKeepAlive, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private(set) var starts: Int64 = 0
    private(set) var stops: Int64 = 0
    var survivedCrash = false
    var failToStart = false

    struct Refused: Error {}

    var isRunning: Bool { lock.withLock { running } }

    func start() throws {
        if failToStart { throw Refused() }
        lock.withLock {
            guard !running else { return }
            running = true
            starts += 1
        }
    }

    func stop() {
        lock.withLock {
            guard running else { return }
            running = false
            stops += 1
        }
    }

    func recover() async throws -> Bool {
        lock.withLock {
            if survivedCrash { running = true }
            return survivedCrash
        }
    }
}

/// One end of a fake WatchConnectivity. With the link up, everything arrives at once. With it down, messages fail, and
/// everything queued (context, user info, files) waits, as the real one does, including across an app's death.
final class FakeTransport: LinkTransport, @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedDelegate: (any LinkTransportDelegate)?
    weak var peer: FakeTransport?
    private var queued: [@Sendable () -> Void] = []
    private var up = true
    private var context: Data?
    private var outstanding: Set<String> = []

    var activated = true
    var installed = true
    /// Drops acks arriving at this end.
    var loseAcks: Int64 = 0
    /// Flips a byte in files sent from this end.
    var corruptFiles: Int64 = 0
    /// Files sent from this end stay in its queue until `releaseFiles`.
    var holdFiles = false
    private(set) var transfers: [String] = []
    private var heldFiles: [@Sendable () -> Void] = []

    var delegate: (any LinkTransportDelegate)? {
        get { lock.withLock { storedDelegate } }
        set { lock.withLock { storedDelegate = newValue } }
    }

    static func pair() -> (phone: FakeTransport, watch: FakeTransport) {
        let phone = FakeTransport()
        let watch = FakeTransport()
        phone.peer = watch
        watch.peer = phone
        return (phone, watch)
    }

    /// A new end with what the system kept across the app's death: the received context and the queue.
    func reconnected() -> FakeTransport { self }

    func setUp(_ value: Bool) {
        lock.withLock { up = value }
        peer?.lock.withLock { peer?.up = value }
        if value {
            flush()
            peer?.flush()
            delegate?.linkDidChangeReachability()
            peer?.delegate?.linkDidChangeReachability()
        }
    }

    func flush() {
        let work = lock.withLock { () -> [@Sendable () -> Void] in
            defer { queued = [] }
            return queued
        }
        work.forEach { $0() }
    }

    func activate() {}
    var isActivated: Bool { activated }
    var isReachable: Bool { lock.withLock { up } }
    var isCounterpartInstalled: Bool { installed }
    var receivedContext: Data? { lock.withLock { context } }
    var outstandingTransfers: Set<String> { lock.withLock { outstanding } }

    private func whenUp(_ work: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if !up { queued.append(work) }
            return up
        }
        if now { work() }
    }

    func publish(context data: Data) throws {
        guard activated else { throw CocoaError(.featureUnsupported) }
        whenUp { [peer] in
            peer?.lock.withLock { peer?.context = data }
            peer?.delegate?.linkDidReceive(context: data)
        }
    }

    func send(message: Data, reply: (@Sendable (Data) -> Void)?, failed: (@Sendable (String) -> Void)?) {
        guard isReachable else {
            failed?("unreachable")
            return
        }
        if peer?.dropsAck(message) == true { return }
        peer?.delegate?.linkDidReceive(message: message, reply: reply)
    }

    func enqueue(_ data: Data) {
        if peer?.dropsAck(data) == true { return }
        whenUp { [peer] in peer?.delegate?.linkDidReceive(queued: data) }
    }

    /// One lost ack loses both of the ways it's sent.
    private var lostAcks: Set<String> = []

    private func dropsAck(_ data: Data) -> Bool {
        guard case .ack(let ack) = LinkMessage.decode(data) else { return false }
        return lock.withLock {
            if lostAcks.contains(ack.chunkId) { return true }
            guard loseAcks > 0 else { return false }
            loseAcks -= 1
            lostAcks.insert(ack.chunkId)
            return true
        }
    }

    func forgetLostAcks() { lock.withLock { lostAcks = [] } }

    func transfer(file: URL, chunkId: String, metadata: Data) {
        // The system takes its own copy of what's queued.
        guard var bytes = try? Data(contentsOf: file) else { return }
        let corrupt = lock.withLock { () -> Bool in
            transfers.append(chunkId)
            outstanding.insert(chunkId)
            guard corruptFiles > 0 else { return false }
            corruptFiles -= 1
            return true
        }
        if corrupt { bytes[bytes.count / 2] ^= 0xff }
        let snapshot = bytes
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self, let peer = self.peer else { return }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? snapshot.write(to: tmp)
            peer.delegate?.linkDidReceive(file: tmp, metadata: metadata)
            try? FileManager.default.removeItem(at: tmp)  // the file disappears when the delegate returns
            self.lock.withLock { _ = self.outstanding.remove(chunkId) }
            self.delegate?.linkDidFinishTransfer(chunkId: chunkId, error: nil)
        }
        if lock.withLock({ holdFiles }) {
            lock.withLock { heldFiles.append(deliver) }
        } else {
            whenUp(deliver)
        }
    }

    func releaseFiles() {
        let work = lock.withLock { () -> [@Sendable () -> Void] in
            holdFiles = false
            defer { heldFiles = [] }
            return heldFiles
        }
        work.forEach { whenUp($0) }
    }
}

extension XCTestCase {
    func tempRoot() throws -> StorageRoot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sensing-link-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try StorageRoot(parent: dir)
    }

    func samples(in root: StorageRoot) throws -> [Sensorlog_V1_SensorSample] {
        guard let walker = FileManager.default.enumerator(at: root.chunks, includingPropertiesForKeys: nil) else { return [] }
        var out: [Sensorlog_V1_SensorSample] = []
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(ChunkWriter.finalSuffix) {
            for frame in FrameCodec.readFrames(try Data(contentsOf: url)) {
                let raw = try XCTUnwrap(FrameCodec.inflate(frame.payload))
                out += try Sensorlog_V1_SampleBatch(serializedBytes: raw).samples
            }
        }
        return out
    }

    /// Links hop between threads and actors, so tests wait for an outcome rather than a number of steps.
    @MainActor
    func until(_ what: String = "condition", timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }
}

extension Array where Element == Sensorlog_V1_SensorSample {
    func stream(_ id: String) -> [Sensorlog_V1_SensorSample] { filter { $0.sensorID == id }.sorted { ($0.tsMonoNs, $0.seq) < ($1.tsMonoNs, $1.seq) } }
    func events(_ id: String, _ kind: String) -> [Sensorlog_V1_SensorSample] { stream(id).filter { $0.event.kind == kind } }
}

/// A phone and a watch running the real controllers, engines and links, with a fake link and fake sensors between them.
@MainActor
final class Rig {
    let clock = FakeClock()
    let transports = FakeTransport.pair()
    let phoneRoot: StorageRoot
    let watchRoot: StorageRoot
    let accel = SensingCatalog.accelerometer
    let phoneAdapter: FakeAdapter
    var watchAdapter: FakeAdapter
    var keepAlive = FakeKeepAlive()
    var phone: RecordingController
    var phoneLink: PhoneLink
    var watch: RecordingController
    var watchLink: WatchLink
    var stopRequests: [String] = []

    static func options(watch: Bool) -> CollectionEngine.Options {
        var o = CollectionEngine.Options()
        o.manualTick = true
        o.freeBytes = { 1 << 40 }
        o.deviceKind = watch ? .watch : .phone
        return o
    }

    init(phoneRoot: StorageRoot, watchRoot: StorageRoot) {
        self.phoneRoot = phoneRoot
        self.watchRoot = watchRoot
        let clock = clock
        phoneAdapter = FakeAdapter(SensingCatalog.accelerometer)
        phone = Self.controller(root: phoneRoot, id: "phone-1", catalog: SensingCatalog.phone, adapter: phoneAdapter, watch: false, clock: clock)
        phoneLink = PhoneLink(transport: transports.phone, root: phoneRoot, engine: phone.engine, recordings: phone.recordings, clock: clock)
        watchAdapter = FakeAdapter(SensingCatalog.accelerometer)
        watch = Self.controller(root: watchRoot, id: "watch-1", catalog: SensingCatalog.watch, adapter: watchAdapter, watch: true, clock: clock)
        watchLink = WatchLink(transport: transports.watch, controller: watch, keepAlive: keepAlive, root: watchRoot, deviceId: "watch-1", clock: clock)
        phoneLink.onStopRequested = { [unowned self] in stopRequests.append($0) }
        phoneLink.activate()
        watchLink.activate()
    }

    static func controller(root: StorageRoot, id: String, catalog: [CatalogEntry], adapter: FakeAdapter, watch: Bool, clock: FakeClock) -> RecordingController {
        RecordingController(root: root, deviceId: id, catalog: catalog, adapters: [adapter],
                            device: DeviceDescription(platform: watch ? "watchos" : "ios", model: "m", os: "o", appVersion: "1", sdkVersion: "0.1", extras: watch ? ["wrist": "left"] : [:]),
                            clock: clock, options: options(watch: watch))
    }

    /// The watch's process dies. The transport, which stands for the system's WatchConnectivity, carries on, and so does a
    /// workout if the system kept it. A new process knows nothing of it until it asks.
    func relaunchWatch(workoutSurvived: Bool = false) {
        keepAlive = FakeKeepAlive()
        keepAlive.survivedCrash = workoutSurvived
        watchAdapter = FakeAdapter(SensingCatalog.accelerometer)
        watch = Self.controller(root: watchRoot, id: "watch-1", catalog: SensingCatalog.watch, adapter: watchAdapter, watch: true, clock: clock)
        watchLink = WatchLink(transport: transports.watch, controller: watch, keepAlive: keepAlive, root: watchRoot, deviceId: "watch-1", clock: clock)
        watchLink.activate()
    }

    func relaunchPhone() {
        phone = Self.controller(root: phoneRoot, id: "phone-1", catalog: SensingCatalog.phone, adapter: phoneAdapter, watch: false, clock: clock)
        phoneLink = PhoneLink(transport: transports.phone, root: phoneRoot, engine: phone.engine, recordings: phone.recordings, clock: clock)
        phoneLink.onStopRequested = { [unowned self] in stopRequests.append($0) }
        phoneLink.activate()
    }

    func recording(_ id: String = "aaaaaaaa-1111-4111-8111-111111111111", maxDurationMs: Int64 = 8 * 60 * 60 * 1000, overrides: [SensorID: SensorOverride] = [:]) -> PeerRecording {
        PeerRecording(id: id, label: "Walking", startWallMs: clock.wallMs(), maxDurationMs: maxDurationMs, overrides: overrides)
    }

    /// Runs a whole recording on the watch, with samples. Its chunks stay in the system's queue until `releaseChunks`, so a
    /// test can set up what goes wrong first.
    func recordOnWatch(_ test: XCTestCase, samples: Int64 = 50) async {
        transports.watch.holdFiles = true
        phoneLink.publish(recording: recording())
        await test.until("the watch to start") { self.watch.state == .recording }
        for _ in 0..<samples {
            clock.advance(ms: 20)
            watchAdapter.push(accel, clock: clock)
        }
        phoneLink.publish(recording: nil)
        await test.until("the watch to stop") { self.watch.state == .stopped }
        await test.until("its chunks to be queued") { await self.watchLink.drainer.status.inFlight > 0 }
    }

    /// What the watch recorded, wherever each chunk has got to. A chunk is on both devices until its ack arrives.
    func watchSamples(_ test: XCTestCase) throws -> [Sensorlog_V1_SensorSample] {
        var seen: Set<String> = []
        return try (test.samples(in: watchRoot) + test.samples(in: phoneRoot)).filter { seen.insert("\($0.sessionID)/\($0.sensorID)/\($0.seq)").inserted }
    }
}
