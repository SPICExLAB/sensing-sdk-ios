import Foundation
import SensingCore
import SensingProto
import SensingStorage
import XCTest
@testable import SensingEngine

final class CollectionEngineTests: XCTestCase {
    private let accel = SensorID(known: "motion.accelerometer")
    private let gyro = SensorID(known: "motion.gyroscope")
    private let clock = FakeClock()

    private func options(_ edit: (inout CollectionEngine.Options) -> Void = { _ in }) -> CollectionEngine.Options {
        var o = CollectionEngine.Options()
        o.manualTick = true
        o.freeBytes = { 1 << 40 }
        edit(&o)
        return o
    }

    private func config(_ ids: SensorID..., hz: Int64 = 50) -> CollectionConfig {
        CollectionConfig(sensors: Dictionary(uniqueKeysWithValues: ids.map { ($0, .hz(hz)) }))
    }

    private func feed(_ a: FakeAdapter, _ sensor: SensorID, _ n: Int64, periodMs: Int64 = 20) {
        guard let sink = a.sinks[sensor] else { return XCTFail("\(sensor) isn't running") }
        for _ in 0..<n {
            clock.advance(ms: periodMs)
            sink.vec3(1, 2, 3, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs(), accuracy: .high)
        }
    }

    func testStartAndStopWriteTheSessionAndClockEventsAndStampEverySample() async throws {
        let root = try tempRoot()
        var o = options()
        o.deviceKind = .watch
        let engine = CollectionEngine(root: root, deviceId: "device-1", clock: clock, options: o)
        let adapter = FakeAdapter(accel)
        let session = await engine.start(config(accel), adapters: [adapter], attrs: ["platform": "ios"])
        feed(adapter, accel, 10)
        await engine.stop(reason: "user_stop")

        let all = try samples(in: root)
        let sessionId = try XCTUnwrap(session)
        XCTAssertEqual(sessionId, sessionId.lowercased())
        XCTAssertTrue(all.allSatisfy { $0.sessionID == sessionId && $0.deviceID == "device-1" && $0.deviceKind == .watch && $0.schemaVersion == 1 })
        let start = try XCTUnwrap(all.events("device.session", "start").first)
        XCTAssertEqual(start.event.attributes["reason"], "engine_start")
        XCTAssertEqual(start.event.attributes["platform"], "ios")
        XCTAssertEqual(all.events("device.session", "end").first?.event.attributes["reason"], "user_stop")
        let clockEvent = try XCTUnwrap(all.events("device.clock", "clock").first)
        XCTAssertNotNil(clockEvent.event.attributes["mono_ns"])
        XCTAssertNotNil(clockEvent.event.attributes["wall_ms"])
        XCTAssertEqual(all.stream("motion.accelerometer").map(\.seq), Array(0..<10))
        XCTAssertEqual(all.stream("motion.accelerometer").first?.accuracy, .high)
        XCTAssertEqual(all.stream("motion.accelerometer").first?.vec3.z, 3)
        XCTAssertEqual(adapter.stopCount, 1)
    }

    func testSeqStaysContiguousAcrossBatchesAndSealedChunks() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        for _ in 0..<120 {  // 12 minutes, so several chunks seal by age
            feed(adapter, accel, 300, periodMs: 20)
            clock.advance(ms: 0)
            await engine.tick()
        }
        await engine.stop()
        let chunks = await engine.chunks().filter { $0.sensorId == "motion.accelerometer" }
        XCTAssertGreaterThanOrEqual(chunks.count, 3, "chunks seal at 5 min")
        XCTAssertEqual(try samples(in: root).stream("motion.accelerometer").map(\.seq), Array(0..<36000))
        let sorted = chunks.sorted { $0.firstSeq < $1.firstSeq }
        for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertEqual(a.lastSeq + 1, b.firstSeq) }
    }

    func testAQuietStreamStillReachesDiskWithinTheBatchWindow() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        feed(adapter, accel, 1)
        await engine.tick()
        clock.advance(ms: 2000)
        await engine.tick()
        let sessionId = await engine.stats().sessionId
        let tmp = root.sessionDirectory(try XCTUnwrap(sessionId)).appendingPathComponent("motion.accelerometer_0.pb.gz.tmp")
        XCTAssertGreaterThan(try Data(contentsOf: tmp).count, 0, "written to the kernel, so a process kill wouldn't lose it")
        await engine.stop()
    }

    func testEveryStartIsANewSessionAndSeqRestarts() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        let first = await engine.start(config(accel), adapters: [adapter])
        feed(adapter, accel, 3)
        await engine.stop()
        let second = await engine.start(config(accel), adapters: [adapter])
        feed(adapter, accel, 2)
        await engine.stop()
        XCTAssertNotEqual(first, second)
        let all = try samples(in: root)
        XCTAssertEqual(all.filter { $0.sessionID == second && $0.sensorID == "motion.accelerometer" }.map(\.seq).sorted(), [0, 1])
    }

    func testStartWhileRunningDoesNothingAndStopWhenStoppedIsSafe() async throws {
        let engine = CollectionEngine(root: try tempRoot(), deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        let first = await engine.start(config(accel), adapters: [adapter])
        let again = await engine.start(config(accel), adapters: [adapter])
        XCTAssertNotNil(first)
        XCTAssertNil(again)
        XCTAssertEqual(adapter.startCount, 1)
        await engine.stop()
        await engine.stop()
        XCTAssertEqual(adapter.stopCount, 1)
    }

    func testEventsAreRefusedWhenNoSessionIsOpen() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let refused = await engine.emit(SensorIDs.label, "session_start", [:])
        XCTAssertFalse(refused)
        await engine.start(config(accel), adapters: [FakeAdapter(accel)])
        let accepted = await engine.emit(SensorIDs.label, "session_start", ["session_id": "x"])
        XCTAssertTrue(accepted)
        await engine.stop()
        XCTAssertEqual(try samples(in: root).stream("label.session").map(\.event.kind), ["session_start"])
    }

    func testASampleArrivingAfterStopIsIgnored() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        let sink = try XCTUnwrap(adapter.sinks[accel])
        await engine.stop()
        sink.vec3(1, 2, 3, tsMonoNs: 1, tsWallMs: 1)
        let pending = await engine.stats().pending
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(try samples(in: root).stream("motion.accelerometer").isEmpty)
    }

    func testASensorThatCannotRunIsSaidOutLoud() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let mag = SensorID(known: "motion.magnetometer")
        let adapter = FakeAdapter(accel, gyro)
        adapter.availabilities[gyro] = .missingPermission(["motion"])
        await engine.start(config(accel, gyro, mag), adapters: [adapter])
        await engine.stop()
        let health = try samples(in: root).events("device.health", "adapter_unavailable")
        let reasons = Dictionary(uniqueKeysWithValues: health.map { ($0.event.attributes["sensor"]!, $0.event.attributes["reason"]!) })
        XCTAssertEqual(reasons["motion.gyroscope"], "missing_permission:motion")
        XCTAssertEqual(reasons["motion.magnetometer"], "missing_hardware", "no adapter claimed it")
        XCTAssertNil(reasons["motion.accelerometer"])
        XCTAssertEqual(adapter.settings.keys.map(\.value), ["motion.accelerometer"])
    }

    func testOneFailingAdapterRetriesWithBackoffAndTheOthersKeepRunning() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let bad = FakeAdapter(gyro)
        bad.failuresLeft = 2
        let good = FakeAdapter(accel)
        await engine.start(config(accel, gyro), adapters: [bad, good])
        XCTAssertEqual(bad.startCount, 1)
        feed(good, accel, 5)
        await engine.tick()
        XCTAssertEqual(bad.startCount, 1, "not before the backoff")
        clock.advance(ms: 1000)
        await engine.tick()
        XCTAssertEqual(bad.startCount, 2)
        clock.advance(ms: 1000)
        await engine.tick()
        XCTAssertEqual(bad.startCount, 2, "the backoff doubled")
        clock.advance(ms: 1000)
        await engine.tick()
        XCTAssertEqual(bad.startCount, 3)
        let failures = await engine.stats().adapterFailures
        XCTAssertEqual(failures, 2)
        XCTAssertNotNil(bad.sinks[gyro], "it's running now")
        feed(bad, gyro, 1)
        await engine.stop()
        let all = try samples(in: root)
        XCTAssertEqual(all.events("device.health", "adapter_failure").count, 2)
        XCTAssertEqual(all.events("device.health", "adapter_failure").first?.event.attributes["error"], "boom")
        XCTAssertEqual(all.stream("motion.gyroscope").count, 1)
    }

    func testDropsConsumeTheirNumbersAndBecomeOneGapEvent() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options { $0.hardCeiling = 10 })
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        await engine.tick()  // clears the start events
        feed(adapter, accel, 25)
        await engine.tick()
        feed(adapter, accel, 2)
        await engine.stop()
        let all = try samples(in: root)
        let seqs = all.stream("motion.accelerometer").map(\.seq)
        XCTAssertEqual(seqs, Array(0..<10) + [25, 26])
        let gaps = all.events("device.gap", "buffer_ceiling")
        XCTAssertEqual(gaps.count, 1, "Android would write 15")
        XCTAssertEqual(gaps[0].event.attributes["sensor"], "motion.accelerometer")
        XCTAssertEqual(gaps[0].event.attributes["seq"], "10")
        XCTAssertEqual(gaps[0].event.attributes["last_seq"], "24")
        XCTAssertEqual(gaps[0].event.attributes["count"], "15")
        let dropped = await engine.stats().dropped
        XCTAssertEqual(dropped, 15)
    }

    func testABacklogWarnsOnceAndRearms() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options { $0.highWater = 20 })
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        feed(adapter, accel, 30)
        await engine.tick()
        feed(adapter, accel, 30)
        await engine.tick()
        await engine.tick()  // nothing waiting: it re-arms
        feed(adapter, accel, 30)
        await engine.tick()
        await engine.stop()
        XCTAssertEqual(try samples(in: root).events("device.health", "persist_backlog").count, 2, "over, still over, clear, over again")
    }

    func testAClockEventEvery15Minutes() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        await engine.start(config(accel), adapters: [FakeAdapter(accel)])
        for _ in 0..<31 {
            clock.advance(ms: 60_000)
            await engine.tick()
        }
        await engine.stop()
        XCTAssertEqual(try samples(in: root).events("device.clock", "clock").count, 3, "at the start, then at 15 and 30 minutes")
    }

    func testALateTickIsRecordedWithHowMuchWasSleep() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        await engine.start(config(accel), adapters: [FakeAdapter(accel)])
        clock.advance(ms: 500)
        await engine.tick()
        clock.advance(ms: 60_000, sleepMs: 50_000)
        await engine.tick()
        await engine.stop()
        let stalls = try samples(in: root).events("device.gap", "process_stall")
        XCTAssertEqual(stalls.count, 1)
        XCTAssertEqual(stalls[0].event.attributes["sleep_ns"], "50000000000")
        let from = try XCTUnwrap(Int64(stalls[0].event.attributes["from_mono_ns"] ?? ""))
        let to = try XCTUnwrap(Int64(stalls[0].event.attributes["to_mono_ns"] ?? ""))
        XCTAssertEqual(to - from, 60_000_000_000)
    }

    func testAStreamThatGoesQuietIsRecordedFromItsOwnTimestamps() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        feed(adapter, accel, 5)
        clock.advance(ms: 900)  // under the 1 s floor: not a gap
        feed(adapter, accel, 5)
        clock.advance(ms: 5000)
        feed(adapter, accel, 5)
        await engine.stop()
        // No tick ran, so this was only seen during Stop's own drain: an event raised there must still land.
        let gaps = try samples(in: root).events("device.gap", "delivery_gap")
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.event.attributes["sensor"], "motion.accelerometer")
    }

    func testAnEventDrivenStreamHasNoDeliveryGaps() async throws {
        let root = try tempRoot()
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        await engine.start(CollectionConfig(sensors: [accel: SensorSetting()]), adapters: [adapter])
        feed(adapter, accel, 1)
        clock.advance(ms: 60_000)
        feed(adapter, accel, 1)
        await engine.stop()
        XCTAssertTrue(try samples(in: root).events("device.gap", "delivery_gap").isEmpty)
    }

    func testAtTheQuotaItStopsCleanlyAndSaysWhy() async throws {
        let root = try tempRoot()
        final class Heard: @unchecked Sendable {
            var reason: String?
        }
        let heard = Heard()
        var o = options {
            $0.policy = RetentionPolicy(hardCapBytes: 2000, minQuotaBytes: 0)
            $0.chunkLimits.maxBytes = 1000
        }
        o.retentionCheckMs = 1000
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: o) { heard.reason = $0 }
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        for _ in 0..<30 {
            guard await engine.isRunning else { break }
            feed(adapter, accel, 100)
            clock.advance(ms: 2000)
            await engine.tick()
        }
        let running = await engine.isRunning
        XCTAssertFalse(running)
        XCTAssertEqual(heard.reason, "quota_reached")
        let all = try samples(in: root)
        XCTAssertEqual(all.events("device.session", "end").last?.event.attributes["reason"], "quota_reached")
        XCTAssertEqual(all.stream("motion.accelerometer").map(\.seq), (0..<UInt64(all.stream("motion.accelerometer").count)).map { $0 }, "nothing was deleted")
    }

    func testEvictOldestRecordsEveryLossInTheStream() async throws {
        let root = try tempRoot()
        var o = options {
            $0.policy = RetentionPolicy(hardCapBytes: 3000, minQuotaBytes: 0)
            $0.retentionMode = .evictOldest
            $0.chunkLimits.maxBytes = 1000
        }
        o.retentionCheckMs = 1000
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: o)
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        for _ in 0..<30 {
            feed(adapter, accel, 100)
            clock.advance(ms: 2000)
            await engine.tick()
        }
        await engine.stop()
        let all = try samples(in: root)
        let evicted = all.events("device.storage_evicted", "tick")
        XCTAssertFalse(evicted.isEmpty)
        for e in evicted {
            XCTAssertEqual(e.event.attributes["sensor"], "motion.accelerometer")
            XCTAssertNotNil(e.event.attributes["first_seq"])
            XCTAssertNotNil(e.event.attributes["last_seq"])
            XCTAssertNotNil(e.event.attributes["bytes"])
            XCTAssertNotNil(e.event.attributes["chunk"])
        }
        XCTAssertEqual(StorageOutbox.pending(root), [], "cleared once those events sealed")
    }

    func testEvictionNeverTakesLabelsOrTheRecordOfWhatWasLost() async throws {
        let root = try tempRoot()
        var o = options {
            $0.policy = RetentionPolicy(hardCapBytes: 1000, minQuotaBytes: 0)
            $0.retentionMode = .evictOldest
            $0.chunkLimits.maxBytes = 200
        }
        o.retentionCheckMs = 500
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: o)
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        await engine.emit(SensorIDs.label, "session_start", ["session_id": "a"])
        for i in 0..<40 {
            if i == 20 { await engine.emit(SensorIDs.label, "session_end", ["session_id": "a"]) }
            feed(adapter, accel, 100)
            clock.advance(ms: 2000)
            await engine.tick()
        }
        await engine.stop()
        let all = try samples(in: root)
        XCTAssertEqual(all.stream("label.session").map(\.event.kind), ["session_start", "session_end"])
        XCTAssertEqual(all.events("device.session", "start").count, 1)
        let lost = all.events("device.storage_evicted", "tick")
        XCTAssertFalse(lost.isEmpty)
        XCTAssertEqual(lost.map(\.seq), (0..<UInt64(lost.count)).map { $0 }, "no eviction record was itself evicted")
        XCTAssertTrue(lost.allSatisfy { $0.event.attributes["sensor"] == "motion.accelerometer" })
    }

    func testANewEngineRecoversWhatADeadOneLeftOpen() async throws {
        let root = try tempRoot()
        let dead = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        await dead.start(config(accel), adapters: [adapter])
        feed(adapter, accel, 10)
        await dead.tick()
        clock.advance(ms: 2000)
        await dead.tick()
        // It never stops: the process died.
        let next = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        let result = await next.recover()
        XCTAssertGreaterThanOrEqual(result.sealed, 1)
        XCTAssertEqual(try samples(in: root).stream("motion.accelerometer").map(\.seq), Array(0..<10))
        let chunks = await next.chunks()
        XCTAssertFalse(chunks.isEmpty)
    }

    func testTotalsCountEachSampleAndEventOnce() async throws {
        let engine = CollectionEngine(root: try tempRoot(), deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        await engine.tick()
        let atStart = await engine.stats().totalSamples
        XCTAssertEqual(atStart, 3, "device.session start, device.clock and the first heartbeat")
        feed(adapter, accel, 10)
        await engine.tick()
        let after = await engine.stats().totalSamples
        XCTAssertEqual(after, 13)
        await engine.stop()
    }

    func testLiveRatesComeFromTheSamplesOwnTimestamps() async throws {
        let engine = CollectionEngine(root: try tempRoot(), deviceId: "d", clock: clock, options: options())
        let adapter = FakeAdapter(accel)
        await engine.start(config(accel), adapters: [adapter])
        feed(adapter, accel, 150)
        await engine.tick()
        let stats = await engine.stats()
        XCTAssertEqual(stats.streams["motion.accelerometer"]?.count, 150)
        XCTAssertEqual(try XCTUnwrap(stats.streams["motion.accelerometer"]?.hz), 50, accuracy: 0.5)
        await engine.stop()
    }

    func testASoakOfEightStreamsAt100HzLosesNothing() async throws {
        let root = try tempRoot()
        let ids = (0..<8).map { SensorID(known: "motion.stream\($0)") }
        let adapter = FakeSoak(ids)
        let engine = CollectionEngine(root: root, deviceId: "d", clock: clock, options: options())
        await engine.start(CollectionConfig(sensors: Dictionary(uniqueKeysWithValues: ids.map { ($0, .hz(100)) })), adapters: [adapter])
        let started = Date()
        for _ in 0..<600 {  // 5 simulated minutes of 500 ms ticks
            for _ in 0..<50 {
                clock.advance(ms: 10)
                adapter.pushAll(mono: clock.monoNs(), wall: clock.wallMs())
            }
            await engine.tick()
        }
        await engine.stop()
        let elapsed = Date().timeIntervalSince(started)
        let stats = await engine.stats()
        XCTAssertEqual(stats.dropped, 0)
        let all = try samples(in: root)
        for id in ids { XCTAssertEqual(all.stream(id.value).map(\.seq), Array(0..<30000), id.value) }
        print("soak: 240000 samples, \(all.count) read back, 300 s simulated in \(elapsed) s")
    }
}

/// Internal view of the outbox, so a test can read it without an engine.
enum StorageOutbox {
    static func pending(_ root: StorageRoot) -> [EvictedChunk] { EvictionOutbox(root: root).pending() }
}

final class FakeSoak: SensorAdapter, @unchecked Sendable {
    let sensors: [SensorID]
    private var sinks: [SampleSink] = []

    init(_ sensors: [SensorID]) { self.sensors = sensors }
    func availability(of sensor: SensorID) -> Availability { .available }
    func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) { self.sinks = sensors.compactMap { sinks[$0] } }
    func stop() { sinks = [] }

    func pushAll(mono: Int64, wall: Int64) {
        for sink in sinks { sink.vec3(0.5, -9.8, 0.25, tsMonoNs: mono, tsWallMs: wall, accuracy: .high) }
    }
}
