import Foundation
import SensingCore
import SensingEngine
import SensingProto
import SensingStorage
import XCTest
@testable import SensingLink

/// What the phone asks for and what the watch does about it, over every way the link can let them down.
@MainActor
final class LinkFlowTests: XCTestCase {
    private func rig() async throws -> Rig {
        let r = Rig(phoneRoot: try tempRoot(), watchRoot: try tempRoot())
        await r.watchLink.prepare()
        return r
    }

    func testAStartOnThePhoneRunsOnTheWatchAndAStopEndsIt() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        XCTAssertEqual(r.keepAlive.starts, 1)
        r.watchAdapter.push(r.accel, clock: r.clock)
        r.phoneLink.publish(recording: nil)
        await until("stopped") { r.watch.state == .stopped }
        await until("the workout to end") { !r.keepAlive.isRunning }

        let all = try r.watchSamples(self)
        let start = try XCTUnwrap(all.events("device.session", "start").first).event.attributes
        XCTAssertEqual(start["platform"], "watchos")
        XCTAssertEqual(start["wrist"], "left")
        XCTAssertEqual(start["activity_session_id"], "aaaaaaaa-1111-4111-8111-111111111111")
        XCTAssertEqual(all.events("device.session", "end").first?.event.attributes["reason"], "phone_stop")
        XCTAssertEqual(all.stream(r.accel.value).count, 1)
        XCTAssertTrue(all.stream("label.session").isEmpty, "labels are the phone's to record")
        XCTAssertEqual(all.stream(r.accel.value).first?.deviceKind, .watch)
    }

    func testTheWatchUsesThePhonesSettings() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording(overrides: [r.accel: SensorOverride(samplingPeriodUs: 20000)]))
        await until("recording") { r.watch.state == .recording }
        XCTAssertEqual(r.watch.effectiveConfig().sensors[r.accel]?.samplingPeriodUs, 20000)
        XCTAssertEqual(r.watch.current?.id, "aaaaaaaa-1111-4111-8111-111111111111")
    }

    func testOnlyTheNewestGenerationApplies() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        r.phoneLink.publish(recording: nil)
        await until("stopped") { r.watch.state == .stopped }
        // The "recording" message overtaken by the "stopped" one arrives late, through the slower channel.
        let stale = DesiredState(generation: 1, recording: r.recording("bbbbbbbb-1111-4111-8111-111111111111"))
        r.watchLink.linkDidReceive(context: try JSONEncoder().encode(stale))
        r.watchLink.linkDidReceive(message: LinkMessage.desired(stale).encoded(), reply: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(r.watch.state, .stopped)
    }

    func testTheGenerationSurvivesARelaunch() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        r.phoneLink.publish(recording: nil)
        await until("stopped") { r.watch.state == .stopped }
        r.relaunchWatch()
        await r.watchLink.prepare()
        let stale = DesiredState(generation: 1, recording: r.recording("bbbbbbbb-1111-4111-8111-111111111111"))
        r.watchLink.linkDidReceive(context: try JSONEncoder().encode(stale))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(r.watch.state, .stopped)
    }

    func testAStatePublishedWhileTheWatchWasAwayStillApplies() async throws {
        let r = try await rig()
        r.transports.phone.setUp(false)
        r.phoneLink.publish(recording: r.recording())
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(r.watch.state, .stopped)
        r.transports.phone.setUp(true)
        await until("recording") { r.watch.state == .recording }
    }

    func testALateStateForARecordingThatsOverStartsNothing() async throws {
        let r = try await rig()
        r.transports.phone.setUp(false)
        r.phoneLink.publish(recording: r.recording(maxDurationMs: 60_000))
        r.clock.advance(ms: 120_000)
        r.transports.phone.setUp(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(r.watch.state, .stopped)
        XCTAssertEqual(r.keepAlive.starts, 0)
    }

    func testAWorkoutThePhoneNeverExplainsEnds() async throws {
        let r = try await rig()
        try r.keepAlive.start()
        r.watchLink.workoutLaunched()
        await r.watchLink.tick()
        XCTAssertTrue(r.keepAlive.isRunning)
        r.clock.advance(ms: WatchLink.orphanWorkoutMs)
        await r.watchLink.tick()
        XCTAssertFalse(r.keepAlive.isRunning)
    }

    func testAWorkoutThatsAlreadyRunningIsUsedNotStartedAgain() async throws {
        let r = try await rig()
        try r.keepAlive.start()
        r.watchLink.workoutLaunched()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        XCTAssertEqual(r.keepAlive.starts, 1)
        r.clock.advance(ms: WatchLink.orphanWorkoutMs)
        await r.watchLink.tick()
        XCTAssertTrue(r.keepAlive.isRunning, "it has a recording to go with it now")
    }

    func testAWorkoutThatWontStartIsRecordedAndTheRecordingRuns() async throws {
        let r = try await rig()
        r.keepAlive.failToStart = true
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        r.phoneLink.publish(recording: nil)
        await until("stopped") { r.watch.state == .stopped }
        XCTAssertEqual(try r.watchSamples(self).events("device.health", "keepalive_failed").count, 1)
    }

    // MARK: - The link goes down

    func testWithTheLinkDownTheWatchRecordsOnAndTheTimeLimitEndsIt() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording(maxDurationMs: 60_000))
        await until("recording") { r.watch.state == .recording }
        r.transports.phone.setUp(false)
        for _ in 0..<5 {
            r.clock.advance(ms: 10_000)
            r.watchAdapter.push(r.accel, clock: r.clock)
            await r.watchLink.tick()
        }
        XCTAssertEqual(r.watch.state, .recording, "nothing in its write path depends on the phone")
        r.clock.advance(ms: 10_000)
        await r.watchLink.tick()
        await until("the limit") { r.watch.state == .stopped }
        await until("the workout to end") { !r.keepAlive.isRunning }
        let all = try r.watchSamples(self)
        XCTAssertEqual(all.stream(r.accel.value).count, 5)
        XCTAssertEqual(all.events("device.session", "end").first?.event.attributes["reason"], ActivitySessions.timeLimit)
    }

    func testAStopOnTheWatchStopsThePhone() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        await r.watchLink.stopPressed()
        XCTAssertEqual(r.watch.state, .stopped)
        await until("the phone to hear") { r.stopRequests.contains("aaaaaaaa-1111-4111-8111-111111111111") }
        await until("the workout to end") { !r.keepAlive.isRunning }
    }

    func testAStopOnTheWatchWithTheLinkDownStopsItAndThePhoneHearsLater() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        r.transports.phone.setUp(false)
        await r.watchLink.stopPressed()
        XCTAssertEqual(r.watch.state, .stopped)
        XCTAssertTrue(r.stopRequests.isEmpty)
        r.transports.phone.setUp(true)
        await until("the phone to hear") { !r.stopRequests.isEmpty }
    }

    // MARK: - Crashes

    func testAWatchCrashWithTheWorkoutAliveResumesWithTheGapRecorded() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording(overrides: [r.accel: SensorOverride(samplingPeriodUs: 20000)]))
        await until("recording") { r.watch.state == .recording }
        r.clock.advance(ms: 20)
        r.watchAdapter.push(r.accel, clock: r.clock)
        await r.watch.engine.tick()
        r.clock.advance(ms: 2000)
        await r.watch.engine.tick()
        let lastWall = r.clock.wallMs() - 2000

        // The process dies, the system keeps the workout, and this app is back within 30 s.
        r.clock.advance(ms: 20_000)
        r.relaunchWatch(workoutSurvived: true)
        await r.watchLink.prepare()

        XCTAssertEqual(r.watch.state, .recording)
        XCTAssertEqual(r.watch.current?.engineSessions.count, 2)
        XCTAssertEqual(r.watch.effectiveConfig().sensors[r.accel]?.samplingPeriodUs, 20000, "its settings came back from the published state")
        r.clock.advance(ms: 20)
        r.watchAdapter.push(r.accel, clock: r.clock)
        r.phoneLink.publish(recording: nil)
        await until("stopped") { r.watch.state == .stopped }

        let all = try r.watchSamples(self)
        XCTAssertEqual(all.stream(r.accel.value).count, 2, "before and after")
        let gap = try XCTUnwrap(all.events("device.gap", "process_death").first).event.attributes
        XCTAssertEqual(gap["from_wall_ms"], String(lastWall))
        XCTAssertEqual(all.events("device.session", "start").last?.event.attributes["reason"], "workout_recovery")
    }

    func testAWatchCrashWithNoWorkoutEndsTheRecording() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        r.clock.advance(ms: 20_000)
        r.relaunchWatch(workoutSurvived: false)
        await r.watchLink.prepare()
        XCTAssertEqual(r.watch.state, .stopped)
        XCTAssertEqual(r.watch.recordings.all().first?.endReason, "process_died")
        XCTAssertFalse(r.keepAlive.isRunning)
    }

    func testAWatchCrashStillTellsThePhoneWhatItRecorded() async throws {
        let r = try await rig()
        let id = "aaaaaaaa-1111-4111-8111-111111111111"
        try await r.phone.start(RecordingSpec(id: id, label: "Walking"))
        await r.phone.stop()
        r.phoneLink.publish(recording: r.recording(id))
        await until("recording") { r.watch.state == .recording }
        r.clock.advance(ms: 20_000)
        r.relaunchWatch(workoutSurvived: false)
        await r.watchLink.prepare()
        await until("the summary") { r.phone.recordings.find(id: id)?.peer != nil }
        XCTAssertEqual(r.phone.recordings.find(id: id)?.peer?.endReason, "process_died")
    }

    func testNothingStartsBeforeRecoveryHasFinished() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        r.transports.phone.setUp(false)
        r.clock.advance(ms: 20_000)
        // The phone moves on to another recording while the watch is down, and this reaches the new process early.
        r.phoneLink.publish(recording: r.recording("bbbbbbbb-1111-4111-8111-111111111111"))
        r.relaunchWatch(workoutSurvived: false)
        let newest = try XCTUnwrap(r.phoneLink.desired)
        r.watchLink.linkDidReceive(context: try JSONEncoder().encode(newest))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(r.watch.state, .stopped, "it waits for prepare")
        XCTAssertNotNil(r.watch.recordings.unfinished, "recovery hasn't touched the dead one")

        await r.watchLink.prepare()
        XCTAssertEqual(r.watch.recordings.find(id: "aaaaaaaa-1111-4111-8111-111111111111")?.endReason, "process_died")
        XCTAssertEqual(r.watch.current?.id, "bbbbbbbb-1111-4111-8111-111111111111", "and then does what the phone last asked")
        XCTAssertEqual(r.watch.state, .recording)
    }

    func testAWorkoutThatOutlivedItsRecordingIsEnded() async throws {
        let r = try await rig()
        r.relaunchWatch(workoutSurvived: true)
        await r.watchLink.prepare()
        XCTAssertEqual(r.watch.state, .stopped)
        XCTAssertFalse(r.keepAlive.isRunning)
    }

    func testAPhoneThatRelaunchedTellsTheWatchToStop() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        r.relaunchPhone()
        XCTAssertNotNil(r.phoneLink.desired?.recording, "the phone remembers what it asked for")
        r.phoneLink.reconcile(activeRecordingId: nil)
        await until("stopped") { r.watch.state == .stopped }
    }

    func testAPhoneThatRelaunchedKeepsCountingGenerations() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        let before = try XCTUnwrap(r.phoneLink.desired?.generation)
        r.relaunchPhone()
        r.phoneLink.publish(recording: nil)
        XCTAssertEqual(r.phoneLink.desired?.generation, before + 1, "or the watch would ignore everything it says")
    }

    // MARK: - Clocks

    func testTheClockPairingIsAtTheMiddleOfTheRoundTrip() {
        let a = PeerClock.attributes(peer: "w", peerMonoNs: 5000, peerWallMs: 7, sentMonoNs: 1_000_000_000, sentWallMs: 1000, repliedMonoNs: 1_100_000_000)
        XCTAssertEqual(a["mono_ns"], "1050000000")
        XCTAssertEqual(a["wall_ms"], "1050")
        XCTAssertEqual(a["rtt_ns"], "100000000")
        XCTAssertEqual(a["peer"], "w")
        XCTAssertEqual(a["peer_mono_ns"], "5000")
        XCTAssertEqual(a["peer_wall_ms"], "7")
    }

    func testThePhoneRecordsPeerClocksInItsOwnStream() async throws {
        let r = try await rig()
        try await r.phone.start(RecordingSpec(id: "aaaaaaaa-1111-4111-8111-111111111111", label: "Walking"))
        r.phoneLink.publish(recording: r.recording())
        await until("recording") { r.watch.state == .recording }
        await r.phoneLink.pairClock()
        r.clock.advance(ms: PhoneLink.clockPairMs)
        await r.phoneLink.tick()
        await r.phone.stop()
        let peers = try samples(in: r.phoneRoot).events("device.clock", "peer_clock")
        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers.first?.event.attributes["peer"], "watch-1")
        XCTAssertEqual(peers.first?.event.attributes["rtt_ns"], "0")
    }

    func testNoPairingWithoutARecordingOrALink() async throws {
        let r = try await rig()
        try await r.phone.start(RecordingSpec(label: "Walking"))
        await r.phoneLink.pairClock()  // nothing published
        r.phoneLink.publish(recording: r.recording())
        r.transports.phone.setUp(false)
        await r.phoneLink.pairClock()  // no link
        await r.phone.stop()
        XCTAssertTrue(try samples(in: r.phoneRoot).events("device.clock", "peer_clock").isEmpty)
    }

    func testTheWatchsSessionsSurviveThePhonesStop() async throws {
        let r = try await rig()
        let id = "aaaaaaaa-1111-4111-8111-111111111111"
        try await r.phone.start(RecordingSpec(id: id, label: "Walking"))
        r.phoneLink.publish(recording: r.recording(id))
        await until("the watch's session to be noted") { r.phone.recordings.find(id: id)?.peerEngineSessions?.isEmpty == false }
        // Found on a simulator pair: the phone's Stop saved its own copy of the record over this.
        await r.phone.stop()
        XCTAssertEqual(r.phone.recordings.find(id: id)?.endReason, "user_stop")
        XCTAssertEqual(r.phone.recordings.find(id: id)?.peerEngineSessions?.count, 1, "an export finds the watch's chunks through these")
    }

    func testStatusReachesThePhone() async throws {
        let r = try await rig()
        r.phoneLink.publish(recording: r.recording())
        await until("the first status") { r.phoneLink.peer.status?.recordingId == "aaaaaaaa-1111-4111-8111-111111111111" }
        XCTAssertNotNil(r.phoneLink.peer.status?.engineSession)
    }
}
