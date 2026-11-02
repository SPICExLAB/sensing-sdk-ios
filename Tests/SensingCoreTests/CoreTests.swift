import XCTest
import SensingProto
@testable import SensingCore

final class CoreTests: XCTestCase {
    func testIdentifierHashKnownAnswer() {
        // printf 'device-a:aa:bb:cc:dd:ee:ff' | shasum -a 256, first 8 bytes.
        XCTAssertEqual(IdentifierHash(salt: "device-a").hash("AA:BB:CC:DD:EE:FF"), "b57a3b2f7dad4b8a")
    }

    func testIdentifierHashIsPerDeviceAndCaseFree() {
        let a = IdentifierHash(salt: "device-a")
        XCTAssertEqual(a.hash("AA:bb:CC:dd:EE:ff"), a.hash("aa:BB:cc:DD:ee:FF"))
        XCTAssertNotEqual(a.hash("aa:bb"), IdentifierHash(salt: "device-b").hash("aa:bb"))
        XCTAssertEqual(a.hash("x").count, 16)
    }

    func testSensorIDRules() {
        XCTAssertNotNil(SensorID("motion.accelerometer"))
        XCTAssertNotNil(SensorID("device.storage_evicted"))
        XCTAssertNotNil(SensorID("a.b.c9"))
        XCTAssertEqual(SensorID("motion.accelerometer")?.group, "motion")
        for bad in ["motion", "Motion.x", "motion.", ".x", "motion.X", "motion accel.x", "m1.x", "health.heart_rate"] {
            XCTAssertNil(SensorID(bad), bad)
        }
    }

    func testProtoRoundTripKeepsEveryEnvelopeField() throws {
        var s = Sensorlog_V1_SensorSample()
        s.deviceID = "d"
        s.sessionID = "s"
        s.sensorID = "motion.accelerometer"
        s.seq = 7
        s.tsMonoNs = 1_000_000_000_123
        s.tsWallMs = 1_793_000_000_000
        s.schemaVersion = 1
        s.accuracy = .high
        s.deviceKind = .watch
        s.vec3 = .with { $0.x = 1; $0.y = 2; $0.z = 9.80665 }
        var batch = Sensorlog_V1_SampleBatch()
        batch.sensorID = s.sensorID
        batch.samples = [s]
        let back = try Sensorlog_V1_SampleBatch(serializedBytes: try batch.serializedData() as Data)
        XCTAssertEqual(back, batch)
    }
}
