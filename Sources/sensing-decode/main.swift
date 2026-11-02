import Foundation
import SensingProto
import SensingStorage

// Turns chunks into CSV and prints a rate and gap report, so recordings can be checked on a Mac.
//
//   sensing-decode <export.zip or folder> [--out DIR] [--sensor ID] [--check]
//
//   --out DIR     writes <device>/<session>/<sensor>.csv, in seq order
//   --sensor ID   only this stream
//   --check       also verifies each chunk against its record, frame by frame, and fails on any problem
//
// Rates and gaps come from each sample's own ts_mono_ns, never from arrival time. Exports are participants' data: keep
// the output out of every repo.

struct Options {
    var input = ""
    var out: URL?
    var sensor: String?
    var check = false
}

func usage() -> Never {
    print("usage: sensing-decode <export.zip or folder> [--out DIR] [--sensor ID] [--check]")
    exit(2)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--check": o.check = true
        case "--out":
            i += 1
            guard i < args.count else { usage() }
            o.out = URL(fileURLWithPath: args[i], isDirectory: true)
        case "--sensor":
            i += 1
            guard i < args.count else { usage() }
            o.sensor = args[i]
        default:
            guard o.input.isEmpty else { usage() }
            o.input = args[i]
        }
        i += 1
    }
    if o.input.isEmpty { usage() }
    return o
}

/// A zip is unpacked with the system's unzip; a folder is used as it is.
func resolve(_ input: String) throws -> (URL, cleanup: () -> Void) {
    let url = URL(fileURLWithPath: input)
    guard url.pathExtension == "zip" else { return (url, {}) }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sensing-decode-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-q", url.path, "-d", tmp.path]
    try unzip.run()
    unzip.waitUntilExit()
    guard unzip.terminationStatus == 0 else { throw NSError(domain: "unzip", code: Int(unzip.terminationStatus)) }
    return (tmp, { try? FileManager.default.removeItem(at: tmp) })
}

/// The ingest's reader carries on past a frame with a bad CRC where Android's stops, so a damaged file reads differently
/// in each. This counts what each sees, so a disagreement is visible.
func tolerantScan(_ data: Data) -> (good: Int, bad: Int) {
    var good = 0, bad = 0
    var pos = data.startIndex
    while pos < data.endIndex {
        var length: UInt64 = 0
        var shift: UInt64 = 0
        var at = pos
        var ended = false
        while at < data.endIndex, shift <= 63 {
            let b = data[at]
            at += 1
            length |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 {
                ended = true
                break
            }
            shift += 7
        }
        guard ended, length <= UInt64(FrameCodec.maxFrameBytes), at + 4 + Int(length) <= data.endIndex else { return (good, bad + 1) }
        let want = UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        let payload = data.subdata(in: (at + 4)..<(at + 4 + Int(length)))
        if CRC32.of(payload) == want { good += 1 } else { bad += 1 }
        pos = at + 4 + Int(length)
    }
    return (good, bad)
}

struct Key: Hashable {
    var device: String
    var session: String
    var sensor: String
}

func csvField(_ s: String) -> String {
    guard s.contains(where: { ",\"\n".contains($0) }) else { return s }
    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

let header = "seq,ts_mono_ns,ts_wall_ms,accuracy,device_kind,payload,x,y,z,w,heading_accuracy,value,lat,lon,alt,loc_accuracy,speed,bearing,provider,"
    + "vertical_accuracy,speed_accuracy,bearing_accuracy,satellites,event_kind,event_attributes,tensor_shape,tensor_values,tensor_names\n"

func csvRow(_ s: Sensorlog_V1_SensorSample) -> String {
    var f = [String](repeating: "", count: 28)
    f[0] = String(s.seq)
    f[1] = String(s.tsMonoNs)
    f[2] = String(s.tsWallMs)
    f[3] = String(describing: s.accuracy)
    f[4] = String(describing: s.deviceKind)
    switch s.payload {
    case nil:
        f[5] = "none"
    case let .vec3(v):
        f[5] = "vec3"; f[6] = "\(v.x)"; f[7] = "\(v.y)"; f[8] = "\(v.z)"
    case let .quat(q):
        f[5] = "quat"; f[6] = "\(q.x)"; f[7] = "\(q.y)"; f[8] = "\(q.z)"; f[9] = "\(q.w)"; f[10] = "\(q.headingAccuracy)"
    case let .scalar(v):
        f[5] = "scalar"; f[11] = "\(v.value)"
    case let .location(l):
        f[5] = "location"; f[12] = "\(l.lat)"; f[13] = "\(l.lon)"; f[14] = "\(l.alt)"; f[15] = "\(l.accuracy)"; f[16] = "\(l.speed)"; f[17] = "\(l.bearing)"
        f[18] = l.provider; f[19] = "\(l.verticalAccuracy)"; f[20] = "\(l.speedAccuracy)"; f[21] = "\(l.bearingAccuracy)"; f[22] = "\(l.satellites)"
    case let .event(e):
        f[5] = "event"; f[23] = e.kind
        let json = try? JSONSerialization.data(withJSONObject: e.attributes, options: [.sortedKeys, .withoutEscapingSlashes])
        f[24] = json.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    case let .tensor(t):
        f[5] = "tensor"; f[25] = t.shape.map(String.init).joined(separator: " ")
        f[26] = t.values.map { "\($0)" }.joined(separator: " "); f[27] = t.names.joined(separator: " ")
    }
    return f.map(csvField).joined(separator: ",") + "\n"
}

func fmt(_ v: Double, _ places: Int) -> String { String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), v) }

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

func run() throws -> Int32 {
    let o = parse(Array(CommandLine.arguments.dropFirst()))
    let (root, cleanup) = try resolve(o.input)
    defer { cleanup() }
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { usage() }
    let all = walker.compactMap { $0 as? URL }
    let chunks = all.filter { $0.lastPathComponent.hasSuffix(ChunkWriter.finalSuffix) }.sorted { $0.path < $1.path }
    let unsealed = all.filter { $0.lastPathComponent.hasSuffix(ChunkWriter.tmpSuffix) }
    var problems: [String] = []
    if !unsealed.isEmpty { problems.append("\(unsealed.count) unsealed .tmp file(s), not read") }

    var streams: [Key: [Sensorlog_V1_SensorSample]] = [:]
    for chunk in chunks {
        let data = try Data(contentsOf: chunk)
        let frames = FrameCodec.readFrames(data)
        if o.check {
            let name = chunk.lastPathComponent
            let tolerant = tolerantScan(data)
            let valid = frames.last?.end ?? 0
            if valid != Int64(data.count) {
                problems.append("\(name): only \(valid) of \(data.count) bytes verify. Android's reader sees \(frames.count) frames; the ingest's sees \(tolerant.good), and skips \(tolerant.bad)")
            }
            let recordURL = ChunkFiles.recordURL(forChunk: chunk)
            if let record = ChunkFiles.readRecord(at: recordURL) {
                if try ChunkFiles.sha256(of: chunk) != record.sha256 { problems.append("\(name): sha256 differs from its record") }
                if record.bytes != Int64(data.count) { problems.append("\(name): \(data.count) bytes, but its record says \(record.bytes)") }
                if record.frames != Int64(frames.count) { problems.append("\(name): \(frames.count) frames, but its record says \(record.frames)") }
            } else if FileManager.default.fileExists(atPath: recordURL.path) {
                problems.append("\(name): its record can't be read")
            }
        }
        for frame in frames {
            guard let raw = FrameCodec.inflate(frame.payload) else {
                problems.append("\(chunk.lastPathComponent): a frame's gzip is bad")
                continue
            }
            let batch = try Sensorlog_V1_SampleBatch(serializedBytes: raw)
            for s in batch.samples where o.sensor == nil || s.sensorID == o.sensor {
                streams[Key(device: s.deviceID, session: s.sessionID, sensor: s.sensorID), default: []].append(s)
            }
        }
    }

    print("\(chunks.count) chunks, \(streams.values.reduce(0) { $0 + $1.count }) samples, \(streams.count) streams")
    let sessions = Dictionary(grouping: streams.keys) { "\($0.device) / \($0.session)" }
    for name in sessions.keys.sorted() {
        print("\n\(name)")
        print("  " + pad("stream", 26) + lpad("samples", 9) + lpad("seconds", 10) + lpad("Hz", 9) + lpad("median ms", 11) + lpad("p5", 8) + lpad("p95", 8)
            + lpad("max gap ms", 12) + lpad("gaps", 6) + lpad("lost seq", 10))
        var recorded: [String: Int] = [:]
        for key in sessions[name]!.sorted(by: { $0.sensor < $1.sensor }) {
            let samples = streams[key]!
            let stats = StreamStats.compute(samples.map { (seq: $0.seq, tsMonoNs: $0.tsMonoNs) })
            print("  " + pad(key.sensor, 26) + lpad(String(stats.samples), 9) + lpad(fmt(stats.durationSeconds, 1), 10) + lpad(fmt(stats.rateHz, 2), 9)
                + lpad(fmt(stats.medianIntervalMs, 2), 11) + lpad(fmt(stats.p5IntervalMs, 1), 8) + lpad(fmt(stats.p95IntervalMs, 1), 8)
                + lpad(fmt(stats.maxGapMs, 1), 12) + lpad(String(stats.gaps), 6) + lpad(String(stats.missingSeq), 10))
            if o.check {
                if stats.duplicateSeq > 0 { problems.append("\(key.sensor): \(stats.duplicateSeq) duplicate seq numbers") }
                if stats.backwards > 0 { problems.append("\(key.sensor): time goes backwards \(stats.backwards) times") }
            }
            if key.sensor == "device.gap" {
                for s in samples { recorded[s.event.kind, default: 0] += 1 }
            }
            if let out = o.out {
                let dir = out.appendingPathComponent(String(key.device.prefix(8))).appendingPathComponent(String(key.session.prefix(8)))
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var text = header
                for s in samples.sorted(by: { $0.seq < $1.seq }) { text += csvRow(s) }
                try text.write(to: dir.appendingPathComponent("\(key.sensor).csv"), atomically: true, encoding: .utf8)
            }
        }
        if !recorded.isEmpty {
            print("  recorded gaps: " + recorded.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
    }
    if let out = o.out { print("\nCSV written to \(out.path)") }
    if o.check {
        if problems.isEmpty {
            print("\ncheck: no problems")
        } else {
            print("\ncheck: \(problems.count) problem(s)")
            problems.forEach { print("  \($0)") }
            return 1
        }
    }
    return 0
}

do {
    exit(try run())
} catch {
    print("sensing-decode: \(error)")
    exit(1)
}
