import Foundation

/// The on-disk format of a chunk file, the same as Android's `FrameCodec`. One frame per SampleBatch, with no file
/// header or footer:
///
///     [uvarint payloadLength][big-endian CRC-32 of payload][payload = one gzip member holding the SampleBatch]
///
/// Each frame is compressed and checksummed on its own, so a torn or corrupt tail never affects the frames before it:
/// recovery scans forward and cuts the file at the end of the last frame that verifies.
public enum FrameCodec {
    /// A batch closes at about 64 KiB before compression; anything past this isn't ours.
    public static let maxFrameBytes: Int64 = 4 * 1024 * 1024

    public struct Frame: Sendable {
        public let payloadOffset: Int64
        public let payload: Data
        /// The offset just past this frame.
        public let end: Int64
    }

    /// One complete frame for these serialized SampleBatch bytes.
    public static func encode(batchBytes: Data, using gzip: GzipCompressor) -> Data {
        let payload = gzip.compress(batchBytes)
        var out = Data(capacity: payload.count + 14)
        var v = UInt64(payload.count)
        while v >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(truncatingIfNeeded: v))
        let crc = CRC32.of(payload)
        out.append(contentsOf: [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
                                UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)])
        out.append(payload)
        return out
    }

    /// The SampleBatch bytes in one frame's payload, or nil if the gzip member is bad.
    public static func inflate(_ payload: Data) -> Data? { Gzip.decompress(payload) }

    /// The byte offset just past the last frame that verifies. Everything from there on is a torn write or corruption,
    /// and is safe to truncate.
    public static func scanValidPrefix(_ data: Data) -> Int64 {
        var end: Int64 = 0
        forEachFrame(data) { end = $0.end }
        return end
    }

    /// Every verified frame, stopping at the first bad one, as Android's reader does.
    public static func readFrames(_ data: Data) -> [Frame] {
        var frames: [Frame] = []
        forEachFrame(data) { frames.append($0) }
        return frames
    }

    private static func forEachFrame(_ data: Data, _ body: (Frame) -> Void) {
        let base = data.startIndex
        let count = Int64(data.count)
        var pos: Int64 = 0
        while pos < count {
            guard let (len, width) = readVarint(data, at: pos), len <= UInt64(maxFrameBytes) else { return }
            let length = Int64(len)
            let header = pos + width
            guard header + 4 + length <= count else { return }
            let crcAt = base + Int(header)  // int-ok: within this file's Data, whose count is an Int
            let want = UInt32(data[crcAt]) << 24 | UInt32(data[crcAt + 1]) << 16 | UInt32(data[crcAt + 2]) << 8 | UInt32(data[crcAt + 3])
            let payloadAt = crcAt + 4
            let payload = data.subdata(in: payloadAt..<(payloadAt + Int(length)))  // int-ok: bounded by maxFrameBytes
            guard CRC32.of(payload) == want else { return }
            let end = header + 4 + length
            body(Frame(payloadOffset: header + 4, payload: payload, end: end))
            pos = end
        }
    }

    private static func readVarint(_ data: Data, at offset: Int64) -> (UInt64, Int64)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var at = offset
        let count = Int64(data.count)
        while at < count {
            let b = data[data.startIndex + Int(at)]  // int-ok: within this file's Data
            at += 1
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return (result, at - offset) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
