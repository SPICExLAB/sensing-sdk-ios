import SensingProto
import XCTest
@testable import SensingStorage

/// Android's ChunkWriterRecoveryTest case for case, plus the places this port deliberately differs.
final class ChunkWriterRecoveryTests: XCTestCase {
    private let clock = FakeClock()
    private var sealed: [ChunkRecord] = []

    private func writer(_ dir: URL, session: String = "s1", sensor: String = "motion.accelerometer", limits: ChunkWriter.Limits = .init()) -> ChunkWriter {
        ChunkWriter(directory: dir, sessionId: session, sensorId: sensor, limits: limits, gzip: GzipCompressor(),
                    nowMonoMs: { [clock] in clock.monoMs }, onSealed: { [unowned self] in sealed.append($0) })
    }

    private func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testAKilledProcessLeavesATmpThatRecoverySealsWithTheRightSeqRange() throws {
        let root = try tempDir(self)
        let dir = root.appendingPathComponent("chunks/s1")
        let w = writer(dir)
        try w.write(encoded("motion.accelerometer", from: 0, 100))
        try w.write(encoded("motion.accelerometer", from: 100, 100))
        try w.write(encoded("motion.accelerometer", from: 200, 100))
        // The process dies here: no seal, the .tmp remains.
        let tmp = dir.appendingPathComponent("motion.accelerometer_0.pb.gz.tmp")
        XCTAssertEqual(try names(dir), [tmp.lastPathComponent])
        // And power failed mid-write of a 4th frame: append garbage.
        let handle = try FileHandle(forWritingTo: tmp)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x40, 1, 2, 3, 4, 5]))
        try handle.close()

        let result = ChunkRecovery(chunksRoot: root.appendingPathComponent("chunks")).run()

        XCTAssertEqual(result.sealed, 1)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(result.bytesTruncated, 6)
        let final = dir.appendingPathComponent("motion.accelerometer_0.pb.gz")
        let record = try XCTUnwrap(ChunkFiles.readRecord(at: ChunkFiles.recordURL(forChunk: final)))
        XCTAssertEqual(record.firstSeq, 0)
        XCTAssertEqual(record.lastSeq, 299)
        XCTAssertEqual(record.frames, 3)
        XCTAssertEqual(record.chunkId, "s1/motion.accelerometer_0")
        XCTAssertEqual(record.sha256, try ChunkFiles.sha256(of: final))
        XCTAssertEqual(record.bytes, ChunkFiles.size(of: final))
    }

    func testATmpWithNoWholeFrameIsDeletedNotSealed() throws {
        let root = try tempDir(self)
        let dir = root.appendingPathComponent("chunks/s2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x20, 0, 0, 0]).write(to: dir.appendingPathComponent("motion.gyroscope_5.pb.gz.tmp"))
        let r = ChunkRecovery(chunksRoot: root.appendingPathComponent("chunks")).run()
        XCTAssertEqual(r.sealed, 0)
        XCTAssertEqual(r.deleted, 1)
        XCTAssertEqual(try names(dir), [])
    }

    func testSealAtMaxAgeRollsToANewChunkWithContiguousSeq() throws {
        let w = writer(try tempDir(self).appendingPathComponent("s3"), session: "s3")
        try w.write(encoded("motion.accelerometer", from: 0, 50))
        clock.monoMs += 5 * 60 * 1000
        try w.write(encoded("motion.accelerometer", from: 50, 50))  // seals chunk 1 after this write
        try w.write(encoded("motion.accelerometer", from: 100, 50))  // opens chunk 2
        try w.seal()
        XCTAssertEqual(sealed.map(\.chunkId), ["s3/motion.accelerometer_0", "s3/motion.accelerometer_100"])
        XCTAssertEqual(sealed[0].lastSeq, 99)
    }

    // The places this differs from Android.

    func testAQuietSensorSealsAtMaxAgeWithNoWriteArriving() throws {
        let w = writer(try tempDir(self))
        try w.write(encoded("motion.accelerometer", from: 0, 10))
        clock.monoMs += 5 * 60 * 1000 - 1
        try w.tick()
        XCTAssertTrue(sealed.isEmpty)
        clock.monoMs += 1
        try w.tick()
        XCTAssertEqual(sealed.count, 1, "Android's writer would keep this open until the session ended")
        XCTAssertFalse(w.hasOpenChunk)
    }

    func testSealsAtMaxBytes() throws {
        var limits = ChunkWriter.Limits()
        limits.maxBytes = 200
        let w = writer(try tempDir(self), limits: limits)
        try w.write(encoded("motion.accelerometer", from: 0, 100))
        XCTAssertEqual(sealed.count, 1)
        XCTAssertGreaterThanOrEqual(sealed[0].bytes, 200)
    }

    func testSealWithNothingOpenIsSafeAndTickDoesNothing() throws {
        let w = writer(try tempDir(self))
        try w.seal()
        try w.tick()
        XCTAssertTrue(sealed.isEmpty)
    }

    func testRecordCarriesWallTimesAndTheDeviceFromTheBatch() throws {
        let w = writer(try tempDir(self))
        try w.write(encoded("motion.accelerometer", from: 10, 5, device: "watch-1"))
        try w.seal()
        XCTAssertEqual(sealed[0].deviceId, "watch-1")
        XCTAssertEqual(sealed[0].firstWallMs, 1_700_000_000_200)
        XCTAssertEqual(sealed[0].lastWallMs, 1_700_000_000_280)
        XCTAssertEqual(sealed[0].firstTsMono, 200_000_000)
        XCTAssertEqual(sealed[0].lastTsMono, 280_000_000)
    }

    func testACrashBetweenRenameAndRecordIsRepairedInsteadOfOrphaned() throws {
        let root = try tempDir(self)
        let dir = root.appendingPathComponent("chunks/s4")
        let w = writer(dir, session: "s4")
        try w.write(encoded("motion.accelerometer", from: 0, 20, session: "s4", device: "d"))
        try w.seal()
        let final = dir.appendingPathComponent("motion.accelerometer_0.pb.gz")
        let original = try XCTUnwrap(ChunkFiles.readRecord(at: ChunkFiles.recordURL(forChunk: final)))
        try FileManager.default.removeItem(at: ChunkFiles.recordURL(forChunk: final))

        let r = ChunkRecovery(chunksRoot: root.appendingPathComponent("chunks")).run()

        XCTAssertEqual(r.recordsRebuilt, 1)
        XCTAssertEqual(try XCTUnwrap(ChunkFiles.readRecord(at: ChunkFiles.recordURL(forChunk: final))), original)
    }

    func testARecordWhoseChunkIsGoneIsRemoved() throws {
        let root = try tempDir(self)
        let dir = root.appendingPathComponent("chunks/s5")
        let w = writer(dir, session: "s5")
        try w.write(encoded("motion.accelerometer", from: 0, 20))
        try w.seal()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("motion.accelerometer_0.pb.gz"))
        let r = ChunkRecovery(chunksRoot: root.appendingPathComponent("chunks")).run()
        XCTAssertEqual(r.recordsRemoved, 1)
        XCTAssertEqual(try names(dir), [])
    }

    func testRecoveryTakesIdsFromTheSamplesNotTheFilename() throws {
        let root = try tempDir(self)
        let dir = root.appendingPathComponent("chunks/wrong-folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frame = FrameCodec.encode(batchBytes: try batch("motion.gyroscope", from: 7, 3, session: "real-session", device: "d").serializedData(), using: GzipCompressor())
        try frame.write(to: dir.appendingPathComponent("wrong_name_1.pb.gz.tmp"))
        _ = ChunkRecovery(chunksRoot: root.appendingPathComponent("chunks")).run()
        let record = try XCTUnwrap(ChunkFiles.readRecord(at: dir.appendingPathComponent("wrong_name_1.meta.json")))
        XCTAssertEqual(record.chunkId, "real-session/motion.gyroscope_7")
        XCTAssertEqual(record.sensorId, "motion.gyroscope")
        XCTAssertEqual(record.deviceId, "d")
    }

    func testAFrameWithAGoodCRCButBadGzipDoesNotCountAndDoesNotCrash() throws {
        let root = try tempDir(self)
        let dir = root.appendingPathComponent("chunks/s6")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let junk = Data(repeating: 7, count: 32)
        var file = Data([UInt8(junk.count)])
        let crc = CRC32.of(junk)
        file.append(contentsOf: [UInt8(crc >> 24), UInt8(crc >> 16 & 0xff), UInt8(crc >> 8 & 0xff), UInt8(crc & 0xff)])
        file.append(junk)
        try file.write(to: dir.appendingPathComponent("motion.gyroscope_0.pb.gz.tmp"))
        let r = ChunkRecovery(chunksRoot: root.appendingPathComponent("chunks")).run()
        XCTAssertEqual(r.deleted, 1)
        XCTAssertEqual(r.sealed, 0)
    }
}
