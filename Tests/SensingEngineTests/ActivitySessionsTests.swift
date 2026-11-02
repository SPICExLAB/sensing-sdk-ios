import Foundation
import SensingCore
import SensingStorage
import XCTest
@testable import SensingEngine

/// Android's ActivitySessionsTest case for case, plus the persistence around it.
final class ActivitySessionsTests: XCTestCase {
    private let clock = FakeClock()
    private let spec = SessionSpec(
        sessionId: "5b0f0c1e-7a7d-4c55-9a8e-111111111111", label: "Cooking", maxDurationMs: 3_600_000,
        startAttrs: ["config_id": "free/cooking", "config_version": "2"],
        labelAttrs: ["label_id": "9c3e2b1a-1d2e-4f00-8b7a-222222222222", "kind": "interval", "taxonomy_id": "daily/cooking"],
        sensors: ["motion.gyroscope": SensorOverride(enabled: true, samplingPeriodUs: 5000)],
        peerSensors: ["motion.accelerometer": SensorOverride(enabled: true, samplingPeriodUs: 10000, extras: ["k": "v"])])
    private var active: ActiveSession { ActiveSession(spec: spec, startWallMs: 1000, startMonoNs: 5_000_000) }

    func testStartOpensTheSessionAndItsIntervalLabelAtTheSameInstant() {
        let events = SessionEvents.start(active)
        XCTAssertEqual(events.map(\.kind), ["session_start", "label_upsert"])
        XCTAssertEqual(events[0].attrs["session_id"], spec.sessionId)
        XCTAssertEqual(events[0].attrs["config_id"], "free/cooking")
        XCTAssertEqual(events[0].attrs["start_wall_ms"], "1000")
        XCTAssertEqual(events[1].attrs["start_mono_ns"], "5000000")
        XCTAssertNil(events[1].attrs["end_wall_ms"], "an open interval has no end")
    }

    func testStopClosesTheLabelWithTheAnswersThenEndsTheSession() {
        let ended = EndedSession(session: active, endWallMs: 9000, endMonoNs: 13_000_000, reason: ActivitySessions.stopped, answered: true)
        let events = SessionEvents.end(ended, answers: ["where": "Home"])
        XCTAssertEqual(events.map(\.kind), ["label_upsert", "session_end"])
        XCTAssertEqual(events[0].attrs["attr.where"], "Home")
        XCTAssertEqual(events[0].attrs["end_wall_ms"], "9000")
        XCTAssertEqual(events[0].attrs["start_wall_ms"], "1000")
        XCTAssertEqual(events[1].attrs["end_reason"], "stopped")
    }

    func testDiscardDeletesTheLabelAndARebootLeavesTheMonoEndOut() {
        let ended = EndedSession(session: active, endWallMs: 9000, endMonoNs: nil, reason: ActivitySessions.discarded, answered: true)
        let events = SessionEvents.end(ended, answers: [:])
        XCTAssertEqual(events[0].kind, "label_delete")
        XCTAssertEqual(events[0].attrs["label_id"], spec.labelAttrs["label_id"])
        XCTAssertNil(events[1].attrs["end_mono_ns"])
    }

    func testASessionWithoutALabelWritesOnlyStartAndEnd() {
        var bare = active
        bare.spec.labelAttrs = [:]
        XCTAssertEqual(SessionEvents.start(bare).map(\.kind), ["session_start"])
        XCTAssertEqual(SessionEvents.end(EndedSession(session: bare, endWallMs: 2, endMonoNs: 2, reason: "stopped", answered: true), answers: [:]).map(\.kind), ["session_end"])
    }

    func testOutboxKeepsAnEventUntilThisProcessWroteIt30SecondsAgoAndANewProcessWritesItAgain() {
        var first = LabelOutbox(processId: "p1")
        first.add([("a", [:]), ("b", [:])])
        XCTAssertEqual(first.due().count, 2)
        first.markEmitted([first.entries[0].id], nowMonoMs: 1000)
        XCTAssertEqual(first.due().map(\.kind), ["b"])
        first.prune(nowMonoMs: 30_999)
        XCTAssertEqual(first.entries.count, 2, "still inside its batch window")
        // The process dies here: the next one sees "a" as written by someone else and writes it again.
        let second = LabelOutbox(processId: "p2", entries: first.entries)
        XCTAssertEqual(second.due().map(\.kind), ["a", "b"])
        first.prune(nowMonoMs: 31_000)
        XCTAssertEqual(first.entries.map(\.kind), ["b"])
    }

    func testOutboxClearsWhatThisProcessWroteOnceItsChunkSealed() {
        var o = LabelOutbox(processId: "p1")
        o.add([("a", [:]), ("b", [:])])
        o.markEmitted([o.entries[0].id], nowMonoMs: 1000)
        o.pruneAllEmitted()
        XCTAssertEqual(o.entries.map(\.kind), ["b"], "no 30 s wait, and an unwritten event stays")
    }

    func testActiveAndEndedSessionsSurviveAJSONRoundTrip() throws {
        XCTAssertEqual(try JSONDecoder().decode(ActiveSession.self, from: JSONEncoder().encode(active)), active)
        let ended = EndedSession(session: active, endWallMs: 9000, endMonoNs: nil, reason: ActivitySessions.timeLimit, answered: false)
        XCTAssertEqual(try JSONDecoder().decode(EndedSession.self, from: JSONEncoder().encode(ended)), ended)
    }

    func testTheWatchsCopyRunsThePhonesPeerSensorsAsItsOwnWithNoLabels() {
        let peer = active.peerCopy(nowMonoNs: 42)
        XCTAssertTrue(peer.mirrored)
        XCTAssertEqual(peer.spec.sensors, spec.peerSensors)
        XCTAssertTrue(peer.spec.labelAttrs.isEmpty && peer.spec.startAttrs.isEmpty)
        XCTAssertEqual(peer.deadlineWallMs, active.deadlineWallMs)
        XCTAssertEqual(peer.startMonoNs, 42)
        XCTAssertNil(peer.spec.sensors["motion.gyroscope"])
    }

    // The store.

    private func written(_ s: ActivitySessions) async -> [SessionEvent] {
        final class Box: @unchecked Sendable {
            var events: [SessionEvent] = []
        }
        let box = Box()
        await s.flush { kind, attrs in
            box.events.append((kind, attrs))
            return true
        }
        return box.events
    }

    func testOneAtATime() throws {
        let s = ActivitySessions(root: try tempRoot(), clock: clock)
        try s.start(spec)
        XCTAssertThrowsError(try s.start(spec)) { XCTAssertEqual($0 as? ActivitySessions.SessionError, .alreadyRunning) }
    }

    func testASessionAndItsEventsSurviveProcessDeath() async throws {
        let root = try tempRoot()
        let first = ActivitySessions(root: root, clock: clock)
        try first.start(spec)
        let wroteOnce = await written(first)
        XCTAssertEqual(wroteOnce.map(\.kind), ["session_start", "label_upsert"])
        let again = await written(first)
        XCTAssertTrue(again.isEmpty, "this process already wrote them")
        // Dead before the batch reached the file: the next process doesn't know, so it writes them again.
        let second = ActivitySessions(root: root, clock: clock)
        XCTAssertEqual(second.active?.spec.sessionId, spec.sessionId)
        let wroteAgain = await written(second)
        XCTAssertEqual(wroteAgain.map(\.kind), ["session_start", "label_upsert"])
    }

    func testFlushStopsAtTheFirstRefusalAndKeepsTheRest() async throws {
        let s = ActivitySessions(root: try tempRoot(), clock: clock)
        try s.start(spec)
        let n = await s.flush { kind, _ in kind == "session_start" }
        XCTAssertEqual(n, 1)
        let rest = await written(s)
        XCTAssertEqual(rest.map(\.kind), ["label_upsert"])
    }

    func testSealedChunksClearTheOutbox() async throws {
        let s = ActivitySessions(root: try tempRoot(), clock: clock)
        try s.start(spec)
        _ = await written(s)
        XCTAssertEqual(s.pendingEvents, 2)
        s.chunksSealed()
        XCTAssertEqual(s.pendingEvents, 0)
    }

    func testASessionPastItsLimitEndsAtItsDeadlineAndLeavesItsQuestionsOpen() async throws {
        let s = ActivitySessions(root: try tempRoot(), clock: clock)
        let a = try s.start(spec)
        XCTAssertFalse(s.expireIfDue())
        clock.advance(ms: spec.maxDurationMs)
        XCTAssertTrue(s.expireIfDue())
        XCTAssertNil(s.active)
        let ended = try XCTUnwrap(s.lastEnded)
        XCTAssertEqual(ended.reason, ActivitySessions.timeLimit)
        XCTAssertEqual(ended.endWallMs, a.deadlineWallMs)
        XCTAssertFalse(ended.answered)
        _ = await written(s)
        s.answerLast(["where": "Home"])
        XCTAssertEqual(s.lastEnded?.answered, true)
        let answered = await written(s)
        XCTAssertEqual(answered.map(\.kind), ["label_upsert"])
        XCTAssertEqual(answered[0].attrs["attr.where"], "Home")
    }

    func testAStoppedSessionHasNothingLeftToAsk() throws {
        let s = ActivitySessions(root: try tempRoot(), clock: clock)
        try s.start(spec)
        s.stop(answers: ["where": "Home"])
        XCTAssertEqual(s.lastEnded?.answered, true)
        XCTAssertEqual(s.lastEnded?.reason, ActivitySessions.stopped)
    }

    func testAMirroredSessionRunsButWritesNoEvents() async throws {
        let s = ActivitySessions(root: try tempRoot(), clock: clock)
        s.mirror(active.peerCopy(nowMonoNs: 1))
        XCTAssertEqual(s.active?.mirrored, true)
        s.mirror(nil)
        XCTAssertNil(s.active)
        let none = await written(s)
        XCTAssertTrue(none.isEmpty)
    }

    func testAPeersSessionNeverReplacesThisDevicesOwn() throws {
        let s = ActivitySessions(root: try tempRoot(), clock: clock)
        try s.start(spec)
        var other = active.peerCopy(nowMonoNs: 1)
        other.spec.sessionId = "another"
        s.mirror(other)
        XCTAssertEqual(s.active?.spec.sessionId, spec.sessionId)
        s.mirror(nil)
        XCTAssertEqual(s.active?.spec.sessionId, spec.sessionId)
    }
}
