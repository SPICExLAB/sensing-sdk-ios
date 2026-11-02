import Foundation
import zlib

/// A store-only zip, written as it goes. Chunks are already gzip, so compressing them again would only spend battery. It reads
/// each file through a small buffer, so an export needs little memory however big it is.
public final class ZipWriter {
    public enum ZipError: Error, Equatable {
        /// Beyond plain zip's 4 GiB. The storage quota's 2 GiB cap keeps recordings well under it.
        case tooLarge
    }

    private struct Entry {
        var path: Data
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private static let bufferSize = 256 * 1024
    private static let version: UInt16 = 20
    private static let utf8Flag: UInt16 = 1 << 11

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: Int64 = 0

    public init(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    public func add(file url: URL, path: String) throws {
        let size = ChunkFiles.size(of: url)
        let crc = try Self.crc(of: url)
        try begin(path: path, crc: crc, size: size)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        while let piece = try reader.read(upToCount: Self.bufferSize), !piece.isEmpty {
            try handle.write(contentsOf: piece)
            offset += Int64(piece.count)
        }
    }

    public func add(data: Data, path: String) throws {
        let crc = data.withUnsafeBytes { buf in
            UInt32(truncatingIfNeeded: crc32(0, buf.bindMemory(to: UInt8.self).baseAddress, uInt(buf.count)))
        }
        try begin(path: path, crc: crc, size: Int64(data.count))
        try handle.write(contentsOf: data)
        offset += Int64(data.count)
    }

    public func finish() throws {
        let start = offset
        for e in entries {
            var d = Data()
            d.append32(0x0201_4b50)
            d.append16(Self.version)
            d.append16(Self.version)
            d.append16(Self.utf8Flag)
            d.append16(0)  // stored
            d.append16(0)  // time and date stay zero: they'd add nothing, and `ts_wall_ms` is the record
            d.append16(0x0021)
            d.append32(e.crc)
            d.append32(e.size)
            d.append32(e.size)
            d.append16(UInt16(e.path.count))
            d.append16(0)
            d.append16(0)
            d.append16(0)
            d.append16(0)
            d.append32(0)
            d.append32(e.offset)
            d.append(e.path)
            try handle.write(contentsOf: d)
            offset += Int64(d.count)
        }
        guard offset <= Int64(UInt32.max), entries.count < Int(UInt16.max) else { throw ZipError.tooLarge }  // int-ok
        var end = Data()
        end.append32(0x0605_4b50)
        end.append16(0)
        end.append16(0)
        end.append16(UInt16(entries.count))
        end.append16(UInt16(entries.count))
        end.append32(UInt32(offset - start))
        end.append32(UInt32(start))
        end.append16(0)
        try handle.write(contentsOf: end)
        try handle.close()
    }

    private func begin(path: String, crc: UInt32, size: Int64) throws {
        guard offset + size < Int64(UInt32.max) else { throw ZipError.tooLarge }
        let name = Data(path.utf8)
        entries.append(Entry(path: name, crc: crc, size: UInt32(size), offset: UInt32(offset)))
        var d = Data()
        d.append32(0x0403_4b50)
        d.append16(Self.version)
        d.append16(Self.utf8Flag)
        d.append16(0)  // stored
        d.append16(0)
        d.append16(0x0021)
        d.append32(crc)
        d.append32(UInt32(size))
        d.append32(UInt32(size))
        d.append16(UInt16(name.count))
        d.append16(0)
        d.append(name)
        try handle.write(contentsOf: d)
        offset += Int64(d.count)
    }

    private static func crc(of url: URL) throws -> UInt32 {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var value: uLong = crc32(0, nil, 0)
        while let piece = try reader.read(upToCount: bufferSize), !piece.isEmpty {
            value = piece.withUnsafeBytes { buf in
                crc32(value, buf.bindMemory(to: UInt8.self).baseAddress, uInt(buf.count))
            }
        }
        return UInt32(truncatingIfNeeded: value)
    }
}

private extension Data {
    mutating func append16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
