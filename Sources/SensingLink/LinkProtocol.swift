import Foundation
import SensingCore
import SensingEngine
import SensingStorage

/// What the phone wants the watch to record.
public struct PeerRecording: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var startWallMs: Int64
    public var maxDurationMs: Int64
    public var overrides: [String: SensorOverride]

    public init(id: String, label: String, startWallMs: Int64, maxDurationMs: Int64, overrides: [SensorID: SensorOverride] = [:]) {
        self.id = id
        self.label = label
        self.startWallMs = startWallMs
        self.maxDurationMs = maxDurationMs
        self.overrides = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.value, $0.value) })
    }

    public var sensorOverrides: [SensorID: SensorOverride] {
        var out: [SensorID: SensorOverride] = [:]
        for (key, value) in overrides {
            if let id = SensorID(key) { out[id] = value }
        }
        return out
    }
}

/// The phone's whole wish, published as one document. The channels can reorder, so the watch applies only the newest
/// generation.
public struct DesiredState: Codable, Sendable, Equatable {
    public var generation: Int64
    public var recording: PeerRecording?

    public init(generation: Int64, recording: PeerRecording?) {
        self.generation = generation
        self.recording = recording
    }
}

public struct ChunkAck: Codable, Sendable, Equatable {
    public static let ok = "ok"

    public var chunkId: String
    /// "ok" or "bad:<reason>", as on Android.
    public var result: String

    public init(chunkId: String, result: String) {
        self.chunkId = chunkId
        self.result = result
    }

    public static func bad(_ chunkId: String, _ reason: String) -> ChunkAck { ChunkAck(chunkId: chunkId, result: "bad:\(reason)") }
}

/// What the watch reports while it's reachable, for the phone's screen.
public struct PeerStatus: Codable, Sendable, Equatable {
    public var recordingId: String?
    public var engineSession: String?
    public var hz: [String: Double]
    public var chunksWaiting: Int64
    public var chunksInFlight: Int64
    public var dropped: Int64
    public var batteryPct: Int64?

    public init(recordingId: String?, engineSession: String?, hz: [String: Double], chunksWaiting: Int64, chunksInFlight: Int64, dropped: Int64, batteryPct: Int64?) {
        self.recordingId = recordingId
        self.engineSession = engineSession
        self.hz = hz
        self.chunksWaiting = chunksWaiting
        self.chunksInFlight = chunksInFlight
        self.dropped = dropped
        self.batteryPct = batteryPct
    }
}

public enum LinkMessage: Codable, Sendable, Equatable {
    case desired(DesiredState)
    case ack(ChunkAck)
    /// The watch's Stop button: stop both devices.
    case stopRequest(recordingId: String)
    case clockPing
    case clockReply(deviceId: String, monoNs: Int64, wallMs: Int64)
    case status(PeerStatus)
    /// Everything the watch recorded, after it stopped, so the phone can see what's missing.
    case summary(PeerSummary)

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> LinkMessage? { try? JSONDecoder().decode(LinkMessage.self, from: data) }
}

public protocol LinkTransportDelegate: AnyObject, Sendable {
    func linkDidActivate()
    func linkDidChangeReachability()
    func linkDidReceive(context: Data)
    func linkDidReceive(message: Data, reply: (@Sendable (Data) -> Void)?)
    func linkDidReceive(queued: Data)
    /// The file disappears when this returns, so it has to be moved before then.
    func linkDidReceive(file: URL, metadata: Data)
    func linkDidFinishTransfer(chunkId: String, error: String?)
}

/// WatchConnectivity's five channels, behind a protocol so that the whole protocol above it runs against a fake on macOS.
public protocol LinkTransport: AnyObject, Sendable {
    var delegate: (any LinkTransportDelegate)? { get set }
    func activate()
    var isActivated: Bool { get }
    var isReachable: Bool { get }
    /// The other device has this app installed.
    var isCounterpartInstalled: Bool { get }
    var receivedContext: Data? { get }
    /// `updateApplicationContext`: only the latest survives, delivered when it can be.
    func publish(context: Data) throws
    /// `sendMessage`: now or never.
    func send(message: Data, reply: (@Sendable (Data) -> Void)?, failed: (@Sendable (String) -> Void)?)
    /// `transferUserInfo`: queued and delivered in order, across launches.
    func enqueue(_ data: Data)
    /// `transferFile`: queued, and survives this app's death.
    func transfer(file: URL, chunkId: String, metadata: Data)
    var outstandingTransfers: Set<String> { get }
    /// A line for a diagnostics screen.
    var facts: String { get }
}

/// `device.clock peer_clock` at the middle of a round trip, which removes the transit bias of Android's one-way hello. The
/// required attributes are Android's, `rtt_ns` is additive.
public enum PeerClock {
    public static func attributes(peer: String, peerMonoNs: Int64, peerWallMs: Int64, sentMonoNs: Int64, sentWallMs: Int64, repliedMonoNs: Int64) -> [String: String] {
        let rtt = repliedMonoNs - sentMonoNs
        return ["peer": peer, "peer_mono_ns": String(peerMonoNs), "peer_wall_ms": String(peerWallMs),
                "mono_ns": String(sentMonoNs + rtt / 2), "wall_ms": String(sentWallMs + rtt / 2 / 1_000_000), "rtt_ns": String(rtt)]
    }
}

/// Resumes a continuation at most once, whichever of a reply, a failure or a timeout comes first.
final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
