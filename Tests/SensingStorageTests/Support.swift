import Foundation
import SensingProto
import XCTest
@testable import SensingStorage

final class FakeClock: @unchecked Sendable {
    var monoMs: Int64 = 0
}

func tempDir(_ test: XCTestCase) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sensing-test-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
}

func batch(_ sensor: String, from: Int64, _ n: Int64, session: String = "", device: String = "") -> Sensorlog_V1_SampleBatch {
    var b = Sensorlog_V1_SampleBatch()
    b.sensorID = sensor
    b.samples = (from..<(from + n)).map { i in
        var s = Sensorlog_V1_SensorSample()
        s.sensorID = sensor
        s.sessionID = session
        s.deviceID = device
        s.seq = UInt64(i)
        s.tsMonoNs = i * 20_000_000
        s.tsWallMs = 1_700_000_000_000 + i * 20
        s.vec3 = .with { $0.x = 1; $0.y = 2; $0.z = 3 }
        return s
    }
    return b
}

func encoded(_ sensor: String, from: Int64, _ n: Int64, session: String = "", device: String = "") throws -> EncodedBatch {
    try XCTUnwrap(try EncodedBatch(batch(sensor, from: from, n, session: session, device: device)))
}
