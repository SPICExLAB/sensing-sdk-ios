import XCTest
@testable import SensingStorage

/// Android's FrameCodecTest, case for case.
final class FrameCodecTests: XCTestCase {
    private let a = Data(String(repeating: "batch-a ", count: 50).utf8)
    private let b = Data(String(repeating: "batch-b ", count: 70).utf8)
    private let gzip = GzipCompressor()

    private func file(_ frames: Data...) -> Data {
        frames.reduce(into: Data()) { $0.append(FrameCodec.encode(batchBytes: $1, using: gzip)) }
    }

    func testFramesRoundTripThroughGzipAndFraming() {
        let out = FrameCodec.readFrames(file(a, b)).map { FrameCodec.inflate($0.payload) }
        XCTAssertEqual(out, [a, b])
    }

    func testATornTailIsCutBackToTheLastWholeFrame() {
        let torn = file(a, b).dropLast(7)  // power loss mid-frame-b
        XCTAssertEqual(FrameCodec.scanValidPrefix(Data(torn)), Int64(file(a).count))
    }

    func testAFlippedByteFailsCRCAndStopsAtTheFrameBeforeIt() {
        var bytes = file(a, b)
        bytes[bytes.count - 3] ^= 0x55
        XCTAssertEqual(FrameCodec.scanValidPrefix(bytes), Int64(file(a).count))
        XCTAssertEqual(FrameCodec.readFrames(bytes).count, 1)
    }

    func testEmptyAndHeaderOnlyFilesHaveNoValidPrefix() {
        XCTAssertEqual(FrameCodec.scanValidPrefix(Data()), 0)
        XCTAssertEqual(FrameCodec.scanValidPrefix(Data([0x10, 0, 0])), 0)  // the varint says 16 bytes, then nothing
    }

    // Beyond Android's tests: the exact layout, since other readers depend on it.

    func testHeaderIsAVarintLengthThenABigEndianCRCOfTheCompressedBytes() {
        var g = SystemRandomNumberGenerator()
        // Incompressible, so the payload needs a two-byte varint.
        let raw = Data((0..<1000).map { _ in UInt8.random(in: 0...255, using: &g) })
        let frame = FrameCodec.encode(batchBytes: raw, using: gzip)
        let payload = gzip.compress(raw)
        XCTAssertGreaterThan(payload.count, 127)
        XCTAssertEqual(frame[0], UInt8(payload.count & 0x7f) | 0x80)
        XCTAssertEqual(frame[1], UInt8(payload.count >> 7))
        let crc = CRC32.of(payload)
        XCTAssertEqual(Array(frame[2..<6]), [UInt8(crc >> 24), UInt8(crc >> 16 & 0xff), UInt8(crc >> 8 & 0xff), UInt8(crc & 0xff)])
        XCTAssertEqual(frame.subdata(in: 6..<frame.count), payload)
    }

    func testAFrameOverTheLimitIsCorruptionEvenIfItFits() {
        // 5 MiB as a varint, and the bytes to match.
        var bytes = Data([0x80, 0x80, 0xc0, 0x02, 0, 0, 0, 0])
        bytes.append(Data(count: 5 * 1024 * 1024))
        XCTAssertEqual(FrameCodec.scanValidPrefix(bytes), 0)
    }

    func testAnOverlongVarintStops() {
        XCTAssertEqual(FrameCodec.scanValidPrefix(Data(repeating: 0xff, count: 20)), 0)
    }

    func testReadsASliceWithANonZeroStartIndex() {
        var padded = Data([9, 9, 9])
        padded.append(file(a))
        XCTAssertEqual(FrameCodec.readFrames(padded.dropFirst(3)).map { FrameCodec.inflate($0.payload) }, [a])
    }
}
