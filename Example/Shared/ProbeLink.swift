import CryptoKit
import Foundation
@preconcurrency import WatchConnectivity

/// Phase 1's bare phone-watch link: desired state one way and whole files the other. The real one comes in Phase 5.
final class ProbeLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = ProbeLink()

    var onContext: (@Sendable ([String: Any]) -> Void)?
    var onMessage: (@Sendable ([String: Any]) -> Void)?
    /// A note on a file received or sent, for the run's log and the screen.
    var onTransfer: (@Sendable (String) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var receivedContext: [String: Any] { WCSession.default.receivedApplicationContext }
    var isReachable: Bool { WCSession.default.isReachable }

    func publish(_ context: [String: Any]) {
        try? WCSession.default.updateApplicationContext(context)
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(context, replyHandler: nil) { [weak self] e in self?.onTransfer?("sendMessage failed: \(e)") }
        }
    }

    func send(file url: URL, run: String) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let meta: [String: Any] = ["run": run, "file": url.lastPathComponent, "size": Int64(data.count), "sha256": sha, "sent_wall_ms": Int64(Date().timeIntervalSince1970 * 1000)]
        WCSession.default.transferFile(url, metadata: meta)
        onTransfer?("sending \(url.lastPathComponent) \(data.count) bytes, outstanding \(WCSession.default.outstandingFileTransfers.count)")
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
    #endif

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) { onContext?(context) }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { onMessage?(message) }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = fileTransfer.file.fileURL.lastPathComponent
        onTransfer?(error.map { "transfer of \(name) failed: \($0)" } ?? "transfer of \(name) finished")
    }

    /// The file disappears when this returns, so it's moved here, synchronously.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let meta = file.metadata ?? [:]
        let run = meta["run"] as? String ?? "unknown"
        let name = meta["file"] as? String ?? file.fileURL.lastPathComponent
        let dir = ProbeFiles.runs.appendingPathComponent("watch-\(run)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: ProbeFiles.protection)
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: dest)
        } catch {
            onTransfer?("receive of \(name) failed: \(error)")
            return
        }
        let data = (try? Data(contentsOf: dest, options: .mappedIfSafe)) ?? Data()
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ok = sha == (meta["sha256"] as? String)
        let sent = meta["sent_wall_ms"] as? Int64 ?? 0
        let tookMs = Int64(Date().timeIntervalSince1970 * 1000) - sent
        let note = "file=\(name) bytes=\(data.count) sha_ok=\(ok) took_ms=\(tookMs)\n"
        let log = dir.appendingPathComponent("transfers.txt")
        if let h = try? FileHandle(forWritingTo: log) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(note.utf8))
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: log.path, contents: Data(note.utf8), attributes: ProbeFiles.protection)
        }
        onTransfer?("received \(note)")
    }
}

extension ProbeLink {
    /// The watch asks the phone to stop both devices. If the phone can't be reached, the watch has stopped anyway.
    func publishRequestStop() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["request": "stop"], replyHandler: nil, errorHandler: nil)
    }
}
