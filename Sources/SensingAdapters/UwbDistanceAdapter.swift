#if os(iOS) || os(watchOS)
import Foundation
@preconcurrency import NearbyInteraction
import SensingCore
import SensingProto

/// `device.peer_distance`: metres between iPhone and watch, by UWB time of flight. Both devices run a session, each given the
/// other's discovery token over the link, and each records what it measures.
///
/// iOS suspends a session in several situations, and a locked phone may well be one. Suspensions are recorded, so a recording says
/// exactly when it had no distance rather than leaving an unexplained hole.
public final class UwbDistanceAdapter: NSObject, SensorAdapter, NISessionDelegate, @unchecked Sendable {
    public let sensors = [SensingCatalog.peerDistance]
    private static let resendSeconds = 5

    private let relay: PeerTokenRelay
    private let queue = DispatchQueue(label: "sensing.uwb", qos: .utility)
    // All touched only on `queue`.
    private var session: NISession?
    private var peerToken: NIDiscoveryToken?
    private var resend: DispatchSourceTimer?
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var decimator = Decimator(periodUs: 1_000_000)

    public init(relay: PeerTokenRelay) { self.relay = relay }

    public func availability(of sensor: SensorID) -> Availability {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement ? .available : .missingHardware
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.peerDistance] else { return }
        let periodUs = settings[SensingCatalog.peerDistance]?.samplingPeriodUs ?? 1_000_000
        relay.onReceive { [weak self] token in
            self?.queue.async { self?.received(token) }
        }
        queue.async { [self] in
            self.sink = sink
            self.clock = clock
            decimator = Decimator(periodUs: periodUs)
            peerToken = nil
            begin()
        }
    }

    public func stop() {
        relay.onReceive(nil)
        queue.sync {
            stopResending()
            session?.invalidate()
            session = nil
            sink = nil
            clock = nil
        }
    }

    private func begin() {
        let s = NISession()
        s.delegate = self
        s.delegateQueue = queue
        session = s
        sendToken()
        startResending()
        if let peerToken { run(peerToken) }
    }

    private func sendToken() {
        guard let token = session?.discoveryToken, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        relay.send(data)
    }

    /// Until distances arrive: the other device may not have been listening yet.
    private func startResending() {
        stopResending()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(Self.resendSeconds), repeating: .seconds(Self.resendSeconds))
        t.setEventHandler { [weak self] in self?.sendToken() }
        resend = t
        t.resume()
    }

    private func stopResending() {
        resend?.cancel()
        resend = nil
    }

    private func received(_ data: Data) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data), token != peerToken else { return }
        peerToken = token
        run(token)
    }

    private func run(_ token: NIDiscoveryToken) {
        session?.run(NINearbyPeerConfiguration(peerToken: token))
    }

    private func note(_ kind: String, _ attrs: [String: String] = [:]) {
        guard let sink, let clock else { return }
        sink.event(kind, attrs, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
    }

    // MARK: - NISessionDelegate

    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        stopResending()
        guard let sink, let clock, let distance = nearbyObjects.first?.distance else { return }
        let mono = clock.monoNs()
        guard decimator.take(tsNs: mono) else { return }
        sink.scalar(distance, tsMonoNs: mono, tsWallMs: clock.wallMs(), accuracy: .high)
    }

    public func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        note("peer_lost", ["reason": reason == .peerEnded ? "peer_ended" : "timeout"])
        // The other side's session may have gone: its new token has to come round again.
        peerToken = nil
        sendToken()
        startResending()
    }

    public func sessionWasSuspended(_ session: NISession) { note("suspended") }

    public func sessionSuspensionEnded(_ session: NISession) {
        note("resumed")
        if let peerToken { run(peerToken) }
    }

    public func session(_ session: NISession, didInvalidateWith error: Error) {
        guard self.session === session else { return }
        note("invalidated", ["reason": String((error as NSError).code)])
        begin()
    }
}
#endif
