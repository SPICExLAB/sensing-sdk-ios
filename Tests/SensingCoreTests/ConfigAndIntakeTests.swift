import SensingProto
import XCTest
@testable import SensingCore

/// Android's CollectionConfigTest, without remote config: the same rules apply to the app's own choices.
final class CollectionConfigTests: XCTestCase {
    private let accel = SensorID(known: "motion.accelerometer")
    private let gyro = SensorID(known: "motion.gyroscope")
    private let linear = SensorID(known: "motion.linear_accel")
    private let baro = SensorID(known: "env.barometer")
    private let bogus = SensorID(known: "motion.bogus")

    private var catalog: [CatalogEntry] {
        [CatalogEntry(id: accel, title: "Accelerometer", detail: "", setting: .hz(50), defaultOn: true),
         CatalogEntry(id: gyro, title: "Gyroscope", detail: "", setting: .hz(50), defaultOn: true),
         CatalogEntry(id: linear, title: "Linear acceleration", detail: "", setting: .hz(50), defaultOn: false),
         CatalogEntry(id: baro, title: "Barometer", detail: "", setting: .hz(5), defaultOn: true)]
    }

    func testFilterKeepsOnlyAdmittedSensors() {
        let c = CollectionConfig.resolve(catalog: catalog).filter { $0.group == "motion" }
        XCTAssertTrue(c.sensors.keys.allSatisfy { $0.group == "motion" })
        XCTAssertNotNil(c.sensors[accel])
    }

    func testDefaultsFollowTheCatalog() {
        let keys = CollectionConfig.resolve(catalog: catalog).sensors.keys
        XCTAssertTrue(keys.contains(gyro))
        XCTAssertFalse(keys.contains(linear))
    }

    func testASessionOnlyAdds() {
        let overrides = [gyro: SensorOverride(enabled: false), baro: SensorOverride(samplingPeriodUs: 1_000_000)]
        let session = [gyro: SensorOverride(samplingPeriodUs: 5000), accel: SensorOverride(samplingPeriodUs: 40000),
                       baro: SensorOverride(samplingPeriodUs: 100_000), bogus: SensorOverride(samplingPeriodUs: 1000)]
        let c = CollectionConfig.resolve(catalog: catalog, overrides: overrides, session: session)
        XCTAssertEqual(c.sensors[gyro]?.samplingPeriodUs, 5000, "the session turns on what was turned off")
        XCTAssertEqual(c.sensors[accel]?.samplingPeriodUs, 20000, "a slower session rate never slows a sensor")
        XCTAssertEqual(c.sensors[baro]?.samplingPeriodUs, 100_000, "the session beats the override's rate")
        XCTAssertNil(c.sensors[bogus], "a sensor outside the catalog can't be switched on")
        XCTAssertNil(CollectionConfig.resolve(catalog: catalog, overrides: overrides).sensors[gyro], "without the session, it's off again")
    }

    func testFasterKeepsAnEventDrivenSensorEventDriven() {
        let c = CollectionConfig.faster(SensorSetting(samplingPeriodUs: nil), SensorOverride(enabled: true, samplingPeriodUs: 1000, extras: ["k": "v"]))
        XCTAssertNil(c.samplingPeriodUs)
        XCTAssertEqual(c.extras["k"], "v")
    }

    func testOverridesSwitchAndChangeRatesButCannotAddUnknownSensors() {
        let c = CollectionConfig.resolve(catalog: catalog, overrides: [linear: .init(enabled: true), gyro: .init(enabled: false), bogus: .init(enabled: true), baro: .init(samplingPeriodUs: 1_000_000)])
        XCTAssertNotNil(c.sensors[linear])
        XCTAssertNil(c.sensors[gyro])
        XCTAssertNil(c.sensors[bogus])
        XCTAssertEqual(c.sensors[baro]?.samplingPeriodUs, 1_000_000)
    }

    func testRateLabels() {
        XCTAssertEqual(CollectionConfig.rateLabel(.hz(50), detail: ""), "50 Hz")
        XCTAssertEqual(CollectionConfig.rateLabel(SensorSetting(samplingPeriodUs: 30_000_000), detail: ""), "every 30 s")
        XCTAssertEqual(CollectionConfig.rateLabel(SensorSetting(samplingPeriodUs: 300_000_000), detail: ""), "every 5 min")
        XCTAssertEqual(CollectionConfig.rateLabel(SensorSetting(), detail: "on each step"), "on each step")
    }
}

final class IntakeTests: XCTestCase {
    private func push(_ i: Intake, slot: Int32 = 0, n: Int) {
        for k in 0..<n { i.push(slot: slot, tsMonoNs: Int64(k), tsWallMs: 0, accuracy: .high, payload: .scalar(Float(k))) }
    }

    func testSeqIsPerStreamAndStartsAtZero() {
        let i = Intake(ceiling: 100)
        i.open(slots: 2)
        push(i, slot: 0, n: 3)
        push(i, slot: 1, n: 2)
        push(i, slot: 0, n: 1)
        let d = i.drain()
        XCTAssertEqual(d.samples.filter { $0.slot == 0 }.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(d.samples.filter { $0.slot == 1 }.map(\.seq), [0, 1])
    }

    func testADropConsumesItsNumberAndConsecutiveDropsAreOneRun() {
        let i = Intake(ceiling: 5)
        i.open(slots: 1)
        push(i, n: 12)
        let d = i.drain()
        XCTAssertEqual(d.samples.map(\.seq), [0, 1, 2, 3, 4])
        XCTAssertEqual(d.drops, [Intake.DropRun(slot: 0, firstSeq: 5, lastSeq: 11, count: 7, pending: 5)])
        XCTAssertEqual(i.dropped, 7)
        push(i, n: 1)
        XCTAssertEqual(i.drain().samples.map(\.seq), [12], "the next sample carries on from the drops")
    }

    func testPushesWhenClosedAreIgnored() {
        let i = Intake(ceiling: 5)
        push(i, n: 0)
        i.open(slots: 1)
        i.close()
        push(i, n: 3)
        XCTAssertTrue(i.drain().samples.isEmpty)
    }

    func testOpeningResetsSeq() {
        let i = Intake(ceiling: 50)
        i.open(slots: 1)
        push(i, n: 3)
        i.open(slots: 1)
        push(i, n: 1)
        XCTAssertEqual(i.drain().samples.map(\.seq), [0])
    }

    func testConcurrentPushesLoseNothingAndKeepSeqUnique() {
        let i = Intake(ceiling: 1_000_000)
        i.open(slots: 4)
        DispatchQueue.concurrentPerform(iterations: 4) { slot in
            for k in 0..<10_000 { i.push(slot: Int32(slot), tsMonoNs: Int64(k), tsWallMs: 0, accuracy: .high, payload: .vec3(1, 2, 3)) }
        }
        let d = i.drain()
        XCTAssertEqual(d.samples.count, 40_000)
        for slot in 0..<4 {
            XCTAssertEqual(d.samples.filter { $0.slot == Int32(slot) }.map(\.seq), (0..<10_000).map(Int64.init))
        }
    }

    func testMotionPayloadsAreStoredInline() {
        // A pointer-sized check that a push won't allocate: an inline enum holding 5 floats.
        if case .quat = RawPayload.quat(1, 2, 3, 4, headingAccuracy: 5) {} else { XCTFail() }
        XCTAssertLessThanOrEqual(MemoryLayout<Intake.Stamped>.size, 96)
    }
}

final class SleepOffsetTrackerTests: XCTestCase {
    func testASampleGetsTheOffsetThatHeldWhenItWasTaken() {
        let t = SleepOffsetTracker(uptimeNs: 1000, offsetNs: 5_000_000)
        XCTAssertEqual(t.monoNs(forUptimeNs: 2000), 5_002_000)
        // The device sleeps for 60 s at uptime 10_000_000.
        t.observe(uptimeNs: 10_000_000, offsetNs: 60_005_000_000)
        XCTAssertEqual(t.monoNs(forUptimeNs: 9_000_000), 14_000_000, "taken before the sleep, delivered after: not late by the sleep")
        XCTAssertEqual(t.monoNs(forUptimeNs: 11_000_000), 60_016_000_000)
    }

    func testReadingNoiseIsNotASleep() {
        let t = SleepOffsetTracker(uptimeNs: 0, offsetNs: 5_000_000)
        t.observe(uptimeNs: 100, offsetNs: 5_000_500)
        XCTAssertEqual(t.monoNs(forUptimeNs: 200), 5_000_200)
    }

    func testTimestampsInSeconds() {
        let t = SleepOffsetTracker(uptimeNs: 0, offsetNs: 1000)
        XCTAssertEqual(t.monoNs(forTimestamp: 13395.904191), 13_395_904_191_000 + 1000, accuracy: 1000)
    }

    func testAnEarlierSampleThanAnyChangeUsesTheOldestOffset() {
        let t = SleepOffsetTracker(uptimeNs: 1000, offsetNs: 7)
        XCTAssertEqual(t.monoNs(forUptimeNs: 500), 507)
    }
}
