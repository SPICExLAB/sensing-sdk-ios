#if canImport(WatchConnectivity)
import Foundation
@preconcurrency import WatchConnectivity

/// The real link. Every payload travels as Data under one key, since the protocol above it is JSON.
public final class WCLinkTransport: NSObject, LinkTransport, WCSessionDelegate, @unchecked Sendable {
    private static let payload = "m"
    private static let chunk = "id"

    private let lock = NSLock()
    private weak var storedDelegate: (any LinkTransportDelegate)?
    private var session: WCSession { WCSession.default }

    public var delegate: (any LinkTransportDelegate)? {
        get { lock.withLock { storedDelegate } }
        set { lock.withLock { storedDelegate = newValue } }
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    public var isActivated: Bool { WCSession.isSupported() && session.activationState == .activated }
    public var isReachable: Bool { WCSession.isSupported() && session.isReachable }

    public var isCounterpartInstalled: Bool {
        guard WCSession.isSupported() else { return false }
        #if os(iOS)
        return session.isPaired && session.isWatchAppInstalled
        #else
        return session.isCompanionAppInstalled
        #endif
    }

    public var receivedContext: Data? { session.receivedApplicationContext[Self.payload] as? Data }

    public var facts: String {
        guard WCSession.isSupported() else { return "not supported" }
        #if os(iOS)
        return "state \(session.activationState.rawValue), paired \(session.isPaired), watch app \(session.isWatchAppInstalled), reachable \(session.isReachable)"
        #else
        return "state \(session.activationState.rawValue), phone app \(session.isCompanionAppInstalled), reachable \(session.isReachable)"
        #endif
    }

    public func publish(context: Data) throws {
        try session.updateApplicationContext([Self.payload: context])
    }

    public func send(message: Data, reply: (@Sendable (Data) -> Void)?, failed: (@Sendable (String) -> Void)?) {
        let replyHandler: (@Sendable ([String: Any]) -> Void)? = reply.map { reply in
            { @Sendable answer in reply(answer[Self.payload] as? Data ?? Data()) }
        }
        session.sendMessage([Self.payload: message], replyHandler: replyHandler) { error in failed?(String(describing: error)) }
    }

    public func enqueue(_ data: Data) {
        session.transferUserInfo([Self.payload: data])
    }

    public func transfer(file: URL, chunkId: String, metadata: Data) {
        session.transferFile(file, metadata: [Self.payload: metadata, Self.chunk: chunkId])
    }

    public var outstandingTransfers: Set<String> {
        Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?[Self.chunk] as? String })
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated { delegate?.linkDidActivate() }
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    /// The person switched watches. The session has to be reactivated to talk to the new one.
    public func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    public func sessionReachabilityDidChange(_ session: WCSession) { delegate?.linkDidChangeReachability() }

    public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        if let data = context[Self.payload] as? Data { delegate?.linkDidReceive(context: data) }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let data = message[Self.payload] as? Data { delegate?.linkDidReceive(message: data, reply: nil) }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let handler = replyHandler
        guard let data = message[Self.payload] as? Data else {
            handler([:])
            return
        }
        delegate?.linkDidReceive(message: data, reply: { answer in handler([Self.payload: answer]) })
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo[Self.payload] as? Data { delegate?.linkDidReceive(queued: data) }
    }

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata?[Self.payload] as? Data else { return }
        delegate?.linkDidReceive(file: file.fileURL, metadata: metadata)
    }

    public func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = fileTransfer.file.metadata?[Self.chunk] as? String else { return }
        delegate?.linkDidFinishTransfer(chunkId: id, error: error.map { String(describing: $0) })
    }
}
#endif
