import XCTest
@testable import SensingStorage

final class ChunkStoreTests: XCTestCase {
    private let clock = FakeClock()

    private func store(_ dir: URL) throws -> ChunkStore {
        ChunkStore(root: try StorageRoot(parent: dir), nowMonoMs: { [clock] in clock.monoMs }, freeBytes: { 1 << 40 })
    }

    func testWritesAWriterPerSensorAndIndexesWhatSeals() throws {
        let s = try store(try tempDir(self))
        var seen: [String] = []
        s.onSealed = { seen.append($0.chunkId) }
        s.openSession("sess")
        try s.write(encoded("motion.accelerometer", from: 0, 10, session: "sess"))
        try s.write(encoded("motion.gyroscope", from: 0, 10, session: "sess"))
        try s.write(encoded("motion.accelerometer", from: 10, 10, session: "sess"))
        XCTAssertTrue(s.sealedChunks.isEmpty)
        try s.sealAll()
        XCTAssertEqual(Set(seen), ["sess/motion.accelerometer_0", "sess/motion.gyroscope_0"])
        XCTAssertEqual(s.sealedChunks.count, 2)
        XCTAssertEqual(s.chunk(id: "sess/motion.accelerometer_0")?.lastSeq, 19)
        XCTAssertGreaterThan(s.status.bytesOnDisk, 0)
    }

    func testWritingWithoutASessionIsAnError() throws {
        XCTAssertThrowsError(try store(try tempDir(self)).write(encoded("motion.accelerometer", from: 0, 1))) {
            XCTAssertEqual($0 as? StorageError, .noOpenSession)
        }
    }

    func testTickSealsQuietChunksByAge() throws {
        let s = try store(try tempDir(self))
        s.openSession("sess")
        try s.write(encoded("device.battery", from: 0, 1, session: "sess"))
        clock.monoMs = 5 * 60 * 1000
        try s.tick()
        XCTAssertEqual(s.sealedChunks.map(\.chunkId), ["sess/device.battery_0"])
    }

    func testANewProcessFindsSealedChunksAndRecoversTheOpenOnes() throws {
        let dir = try tempDir(self)
        let first = try store(dir)
        first.openSession("sess")
        try first.write(encoded("motion.accelerometer", from: 0, 10, session: "sess"))
        try first.sealAll()
        first.openSession("sess2")
        try first.write(encoded("motion.gyroscope", from: 0, 10, session: "sess2"))
        // The process dies with the gyroscope chunk open.

        let second = try store(dir)
        XCTAssertTrue(second.sealedChunks.isEmpty, "nothing is known until recover()")
        let result = second.recover()
        XCTAssertEqual(result.sealed, 1)
        XCTAssertEqual(second.sealedChunks.map(\.chunkId).sorted(), ["sess/motion.accelerometer_0", "sess2/motion.gyroscope_0"])
    }

    func testDeleteRemovesTheChunkAndItsRecord() throws {
        let s = try store(try tempDir(self))
        s.openSession("sess")
        try s.write(encoded("motion.accelerometer", from: 0, 10, session: "sess"))
        try s.sealAll()
        let r = try XCTUnwrap(s.sealedChunks.first)
        s.delete(r)
        XCTAssertTrue(s.sealedChunks.isEmpty)
        XCTAssertEqual(s.status.bytesOnDisk, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.fileURL(for: r).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChunkFiles.recordURL(forChunk: s.fileURL(for: r)).path))
    }

    func testOrderIsByWallTime() throws {
        let s = try store(try tempDir(self))
        s.openSession("sess")
        try s.write(encoded("motion.gyroscope", from: 100, 5, session: "sess"))
        try s.write(encoded("motion.accelerometer", from: 0, 5, session: "sess"))
        try s.sealAll()
        XCTAssertEqual(s.sealedChunks.map(\.sensorId), ["motion.accelerometer", "motion.gyroscope"])
    }
}

final class DeviceIdentityTests: XCTestCase {
    func testALowerCaseIdThatLastsUntilReinstall() throws {
        let dir = try tempDir(self)
        let root = try StorageRoot(parent: dir)
        let id = try DeviceIdentity.load(root: root)
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(id.count, 36)
        XCTAssertEqual(try DeviceIdentity.load(root: try StorageRoot(parent: dir)), id)
        let other = try StorageRoot(parent: try tempDir(self))
        XCTAssertNotEqual(try DeviceIdentity.load(root: other), id)
    }
}
