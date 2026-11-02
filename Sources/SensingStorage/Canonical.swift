import Foundation
import SensingProto

/// One sample as a canonical line of text, so three languages' decoders can be compared on content rather than bytes
/// (gzip output and map order vary between writers, so byte equality is the wrong target). `tools/android-compat` and
/// `tools/go-compat` print exactly the same thing:
///
///     device|session|sensor|seq|ts_mono_ns|ts_wall_ms|schema_version|accuracy|device_kind|payload
///
/// Floats are their bit patterns in hex, so nothing is lost to printing. Strings are percent-encoded byte by byte
/// outside `A-Za-z0-9._-:/`. Event attributes are sorted by key. Enums are their numbers.
public enum Canonical {
    public static func line(_ s: Sensorlog_V1_SensorSample) -> String {
        [pct(s.deviceID), pct(s.sessionID), pct(s.sensorID), String(s.seq), String(s.tsMonoNs), String(s.tsWallMs),
         String(s.schemaVersion), String(s.accuracy.rawValue), String(s.deviceKind.rawValue), payload(s)].joined(separator: "|")
    }

    /// Every sample in a chunk file's verified frames.
    public static func lines(chunk data: Data) throws -> [String] {
        var out: [String] = []
        for frame in FrameCodec.readFrames(data) {
            guard let raw = FrameCodec.inflate(frame.payload) else { continue }
            let batch = try Sensorlog_V1_SampleBatch(serializedBytes: raw)
            out += batch.samples.map(line)
        }
        return out
    }

    private static func payload(_ s: Sensorlog_V1_SensorSample) -> String {
        switch s.payload {
        case nil:
            return "none"
        case let .vec3(v):
            return "vec3 \(f32(v.x)) \(f32(v.y)) \(f32(v.z))"
        case let .quat(q):
            return "quat \(f32(q.x)) \(f32(q.y)) \(f32(q.z)) \(f32(q.w)) \(f32(q.headingAccuracy))"
        case let .scalar(v):
            return "scalar \(f32(v.value))"
        case let .location(l):
            return "location \(f64(l.lat)) \(f64(l.lon)) \(f64(l.alt)) \(f32(l.accuracy)) \(f32(l.speed)) \(f32(l.bearing)) \(pct(l.provider)) "
                + "\(f32(l.verticalAccuracy)) \(f32(l.speedAccuracy)) \(f32(l.bearingAccuracy)) \(l.satellites) \(l.elapsedRealtimeUncertaintyNs)"
        case let .event(e):
            let attrs = e.attributes.map { "\(pct($0.key))=\(pct($0.value))" }.sorted().joined(separator: ",")
            return "event \(pct(e.kind)) \(attrs)"
        case let .tensor(t):
            return "tensor \(t.shape.map(String.init).joined(separator: ",")) \(t.values.map(f32).joined(separator: ",")) \(t.names.map(pct).joined(separator: ","))"
        }
    }

    private static func f32(_ v: Float) -> String { pad(String(v.bitPattern, radix: 16), 8) }
    private static func f64(_ v: Double) -> String { pad(String(v.bitPattern, radix: 16), 16) }
    private static func pad(_ s: String, _ n: Int) -> String { String(repeating: "0", count: max(0, n - s.count)) + s }

    private static func pct(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if b < 0x80, c.isLetter || c.isNumber || "._-:/".contains(c) {
                out.append(c)
            } else {
                out += "%" + pad(String(b, radix: 16), 2)
            }
        }
        return out
    }
}
