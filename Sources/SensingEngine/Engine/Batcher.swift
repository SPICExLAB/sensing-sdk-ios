import Foundation
import SensingStorage

/// Groups one stream's serialized samples into a SampleBatch, closing it at about 64 KiB or 2 s, as on Android. High-rate
/// sensors close on size and event sensors on time. It holds bytes rather than messages, which also keeps memory down on
/// the watch, and writes the outer message's own tags: `SampleBatch { string sensor_id = 1; repeated SensorSample samples = 2; }`.
/// One owner, on one queue.
final class Batcher {
    private let sensorId: String
    private let header: Data
    private let maxBytes: Int64
    private let maxAgeMs: Int64
    private var body = Data()
    private var openedMonoMs: Int64 = 0
    private var deviceId = ""
    private var firstSeq: Int64 = 0
    private var lastSeq: Int64 = 0
    private var firstTsMono: Int64 = 0
    private var lastTsMono: Int64 = 0
    private var firstWallMs: Int64 = 0
    private var lastWallMs: Int64 = 0
    private var count: Int64 = 0

    init(sensorId: String, maxBytes: Int64, maxAgeMs: Int64) {
        self.sensorId = sensorId
        self.maxBytes = maxBytes
        self.maxAgeMs = maxAgeMs
        let name = Data(sensorId.utf8)
        var h = Data([0x0a])
        Self.appendVarint(&h, UInt64(name.count))
        h.append(name)
        header = h
        body.reserveCapacity(numericCast(maxBytes) + 1024)
    }

    /// Returns a closed batch when this sample filled it.
    func add(sample: Data, deviceId: String, seq: Int64, tsMonoNs: Int64, tsWallMs: Int64, nowMonoMs: Int64) -> EncodedBatch? {
        if count == 0 {
            openedMonoMs = nowMonoMs
            self.deviceId = deviceId
            firstSeq = seq
            firstTsMono = tsMonoNs
            firstWallMs = tsWallMs
        }
        body.append(0x12)
        Self.appendVarint(&body, UInt64(sample.count))
        body.append(sample)
        lastSeq = seq
        lastTsMono = tsMonoNs
        lastWallMs = tsWallMs
        count += 1
        return Int64(body.count) >= maxBytes ? flush() : nil
    }

    func flushIfDue(nowMonoMs: Int64) -> EncodedBatch? {
        count > 0 && nowMonoMs - openedMonoMs >= maxAgeMs ? flush() : nil
    }

    func flush() -> EncodedBatch? {
        guard count > 0 else { return nil }
        var bytes = header
        bytes.append(body)
        body.removeAll(keepingCapacity: true)
        count = 0
        return EncodedBatch(sensorId: sensorId, deviceId: deviceId, bytes: bytes, firstSeq: firstSeq, lastSeq: lastSeq,
                            firstTsMono: firstTsMono, lastTsMono: lastTsMono, firstWallMs: firstWallMs, lastWallMs: lastWallMs)
    }

    private static func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(truncatingIfNeeded: v))
    }
}
