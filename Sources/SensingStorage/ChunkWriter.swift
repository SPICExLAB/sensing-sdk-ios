import CryptoKit
import Foundation
import SensingCore

/// Appends frames for one (session, sensor) to a `.pb.gz.tmp` file and seals it into an immutable `.pb.gz` chunk.
///
/// Durability: each frame goes straight to the kernel with write(2), with no buffer in this process, so a process kill
/// loses nothing already batched. `tick` fsyncs every 2 s, and a seal uses `F_FULLFSYNC`, which reaches the media. That
/// costs more, so it's only done at the seal; sudden power loss can lose up to one seal interval (open question Q9).
///
/// A chunk seals at 5 MiB or 5 min. Unlike Android's, the age limit also fires from `tick`, so a quiet sensor's chunk
/// doesn't stay open until the session ends.
///
/// Not thread-safe: one engine queue owns it.
public final class ChunkWriter {
    public struct Limits: Sendable {
        public var maxBytes: Int64 = 5 * 1024 * 1024
        public var maxAgeMs: Int64 = 5 * 60 * 1000
        public var fsyncIntervalMs: Int64 = 2000

        public init() {}
    }

    public static let finalSuffix = ".pb.gz"
    public static let tmpSuffix = ".pb.gz.tmp"
    public static let metaSuffix = ".meta.json"

    public let sessionId: String
    public let sensorId: String

    private let directory: URL
    private let limits: Limits
    private let gzip: GzipCompressor
    private let nowMonoMs: () -> Int64
    private let onSealed: (ChunkRecord) -> Void

    private var file: URL?
    private var fd: Int32 = -1
    private var firstSeq: Int64 = 0
    private var lastSeq: Int64 = 0
    private var firstTsMono: Int64 = 0
    private var lastTsMono: Int64 = 0
    private var firstWallMs: Int64 = 0
    private var lastWallMs: Int64 = 0
    private var deviceId = ""
    private var frames: Int64 = 0
    private var bytes: Int64 = 0
    private var openedMonoMs: Int64 = 0
    private var lastFsyncMonoMs: Int64 = 0
    private var dirty = false

    public init(directory: URL, sessionId: String, sensorId: String, limits: Limits = Limits(), gzip: GzipCompressor,
                nowMonoMs: @escaping () -> Int64, onSealed: @escaping (ChunkRecord) -> Void = { _ in }) {
        self.directory = directory
        self.sessionId = sessionId
        self.sensorId = sensorId
        self.limits = limits
        self.gzip = gzip
        self.nowMonoMs = nowMonoMs
        self.onSealed = onSealed
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    public var hasOpenChunk: Bool { file != nil }

    public func write(_ batch: EncodedBatch) throws {
        if file == nil { try open(batch) }
        let frame = FrameCodec.encode(batchBytes: batch.bytes, using: gzip)
        guard Int64(frame.count) <= FrameCodec.maxFrameBytes else { throw StorageError.frameTooLarge(Int64(frame.count)) }
        try writeAll(frame)
        bytes += Int64(frame.count)
        frames += 1
        dirty = true
        lastSeq = batch.lastSeq
        lastTsMono = batch.lastTsMono
        lastWallMs = batch.lastWallMs
        try maintain()
    }

    /// Timers that don't depend on a write arriving.
    public func tick() throws {
        guard file != nil else { return }
        try maintain()
    }

    /// Safe when nothing is open. Also called on stop.
    public func seal() throws {
        guard let tmp = file else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }  // not every filesystem supports it
        close(fd)
        fd = -1
        file = nil
        dirty = false
        guard frames > 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        let final = ChunkFiles.finalURL(forTmp: tmp)
        guard rename(tmp.path, final.path) == 0 else { throw StorageError.io("rename", errno) }
        ChunkFiles.syncDirectory(directory)
        let record = ChunkRecord(
            chunkId: ChunkRecord.id(session: sessionId, sensor: sensorId, firstSeq: firstSeq),
            sessionId: sessionId, sensorId: sensorId, firstSeq: firstSeq, lastSeq: lastSeq,
            firstTsMono: firstTsMono, lastTsMono: lastTsMono, firstWallMs: firstWallMs, lastWallMs: lastWallMs,
            bytes: ChunkFiles.size(of: final), sha256: try ChunkFiles.sha256(of: final), frames: frames, deviceId: deviceId)
        try ChunkFiles.writeRecord(record, for: final)
        onSealed(record)
    }

    private func maintain() throws {
        let now = nowMonoMs()
        if dirty, now - lastFsyncMonoMs >= limits.fsyncIntervalMs {
            guard fsync(fd) == 0 else { throw StorageError.io("fsync", errno) }
            dirty = false
            lastFsyncMonoMs = now
        }
        if bytes >= limits.maxBytes || now - openedMonoMs >= limits.maxAgeMs { try seal() }
    }

    private func open(_ batch: EncodedBatch) throws {
        try StorageRoot.ensureDirectory(directory)
        let tmp = directory.appendingPathComponent("\(sensorId)_\(batch.firstSeq)\(Self.tmpSuffix)")
        let descriptor = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { throw StorageError.io("open", errno) }
        StorageRoot.protect(tmp)
        fd = descriptor
        file = tmp
        firstSeq = batch.firstSeq
        lastSeq = batch.firstSeq
        firstTsMono = batch.firstTsMono
        lastTsMono = batch.firstTsMono
        firstWallMs = batch.firstWallMs
        lastWallMs = batch.firstWallMs
        deviceId = batch.deviceId
        frames = 0
        bytes = 0
        openedMonoMs = nowMonoMs()
        lastFsyncMonoMs = openedMonoMs
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw StorageError.io("write", errno)
                }
                offset += n
            }
        }
    }
}

/// File helpers the writer and recovery share.
public enum ChunkFiles {
    static func finalURL(forTmp tmp: URL) -> URL {
        tmp.deletingLastPathComponent().appendingPathComponent(String(tmp.lastPathComponent.dropLast(".tmp".count)))
    }

    public static func recordURL(forChunk chunk: URL) -> URL {
        let name = String(chunk.lastPathComponent.dropLast(ChunkWriter.finalSuffix.count)) + ChunkWriter.metaSuffix
        return chunk.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func chunkURL(forRecord record: URL) -> URL {
        let name = String(record.lastPathComponent.dropLast(ChunkWriter.metaSuffix.count)) + ChunkWriter.finalSuffix
        return record.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func size(of url: URL) -> Int64 {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_size : 0
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 64 * 1024), !block.isEmpty { hash.update(data: block) }
        return Hex.lower(hash.finalize())
    }

    public static func writeRecord(_ record: ChunkRecord, for chunk: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = recordURL(forChunk: chunk)
        try encoder.encode(record).write(to: url, options: .atomic)
        StorageRoot.protect(url)
    }

    public static func readRecord(at url: URL) -> ChunkRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChunkRecord.self, from: data)
    }

    /// Makes a rename durable: the directory entry has to reach the disk too.
    static func syncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }
}
