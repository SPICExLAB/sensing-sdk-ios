import Foundation
import SensingEngine
import SensingStorage

/// The watch's route off the device: `transferFile` to the phone, then the phone's ack. Android's `PhoneRelayTransport`.
///
/// WatchConnectivity holds a transfer across this app's death, so a chunk already in its queue isn't sent twice. An ack can
/// arrive before the transfer's own completion, or after this app gave up waiting, and either way it still counts.
public final class PhoneRelayUploader: ChunkUploader, @unchecked Sendable {
    public static let ackTimeoutMs: Int64 = 10 * 60 * 1000
    private static let maxRememberedAcks = 1000

    public let name = "phone_relay"

    private struct AckWait {
        var continuation: OnceResume<ChunkStep>
        var deadlineMs: Int64
    }

    private let transport: any LinkTransport
    private let nowMs: @Sendable () -> Int64
    private let lock = NSLock()
    private var finishWaits: [String: OnceResume<ChunkStep>] = [:]
    private var ackWaits: [String: AckWait] = [:]
    private var acks: [String: String] = [:]
    private var pendingMetadata: [String: Data] = [:]

    public init(transport: any LinkTransport, nowMs: @escaping @Sendable () -> Int64) {
        self.transport = transport
        self.nowMs = nowMs
    }

    public func initiate(_ chunk: ChunkRecord) async -> ChunkInit {
        let alreadyAcked = lock.withLock { () -> Bool in
            guard acks[chunk.chunkId] == ChunkAck.ok else { return false }
            acks[chunk.chunkId] = nil
            return true
        }
        if alreadyAcked { return .alreadyHave }
        guard transport.isActivated else { return .unavailable("link not active") }
        guard transport.isCounterpartInstalled else { return .unavailable("no phone app") }
        guard let metadata = try? JSONEncoder().encode(chunk) else { return .failed("metadata") }
        lock.withLock { pendingMetadata[chunk.chunkId] = metadata }
        return .ready(handle: chunk.chunkId)
    }

    public func upload(handle chunkId: String, file: URL, fromOffset: Int64) async -> ChunkStep {
        await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            let (answered, metadata) = lock.withLock { () -> (Bool, Data?) in
                if acks[chunkId] != nil { return (true, nil) }
                finishWaits[chunkId] = once
                defer { pendingMetadata[chunkId] = nil }
                return (false, pendingMetadata[chunkId])
            }
            if answered {
                once.resume(.ok)
            } else if !transport.outstandingTransfers.contains(chunkId) {
                guard let metadata else {
                    finished(chunkId: chunkId, error: "metadata")
                    return
                }
                transport.transfer(file: file, chunkId: chunkId, metadata: metadata)
            }
        }
    }

    public func commit(_ chunk: ChunkRecord, handle chunkId: String) async -> ChunkStep {
        await withCheckedContinuation { continuation in
            let once = OnceResume(continuation)
            let answered = lock.withLock { () -> String? in
                if let result = acks[chunkId] {
                    acks[chunkId] = nil
                    return result
                }
                ackWaits[chunkId] = AckWait(continuation: once, deadlineMs: nowMs() + Self.ackTimeoutMs)
                return nil
            }
            if let answered { once.resume(Self.step(answered)) }
        }
    }

    public func finished(chunkId: String, error: String?) {
        let wait = lock.withLock { () -> OnceResume<ChunkStep>? in
            defer { finishWaits[chunkId] = nil }
            return finishWaits[chunkId]
        }
        wait?.resume(error.map { .failed("transfer: \($0)") } ?? .ok)
    }

    /// Every ack arrives twice, by message and by queue. So one with no attempt in flight is either a duplicate or late: a late
    /// `ok` still counts, but a `bad` says nothing about the next attempt, and keeping it would fail that attempt unsent.
    public func received(_ ack: ChunkAck) {
        let (finish, wait) = lock.withLock { () -> (OnceResume<ChunkStep>?, AckWait?) in
            let finish = finishWaits.removeValue(forKey: ack.chunkId)
            let wait = ackWaits.removeValue(forKey: ack.chunkId)
            if wait == nil, finish != nil || ack.result == ChunkAck.ok {
                if acks.count >= Self.maxRememberedAcks { acks.removeAll() }  // the worst this costs is one needless resend
                acks[ack.chunkId] = ack.result
            }
            return (finish, wait)
        }
        // The ack means the bytes arrived, whatever the transfer's own callback has said so far.
        finish?.resume(.ok)
        wait?.continuation.resume(Self.step(ack.result))
    }

    /// Call now and then: no ack this long after the transfer finished means it gets sent again.
    public func expireAcks() {
        let now = nowMs()
        let late = lock.withLock { () -> [OnceResume<ChunkStep>] in
            let due = ackWaits.filter { $0.value.deadlineMs <= now }
            due.keys.forEach { ackWaits[$0] = nil }
            return due.values.map(\.continuation)
        }
        late.forEach { $0.resume(.failed("no ack")) }
    }

    private static func step(_ result: String) -> ChunkStep { result == ChunkAck.ok ? .ok : .failed(result) }
}
