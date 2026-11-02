import XCTest
@testable import SensingStorage

/// Reads chunks written by Android's real FrameCodec and Wire, and the ingest's real encoder (`scripts/compat.sh
/// --regen-fixtures`). They're the golden fixtures this format never had.
final class FixtureTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    private func check(_ folder: String) throws {
        let dir = fixtures.appendingPathComponent(folder)
        let chunks = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(ChunkWriter.finalSuffix) }
        XCTAssertFalse(chunks.isEmpty)
        var lines: [String] = []
        for chunk in chunks {
            let data = try Data(contentsOf: chunk)
            XCTAssertEqual(FrameCodec.scanValidPrefix(data), Int64(data.count), chunk.lastPathComponent)
            lines += try Canonical.lines(chunk: data)
        }
        let expected = try String(contentsOf: dir.appendingPathComponent("expected.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.sorted(), expected)
    }

    func testReadsAndroidWrittenChunks() throws { try check("android") }

    func testReadsGoWrittenChunks() throws { try check("go") }

    func testAgreesWithAndroidOnWhereDamagedFilesStopBeingValid() throws {
        let dir = fixtures.appendingPathComponent("android/damaged")
        let expected = try String(contentsOf: dir.appendingPathComponent("expected-prefix.txt"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
        XCTAssertEqual(expected.count, 2)
        XCTAssertEqual(expected[0], expected[1], "Android's scanner keeps exactly the first frame")
        for name in ["torn.bin", "flipped.bin"] {
            XCTAssertEqual(FrameCodec.scanValidPrefix(try Data(contentsOf: dir.appendingPathComponent(name))), expected[0], name)
        }
    }

    func testRecoversAnAndroidWrittenTornFile() throws {
        let root = try tempDir(self)
        let session = root.appendingPathComponent("chunks/s1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let tmp = session.appendingPathComponent("motion.accelerometer_0.pb.gz.tmp")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("android/damaged/torn.bin"), to: tmp)
        let r = ChunkRecovery(chunksRoot: root.appendingPathComponent("chunks")).run()
        XCTAssertEqual(r.sealed, 1)
        let record = try XCTUnwrap(ChunkFiles.readRecord(at: session.appendingPathComponent("motion.accelerometer_0.meta.json")))
        XCTAssertEqual(record.firstSeq, 0)
        XCTAssertEqual(record.lastSeq, 99)
        XCTAssertEqual(record.frames, 1)
    }
}
