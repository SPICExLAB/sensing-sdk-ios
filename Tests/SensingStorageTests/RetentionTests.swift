import XCTest
@testable import SensingStorage

/// Android's RetentionTest case for case, plus the places this port deliberately differs.
final class RetentionTests: XCTestCase {
    private func rec(_ id: String, _ sensor: String, _ ts: Int64, _ bytes: Int64) -> ChunkRecord {
        ChunkRecord(chunkId: "s/\(sensor)_\(id)", sessionId: "s", sensorId: sensor, firstSeq: 0, lastSeq: 9, firstTsMono: ts, lastTsMono: ts + 9,
                    firstWallMs: ts, lastWallMs: ts + 9, bytes: bytes, sha256: "sha", frames: 1, deviceId: "")
    }

    private let gib: Int64 = 1024 * 1024 * 1024

    func testQuotaIsTheSmallerOfTheCapAndATenthOfFreeSpaceNeverBelowTheFloor() {
        let p = RetentionPolicy()
        XCTAssertEqual(p.quotaBytes(freeBytes: 100 * gib), RetentionPolicy.defaultHardCap)
        // 10% of 10 GiB, to within the float rounding Android's `.toLong()` has too.
        XCTAssertEqual(Double(p.quotaBytes(freeBytes: 10 * gib)), Double(gib), accuracy: 1)
        XCTAssertEqual(p.quotaBytes(freeBytes: 1024), RetentionPolicy.minQuota)
    }

    func testNothingIsSelectedUnderQuota() {
        let p = RetentionPolicy(hardCapBytes: 1000, minQuotaBytes: 0)
        XCTAssertTrue(p.select(onDiskBytes: 1000, freeBytes: 1 << 40, candidates: [rec("a", "motion.accelerometer", 1, 500)]).isEmpty)
    }

    func testSelectsOldestFirstAcrossSensorsUntilUnderQuota() {
        let p = RetentionPolicy(hardCapBytes: 1000, minQuotaBytes: 0)
        let candidates = [
            rec("a", "motion.accelerometer", 10, 400),
            rec("b", "loc.fused", 20, 100),
            rec("c", "motion.accelerometer", 30, 400),
            rec("d", "device.battery", 40, 50),
        ]
        let out = p.select(onDiskBytes: 1450, freeBytes: 1 << 40, candidates: candidates)  // excess 450
        XCTAssertEqual(out.map(\.chunkId), ["s/motion.accelerometer_a", "s/loc.fused_b"])
    }

    // Enforcement with real files.

    private func store(_ dir: URL, mode: RetentionMode, cap: Int64) throws -> ChunkStore {
        ChunkStore(root: try StorageRoot(parent: dir), policy: RetentionPolicy(hardCapBytes: cap, minQuotaBytes: 0), mode: mode,
                   nowMonoMs: { 0 }, freeBytes: { 1 << 40 })
    }

    private func put(_ s: ChunkStore, session: String, sensor: String, wall: Int64, size: Int) throws -> ChunkRecord {
        let dir = s.root.sessionDirectory(session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = rec("0", sensor, wall, Int64(size))
        r.sessionId = session
        r.firstSeq = 0
        r.chunkId = ChunkRecord.id(session: session, sensor: sensor, firstSeq: 0)
        let file = s.fileURL(for: r)
        try Data(count: size).write(to: file)
        try ChunkFiles.writeRecord(r, for: file)
        s.adopt(r)
        return r
    }

    func testEnforceDeletesFilesAndReportsEachLossWithItsSeqRange() throws {
        let s = try store(try tempDir(self), mode: .evictOldest, cap: 1000)
        let a = try put(s, session: "s1", sensor: "motion.accelerometer", wall: 1, size: 600)
        let b = try put(s, session: "s1", sensor: "loc.fused", wall: 2, size: 300)
        _ = try put(s, session: "s2", sensor: "motion.accelerometer", wall: 3, size: 600)

        let evicted = try s.enforceRetention(reason: "test")

        XCTAssertEqual(evicted.map(\.chunkId), [a.chunkId])
        XCTAssertEqual(evicted[0].firstSeq, 0)
        XCTAssertEqual(evicted[0].lastSeq, 9)
        XCTAssertEqual(evicted[0].reason, "test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.fileURL(for: a).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChunkFiles.recordURL(forChunk: s.fileURL(for: a)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.fileURL(for: b).path))
        XCTAssertEqual(s.status.bytesOnDisk, 900)
    }

    func testBusyChunksAreSkipped() throws {
        let s = try store(try tempDir(self), mode: .evictOldest, cap: 100)
        let busy = try put(s, session: "s1", sensor: "motion.accelerometer", wall: 1, size: 200)
        let idle = try put(s, session: "s2", sensor: "motion.accelerometer", wall: 2, size: 200)
        s.isBusy = { $0.chunkId == busy.chunkId }
        XCTAssertEqual(try s.enforceRetention(reason: "test").map(\.chunkId), [idle.chunkId])
    }

    func testOldestMeansWallTimeBecauseMonoResetsAtReboot() throws {
        let s = try store(try tempDir(self), mode: .evictOldest, cap: 100)
        var before = try put(s, session: "s1", sensor: "motion.accelerometer", wall: 100, size: 200)
        before.firstTsMono = 9_000_000  // long uptime before the reboot
        s.adopt(before)
        var after = try put(s, session: "s2", sensor: "motion.accelerometer", wall: 200, size: 200)
        after.firstTsMono = 5  // just rebooted: Android would call this the oldest
        s.adopt(after)
        XCTAssertEqual(try s.enforceRetention(reason: "test").first?.chunkId, before.chunkId)
    }

    func testEvictionsSurviveARestartUntilTheyAreInTheStream() throws {
        let dir = try tempDir(self)
        let s = try store(dir, mode: .evictOldest, cap: 100)
        let a = try put(s, session: "s1", sensor: "motion.accelerometer", wall: 1, size: 200)
        _ = try put(s, session: "s2", sensor: "motion.accelerometer", wall: 2, size: 50)
        try s.enforceRetention(reason: "seal")

        let restarted = try store(dir, mode: .evictOldest, cap: 100)
        XCTAssertEqual(restarted.evictions.pending().map(\.chunkId), [a.chunkId], "Android's in-memory flow would have lost this")
        try restarted.evictions.remove([a.chunkId])
        XCTAssertEqual(try store(dir, mode: .evictOldest, cap: 100).evictions.pending(), [])
    }

    func testStopWhenFullNeverDeletesAndReportsOverQuota() throws {
        let s = try store(try tempDir(self), mode: .stopWhenFull, cap: 100)
        let a = try put(s, session: "s1", sensor: "motion.accelerometer", wall: 1, size: 200)
        XCTAssertTrue(s.status.isOverQuota)
        XCTAssertEqual(s.status.fraction, 2)
        XCTAssertEqual(try s.enforceRetention(reason: "test"), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.fileURL(for: a).path))
    }
}
