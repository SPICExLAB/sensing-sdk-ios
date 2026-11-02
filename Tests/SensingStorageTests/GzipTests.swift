import XCTest
@testable import SensingStorage

final class GzipTests: XCTestCase {
    func testCRC32KnownAnswer() {
        XCTAssertEqual(CRC32.of(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testRoundTripAndReuse() {
        let z = GzipCompressor()
        for text in ["batch-a ", "batch-b ", ""] {
            let input = Data(String(repeating: text, count: 50).utf8)
            let packed = z.compress(input)
            XCTAssertEqual(Array(packed.prefix(2)), [0x1f, 0x8b], "must be a real gzip member")
            XCTAssertEqual(Gzip.decompress(packed), input)
        }
    }

    func testIncompressibleInputFits() {
        var g = SystemRandomNumberGenerator()
        let input = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &g) })
        XCTAssertEqual(Gzip.decompress(GzipCompressor().compress(input)), input)
    }

    func testCorruptionIsRefused() {
        var packed = GzipCompressor().compress(Data(String(repeating: "x", count: 500).utf8))
        packed[packed.count / 2] ^= 0xff
        XCTAssertNil(Gzip.decompress(packed))
        XCTAssertNil(Gzip.decompress(Data([1, 2, 3])))
    }
}
