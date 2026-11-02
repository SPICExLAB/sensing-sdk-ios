import Foundation
import SensingProto

/// One sealed chunk, stored beside it as `<sensor_id>_<first_seq>.meta.json`. There's no database: a chunk's state is
/// the file system's (`.tmp` is being written, `.pb.gz` is sealed), so a row can't outlive its file or go stale.
public struct ChunkRecord: Codable, Sendable, Equatable {
    /// `<session_id>/<sensor_id>_<first_seq>`
    public var chunkId: String
    public var sessionId: String
    public var sensorId: String
    public var firstSeq: Int64
    public var lastSeq: Int64
    public var firstTsMono: Int64
    public var lastTsMono: Int64
    /// Wall times aren't in Android's record. Retention sorts on them, because `ts_mono_ns` resets at reboot.
    public var firstWallMs: Int64
    public var lastWallMs: Int64
    public var bytes: Int64
    public var sha256: String
    public var frames: Int64
    /// The device that recorded it: on the phone, a watch chunk keeps the watch's id.
    public var deviceId: String

    public static func id(session: String, sensor: String, firstSeq: Int64) -> String { "\(session)/\(sensor)_\(firstSeq)" }
}

/// A SampleBatch serialized and ready to frame, with what the writer needs to know about it. It carries bytes rather
/// than messages, because the engine builds batches from each sample's bytes as they arrive.
public struct EncodedBatch: Sendable {
    public var sensorId: String
    public var deviceId: String
    public var bytes: Data
    public var firstSeq: Int64
    public var lastSeq: Int64
    public var firstTsMono: Int64
    public var lastTsMono: Int64
    public var firstWallMs: Int64
    public var lastWallMs: Int64

    public init(sensorId: String, deviceId: String, bytes: Data, firstSeq: Int64, lastSeq: Int64,
                firstTsMono: Int64, lastTsMono: Int64, firstWallMs: Int64, lastWallMs: Int64) {
        self.sensorId = sensorId
        self.deviceId = deviceId
        self.bytes = bytes
        self.firstSeq = firstSeq
        self.lastSeq = lastSeq
        self.firstTsMono = firstTsMono
        self.lastTsMono = lastTsMono
        self.firstWallMs = firstWallMs
        self.lastWallMs = lastWallMs
    }

    /// From a whole message. nil if the batch has no samples. Tests and tools use this.
    public init?(_ batch: Sensorlog_V1_SampleBatch) throws {
        guard let first = batch.samples.first, let last = batch.samples.last else { return nil }
        self.init(sensorId: batch.sensorID, deviceId: first.deviceID, bytes: try batch.serializedData(),
                  firstSeq: Int64(truncatingIfNeeded: first.seq), lastSeq: Int64(truncatingIfNeeded: last.seq),
                  firstTsMono: first.tsMonoNs, lastTsMono: last.tsMonoNs, firstWallMs: first.tsWallMs, lastWallMs: last.tsWallMs)
    }
}

public enum StorageError: Error, CustomStringConvertible, Equatable {
    case io(String, Int32)
    case frameTooLarge(Int64)
    case noOpenSession

    public var description: String {
        switch self {
        case let .io(op, code): "\(op) failed: \(String(cString: strerror(code)))"
        case let .frameTooLarge(n): "a frame of \(n) bytes is over the limit"
        case .noOpenSession: "no open session"
        }
    }
}
