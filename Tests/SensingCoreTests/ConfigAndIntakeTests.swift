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

import simd

/// inrtl-swift's convention vectors, against Android's units and signs.
final class ConversionTests: XCTestCase {
    func testAtRestFaceUpReadsLikeAndroid() {
        // CoreMotion at rest, face up: acceleration and gravity (0, 0, -1) g. Android: +9.81 on z.
        XCTAssertEqual(Conversions.metresPerSecondSquared(-1), 9.80665, accuracy: 1e-5)
        XCTAssertEqual(Conversions.metresPerSecondSquared(0), 0)
        // Pushed up at 1 g, CoreMotion reports user acceleration z = -1. Android's linear acceleration is +9.81.
        XCTAssertGreaterThan(Conversions.metresPerSecondSquared(-1), 0)
    }

    func testNorthTurnsIntoAndroidsFrame() {
        // A device whose x axis points north in CoreMotion's x-north frame must point north (+y) in Android's x-east frame.
        let q = Conversions.orientation(coreMotion: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), northReferenced: true)
        XCTAssertLessThan(simd_distance(q.act(SIMD3<Float>(1, 0, 0)), SIMD3(0, 1, 0)), 1e-6)
        // West (+y in x-north, y-west) becomes -x, since east is +x.
        XCTAssertLessThan(simd_distance(q.act(SIMD3<Float>(0, 1, 0)), SIMD3(-1, 0, 0)), 1e-6)
    }

    func testUpStaysUpForAnyAttitude() {
        for (axis, angle) in [(SIMD3<Double>(1, 2, 3), 0.7), (SIMD3(0, 1, 0), 2.5), (SIMD3(1, 0, 0), -1.2)] {
            let cm = simd_quatd(angle: angle, axis: simd_normalize(axis))
            let q = Conversions.orientation(coreMotion: cm, northReferenced: true)
            let upInDevice = cm.inverse.act(SIMD3<Double>(0, 0, 1))
            XCTAssertLessThan(simd_distance(q.act(SIMD3<Float>(upInDevice)), SIMD3(0, 0, 1)), 1e-5)
        }
    }

    func testAnArbitraryHeadingHasNoNorthToTurnFrom() {
        let cm = simd_quatd(angle: 0.4, axis: SIMD3(0, 0, 1))
        XCTAssertLessThan(simd_distance(Conversions.orientation(coreMotion: cm, northReferenced: false).vector, SIMD4<Float>(cm.vector)), 1e-6)
    }

    func testTheResultIsAUnitQuaternion() {
        let q = Conversions.orientation(coreMotion: simd_quatd(ix: 0.1, iy: 0.2, iz: 0.3, r: 0.9), northReferenced: true)
        XCTAssertEqual(simd_length(q.vector), 1, accuracy: 1e-5)
    }

    func testHeadingAccuracyIsRadiansOrMinusOne() {
        XCTAssertEqual(Conversions.headingAccuracy(degrees: 180), .pi, accuracy: 1e-5)
        XCTAssertEqual(Conversions.headingAccuracy(degrees: -1), -1)
    }

    func testCalibrationMapsToAndroidsAccuracy() {
        XCTAssertEqual(Conversions.accuracy(magneticCalibration: -1), .unreliable)
        XCTAssertEqual(Conversions.accuracy(magneticCalibration: 0), .low)
        XCTAssertEqual(Conversions.accuracy(magneticCalibration: 1), .medium)
        XCTAssertEqual(Conversions.accuracy(magneticCalibration: 2), .high)
    }

    func testWallTimeIsNowMinusTheSamplesAge() {
        struct Fixed: EngineClock {
            func monoNs() -> Int64 { 10_000_000_000 }
            func uptimeNs() -> Int64 { 0 }
            func wallMs() -> Int64 { 1_793_000_000_000 }
        }
        XCTAssertEqual(Conversions.wallMs(forMonoNs: 9_990_000_000, clock: Fixed()), 1_793_000_000_000 - 10)
    }

    func testCatalogsMatchThePlansDefaultRates() {
        func hz(_ c: [CatalogEntry], _ id: SensorID) -> Int64? { c.first { $0.id == id }?.setting.samplingPeriodUs.map { 1_000_000 / $0 } }
        XCTAssertEqual(hz(SensingCatalog.phone, SensingCatalog.accelerometer), 50)
        XCTAssertEqual(hz(SensingCatalog.watch, SensingCatalog.accelerometer), 25)
        XCTAssertEqual(hz(SensingCatalog.phone, SensingCatalog.magnetometer), 20)
        XCTAssertEqual(hz(SensingCatalog.watch, SensingCatalog.magnetometer), 10)
        XCTAssertEqual(hz(SensingCatalog.phone, SensingCatalog.gravity), 10)
        XCTAssertNil(hz(SensingCatalog.phone, SensingCatalog.barometer), "delivered at its own pace")
        XCTAssertNil(hz(SensingCatalog.phone, SensingCatalog.steps))
    }

    func testCPUTimeIsReadable() {
        let before = ProcessCPU.milliseconds()
        var x = 0.0
        for i in 0..<2_000_000 { x += sqrt(Double(i)) }
        XCTAssertGreaterThan(x, 0)
        XCTAssertGreaterThanOrEqual(ProcessCPU.milliseconds(), before)
    }
}

final class DecimatorTests: XCTestCase {
    /// Device motion measured on an iPhone 15 Pro when 50 Hz was asked for.
    private let source: Int64 = 19_890_000

    private func rate(targetHz: Int64, sourcePeriodNs: Int64, seconds: Int64, jitterNs: Int64 = 0) -> Double {
        var d = Decimator(periodUs: 1_000_000 / targetHz, sourcePeriodUs: 20000)  // the source was asked for 50 Hz
        var kept: Int64 = 0
        var t: Int64 = 1_000_000_000
        let end = t + seconds * 1_000_000_000
        var flip = false
        while t < end {
            flip.toggle()
            if d.take(tsNs: t + (flip ? jitterNs : -jitterNs)) { kept += 1 }
            t += sourcePeriodNs
        }
        return Double(kept) / Double(seconds)
    }

    func testThinsToTheAskedRateFromASourceThatIsNotAMultiple() {
        XCTAssertEqual(rate(targetHz: 10, sourcePeriodNs: source, seconds: 60), 10, accuracy: 0.2)
        XCTAssertEqual(rate(targetHz: 20, sourcePeriodNs: source, seconds: 60), 20, accuracy: 0.5)
    }

    func testKeepsEverySampleWhenTheRatesMatch() {
        XCTAssertEqual(rate(targetHz: 50, sourcePeriodNs: source, seconds: 60), 50.27, accuracy: 0.1)
    }

    func testJitterDoesNotLoseSamples() {
        XCTAssertEqual(rate(targetHz: 50, sourcePeriodNs: 20_000_000, seconds: 60, jitterNs: 1_000_000), 50, accuracy: 0.1)
    }

    func testThinningAStreamWithoutAKnownSourceStillKeepsTheAverage() {
        var d = Decimator(periodUs: 100_000)
        var kept = 0
        var t: Int64 = 0
        for _ in 0..<3000 {
            if d.take(tsNs: t) { kept += 1 }
            t += source
        }
        XCTAssertEqual(Double(kept) / (Double(t) / 1e9), 10, accuracy: 0.2)
    }

    func testAfterAStallItRestartsRatherThanBursts() {
        var d = Decimator(periodUs: 100_000)
        XCTAssertTrue(d.take(tsNs: 0))
        XCTAssertTrue(d.take(tsNs: 10_000_000_000))  // 10 s later
        XCTAssertFalse(d.take(tsNs: 10_020_000_000), "not a burst to catch up")
        XCTAssertTrue(d.take(tsNs: 10_100_000_000))
    }
}

/// Android's `DeviceAdaptersTest`, case for case where it applies, plus what's particular to iOS.
final class DeviceMappingTests: XCTestCase {
    func testBatteryAttributesUseAndroidsNames() {
        let a = BatteryEvent.attributes(levelFraction: 0.65, charge: .unplugged, lowPower: false, thermalState: 1)
        XCTAssertEqual(a["level"], "65")
        XCTAssertEqual(a["scale"], "100")
        XCTAssertEqual(a["pct"], "65")
        XCTAssertEqual(a["status"], "discharging")
        XCTAssertEqual(a["plugged"], "none")
        XCTAssertEqual(a["health"], "unknown")
        XCTAssertEqual(a["present"], "true")
        XCTAssertEqual(a["low_power"], "false")
        XCTAssertEqual(a["thermal_state"], "1")
        XCTAssertNil(a["temperature_c"], "iOS has none, so it's absent as on an Android device without one")
    }

    func testBatteryCharging() {
        XCTAssertEqual(BatteryEvent.attributes(levelFraction: 1, charge: .full, lowPower: true, thermalState: 0)["status"], "full")
        XCTAssertEqual(BatteryEvent.attributes(levelFraction: 0.5, charge: .charging, lowPower: false, thermalState: 0)["plugged"], "other")
    }

    func testAnUnknownBatteryLevelHasNoPercentage() {
        let a = BatteryEvent.attributes(levelFraction: -1, charge: .unknown, lowPower: false, thermalState: 0)
        XCTAssertEqual(a["level"], "-1")
        XCTAssertNil(a["pct"])
        XCTAssertEqual(a["status"], "unknown")
    }

    func testNetworkAttributesAreTheThreeFieldsThatDefineAChange() {
        XCTAssertEqual(NetworkEvent.attributes(transport: "wifi", metered: false, validated: true), ["transport": "wifi", "metered": "false", "validated": "true"])
        XCTAssertEqual(NetworkEvent.none["transport"], "none")
    }

    func testDbfsOfFullScaleHalfScaleAndSilence() {
        XCTAssertEqual(AudioLevel.dbfs(rms: 32767.0 / 32768.0), 0, accuracy: 0.01)
        XCTAssertEqual(AudioLevel.dbfs(rms: 16384.0 / 32768.0), -6.02, accuracy: 0.05)
        XCTAssertEqual(AudioLevel.dbfs(rms: 0), AudioLevel.floorDbfs)
    }

    func testBelowOneStepIsSilence() {
        XCTAssertEqual(AudioLevel.dbfs(rms: 0.5 / 32768.0), AudioLevel.floorDbfs)
        XCTAssertGreaterThan(AudioLevel.dbfs(rms: 2.0 / 32768.0), AudioLevel.floorDbfs)
    }

    func testAnAudioWindowAddsUpBuffersUntilItsFull() {
        var w = AudioLevel.Window(sampleRate: 48000, milliseconds: 1000)
        // Half scale, in buffers that don't line up with the window.
        for _ in 0..<11 { XCTAssertNil(w.add(sumSquares: 0.25 * 4096, count: 4096)) }
        let level = try? XCTUnwrap(w.add(sumSquares: 0.25 * 4096, count: 4096))
        XCTAssertEqual(level ?? 0, -6.02, accuracy: 0.05)
        XCTAssertNil(w.add(sumSquares: 0, count: 100), "it starts over")
    }

    func testScanRowsBecomeAnNBy2TensorNamedByHash() {
        let hash = IdentifierHash(salt: "s")
        var w = BluetoothWindow(salt: "s")
        w.record(identifier: "aa", rssi: -40, txPower: 4)
        w.record(identifier: "bb", rssi: -70, txPower: nil)
        let t = w.finish()
        XCTAssertEqual(t.shape, [2, 2])
        XCTAssertEqual(t.values, [-40, 4, -70, 127])
        XCTAssertEqual(t.names, [hash.hash("aa"), hash.hash("bb")])
        XCTAssertEqual(w.finish().shape, [0, 2], "the next window starts empty, and an empty scan is still recorded")
    }

    func testEachDeviceAppearsOnceWithItsLastReading() {
        var w = BluetoothWindow(salt: "s")
        w.record(identifier: "aa", rssi: -40, txPower: nil)
        w.record(identifier: "bb", rssi: -50, txPower: nil)
        w.record(identifier: "aa", rssi: -60, txPower: 1)
        XCTAssertEqual(w.finish().values, [-60, 1, -50, 127])
    }

    func testAnRssiOf127MeansNoReading() {
        var w = BluetoothWindow(salt: "s")
        w.record(identifier: "aa", rssi: 127, txPower: nil)
        XCTAssertEqual(w.finish().shape, [0, 2])
    }

    func testNoRawIdentifierReachesATensor() {
        var w = BluetoothWindow(salt: "s")
        let id = UUID().uuidString.lowercased()
        w.record(identifier: id, rssi: -40, txPower: nil)
        let t = w.finish()
        XCTAssertEqual(t.names.count, 1)
        XCTAssertFalse(t.names[0].contains(id))
        XCTAssertEqual(t.names[0].count, 16)
    }

    private func fix(hAcc: Double = 5, vAcc: Double = 3, speed: Double = 1.5, sAcc: Double = 0.2, course: Double = 90, cAcc: Double = 10) -> LocationMapping.Fix {
        LocationMapping.Fix(latitude: 51.5, longitude: -0.1, ellipsoidalAltitude: 60, horizontalAccuracy: hAcc, verticalAccuracy: vAcc, speed: speed, speedAccuracy: sAcc, course: course, courseAccuracy: cAcc)
    }

    func testAFixMapsToAndroidsFields() throws {
        let p = try XCTUnwrap(LocationMapping.payload(fix()))
        XCTAssertEqual(p.lat, 51.5)
        XCTAssertEqual(p.lon, -0.1)
        XCTAssertEqual(p.alt, 60)
        XCTAssertEqual(p.accuracy, 5)
        XCTAssertEqual(p.speed, 1.5)
        XCTAssertEqual(p.bearing, 90)
        XCTAssertEqual(p.provider, "corelocation")
        XCTAssertEqual(p.verticalAccuracy, 3)
        XCTAssertEqual(p.speedAccuracy, 0.2, accuracy: 1e-6)
        XCTAssertEqual(p.bearingAccuracy, 10)
        XCTAssertEqual(p.satellites, 0)
    }

    func testValuesCoreLocationDoesntHaveBecomeZero() throws {
        let p = try XCTUnwrap(LocationMapping.payload(fix(vAcc: -1, speed: -1, sAcc: -1, course: -1, cAcc: -1)))
        XCTAssertEqual(p.alt, 0, "an invalid altitude isn't a real one")
        XCTAssertEqual(p.speed, 0)
        XCTAssertEqual(p.bearing, 0)
        XCTAssertEqual(p.verticalAccuracy, 0)
        XCTAssertEqual(p.speedAccuracy, 0)
        XCTAssertEqual(p.bearingAccuracy, 0)
    }

    func testAFixWithNoPositionIsSkipped() {
        XCTAssertNil(LocationMapping.payload(fix(hAcc: -1)))
    }

    func testAFixSaysWhereItCameFrom() {
        var f = fix()
        f.simulated = true
        XCTAssertEqual(LocationMapping.payload(f)?.provider, "simulated")
        f = fix()
        f.accessory = true
        XCTAssertEqual(LocationMapping.payload(f)?.provider, "accessory")
    }

    func testActivityTransitionsEnterThenLeave() {
        var t = ActivityTransitions()
        var seen = t.observe(.init(stationary: true))
        XCTAssertEqual(seen.map(\.activity), ["still"])
        XCTAssertEqual(seen.map(\.transition), ["enter"])
        seen = t.observe(.init(walking: true))
        XCTAssertEqual(seen.map(\.activity), ["still", "walking"])
        XCTAssertEqual(seen.map(\.transition), ["exit", "enter"])
    }

    func testTheSameActivityTwiceIsNoTransition() {
        var t = ActivityTransitions()
        _ = t.observe(.init(walking: true))
        XCTAssertTrue(t.observe(.init(walking: true)).isEmpty)
    }

    func testUnknownLeavesTheCurrentActivityStanding() {
        var t = ActivityTransitions()
        _ = t.observe(.init(running: true))
        XCTAssertTrue(t.observe(.init()).isEmpty)
        XCTAssertEqual(t.observe(.init(walking: true)).map(\.activity), ["running", "walking"])
    }

    func testTheMostSpecificActivityWins() {
        var t = ActivityTransitions()
        XCTAssertEqual(t.observe(.init(stationary: true, automotive: true)).last?.activity, "in_vehicle", "a red light")
        t = ActivityTransitions()
        XCTAssertEqual(t.observe(.init(walking: true, cycling: true)).last?.activity, "on_bicycle")
        t = ActivityTransitions()
        XCTAssertEqual(t.observe(.init(walking: true, running: true)).last?.activity, "running")
        t = ActivityTransitions()
        XCTAssertEqual(t.observe(.init(stationary: true, walking: true)).last?.activity, "walking")
    }

    func testTheWatchHasNoBluetoothAndKeepsLocationOffByDefault() {
        let phone = Dictionary(uniqueKeysWithValues: SensingCatalog.phone.map { ($0.id, $0) })
        let watch = Dictionary(uniqueKeysWithValues: SensingCatalog.watch.map { ($0.id, $0) })
        XCTAssertNotNil(phone[SensingCatalog.bluetooth])
        XCTAssertNil(watch[SensingCatalog.bluetooth])
        XCTAssertEqual(phone[SensingCatalog.location]?.defaultOn, true)
        XCTAssertEqual(watch[SensingCatalog.location]?.defaultOn, false)
        XCTAssertEqual(watch[SensingCatalog.activity]?.defaultOn, false)
        XCTAssertEqual(phone[SensingCatalog.location]?.setting.samplingPeriodUs, 30_000_000)
    }

    func testSoundAndBluetoothAreOffUntilSomeoneTurnsThemOn() {
        for catalog in [SensingCatalog.phone, SensingCatalog.watch] {
            XCTAssertEqual(catalog.first { $0.id == SensingCatalog.audioLevel }?.defaultOn, false)
        }
        XCTAssertEqual(SensingCatalog.phone.first { $0.id == SensingCatalog.bluetooth }?.defaultOn, false)
    }

    func testBatteryScreenAndNetworkAreOnEverywhere() {
        for catalog in [SensingCatalog.phone, SensingCatalog.watch] {
            for id in [SensingCatalog.battery, SensingCatalog.screen, SensingCatalog.network] {
                XCTAssertEqual(catalog.first { $0.id == id }?.defaultOn, true, id.value)
            }
        }
    }
}

final class ForwardGateTests: XCTestCase {
    func testOnlyForward() {
        var g = ForwardGate()
        XCTAssertTrue(g.admit(tsNs: 100))
        XCTAssertTrue(g.admit(tsNs: 100), "the same time is fine")
        XCTAssertFalse(g.admit(tsNs: 99))
        XCTAssertTrue(g.admit(tsNs: 101))
    }

    func testAReadingFromBeforeTheStartIsOut() {
        var g = ForwardGate(startNs: 1000)
        XCTAssertFalse(g.admit(tsNs: 999), "a cached fix")
        XCTAssertTrue(g.admit(tsNs: 1000))
    }

    func testAnEventMovesItOn() {
        var g = ForwardGate()
        XCTAssertTrue(g.admit(tsNs: 100))
        g.note(tsNs: 200)
        XCTAssertFalse(g.admit(tsNs: 150))
        g.note(tsNs: 120)
        XCTAssertTrue(g.admit(tsNs: 200), "an older note doesn't move it back")
    }
}
