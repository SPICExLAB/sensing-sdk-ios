import Foundation

/// The persistence layer's front door, and the only writer to disk. Everything downstream reads sealed chunks. Not
/// thread-safe: one engine queue owns it.
public final class ChunkStore {
    public struct Status: Sendable, Equatable {
        public var bytesOnDisk: Int64
        public var quotaBytes: Int64
        public var freeBytes: Int64

        public init(bytesOnDisk: Int64, quotaBytes: Int64, freeBytes: Int64) {
            self.bytesOnDisk = bytesOnDisk
            self.quotaBytes = quotaBytes
            self.freeBytes = freeBytes
        }

        public var isOverQuota: Bool { bytesOnDisk >= quotaBytes }
        /// How full the quota is, from 0 to 1 or more.
        public var fraction: Double { quotaBytes > 0 ? Double(bytesOnDisk) / Double(quotaBytes) : 1 }
    }

    public let root: StorageRoot
    public var policy: RetentionPolicy
    public var mode: RetentionMode
    /// Chunks that mustn't be evicted right now: an upload or a transfer has them.
    public var isBusy: (ChunkRecord) -> Bool = { _ in false }
    /// Streams never deleted for space: tiny ones whose loss would cost far more than they free, such as labels and the
    /// record of what was lost.
    public var neverEvict: Set<String> = []
    /// Every chunk as it seals.
    public var onSealed: (ChunkRecord) -> Void = { _ in }

    public let evictions: EvictionOutbox

    private let limits: ChunkWriter.Limits
    private let nowMonoMs: () -> Int64
    private let freeBytes: () -> Int64
    private let gzip = GzipCompressor()
    private var writers: [String: ChunkWriter] = [:]
    private var sessionId: String?
    private var index: [String: ChunkRecord] = [:]

    public init(root: StorageRoot, limits: ChunkWriter.Limits = ChunkWriter.Limits(), policy: RetentionPolicy = RetentionPolicy(),
                mode: RetentionMode = .stopWhenFull, nowMonoMs: @escaping () -> Int64, freeBytes: (() -> Int64)? = nil) {
        self.root = root
        self.limits = limits
        self.policy = policy
        self.mode = mode
        self.nowMonoMs = nowMonoMs
        self.freeBytes = freeBytes ?? { FreeSpace.available(at: root.chunks) }
        evictions = EvictionOutbox(root: root)
    }

    /// Call once per process start, before any session opens. Safe to call again if files were unreadable before the
    /// first unlock.
    @discardableResult
    public func recover() -> ChunkRecovery.Result {
        let result = ChunkRecovery(chunksRoot: root.chunks).run()
        reloadIndex()
        return result
    }

    public func openSession(_ id: String) { sessionId = id }

    public func write(_ batch: EncodedBatch) throws {
        guard let session = sessionId else { throw StorageError.noOpenSession }
        let writer = writers[batch.sensorId] ?? makeWriter(session: session, sensor: batch.sensorId)
        writers[batch.sensorId] = writer
        try writer.write(batch)
    }

    /// Timers that don't depend on a write arriving: fsync and the age limit.
    public func tick() throws {
        for writer in writers.values { try writer.tick() }
    }

    /// Seals every open chunk: on stop, or at the end of a session.
    public func sealAll() throws {
        for writer in writers.values { try writer.seal() }
        writers.removeAll()
    }

    /// Adds a chunk that arrived from elsewhere (the watch) and is already sealed in place.
    public func adopt(_ record: ChunkRecord) { index[record.chunkId] = record }

    public var sealedChunks: [ChunkRecord] {
        index.values.sorted { ($0.firstWallMs, $0.chunkId) < ($1.firstWallMs, $1.chunkId) }
    }

    public func chunk(id: String) -> ChunkRecord? { index[id] }

    public func fileURL(for record: ChunkRecord) -> URL {
        root.sessionDirectory(record.sessionId).appendingPathComponent("\(record.sensorId)_\(record.firstSeq)\(ChunkWriter.finalSuffix)")
    }

    /// Deletes a chunk and its record. The record goes last: a crash between the two leaves a record with no file,
    /// which the startup sweep removes.
    public func delete(_ record: ChunkRecord) {
        let file = fileURL(for: record)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: ChunkFiles.recordURL(forChunk: file))
        index[record.chunkId] = nil
    }

    public var status: Status {
        let free = freeBytes()
        return Status(bytesOnDisk: index.values.reduce(0) { $0 + $1.bytes }, quotaBytes: policy.quotaBytes(freeBytes: free), freeBytes: free)
    }

    /// In `evictOldest` mode, deletes the oldest chunks until under quota. Each loss is persisted before its file goes.
    /// In `stopWhenFull` mode it deletes nothing, and the engine stops the recording when `status.isOverQuota`.
    @discardableResult
    public func enforceRetention(reason: String) throws -> [EvictedChunk] {
        guard mode == .evictOldest else { return [] }
        let s = status
        let candidates = sealedChunks.filter { !isBusy($0) && !neverEvict.contains($0.sensorId) }
        let victims = policy.select(onDiskBytes: s.bytesOnDisk, freeBytes: s.freeBytes, candidates: candidates)
        guard !victims.isEmpty else { return [] }
        let evicted = victims.map {
            EvictedChunk(chunkId: $0.chunkId, sensorId: $0.sensorId, firstSeq: $0.firstSeq, lastSeq: $0.lastSeq, bytes: $0.bytes, reason: reason)
        }
        try evictions.append(evicted)
        victims.forEach(delete)
        return evicted
    }

    private func makeWriter(session: String, sensor: String) -> ChunkWriter {
        ChunkWriter(directory: root.sessionDirectory(session), sessionId: session, sensorId: sensor, limits: limits, gzip: gzip,
                    nowMonoMs: nowMonoMs) { [weak self] record in
            guard let self else { return }
            self.index[record.chunkId] = record
            self.onSealed(record)
        }
    }

    private func reloadIndex() {
        index.removeAll()
        guard let walker = FileManager.default.enumerator(at: root.chunks, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(ChunkWriter.metaSuffix) {
            if let record = ChunkFiles.readRecord(at: url) { index[record.chunkId] = record }
        }
    }
}
