import Foundation
import SensingProto

/// Runs once at startup, before a session opens. A `.tmp` left by a dead process is cut back to its last frame that
/// verifies and sealed as an ordinary chunk, so the worst-case loss is the torn tail, never the file.
///
/// Beyond Android's recovery, it sweeps: a sealed chunk with no record (a crash between the rename and the record, which
/// Android's would orphan for good) gets one rebuilt, and a record whose chunk is gone is removed. Ids come from the
/// samples rather than the filename.
public struct ChunkRecovery {
    public struct Result: Sendable, Equatable {
        public var sealed = 0
        public var deleted = 0
        public var bytesTruncated: Int64 = 0
        public var recordsRebuilt = 0
        public var recordsRemoved = 0
        /// Files that couldn't be read yet, usually before the first unlock after a reboot. Run again later.
        public var deferred = 0

        public init() {}
    }

    private let chunksRoot: URL

    public init(chunksRoot: URL) { self.chunksRoot = chunksRoot }

    public func run() -> Result {
        var result = Result()
        let files = allFiles()
        for tmp in files where tmp.lastPathComponent.hasSuffix(ChunkWriter.tmpSuffix) { recoverTmp(tmp, &result) }
        for chunk in allFiles() where chunk.lastPathComponent.hasSuffix(ChunkWriter.finalSuffix) {
            guard !FileManager.default.fileExists(atPath: ChunkFiles.recordURL(forChunk: chunk).path) else { continue }
            guard let data = try? Data(contentsOf: chunk) else {
                result.deferred += 1
                continue
            }
            if let record = Self.record(for: chunk, data: data), (try? ChunkFiles.writeRecord(record, for: chunk)) != nil {
                result.recordsRebuilt += 1
            }
        }
        for meta in allFiles() where meta.lastPathComponent.hasSuffix(ChunkWriter.metaSuffix) {
            if !FileManager.default.fileExists(atPath: ChunkFiles.chunkURL(forRecord: meta).path) {
                try? FileManager.default.removeItem(at: meta)
                result.recordsRemoved += 1
            }
        }
        return result
    }

    private func recoverTmp(_ tmp: URL, _ result: inout Result) {
        guard let data = try? Data(contentsOf: tmp) else {
            result.deferred += 1
            return
        }
        let good = FrameCodec.scanValidPrefix(data)
        if good < Int64(data.count) {
            guard truncate(tmp.path, off_t(good)) == 0 else {
                result.deferred += 1
                return
            }
            result.bytesTruncated += Int64(data.count) - good
        }
        let kept = data.prefix(Int(good))  // int-ok: no larger than this file's Data, whose count is an Int
        let final = ChunkFiles.finalURL(forTmp: tmp)
        guard good > 0, let record = Self.record(for: final, data: Data(kept)) else {
            try? FileManager.default.removeItem(at: tmp)
            result.deleted += 1
            return
        }
        guard rename(tmp.path, final.path) == 0 else {
            result.deferred += 1
            return
        }
        ChunkFiles.syncDirectory(final.deletingLastPathComponent())
        var sealed = record
        sealed.bytes = ChunkFiles.size(of: final)
        sealed.sha256 = (try? ChunkFiles.sha256(of: final)) ?? ""
        try? ChunkFiles.writeRecord(sealed, for: final)
        result.sealed += 1
    }

    /// Rebuilds a chunk's record from its frames. nil if no frame holds a sample.
    static func record(for chunk: URL, data: Data) -> ChunkRecord? {
        var first: Sensorlog_V1_SensorSample?
        var last: Sensorlog_V1_SensorSample?
        var frames: Int64 = 0
        for frame in FrameCodec.readFrames(data) {
            guard let raw = FrameCodec.inflate(frame.payload),
                  let batch = try? Sensorlog_V1_SampleBatch(serializedBytes: raw), !batch.samples.isEmpty else { continue }
            if first == nil { first = batch.samples.first }
            last = batch.samples.last
            frames += 1
        }
        guard let first, let last else { return nil }
        // Samples are stamped with both ids. A file from before that falls back on the path.
        let session = first.sessionID.isEmpty ? chunk.deletingLastPathComponent().lastPathComponent : first.sessionID
        let sensor = first.sensorID.isEmpty ? sensorFromName(chunk) : first.sensorID
        let firstSeq = Int64(truncatingIfNeeded: first.seq)
        return ChunkRecord(
            chunkId: ChunkRecord.id(session: session, sensor: sensor, firstSeq: firstSeq),
            sessionId: session, sensorId: sensor, firstSeq: firstSeq, lastSeq: Int64(truncatingIfNeeded: last.seq),
            firstTsMono: first.tsMonoNs, lastTsMono: last.tsMonoNs, firstWallMs: first.tsWallMs, lastWallMs: last.tsWallMs,
            bytes: ChunkFiles.size(of: chunk), sha256: (try? ChunkFiles.sha256(of: chunk)) ?? "", frames: frames, deviceId: first.deviceID)
    }

    private static func sensorFromName(_ chunk: URL) -> String {
        let stem = chunk.lastPathComponent.dropLast(ChunkWriter.finalSuffix.count)
        guard let underscore = stem.lastIndex(of: "_") else { return String(stem) }
        return String(stem[..<underscore])
    }

    private func allFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: chunksRoot, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
    }
}
