import Foundation
import SensingCore
import SensingEngine
import SensingStorage

/// The phone's side of the link: publishes what the watch should do, takes its chunks, and pairs the two clocks. The watch
/// holds no state the phone can't replace: everything it needs is in one document, re-sent whenever it might have been missed.
@MainActor
public final class PhoneLink: LinkTransportDelegate {
    public struct PeerState: Sendable, Equatable {
        public var reachable = false
        public var status: PeerStatus?
        public var received: Int64 = 0
        public var refused: Int64 = 0

        public init() {}
    }

    private struct Persisted: Codable {
        var generation: Int64 = 0
        var desired: DesiredState?
    }

    public static let clockPairMs: Int64 = 60_000

    public private(set) var peer = PeerState()
    public var onStopRequested: ((String) -> Void)?
    /// Something in `peer` changed.
    public var onChange: (() -> Void)?

    public let transport: any LinkTransport
    private let receiver: ChunkReceiver
    private let engine: CollectionEngine
    private let recordings: RecordingStore
    private let clock: any EngineClock
    private let stateURL: URL
    private var persisted = Persisted()
    private var lastPairMs: Int64 = 0
    private var pairing = false

    public init(transport: any LinkTransport, root: StorageRoot, engine: CollectionEngine, recordings: RecordingStore, clock: any EngineClock = SystemClock()) {
        self.transport = transport
        self.engine = engine
        self.recordings = recordings
        self.clock = clock
        receiver = ChunkReceiver(root: root)
        stateURL = root.state.appendingPathComponent("phone_link.json")
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(Persisted.self, from: data) { persisted = saved }
    }

    public func activate() {
        transport.delegate = self
        transport.activate()
        peer.reachable = transport.isReachable
        drainIncoming()  // what a crash left behind
    }

    /// Whether the watch app is there can't be known until the session has activated, which takes a moment after launch. Waits
    /// at most `timeoutMs`. By the time this is called the phone is recording already, so this delays only the watch.
    public func waitUntilActive(timeoutMs: Int64 = 2000) async {
        var waited: Int64 = 0
        while !transport.isActivated, waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
    }

    public var desired: DesiredState? { persisted.desired }
    private var recordingId: String? { persisted.desired?.recording?.id }

    public func publish(recording: PeerRecording?) {
        persisted.generation += 1
        let state = DesiredState(generation: persisted.generation, recording: recording)
        persisted.desired = state
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: stateURL, options: .atomic)
            StorageRoot.protectFile(stateURL)
        }
        deliver(state)
    }

    /// At launch, once recovery has finished: a recording the watch was told about that no longer runs here has ended.
    public func reconcile(activeRecordingId: String?) {
        guard let published = recordingId, published != activeRecordingId else { return }
        publish(recording: nil)
    }

    /// Call about once a second while recording.
    public func tick() async {
        guard recordingId != nil, clock.monoNs() / 1_000_000 - lastPairMs >= Self.clockPairMs else { return }
        await pairClock()
    }

    /// At start, at stop, every minute and when reachability changes. Waits at most 2 s, because Stop waits for it.
    public func pairClock() async {
        guard recordingId != nil, transport.isReachable, !pairing else { return }
        pairing = true
        defer { pairing = false }
        lastPairMs = clock.monoNs() / 1_000_000
        let sentMono = clock.monoNs()
        let sentWall = clock.wallMs()
        let transport = transport
        let reply: Data? = await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            transport.send(message: LinkMessage.clockPing.encoded(), reply: { once.resume($0) }, failed: { _ in once.resume(nil) })
            Task {
                try? await Task.sleep(for: .seconds(2))
                once.resume(nil)
            }
        }
        let repliedMono = clock.monoNs()
        guard let reply, case .clockReply(let device, let mono, let wall) = LinkMessage.decode(reply) else { return }
        await engine.emit(SensorIDs.clock, "peer_clock", PeerClock.attributes(peer: device, peerMonoNs: mono, peerWallMs: wall, sentMonoNs: sentMono, sentWallMs: sentWall, repliedMonoNs: repliedMono))
    }

    /// Chunks the watch said it recorded that aren't here.
    public func missingPeerChunks(recordingId: String) async -> [String] {
        guard let peer = recordings.find(id: recordingId)?.peer else { return [] }
        let present = Set(await engine.chunks().map(\.chunkId))
        return peer.chunkIds.filter { !present.contains($0) }
    }

    private func deliver(_ state: DesiredState) {
        guard let context = try? JSONEncoder().encode(state) else { return }
        // Throws before activation. `linkDidActivate` publishes it then.
        try? transport.publish(context: context)
        if transport.isReachable { transport.send(message: LinkMessage.desired(state).encoded(), reply: nil, failed: nil) }
    }

    private func drainIncoming() {
        receiver.drain { processed in
            Task { @MainActor [weak self] in await self?.finish(processed) }
        }
    }

    private func finish(_ processed: ChunkReceiver.Processed) async {
        if let record = processed.adopted {
            await engine.adopt(record)
            noteEngineSession(record.sessionId)
        }
        if processed.ack.result == ChunkAck.ok { peer.received += 1 } else { peer.refused += 1 }
        let ack = LinkMessage.ack(processed.ack).encoded()
        // Queued so it can't be lost, and sent now so that it usually arrives sooner.
        transport.enqueue(ack)
        if transport.isReachable { transport.send(message: ack, reply: nil, failed: nil) }
        onChange?()
    }

    private func noteEngineSession(_ session: String) {
        guard let id = recordingId, var r = recordings.find(id: id), !(r.peerEngineSessions ?? []).contains(session), !r.engineSessions.contains(session) else { return }
        r.peerEngineSessions = (r.peerEngineSessions ?? []) + [session]
        try? recordings.save(r)
    }

    private func handle(_ message: LinkMessage) {
        switch message {
        case .stopRequest(let id):
            onStopRequested?(id)
        case .status(let status):
            peer.status = status
            if let session = status.engineSession { noteEngineSession(session) }
            onChange?()
        case .summary(let summary):
            guard var r = recordings.find(id: summary.recordingId) else { return }
            r.peer = summary
            r.peerEngineSessions = summary.engineSessions
            try? recordings.save(r)
            onChange?()
        case .desired, .ack, .clockPing, .clockReply:
            break
        }
    }

    // MARK: - LinkTransportDelegate

    public nonisolated func linkDidActivate() {
        Task { @MainActor in
            if let state = persisted.desired { deliver(state) }
        }
    }

    public nonisolated func linkDidChangeReachability() {
        Task { @MainActor in
            peer.reachable = transport.isReachable
            onChange?()
            await pairClock()
        }
    }

    public nonisolated func linkDidReceive(context: Data) {}

    public nonisolated func linkDidReceive(message: Data, reply: (@Sendable (Data) -> Void)?) {
        reply?(Data())
        guard let decoded = LinkMessage.decode(message) else { return }
        Task { @MainActor in handle(decoded) }
    }

    public nonisolated func linkDidReceive(queued: Data) {
        guard let decoded = LinkMessage.decode(queued) else { return }
        Task { @MainActor in handle(decoded) }
    }

    public nonisolated func linkDidReceive(file: URL, metadata: Data) {
        guard receiver.accept(file: file, metadata: metadata) else { return }  // no ack, so the watch sends it again
        Task { @MainActor in drainIncoming() }
    }

    public nonisolated func linkDidFinishTransfer(chunkId: String, error: String?) {}
}
