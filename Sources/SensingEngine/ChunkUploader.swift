import Foundation
import SensingStorage

public enum ChunkInit: Sendable, Equatable {
    /// The far side will take the bytes; `resumeFrom` is how many it already holds.
    case ready(handle: String, resumeFrom: Int64 = 0)
    /// It already has this chunk: nothing to send.
    case alreadyHave
    /// No route right now. Ends the attempt and costs the chunk nothing.
    case unavailable(String)
    case failed(String)
}

public enum ChunkStep: Sendable, Equatable {
    case ok
    case failed(String)
}

/// The durable path off a device: initiate, upload, commit. Android's `UploadTransport`, and the seam where a cloud uploader
/// plugs in later. The watch's route to the phone is an implementation, so the seam stays exercised.
public protocol ChunkUploader: Sendable {
    var name: String { get }
    func initiate(_ chunk: ChunkRecord) async -> ChunkInit
    func upload(handle: String, file: URL, fromOffset: Int64) async -> ChunkStep
    func commit(_ chunk: ChunkRecord, handle: String) async -> ChunkStep
}

/// Where a drainer finds what to send, and what it deletes once it's safely elsewhere.
public protocol ChunkSource: Sendable {
    func sealedChunks() async -> [ChunkRecord]
    func fileURL(of chunk: ChunkRecord) async -> URL
    func remove(_ chunk: ChunkRecord) async
}

extension CollectionEngine: ChunkSource {
    public func sealedChunks() -> [ChunkRecord] { chunks() }
    public func fileURL(of chunk: ChunkRecord) -> URL { fileURL(for: chunk) }
    public func remove(_ chunk: ChunkRecord) { delete(chunk) }
}

/// A failed chunk waits 30 s, doubling to an hour, with ±20% so that many chunks don't retry together.
public enum RetrySchedule {
    public static let baseMs: Int64 = 30_000
    public static let capMs: Int64 = 3_600_000

    public static func delayMs(failures: Int64, jitter: Double) -> Int64 {
        let doubled = min(capMs, baseMs << min(max(failures - 1, 0), 17))
        return Int64(Double(doubled) * (0.8 + 0.4 * jitter))
    }
}

/// Sends sealed chunks through an uploader, a few at a time, and deletes each only after the far side has it.
///
/// An actor with suspension points, so state can change across any `await`. That's the re-entrancy bug class that hit
/// Android's engine, so nothing here trusts what it read before suspending: `tick` works from a snapshot, and a chunk stays
/// in `inFlight` until its file is gone.
public actor ChunkDrainer {
    public struct Status: Sendable, Equatable {
        public var waiting: Int64 = 0
        public var inFlight: Int64 = 0
        public var delivered: Int64 = 0
        public var lastFailure: String?

        public init() {}
    }

    private struct Attempts {
        var failures: Int64 = 0
        var nextMs: Int64 = 0
    }

    private enum Outcome {
        case delivered
        case unavailable(String)
        case failed(String)
    }

    private let uploader: any ChunkUploader
    private let source: any ChunkSource
    private let nowMs: @Sendable () -> Int64
    private let jitter: @Sendable () -> Double
    private let maxConcurrent: Int64
    private var attempts: [String: Attempts] = [:]
    private var inFlight: Set<String> = []
    private var finished: Set<String> = []
    private var running: [String: Task<Void, Never>] = [:]
    private var ticking = false
    private var current = Status()

    public static let unavailableRetryMs: Int64 = 30_000

    public init(uploader: any ChunkUploader, source: any ChunkSource, nowMs: @escaping @Sendable () -> Int64, maxConcurrent: Int64 = 4,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.uploader = uploader
        self.source = source
        self.nowMs = nowMs
        self.maxConcurrent = maxConcurrent
        self.jitter = jitter
    }

    public var status: Status { current }

    /// Starts whatever is due, without waiting for it to finish.
    public func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let sealed = await source.sealedChunks()
        let now = nowMs()
        var waiting: Int64 = 0
        for chunk in sealed where !finished.contains(chunk.chunkId) {
            waiting += 1
            guard !inFlight.contains(chunk.chunkId), Int64(inFlight.count) < maxConcurrent, attempts[chunk.chunkId, default: Attempts()].nextMs <= now else { continue }
            inFlight.insert(chunk.chunkId)
            running[chunk.chunkId] = Task { await self.send(chunk) }
        }
        current.waiting = waiting
        current.inFlight = Int64(inFlight.count)
    }

    /// Waits for everything started so far. For tests, and for winding down.
    public func settle() async {
        while let task = running.values.first {
            await task.value
        }
    }

    private func send(_ chunk: ChunkRecord) async {
        let file = await source.fileURL(of: chunk)
        let outcome = await Self.attempt(chunk, file: file, through: uploader)
        switch outcome {
        case .delivered:
            await source.remove(chunk)
            finished.insert(chunk.chunkId)
            attempts[chunk.chunkId] = nil
            current.delivered += 1
            current.waiting = max(current.waiting - 1, 0)
        case .unavailable:
            attempts[chunk.chunkId, default: Attempts()].nextMs = nowMs() + Self.unavailableRetryMs
        case .failed(let reason):
            var a = attempts[chunk.chunkId, default: Attempts()]
            a.failures += 1
            a.nextMs = nowMs() + RetrySchedule.delayMs(failures: a.failures, jitter: jitter())
            attempts[chunk.chunkId] = a
            current.lastFailure = "\(chunk.chunkId): \(reason)"
        }
        inFlight.remove(chunk.chunkId)
        running[chunk.chunkId] = nil
        current.inFlight = Int64(inFlight.count)
    }

    private static func attempt(_ chunk: ChunkRecord, file: URL, through uploader: any ChunkUploader) async -> Outcome {
        switch await uploader.initiate(chunk) {
        case .alreadyHave:
            return .delivered
        case .unavailable(let reason):
            return .unavailable(reason)
        case .failed(let reason):
            return .failed(reason)
        case .ready(let handle, let resumeFrom):
            if case .failed(let reason) = await uploader.upload(handle: handle, file: file, fromOffset: resumeFrom) { return .failed(reason) }
            if case .failed(let reason) = await uploader.commit(chunk, handle: handle) { return .failed(reason) }
            return .delivered
        }
    }
}
