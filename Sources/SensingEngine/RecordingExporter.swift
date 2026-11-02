import Foundation
import SensingCore
import SensingStorage

/// What's in an export, beside the chunks. Inside the zip, chunks sit where the ingest's landing layout puts them:
/// `chunks/<device_id>/<session_id>/<sensor_id>_<first_seq>.pb.gz`.
public struct ExportManifest: Codable, Sendable, Equatable {
    public static let currentFormat = "sensing-export/1"

    public struct Chunk: Codable, Sendable, Equatable {
        public var path: String
        public var chunkId: String
        public var deviceId: String
        public var sessionId: String
        public var sensorId: String
        public var firstSeq: Int64
        public var lastSeq: Int64
        public var bytes: Int64
        public var sha256: String
        public var frames: Int64
    }

    public var format = ExportManifest.currentFormat
    public var recording: RecordingSummary
    public var createdWallMs: Int64
    public var sdkVersion: String
    public var chunks: [Chunk]
    /// Watch chunks that hadn't arrived when this was made.
    public var missingPeerChunks: [String]
}

public enum RecordingExporter {
    public static func path(of record: ChunkRecord) -> String {
        "chunks/\(record.deviceId)/\(record.sessionId)/\(record.sensorId)_\(record.firstSeq)\(ChunkWriter.finalSuffix)"
    }

    /// Writes the zip, reading each chunk as it goes. A file that's gone since the list was made fails the export rather than
    /// quietly leaving it out.
    public static func write(recording: RecordingSummary, chunks: [(record: ChunkRecord, file: URL)], missingPeerChunks: [String], createdWallMs: Int64, to url: URL) throws {
        let zip = try ZipWriter(to: url)
        do {
            var listed: [ExportManifest.Chunk] = []
            for (record, file) in chunks {
                let path = path(of: record)
                try zip.add(file: file, path: path)
                listed.append(ExportManifest.Chunk(path: path, chunkId: record.chunkId, deviceId: record.deviceId, sessionId: record.sessionId, sensorId: record.sensorId,
                                                   firstSeq: record.firstSeq, lastSeq: record.lastSeq, bytes: record.bytes, sha256: record.sha256, frames: record.frames))
            }
            let manifest = ExportManifest(recording: recording, createdWallMs: createdWallMs, sdkVersion: SDK.version, chunks: listed, missingPeerChunks: missingPeerChunks)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            try zip.add(data: try encoder.encode(manifest), path: "manifest.json")
            try zip.finish()
            StorageRoot.protectFile(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
