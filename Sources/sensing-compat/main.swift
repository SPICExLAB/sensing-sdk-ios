import Foundation
import SensingProto
import SensingStorage

// scripts/compat.sh drives this. It proves the chunk format against Android's and the ingest's real decoders.
//
//   sensing-compat write DIR    writes a fixture of every payload type through the real ChunkStore,
//                               plus DIR/expected.txt: its canonical lines, sorted
//   sensing-compat read PATH    prints the canonical lines of every chunk under PATH, sorted

let device = "aaaaaaaa-0000-4000-8000-000000000001"
let session = "bbbbbbbb-0000-4000-8000-000000000002"
let activity = "cccccccc-0000-4000-8000-000000000003"
let label = "dddddddd-0000-4000-8000-000000000004"

func sample(_ sensor: String, seq: UInt64, _ fill: (inout Sensorlog_V1_SensorSample) -> Void) -> Sensorlog_V1_SensorSample {
    var s = Sensorlog_V1_SensorSample()
    s.deviceID = device
    s.sessionID = session
    s.sensorID = sensor
    s.seq = seq
    s.tsMonoNs = 200_000_000_000_000 + Int64(seq) * 20_000_000
    s.tsWallMs = 1_793_000_000_000 + Int64(seq) * 20
    s.schemaVersion = 1
    s.accuracy = .high
    s.deviceKind = .phone
    fill(&s)
    return s
}

func event(_ sensor: String, seq: UInt64, _ kind: String, _ attrs: [String: String]) -> Sensorlog_V1_SensorSample {
    sample(sensor, seq: seq) { s in
        s.event = .with {
            $0.kind = kind
            $0.attributes = attrs
        }
    }
}

func fixtureBatches() -> [Sensorlog_V1_SampleBatch] {
    func batch(_ sensor: String, _ samples: [Sensorlog_V1_SensorSample]) -> Sensorlog_V1_SampleBatch {
        var b = Sensorlog_V1_SampleBatch()
        b.sensorID = sensor
        b.samples = samples
        return b
    }
    let accel = "motion.accelerometer"
    let wall = "1793000000000", mono = "200000000000000"
    return [
        // Several frames in one chunk, with values that print badly as decimals.
        batch(accel, (0..<100).map { i in sample(accel, seq: UInt64(i)) { s in s.vec3 = .with { $0.x = 0.1 * Float(i); $0.y = -9.80665; $0.z = 1e-30 } } }),
        batch(accel, (100..<200).map { i in sample(accel, seq: UInt64(i)) { s in s.vec3 = .with { $0.x = 0.1 * Float(i); $0.y = 9.80665; $0.z = 1e30 } } }),
        batch("motion.rotation_vector", [sample("motion.rotation_vector", seq: 0) { s in
            s.accuracy = .medium
            s.quat = .with { $0.x = 0.5; $0.y = -0.5; $0.z = 0.25; $0.w = 0.625; $0.headingAccuracy = -1 }
        }]),
        batch("env.barometer", [sample("env.barometer", seq: 0) { s in
            s.accuracy = .unreliable
            s.scalar = .with { $0.value = 1000.50781 }
        }]),
        batch("loc.fused", [
            sample("loc.fused", seq: 0) { s in
                s.location = .with {
                    $0.lat = 40.712776123456789
                    $0.lon = -74.005974123456789
                    $0.alt = 10.5
                    $0.accuracy = 5
                    $0.speed = 1.5
                    $0.bearing = 270
                    $0.provider = "corelocation"
                    $0.verticalAccuracy = 3
                    $0.speedAccuracy = 0.5
                    $0.bearingAccuracy = 10
                    $0.satellites = 7
                    $0.elapsedRealtimeUncertaintyNs = 123_456_789
                }
            },
            // One sensor can mix payload types, so consumers must switch on the oneof.
            event("loc.fused", seq: 1, "listening", ["interval_ms": "30000", "provider_enabled": "true"]),
        ]),
        batch("device.bluetooth_scan", [
            sample("device.bluetooth_scan", seq: 0) { s in
                s.tensor = .with {
                    $0.shape = [2, 2]
                    $0.values = [-60, 127, -71.5, 4]
                    $0.names = ["b57a3b2f7dad4b8a", "0123456789abcdef"]
                }
            },
            sample("device.bluetooth_scan", seq: 1) { s in s.tensor = .with { $0.shape = [0, 2] } },
        ]),
        batch("device.session", [event("device.session", seq: 0, "start", ["reason": "engine_start", "platform": "ios", "note": "é=;,|% ok"])]),
        batch("device.clock", [event("device.clock", seq: 0, "clock", ["mono_ns": mono, "wall_ms": wall])]),
        // A whole activity session, so the ingest's label projection is exercised.
        batch("label.session", [
            event("label.session", seq: 0, "session_start", ["session_id": activity, "config_id": "free/walking", "config_version": "1", "module": "free",
                                                             "taxonomy_version": "2", "start_wall_ms": wall, "start_mono_ns": mono]),
            event("label.session", seq: 1, "label_upsert", ["session_id": activity, "label_id": label, "kind": "interval", "taxonomy_id": "locomotion/walking",
                                                            "taxonomy_version": "2", "source": "tap", "confidence": "1", "start_wall_ms": wall, "start_mono_ns": mono]),
            event("label.session", seq: 2, "label_upsert", ["session_id": activity, "label_id": label, "kind": "interval", "taxonomy_id": "locomotion/walking",
                                                            "taxonomy_version": "2", "source": "tap", "confidence": "1", "start_wall_ms": wall, "start_mono_ns": mono,
                                                            "end_wall_ms": "1793000060000", "end_mono_ns": "200060000000000", "attr.where": "outdoors"]),
            event("label.session", seq: 3, "session_end", ["session_id": activity, "end_reason": "stopped", "end_wall_ms": "1793000060000", "end_mono_ns": "200060000000000"]),
        ]),
    ]
}

func chunkFiles(under path: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(ChunkWriter.finalSuffix) }.sorted { $0.path < $1.path }
}

func canonicalLines(under path: URL) throws -> [String] {
    try chunkFiles(under: path).flatMap { try Canonical.lines(chunk: Data(contentsOf: $0)) }.sorted()
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: sensing-compat write DIR | read PATH")
    exit(2)
}
let path = URL(fileURLWithPath: arguments[2])
switch arguments[1] {
case "write":
    let store = ChunkStore(root: try StorageRoot(parent: path), nowMonoMs: { 0 }, freeBytes: { 1 << 40 })
    store.openSession(session)
    for batch in fixtureBatches() {
        if let encoded = try EncodedBatch(batch) { try store.write(encoded) }
    }
    try store.sealAll()
    let lines = try canonicalLines(under: path)
    try (lines.joined(separator: "\n") + "\n").write(to: path.appendingPathComponent("expected.txt"), atomically: true, encoding: .utf8)
    print("wrote \(store.sealedChunks.count) chunks, \(lines.count) samples")
case "read":
    for line in try canonicalLines(under: path) { print(line) }
default:
    print("usage: sensing-compat write DIR | read PATH")
    exit(2)
}
