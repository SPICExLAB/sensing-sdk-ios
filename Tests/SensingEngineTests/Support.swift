import Foundation
import SensingCore
import SensingProto
import SensingStorage
import XCTest
@testable import SensingEngine

final class FakeClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var mono: Int64 = 1_000_000_000_000
    private var sleep: Int64 = 0
    private var wall: Int64 = 1_793_000_000_000

    func monoNs() -> Int64 { lock.withLock { mono } }
    func uptimeNs() -> Int64 { lock.withLock { mono - sleep } }
    func wallMs() -> Int64 { lock.withLock { wall } }

    func advance(ms: Int64, sleepMs: Int64 = 0) {
        lock.withLock {
            mono += ms * 1_000_000
            sleep += sleepMs * 1_000_000
            wall += ms
        }
    }
}

final class FakeAdapter: SensorAdapter, @unchecked Sendable {
    let sensors: [SensorID]
    var availabilities: [SensorID: Availability] = [:]
    var failuresLeft = 0
    private(set) var startCount: Int64 = 0
    private(set) var stopCount: Int64 = 0
    private(set) var sinks: [SensorID: SampleSink] = [:]
    private(set) var settings: [SensorID: SensorSetting] = [:]

    struct Boom: Error, CustomStringConvertible {
        var description: String { "boom" }
    }

    init(_ sensors: SensorID...) { self.sensors = sensors }

    func availability(of sensor: SensorID) -> Availability { availabilities[sensor] ?? .available }

    func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        startCount += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Boom()
        }
        self.settings = settings
        self.sinks = sinks
    }

    func stop() {
        stopCount += 1
        sinks = [:]
    }
}

extension XCTestCase {
    func tempRoot() throws -> StorageRoot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sensing-engine-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try StorageRoot(parent: dir)
    }

    /// Every sample on disk, read back through the real format.
    func samples(in root: StorageRoot) throws -> [Sensorlog_V1_SensorSample] {
        guard let walker = FileManager.default.enumerator(at: root.chunks, includingPropertiesForKeys: nil) else { return [] }
        var out: [Sensorlog_V1_SensorSample] = []
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(ChunkWriter.finalSuffix) {
            for frame in FrameCodec.readFrames(try Data(contentsOf: url)) {
                let raw = try XCTUnwrap(FrameCodec.inflate(frame.payload))
                out += try Sensorlog_V1_SampleBatch(serializedBytes: raw).samples
            }
        }
        return out
    }
}

extension Sequence where Element == Sensorlog_V1_SensorSample {
    func stream(_ id: String) -> [Sensorlog_V1_SensorSample] { filter { $0.sensorID == id }.sorted { $0.seq < $1.seq } }
    func events(_ id: String, _ kind: String) -> [Sensorlog_V1_SensorSample] { stream(id).filter { $0.event.kind == kind } }
}
