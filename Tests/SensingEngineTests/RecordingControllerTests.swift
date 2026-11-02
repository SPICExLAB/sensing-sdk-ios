import Foundation
import SensingCore
import SensingProto
import SensingStorage
import XCTest
@testable import SensingEngine

/// The whole flow of a recording, with fake sensors.
@MainActor
final class RecordingControllerTests: XCTestCase {
    private let clock = FakeClock()
    private let accel = SensingCatalog.accelerometer
    private let device = DeviceDescription(platform: "ios", model: "iPhone16,1", os: "iOS 26.7.1", appVersion: "1", sdkVersion: "0.1")

    private func options() -> CollectionEngine.Options {
        var o = CollectionEngine.Options()
        o.manualTick = true
        o.freeBytes = { 1 << 40 }
        return o
    }

    private func controller(_ root: StorageRoot, adapter: FakeAdapter? = nil, options custom: CollectionEngine.Options? = nil) -> RecordingController {
        RecordingController(root: root, deviceId: "dev-1", catalog: SensingCatalog.phone, adapters: [adapter ?? FakeAdapter(accel)], device: device, clock: clock, options: custom ?? options())
    }

    private let spec = RecordingSpec(id: "aaaaaaaa-1111-4111-8111-111111111111", label: "Walking",
                                     startAttrs: ["config_id": "free/walking", "module": "free", "taxonomy_version": "2"],
                                     labelAttrs: ["label_id": "bbbbbbbb-2222-4222-8222-222222222222", "kind": "interval", "taxonomy_id": "locomotion/walking",
                                                  "taxonomy_version": "2", "source": "tap", "confidence": "1"])

    func testARecordingWritesItsLabelsAndItsSummary() async throws {
        let root = try tempRoot()
        let c = controller(root)
        try await c.start(spec)
        XCTAssertEqual(c.state, .recording)
        clock.advance(ms: 60_000)
        await c.stop(answers: ["where": "outdoors"])
        XCTAssertEqual(c.state, .stopped)

        let all = try samples(in: root)
        XCTAssertEqual(all.stream("label.session").map(\.event.kind), ["session_start", "label_upsert", "label_upsert", "session_end"])
        let closed = all.stream("label.session")[2].event.attributes
        XCTAssertEqual(closed["attr.where"], "outdoors")
        XCTAssertEqual(closed["taxonomy_id"], "locomotion/walking")
        XCTAssertEqual(all.stream("label.session")[3].event.attributes["end_reason"], "stopped")
        let start = try XCTUnwrap(all.events("device.session", "start").first).event.attributes
        XCTAssertEqual(start["platform"], "ios")
        XCTAssertEqual(start["model"], "iPhone16,1")
        XCTAssertEqual(start["activity_session_id"], spec.id)
        XCTAssertEqual(all.events("device.session", "end").first?.event.attributes["reason"], "user_stop")

        let summary = try XCTUnwrap(c.recordings.all().first)
        XCTAssertEqual(summary.id, spec.id)
        XCTAssertEqual(summary.taxonomyId, "locomotion/walking")
        XCTAssertEqual(summary.endReason, "user_stop")
        XCTAssertEqual(try XCTUnwrap(summary.endWallMs) - summary.startWallMs, 60_000)
        XCTAssertEqual(summary.engineSessions.count, 1)
        XCTAssertEqual(c.sessions.pendingEvents, 0, "the chunks sealed, so nothing's owed")
    }

    func testADoubleTapOnStartQueuesInsteadOfInterleaving() async throws {
        let adapter = FakeAdapter(accel)
        let c = controller(try tempRoot(), adapter: adapter)
        let spec = spec
        let first = Task { @MainActor in try await c.start(spec) }
        let second = Task { @MainActor in try await c.start(spec) }
        let results = [await first.result, await second.result]
        XCTAssertEqual(results.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(adapter.startCount, 1)
        await c.stop()
    }

    func testAStopDuringStartWaitsItsTurn() async throws {
        let root = try tempRoot()
        let adapter = FakeAdapter(accel)
        let c = controller(root, adapter: adapter)
        let spec = spec
        let started = Task { @MainActor in _ = try? await c.start(spec) }
        let stopped = Task { @MainActor in await c.stop() }
        _ = await (started.value, stopped.value)
        // Whichever order they ran in, the state is coherent: no half-started engine.
        let running = await c.engine.isRunning
        XCTAssertEqual(running, c.state == .recording)
        await c.stop()
        XCTAssertEqual(c.state, .stopped)
    }

    func testDiscardDeletesTheLabelButKeepsTheData() async throws {
        let root = try tempRoot()
        let adapter = FakeAdapter(accel)
        let c = controller(root, adapter: adapter)
        try await c.start(spec)
        adapter.sinks[accel]?.vec3(1, 2, 3, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
        await c.discard()
        let all = try samples(in: root)
        XCTAssertEqual(all.stream("label.session").map(\.event.kind), ["session_start", "label_upsert", "label_delete", "session_end"])
        XCTAssertEqual(all.stream("label.session").last?.event.attributes["end_reason"], "discarded")
        XCTAssertEqual(all.stream(accel.value).count, 1)
    }

    func testTheTimeLimitEndsItAndLeavesItsQuestionsOpen() async throws {
        let root = try tempRoot()
        let c = controller(root)
        var ended: RecordingSummary?
        c.onEnded = { ended = $0 }
        var short = spec
        short.maxDurationMs = 10_000
        try await c.start(short)
        clock.advance(ms: 9000)
        await c.tick()
        XCTAssertEqual(c.state, .recording)
        clock.advance(ms: 1000)
        await c.tick()
        XCTAssertEqual(c.state, .stopped)
        XCTAssertEqual(ended?.endReason, ActivitySessions.timeLimit)
        XCTAssertEqual(c.sessions.lastEnded?.answered, false)
        XCTAssertEqual(try samples(in: root).stream("label.session").last?.event.attributes["end_reason"], "time_limit")
    }

    func testAStartWhileRecordingIsRefused() async throws {
        let c = controller(try tempRoot())
        try await c.start(spec)
        do {
            try await c.start(spec)
            XCTFail("should refuse")
        } catch {
            XCTAssertEqual(error as? RecordingController.ControllerError, .alreadyRecording)
        }
        await c.stop()
    }

    func testAFullDiskEndsTheRecordingWithItsReason() async throws {
        let root = try tempRoot()
        var o = options()
        o.policy = RetentionPolicy(hardCapBytes: 500, minQuotaBytes: 0)
        o.chunkLimits.maxBytes = 200
        o.retentionCheckMs = 1000
        let adapter = FakeAdapter(accel)
        let c = controller(root, adapter: adapter, options: o)
        var ended: RecordingSummary?
        c.onEnded = { ended = $0 }
        try await c.start(spec)
        for _ in 0..<20 {
            guard await c.engine.isRunning else { break }
            for _ in 0..<100 {
                clock.advance(ms: 20)
                adapter.sinks[accel]?.vec3(1, 2, 3, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
            }
            clock.advance(ms: 2000)
            await c.engine.tick()
        }
        for _ in 0..<50 where c.state == .recording { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(c.state, .stopped)
        XCTAssertEqual(ended?.endReason, "quota_reached")
        XCTAssertEqual(c.recordings.all().first?.endReason, "quota_reached")
    }

    // MARK: - Crash recovery

    func testACrashEndsTheRecordingAndTheNextLaunchRecordsTheGap() async throws {
        let root = try tempRoot()
        let adapter = FakeAdapter(accel)
        let dead = controller(root, adapter: adapter)
        try await dead.start(spec)
        for _ in 0..<100 {
            clock.advance(ms: 20)
            adapter.sinks[accel]?.vec3(1, 2, 3, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
        }
        await dead.engine.tick()
        clock.advance(ms: 2000)
        await dead.engine.tick()
        let lastWall = clock.wallMs() - 2000
        // The process dies. Time passes before the next launch.
        clock.advance(ms: 300_000)

        let next = controller(root)
        await next.recover()

        XCTAssertEqual(next.state, .stopped, "no auto-resume (S-011)")
        let all = try samples(in: root)
        XCTAssertEqual(all.stream(accel.value).map(\.seq), Array(0..<100), "the .tmp was recovered")
        let gap = try XCTUnwrap(all.events("device.gap", "process_death").first).event.attributes
        XCTAssertEqual(gap["recording_id"], spec.id)
        XCTAssertEqual(gap["from_wall_ms"], String(lastWall))
        XCTAssertEqual(gap["to_wall_ms"], String(clock.wallMs()))
        XCTAssertEqual(all.events("device.session", "start").last?.event.attributes["reason"], "recovery")
        XCTAssertEqual(all.events("device.session", "end").last?.event.attributes["reason"], "recovery_done")

        let labels = all.stream("label.session").map(\.event.kind)
        XCTAssertTrue(labels.contains("session_end"), "the session's end was owed, and written")
        let end = try XCTUnwrap(all.events("label.session", "session_end").last).event.attributes
        XCTAssertEqual(end["end_reason"], "process_died")
        XCTAssertEqual(end["end_wall_ms"], String(lastWall), "it ends where the data ends, not at the next launch")

        let summary = try XCTUnwrap(next.recordings.all().first)
        XCTAssertEqual(summary.endReason, "process_died")
        XCTAssertEqual(summary.endWallMs, lastWall)
        XCTAssertNil(next.recordings.unfinished)
        XCTAssertEqual(next.sessions.pendingEvents, 0)
        XCTAssertEqual(next.sessions.lastEnded?.answered, false, "its questions can still be asked")

        // A second launch finds nothing to do.
        let before = try samples(in: root).count
        let third = controller(root)
        await third.recover()
        XCTAssertEqual(try samples(in: root).count, before)
    }

    func testAPlainLaunchWritesNothing() async throws {
        let root = try tempRoot()
        let c = controller(root)
        await c.recover()
        XCTAssertTrue(try samples(in: root).isEmpty)
        try await c.start(spec)
        await c.stop()
        let before = try samples(in: root).count
        let next = controller(root)
        await next.recover()
        XCTAssertEqual(try samples(in: root).count, before, "a recording that ended properly owes nothing")
    }

    func testHeartbeatsCarryWhatA3AndA6Measure() async throws {
        let root = try tempRoot()
        var o = options()
        o.heartbeatExtras = { ["battery_pct": "65"] }
        let c = controller(root, options: o)
        try await c.start(spec)
        clock.advance(ms: 60_000)
        await c.engine.tick()
        await c.stop()
        let beats = try samples(in: root).events("device.health", "heartbeat")
        XCTAssertEqual(beats.map { $0.event.attributes["reason"] }, ["session_start", "periodic", "session_end"])
        let a = try XCTUnwrap(beats.last).event.attributes
        XCTAssertNotNil(a["cpu_ms"])
        XCTAssertEqual(a["battery_pct"], "65")
        XCTAssertEqual(a["uptime_ms"], "60000")
        XCTAssertEqual(a["dropped"], "0")
    }
}
