import Foundation
import SensingCore
import SensingEngine
import SensingStorage

/// What keeps the watch's app alive with the screen off.
public protocol WatchKeepAlive: AnyObject, Sendable {
    var isRunning: Bool { get }
    func start() throws
    func stop()
    /// Reattaches to a session the system kept running after this app died. Returns whether there was one.
    func recover() async throws -> Bool
}

/// The watch's side of the link. It does what the newest published state says, and nothing in its write path depends on the
/// phone: with the link down it keeps recording, until the state arrives, its Stop button, or the time limit.
@MainActor
public final class WatchLink: LinkTransportDelegate {
    private struct Persisted: Codable {
        var generation: Int64 = 0
    }

    public static let statusMs: Int64 = 5000
    public static let drainMs: Int64 = 5000
    /// The phone opened this app to record, and then never said what.
    public static let orphanWorkoutMs: Int64 = 60_000

    public var onChange: (() -> Void)?
    public let controller: RecordingController
    public let drainer: ChunkDrainer

    private let transport: any LinkTransport
    private let uploader: PhoneRelayUploader
    private let keepAlive: any WatchKeepAlive
    private let deviceId: String
    private let clock: any EngineClock
    private let stateURL: URL
    private let commands = CommandQueue()
    private let batteryPct: @Sendable () -> Int64?
    private var persisted = Persisted()
    private var lastStatusMs: Int64 = 0
    private var lastDrainMs: Int64 = 0
    private var workoutLaunchMs: Int64?
    private var prepared = false
    /// What arrived before `prepare`: nothing starts until recovery has finished.
    private var heldState: DesiredState?

    public init(transport: any LinkTransport, controller: RecordingController, keepAlive: any WatchKeepAlive, root: StorageRoot, deviceId: String,
                clock: any EngineClock = SystemClock(), batteryPct: @escaping @Sendable () -> Int64? = { nil }) {
        self.transport = transport
        self.controller = controller
        self.keepAlive = keepAlive
        self.deviceId = deviceId
        self.clock = clock
        self.batteryPct = batteryPct
        let nowMs: @Sendable () -> Int64 = { clock.monoNs() / 1_000_000 }
        uploader = PhoneRelayUploader(transport: transport, nowMs: nowMs)
        drainer = ChunkDrainer(uploader: uploader, source: controller.engine, nowMs: nowMs)
        stateURL = root.state.appendingPathComponent("watch_link.json")
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(Persisted.self, from: data) { persisted = saved }
        controller.onEnded = { [weak self] summary in
            guard let self else { return }
            Task { @MainActor in await self.ended(summary) }
        }
    }

    public var isReachable: Bool { transport.isReachable }

    public func activate() {
        transport.delegate = self
        transport.activate()
    }

    /// At launch, before anything else runs: finishes what a dead process left, then does what the phone last asked.
    public func prepare() async {
        guard !prepared else { return }
        prepared = true
        try? await commands.run { [self] in
            // The settings of a recording this resumes are in the published state.
            let context = transport.receivedContext.flatMap { try? JSONDecoder().decode(DesiredState.self, from: $0) }
            let latest = [context, heldState].compactMap { $0 }.max { $0.generation < $1.generation }
            heldState = nil
            if let overrides = latest?.recording?.sensorOverrides { controller.overrides = overrides }
            let alreadyStarted = keepAlive.isRunning  // the phone opened this app, and the workout has begun
            let resumed = alreadyStarted ? false : ((try? await keepAlive.recover()) ?? false)
            await controller.recover(resuming: resumed && controller.recordings.unfinished != nil)
            if resumed && controller.state == .stopped { keepAlive.stop() }  // a workout with no recording to go with it
            if let latest { await applyNow(latest) }
            await drainer.tick()
        }
        onChange?()
    }

    /// The phone opened this app through `startWatchApp`. The workout has to begin at once, so it isn't waiting on anything.
    public func workoutLaunched() { workoutLaunchMs = clock.monoNs() / 1_000_000 }

    /// The Stop button. This device stops now, whether or not the phone can be reached, and the phone hears when it can.
    public func stopPressed() async {
        if let id = controller.current?.id {
            let request = LinkMessage.stopRequest(recordingId: id).encoded()
            transport.enqueue(request)
            if transport.isReachable { transport.send(message: request, reply: nil, failed: nil) }
        }
        await controller.stop(reason: "watch_stop")
    }

    /// Something went wrong with the workout. Without it this app gets suspended, so it stops cleanly while it can.
    public func keepAliveFailed(_ detail: String) async {
        guard controller.state == .recording else { return }
        await controller.engine.emit(SensorIDs.health, "keepalive_lost", ["detail": detail])
        await controller.stop(reason: "keepalive_lost")
    }

    public func note(_ kind: String, _ detail: String) async {
        await controller.engine.emit(SensorIDs.health, kind, ["detail": detail])
    }

    /// Call about once a second.
    public func tick() async {
        let now = clock.monoNs() / 1_000_000
        await controller.tick()
        if let launched = workoutLaunchMs, now - launched >= Self.orphanWorkoutMs {
            workoutLaunchMs = nil
            if controller.state == .stopped { keepAlive.stop() }
        }
        if now - lastDrainMs >= Self.drainMs {
            lastDrainMs = now
            uploader.expireAcks()
            await drainer.tick()
        }
        if controller.state == .recording, transport.isReachable, now - lastStatusMs >= Self.statusMs {
            lastStatusMs = now
            await sendStatus()
        }
    }

    private func applyNow(_ state: DesiredState) async {
        guard state.generation > persisted.generation else { return }
        persisted.generation = state.generation
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: stateURL, options: .atomic)
            StorageRoot.protectFile(stateURL)
        }
        guard let wanted = state.recording else {
            await controller.stop(reason: "phone_stop")
            workoutLaunchMs = nil
            if controller.state == .stopped { keepAlive.stop() }
            return
        }
        if let running = controller.current {
            if running.id == wanted.id { return }
            await controller.stop(reason: "superseded")
        }
        // Published long ago, and this app has only just heard. It's over.
        guard clock.wallMs() - wanted.startWallMs < wanted.maxDurationMs, controller.recordings.find(id: wanted.id) == nil else {
            if workoutLaunchMs != nil { keepAlive.stop() }
            workoutLaunchMs = nil
            return
        }
        var failure: String?
        do {
            try keepAlive.start()
        } catch {
            failure = String(describing: error)
        }
        controller.overrides = wanted.sensorOverrides
        workoutLaunchMs = nil
        do {
            try await controller.start(RecordingSpec(id: wanted.id, label: wanted.label, maxDurationMs: wanted.maxDurationMs), mirroredStartWallMs: wanted.startWallMs)
        } catch {
            keepAlive.stop()
            return
        }
        if let failure { await controller.engine.emit(SensorIDs.health, "keepalive_failed", ["detail": failure]) }
        await sendStatus()
    }

    private func ended(_ summary: RecordingSummary) async {
        keepAlive.stop()
        let chunks = await controller.engine.chunks().filter { summary.engineSessions.contains($0.sessionId) }
        let peer = PeerSummary(recordingId: summary.id, deviceId: deviceId, endReason: summary.endReason ?? "", engineSessions: summary.engineSessions, chunkIds: chunks.map(\.chunkId))
        transport.enqueue(LinkMessage.summary(peer).encoded())
        lastDrainMs = clock.monoNs() / 1_000_000
        await drainer.tick()
        onChange?()
    }

    private func sendStatus() async {
        let stats = await controller.engine.stats()
        let drain = await drainer.status
        let status = PeerStatus(recordingId: controller.current?.id, engineSession: stats.sessionId, hz: stats.streams.mapValues(\.hz),
                                chunksWaiting: drain.waiting, chunksInFlight: drain.inFlight, dropped: stats.dropped, batteryPct: batteryPct())
        transport.send(message: LinkMessage.status(status).encoded(), reply: nil, failed: nil)
    }

    private func enqueue(_ state: DesiredState) {
        guard prepared else {
            if state.generation > heldState?.generation ?? 0 { heldState = state }
            return
        }
        Task { @MainActor in
            try? await commands.run { [self] in await applyNow(state) }
            onChange?()
        }
    }

    private func handle(_ message: LinkMessage) {
        switch message {
        case .desired(let state):
            enqueue(state)
        case .ack(let ack):
            uploader.received(ack)
        case .stopRequest, .clockPing, .clockReply, .status, .summary:
            break
        }
    }

    // MARK: - LinkTransportDelegate

    public nonisolated func linkDidActivate() {
        guard let context = transport.receivedContext, let state = try? JSONDecoder().decode(DesiredState.self, from: context) else { return }
        Task { @MainActor in enqueue(state) }
    }

    public nonisolated func linkDidChangeReachability() {
        Task { @MainActor in onChange?() }
    }

    public nonisolated func linkDidReceive(context: Data) {
        guard let state = try? JSONDecoder().decode(DesiredState.self, from: context) else { return }
        Task { @MainActor in enqueue(state) }
    }

    public nonisolated func linkDidReceive(message: Data, reply: (@Sendable (Data) -> Void)?) {
        guard let decoded = LinkMessage.decode(message) else {
            reply?(Data())
            return
        }
        // Answered here, with no hop, so that the round trip measures the link and not this app's main thread.
        if case .clockPing = decoded {
            reply?(LinkMessage.clockReply(deviceId: deviceId, monoNs: clock.monoNs(), wallMs: clock.wallMs()).encoded())
            return
        }
        reply?(Data())
        Task { @MainActor in handle(decoded) }
    }

    public nonisolated func linkDidReceive(queued: Data) {
        guard let decoded = LinkMessage.decode(queued) else { return }
        Task { @MainActor in handle(decoded) }
    }

    public nonisolated func linkDidReceive(file: URL, metadata: Data) {}

    public nonisolated func linkDidFinishTransfer(chunkId: String, error: String?) {
        uploader.finished(chunkId: chunkId, error: error)
    }
}
