import Foundation
import zlib

/// Compresses each input into one complete gzip member, as Android's `GZIPOutputStream` does per frame. One z_stream is
/// reused, so a frame doesn't pay for a fresh allocation. Not thread-safe: the owner keeps it on one queue.
public final class GzipCompressor {
    private var stream = z_stream()

    public init() {
        // windowBits 15 + 16 asks zlib for a gzip wrapper rather than raw deflate.
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK, "deflateInit2 failed: \(status)")
    }

    deinit { deflateEnd(&stream) }

    public func compress(_ input: Data) -> Data {
        deflateReset(&stream)
        var output = Data(count: numericCast(deflateBound(&stream, uLong(input.count))))
        let capacity = output.count
        let written: Int = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                // zlib's next_in isn't const on this platform, but it doesn't write through it.
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                let status = deflate(&stream, Z_FINISH)
                precondition(status == Z_STREAM_END, "deflate failed: \(status)")
                return capacity - numericCast(stream.avail_out)
            }
        }
        output.removeSubrange(written..<output.count)
        return output
    }
}

public enum Gzip {
    /// Decompresses one gzip member, or nil if it isn't a valid one (bad header, bad data, or a bad trailer CRC).
    public static func decompress(_ input: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let ok: Bool = input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Bool in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count)
            while true {
                let (status, produced): (Int32, Int) = chunk.withUnsafeMutableBytes { dst in
                    stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(dst.count)
                    let s = inflate(&stream, Z_NO_FLUSH)
                    return (s, dst.count - numericCast(stream.avail_out))
                }
                out.append(contentsOf: chunk[0..<produced])
                if status == Z_STREAM_END { return true }
                if status != Z_OK { return false }
                if stream.avail_in == 0 && produced == 0 { return false }
            }
        }
        return ok ? out : nil
    }
}

public enum CRC32 {
    /// Standard CRC-32 (the same polynomial as `java.util.zip.CRC32`).
    public static func of(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> UInt32 in
            UInt32(truncatingIfNeeded: crc32(0, buf.bindMemory(to: Bytef.self).baseAddress, uInt(buf.count)))
        }
    }
}
