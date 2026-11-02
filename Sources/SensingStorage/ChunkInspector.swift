import Foundation
import SensingProto

/// Rates and gaps per stream, read back from the chunks themselves. It decodes every frame, so call it off the main thread.
public enum ChunkInspector {
    public struct Stream: Sendable, Equatable, Identifiable {
        public var deviceId: String
        public var sessionId: String
        public var sensorId: String
        public var stats: StreamStats

        public var id: String { "\(deviceId)/\(sessionId)/\(sensorId)" }
    }

    public static func streams(_ chunks: [(record: ChunkRecord, file: URL)]) -> [Stream] {
        var points: [String: (ChunkRecord, [(seq: UInt64, tsMonoNs: Int64)])] = [:]
        for (record, file) in chunks {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            let key = "\(record.deviceId)/\(record.sessionId)/\(record.sensorId)"
            var collected = points[key]?.1 ?? []
            for frame in FrameCodec.readFrames(data) {
                guard let raw = FrameCodec.inflate(frame.payload), let batch = try? Sensorlog_V1_SampleBatch(serializedBytes: raw) else { continue }
                for s in batch.samples { collected.append((seq: s.seq, tsMonoNs: s.tsMonoNs)) }
            }
            points[key] = (record, collected)
        }
        return points.values.map { record, samples in
            Stream(deviceId: record.deviceId, sessionId: record.sessionId, sensorId: record.sensorId, stats: StreamStats.compute(samples))
        }.sorted { ($0.deviceId, $0.sessionId, $0.sensorId) < ($1.deviceId, $1.sessionId, $1.sensorId) }
    }
}
