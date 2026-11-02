import Foundation
import SensingCore
import SensingEngine
import SensingProto
import SensingStorage
import XCTest
@testable import SensingLink

/// A chunk leaves the watch only after the phone has it, whatever gets lost on the way.
@MainActor
final class ChunkTransferTests: XCTestCase {
    private func rig() async throws -> Rig {
        let r = Rig(phoneRoot: try tempRoot(), watchRoot: try tempRoot())
        await r.watchLink.prepare()
        return r
    }

    private func phoneChunks(_ r: Rig) async -> [ChunkRecord] { await r.phone.engine.chunks() }
    private func watchChunks(_ r: Rig) async -> [ChunkRecord] { await r.watch.engine.chunks() }

    /// Past every retry's wait.
    private func retryLater(_ r: Rig) async {
        r.clock.advance(ms: RetrySchedule.capMs * 2)
        await r.watchLink.tick()
    }

    /// Keeps the drainer going, since it only starts four at a time and retries wait.
    private func drained(_ r: Rig) async -> Bool {
        await r.watchLink.drainer.tick()
        return await watchChunks(r).isEmpty
    }

    func testChunksReachThePhoneAndLeaveTheWatch() async throws {
        let r = try await rig()
        await r.recordOnWatch(self)
        let sent = await watchChunks(r)
        XCTAssertGreaterThanOrEqual(sent.count, 3)
        r.transports.watch.releaseFiles()
        await until("everything to move") { await self.drained(r) }
        let onPhone = await phoneChunks(r)
        XCTAssertEqual(Set(onPhone.map(\.chunkId)), Set(sent.map(\.chunkId)))
        XCTAssertEqual(try samples(in: r.phoneRoot).stream(r.accel.value).map(\.seq), Array(0..<50))
        XCTAssertTrue(onPhone.allSatisfy { $0.deviceId == "watch-1" }, "a watch chunk keeps the watch's id on the phone")
        XCTAssertEqual(r.phoneLink.peer.received, Int64(sent.count))
        XCTAssertTrue(try samples(in: r.watchRoot).isEmpty, "deleted, now that the phone has them")
    }

    func testNothingLeavesTheWatchUntilThePhoneHasIt() async throws {
        let r = try await rig()
        await r.recordOnWatch(self)
        let before = try samples(in: r.watchRoot).count
        r.transports.watch.setUp(false)
        r.transports.watch.releaseFiles()
        await r.watchLink.drainer.tick()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try samples(in: r.watchRoot).count, before)
        r.transports.watch.setUp(true)
        await until("everything to move") { await self.drained(r) }
    }

    func testAChunkOnThePhoneSurvivesAPhoneRelaunch() async throws {
        let r = try await rig()
        await r.recordOnWatch(self)
        r.transports.watch.releaseFiles()
        await until("everything to move") { await self.drained(r) }
        let count = await phoneChunks(r).count
        r.relaunchPhone()
        await r.phone.recover()
        let after = await phoneChunks(r)
        XCTAssertEqual(after.count, count)
        XCTAssertTrue(after.allSatisfy { $0.deviceId == "watch-1" })
    }

    func testALostAckMeansAResendAndNoDuplicate() async throws {
        let r = try await rig()
        r.transports.watch.loseAcks = 1
        await r.recordOnWatch(self)
        let total = await watchChunks(r).count
        r.transports.watch.releaseFiles()
        await until("all but the unacked one to clear") { await r.watchLink.drainer.tick(); return await self.watchChunks(r).count == 1 }
        await until("the phone to hold them all") { await self.phoneChunks(r).count == total }
        let waitingKept = await watchChunks(r).first
        let kept = try XCTUnwrap(waitingKept)
        let keptFile = await r.watch.engine.fileURL(for: kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path), "no ack, so its file stays")

        // Ten minutes pass with no ack.
        r.transports.watch.forgetLostAcks()
        r.clock.advance(ms: PhoneRelayUploader.ackTimeoutMs)
        await r.watchLink.tick()
        await until("the attempt to fail") { await r.watchLink.drainer.status.lastFailure?.contains("no ack") == true }
        let before = r.transports.watch.transfers.count
        await retryLater(r)
        await until("the resend to be acked") { await self.drained(r) }
        XCTAssertEqual(r.transports.watch.transfers.count, before + 1)
        let phone = await phoneChunks(r)
        XCTAssertEqual(phone.count, total, "the same chunk, once")
        XCTAssertEqual(try samples(in: r.phoneRoot).stream(r.accel.value).map(\.seq), Array(0..<50))
    }

    func testAnAckAfterTheWatchGaveUpStillCounts() async throws {
        let r = try await rig()
        r.transports.watch.loseAcks = 1
        await r.recordOnWatch(self)
        r.transports.watch.releaseFiles()
        await until("one left") { await r.watchLink.drainer.tick(); return await self.watchChunks(r).count == 1 }
        let waitingKept = await watchChunks(r).first
        let kept = try XCTUnwrap(waitingKept)
        r.clock.advance(ms: PhoneRelayUploader.ackTimeoutMs)
        await r.watchLink.tick()
        await until("the attempt to fail") { await r.watchLink.drainer.status.lastFailure?.contains("no ack") == true }
        let before = r.transports.watch.transfers.count
        // Now the queued one arrives after all.
        r.watchLink.linkDidReceive(queued: LinkMessage.ack(ChunkAck(chunkId: kept.chunkId, result: ChunkAck.ok)).encoded())
        try await Task.sleep(for: .milliseconds(20))
        await retryLater(r)
        await until("it to clear") { await self.drained(r) }
        XCTAssertEqual(r.transports.watch.transfers.count, before, "no need to send it again")
    }

    func testAnAckBeforeTheTransferCallbackIsEnough() async throws {
        let (phone, _) = FakeTransport.pair()
        let uploader = PhoneRelayUploader(transport: phone, nowMs: { 0 })
        let record = ChunkRecord(chunkId: "s/x_0", sessionId: "s", sensorId: "x", firstSeq: 0, lastSeq: 0, firstTsMono: 0, lastTsMono: 0, firstWallMs: 0, lastWallMs: 0, bytes: 0, sha256: "", frames: 0, deviceId: "w")
        let initiated = await uploader.initiate(record)
        XCTAssertEqual(initiated, .ready(handle: "s/x_0"))
        phone.holdFiles = true
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: tmp)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let upload = Task { await uploader.upload(handle: "s/x_0", file: tmp, fromOffset: 0) }
        await until("the transfer") { phone.outstandingTransfers.contains("s/x_0") }
        uploader.received(ChunkAck(chunkId: "s/x_0", result: ChunkAck.ok))
        let step = await upload.value
        XCTAssertEqual(step, .ok)
        let committed = await uploader.commit(record, handle: "s/x_0")
        XCTAssertEqual(committed, .ok)
    }

    func testADuplicateRefusalDoesntFailTheNextAttempt() async throws {
        let (phone, _) = FakeTransport.pair()
        let uploader = PhoneRelayUploader(transport: phone, nowMs: { 0 })
        let record = ChunkRecord(chunkId: "s/x_0", sessionId: "s", sensorId: "x", firstSeq: 0, lastSeq: 0, firstTsMono: 0, lastTsMono: 0, firstWallMs: 0, lastWallMs: 0, bytes: 0, sha256: "", frames: 0, deviceId: "w")
        // The first attempt's refusal, by queue, after its message already ended that attempt.
        uploader.received(.bad("s/x_0", "sha"))
        let initiated = await uploader.initiate(record)
        XCTAssertEqual(initiated, .ready(handle: "s/x_0"))
        phone.holdFiles = true
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: tmp)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let upload = Task { await uploader.upload(handle: "s/x_0", file: tmp, fromOffset: 0) }
        await until("the file to really go") { phone.transfers == ["s/x_0"] }
        uploader.finished(chunkId: "s/x_0", error: nil)
        let step = await upload.value
        XCTAssertEqual(step, .ok)
    }

    func testACorruptFileIsRefusedAndSentAgain() async throws {
        let r = try await rig()
        r.transports.watch.corruptFiles = 1
        await r.recordOnWatch(self)
        let total = await watchChunks(r).count
        r.transports.watch.releaseFiles()
        await until("the refusal") { r.phoneLink.peer.refused == 1 }
        await until("the attempt to fail") { await r.watchLink.drainer.status.lastFailure?.contains("bad:") == true }
        let failure = await r.watchLink.drainer.status.lastFailure
        XCTAssertTrue(failure?.contains("bad:sha") == true, failure ?? "")
        await until("only the bad one left") { await r.watchLink.drainer.tick(); return await self.watchChunks(r).count == 1 }
        let held = await phoneChunks(r).count
        XCTAssertEqual(held, total - 1)
        await retryLater(r)
        await until("it to clear") { await self.drained(r) }
        let all = await phoneChunks(r).count
        XCTAssertEqual(all, total)
    }

    func testTheSameIdWithDifferentBytesIsAConflictAndNeverDeleted() async throws {
        let r = try await rig()
        await r.recordOnWatch(self)
        let waitingChunk = await watchChunks(r).first
        let chunk = try XCTUnwrap(waitingChunk)
        // The phone already holds something else under this id.
        let directory = r.phoneRoot.sessionDirectory(chunk.sessionId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("something else".utf8).write(to: directory.appendingPathComponent("\(chunk.sensorId)_\(chunk.firstSeq)\(ChunkWriter.finalSuffix)"))
        r.transports.watch.releaseFiles()
        await until("the refusal") { r.phoneLink.peer.refused == 1 }
        await until("the rest to clear") { await r.watchLink.drainer.tick(); return await self.watchChunks(r).count == 1 }
        let first = await watchChunks(r).first?.chunkId
        XCTAssertEqual(first, chunk.chunkId)
        await retryLater(r)
        await until("a second refusal") { r.phoneLink.peer.refused == 2 }
        let second = await watchChunks(r).first?.chunkId
        XCTAssertEqual(second, chunk.chunkId, "the only copy stays")
    }

    func testAFileWithBadIdsIsRefusedAndWritesNothingOutsideItsFolder() async throws {
        let r = try await rig()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: tmp)
        var record = ChunkRecord(chunkId: "", sessionId: "../../evil", sensorId: "motion.accelerometer", firstSeq: 0, lastSeq: 0, firstTsMono: 0, lastTsMono: 0,
                                 firstWallMs: 0, lastWallMs: 0, bytes: 1, sha256: try ChunkFiles.sha256(of: tmp), frames: 0, deviceId: "w")
        record.chunkId = ChunkRecord.id(session: record.sessionId, sensor: record.sensorId, firstSeq: 0)
        r.phoneLink.linkDidReceive(file: tmp, metadata: try JSONEncoder().encode(record))
        await until("the refusal") { r.phoneLink.peer.refused == 1 }
        let none = await phoneChunks(r)
        XCTAssertTrue(none.isEmpty)
        let parent = r.phoneRoot.chunks.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("evil").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.deletingLastPathComponent().appendingPathComponent("evil").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.phoneRoot.incoming.path), [], "and it doesn't linger")
    }

    func testAFileAcceptedBeforeACrashIsFinishedAtTheNextLaunch() async throws {
        let r = try await rig()
        await r.recordOnWatch(self)
        let waitingChunk = await watchChunks(r).first
        let chunk = try XCTUnwrap(waitingChunk)
        let receiver = ChunkReceiver(root: r.phoneRoot)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = await r.watch.engine.fileURL(for: chunk)
        try FileManager.default.copyItem(at: source, to: copy)
        XCTAssertTrue(receiver.accept(file: copy, metadata: try JSONEncoder().encode(chunk)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "moved before the delegate returned")
        let notYet = await phoneChunks(r).count
        XCTAssertEqual(notYet, 0)
        r.relaunchPhone()
        await until("it to be finished") { await self.phoneChunks(r).count == 1 }
        r.transports.watch.releaseFiles()
        await until("the ack to arrive and the watch to let go") { await self.drained(r) }
        let onPhone = await phoneChunks(r).filter { $0.chunkId == chunk.chunkId }
        XCTAssertEqual(onPhone.count, 1)
    }

    func testFilesArrivingWhileOthersAreBeingFinishedAreNotLost() async throws {
        let root = try tempRoot()
        let receiver = ChunkReceiver(root: root)
        let results = Results()
        let session = "aaaaaaaa-1111-4111-8111-111111111111"
        let total: Int64 = 200
        for i in 0..<total {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let body = Data("chunk \(i)".utf8)
            try body.write(to: tmp)
            let record = ChunkRecord(chunkId: ChunkRecord.id(session: session, sensor: "motion.accelerometer", firstSeq: i), sessionId: session, sensorId: "motion.accelerometer",
                                     firstSeq: i, lastSeq: i, firstTsMono: 0, lastTsMono: 0, firstWallMs: 0, lastWallMs: 0, bytes: Int64(body.count), sha256: try ChunkFiles.sha256(of: tmp), frames: 0, deviceId: "w")
            XCTAssertTrue(receiver.accept(file: tmp, metadata: try JSONEncoder().encode(record)))
            // A drain for an earlier file runs alongside every accept, which is how the delegate uses this.
            receiver.drain { results.add($0.ack) }
        }
        await until("every file to be finished") { results.count == total }
        XCTAssertEqual(results.okCount, total)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.incoming.path), [], "nothing stranded")
    }

    func testAWatchRelaunchDoesntSendWhatsStillQueued() async throws {
        let r = try await rig()
        await r.recordOnWatch(self)
        await until("transfers to start") { !r.transports.watch.outstandingTransfers.isEmpty }
        let sent = r.transports.watch.transfers.count
        XCTAssertGreaterThan(sent, 0)
        // The app dies with those in the system's queue.
        r.relaunchWatch()
        await r.watchLink.prepare()
        await r.watchLink.drainer.tick()
        try await Task.sleep(for: .milliseconds(30))
        let doubled = Dictionary(grouping: r.transports.watch.transfers) { $0 }.filter { $0.value.count > 1 }
        XCTAssertTrue(doubled.isEmpty, "\(doubled.keys)")
        r.transports.watch.releaseFiles()
        await until("everything to clear") { await self.drained(r) }
    }

    func testTheSummaryShowsWhatsMissing() async throws {
        let r = try await rig()
        // The phone has its own record of this recording.
        let id = "aaaaaaaa-1111-4111-8111-111111111111"
        try await r.phone.start(RecordingSpec(id: id, label: "Walking"))
        await r.phone.stop()
        await r.recordOnWatch(self)
        await until("the summary") { r.phone.recordings.find(id: id)?.peer != nil }
        let peer = try XCTUnwrap(r.phone.recordings.find(id: id)?.peer)
        XCTAssertEqual(peer.deviceId, "watch-1")
        XCTAssertEqual(peer.endReason, "phone_stop")
        XCTAssertEqual(r.phone.recordings.find(id: id)?.peerEngineSessions, peer.engineSessions)
        let missing = await r.phoneLink.missingPeerChunks(recordingId: id)
        XCTAssertEqual(Set(missing), Set(peer.chunkIds))
        XCTAssertFalse(missing.isEmpty)
        r.transports.watch.releaseFiles()
        await until("everything to arrive") {
            await r.watchLink.drainer.tick()
            return await r.phoneLink.missingPeerChunks(recordingId: id).isEmpty
        }
    }
}

private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var acks: [ChunkAck] = []

    func add(_ ack: ChunkAck) { lock.withLock { acks.append(ack) } }
    var count: Int64 { lock.withLock { Int64(acks.count) } }
    var okCount: Int64 { lock.withLock { Int64(acks.filter { $0.result == ChunkAck.ok }.count) } }
}

/// The drainer alone, against an uploader that does as it's told.
final class ChunkDrainerTests: XCTestCase {
    private final class FakeSource: ChunkSource, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ChunkRecord]
        private(set) var removed: [String] = []

        init(count: Int64) {
            stored = (0..<count).map { i in
                ChunkRecord(chunkId: "s/x_\(i)", sessionId: "s", sensorId: "x", firstSeq: i, lastSeq: i, firstTsMono: 0, lastTsMono: 0, firstWallMs: i, lastWallMs: i, bytes: 1, sha256: "", frames: 1, deviceId: "w")
            }
        }

        var left: Int64 { lock.withLock { Int64(stored.count) } }
        func sealedChunks() async -> [ChunkRecord] { lock.withLock { stored } }
        func fileURL(of chunk: ChunkRecord) async -> URL { URL(fileURLWithPath: "/dev/null") }
        func remove(_ chunk: ChunkRecord) async {
            lock.withLock {
                stored.removeAll { $0.chunkId == chunk.chunkId }
                removed.append(chunk.chunkId)
            }
        }
    }

    private final class FakeUploader: ChunkUploader, @unchecked Sendable {
        let name = "fake"
        private let lock = NSLock()
        var answer = ChunkInit.ready(handle: "h")
        var commitAnswer = ChunkStep.ok
        private var running: Int64 = 0
        private var highest: Int64 = 0
        private var called: [String] = []
        private var gate: [CheckedContinuation<Void, Never>] = []
        var holding = false

        var concurrent: Int64 { lock.withLock { running } }
        var peak: Int64 { lock.withLock { highest } }
        var calls: [String] { lock.withLock { called } }

        func initiate(_ chunk: ChunkRecord) async -> ChunkInit {
            lock.withLock { called.append(chunk.chunkId) }
            return lock.withLock { answer }
        }

        func upload(handle: String, file: URL, fromOffset: Int64) async -> ChunkStep {
            lock.withLock {
                running += 1
                highest = max(highest, running)
            }
            if lock.withLock({ holding }) {
                await withCheckedContinuation { c in lock.withLock { gate.append(c) } }
            }
            lock.withLock { running -= 1 }
            return .ok
        }

        func commit(_ chunk: ChunkRecord, handle: String) async -> ChunkStep { lock.withLock { commitAnswer } }

        func release() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                holding = false
                defer { gate = [] }
                return gate
            }
            waiting.forEach { $0.resume() }
        }
    }

    private final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 1000
        func read() -> Int64 { lock.withLock { value } }
        func advance(_ ms: Int64) { lock.withLock { value += ms } }
    }

    func testAtMostFourAtATime() async {
        let source = FakeSource(count: 10)
        let uploader = FakeUploader()
        uploader.holding = true
        let now = Now()
        let drainer = ChunkDrainer(uploader: uploader, source: source, nowMs: { now.read() })
        await drainer.tick()
        await drainer.tick()
        for _ in 0..<200 where uploader.concurrent < 4 { try? await Task.sleep(for: .milliseconds(2)) }
        let status = await drainer.status
        XCTAssertEqual(status.inFlight, 4)
        XCTAssertEqual(status.waiting, 10)
        XCTAssertEqual(uploader.calls.count, 4, "a second tick doesn't start the same ones again")
        uploader.release()
        await drainer.settle()
        XCTAssertEqual(source.left, 6)
        await drainer.tick()
        await drainer.settle()
        await drainer.tick()
        await drainer.settle()
        XCTAssertEqual(source.left, 0)
        XCTAssertLessThanOrEqual(uploader.peak, 4)
        XCTAssertEqual(uploader.calls.count, 10, "each sent once")
        let done = await drainer.status
        XCTAssertEqual(done.delivered, 10)
    }

    func testAFailureWaitsAndKeepsTheChunk() async {
        let source = FakeSource(count: 1)
        let uploader = FakeUploader()
        uploader.commitAnswer = .failed("bad:sha")
        let now = Now()
        let drainer = ChunkDrainer(uploader: uploader, source: source, nowMs: { now.read() }, jitter: { 0.5 })
        await drainer.tick()
        await drainer.settle()
        XCTAssertEqual(source.left, 1)
        XCTAssertEqual(uploader.calls.count, 1)
        let failed = await drainer.status.lastFailure
        XCTAssertEqual(failed, "s/x_0: bad:sha")
        now.advance(29_000)
        await drainer.tick()
        await drainer.settle()
        XCTAssertEqual(uploader.calls.count, 1, "not yet")
        now.advance(1000)
        await drainer.tick()
        await drainer.settle()
        XCTAssertEqual(uploader.calls.count, 2)
        // The second wait is twice the first.
        now.advance(59_000)
        await drainer.tick()
        await drainer.settle()
        XCTAssertEqual(uploader.calls.count, 2)
        now.advance(1000)
        uploader.commitAnswer = .ok
        await drainer.tick()
        await drainer.settle()
        XCTAssertEqual(source.left, 0)
    }

    func testNoRouteCostsNothing() async {
        let source = FakeSource(count: 1)
        let uploader = FakeUploader()
        uploader.answer = .unavailable("no phone")
        let now = Now()
        let drainer = ChunkDrainer(uploader: uploader, source: source, nowMs: { now.read() }, jitter: { 0.5 })
        for _ in 0..<5 {
            await drainer.tick()
            await drainer.settle()
            now.advance(ChunkDrainer.unavailableRetryMs)
        }
        XCTAssertEqual(uploader.calls.count, 5, "the same short wait each time, with no backing off")
        XCTAssertEqual(source.left, 1)
        let failure = await drainer.status.lastFailure
        XCTAssertNil(failure)
    }

    func testAlreadyThereMeansDelete() async {
        let source = FakeSource(count: 1)
        let uploader = FakeUploader()
        uploader.answer = .alreadyHave
        let drainer = ChunkDrainer(uploader: uploader, source: source, nowMs: { 0 })
        await drainer.tick()
        await drainer.settle()
        XCTAssertEqual(source.left, 0)
    }

    func testTheScheduleDoublesToAnHourWithTwentyPercentEitherWay() {
        XCTAssertEqual(RetrySchedule.delayMs(failures: 1, jitter: 0.5), 30_000)
        XCTAssertEqual(RetrySchedule.delayMs(failures: 2, jitter: 0.5), 60_000)
        XCTAssertEqual(RetrySchedule.delayMs(failures: 3, jitter: 0.5), 120_000)
        XCTAssertEqual(RetrySchedule.delayMs(failures: 8, jitter: 0.5), 3_600_000)
        XCTAssertEqual(RetrySchedule.delayMs(failures: 500, jitter: 0.5), 3_600_000)
        XCTAssertEqual(RetrySchedule.delayMs(failures: 1, jitter: 0), 24_000)
        XCTAssertEqual(RetrySchedule.delayMs(failures: 1, jitter: 1), 36_000)
    }
}
