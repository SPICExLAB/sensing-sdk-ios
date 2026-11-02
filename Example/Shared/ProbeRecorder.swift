@preconcurrency import CoreMotion
import Foundation
import SensingCore

/// Phase 1's bare recorder: every CoreMotion sample's own timestamp, plus events, in CSV. It answers whether sensors
/// keep delivering with the screen locked, before the real engine exists. It writes on the callback queue, which the
/// real engine doesn't, so its CPU numbers say nothing about the SDK.
///
/// rows.csv:   stream,seq,ts_s,cb_uptime_ns,x,y,z   (ts_s is CMLogItem.timestamp; judge rates by it, never by arrival)
/// events.csv: kind,mono_ns,uptime_ns,wall_ms,detail
final class ProbeRecorder: @unchecked Sendable {
    struct Settings: Sendable {
        var hz: Double
        var label: String
    }

    struct StreamStat: Sendable {
        var count: Int64 = 0
        var lastTs: Double = 0
        var recentIntervalSum: Double = 0
        var recentIntervals: Int64 = 0
    }

    let directory: URL
    private let settings: Settings
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let dispatch = DispatchQueue(label: "sensing.probe", qos: .userInitiated)
    private let queue = OperationQueue()
    private let rows: FileHandle
    private let events: FileHandle
    private var buffer = Data()
    private var timer: DispatchSourceTimer?
    private var seq: [Character: Int64] = [:]
    private var lastTick = Clock.uptimeNs()
    private var ticks: Int64 = 0
    private var closed = false

    private let statsLock = NSLock()
    private var stats: [String: StreamStat] = [:]

    init(settings: Settings, runsDirectory: URL) throws {
        self.settings = settings
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        directory = runsDirectory.appendingPathComponent("\(stamp.string(from: Date()))-\(settings.label)-\(Int64(settings.hz))hz")
        let protection: [FileAttributeKey: Any] = ProbeFiles.protection
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        let rowsURL = directory.appendingPathComponent("rows.csv")
        let eventsURL = directory.appendingPathComponent("events.csv")
        FileManager.default.createFile(atPath: rowsURL.path, contents: Data("stream,seq,ts_s,cb_uptime_ns,x,y,z\n".utf8), attributes: protection)
        FileManager.default.createFile(atPath: eventsURL.path, contents: Data("kind,mono_ns,uptime_ns,wall_ms,detail\n".utf8), attributes: protection)
        rows = try FileHandle(forWritingTo: rowsURL)
        events = try FileHandle(forWritingTo: eventsURL)
        try rows.seekToEnd()
        try events.seekToEnd()
        queue.underlyingQueue = dispatch
        queue.maxConcurrentOperationCount = 1
        queue.name = "sensing.probe"
    }

    func start() {
        let interval = 1.0 / settings.hz
        event("start", "hz=\(settings.hz) label=\(settings.label)")
        clockEvent()
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = interval
            motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                self.row("a", d.timestamp, d.acceleration.x, d.acceleration.y, d.acceleration.z)
            }
        } else { event("unavailable", "accelerometer") }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = interval
            let frames = CMMotionManager.availableAttitudeReferenceFrames()
            let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
            event("attitude_frame", "\(frame.rawValue) available=\(frames.rawValue)")
            var n: Int64 = 0
            motion.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                self.row("g", d.timestamp, d.rotationRate.x, d.rotationRate.y, d.rotationRate.z)
                n += 1
                if n % 10 == 0 {  // these two only prove the fields exist and hold sensible values
                    self.row("m", d.timestamp, d.magneticField.field.x, d.magneticField.field.y, d.magneticField.field.z)
                    self.row("q", d.timestamp, d.attitude.quaternion.x, d.attitude.quaternion.y, d.attitude.quaternion.z)
                }
            }
        } else { event("unavailable", "deviceMotion") }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
                guard let self else { return }
                if let error { self.event("altimeter_error", String(describing: error)) }
                guard let d = data else { return }
                self.row("b", d.timestamp, d.pressure.doubleValue, d.relativeAltitude.doubleValue, 0)
            }
        } else { event("unavailable", "altimeter") }

        let t = DispatchSource.makeTimerSource(queue: dispatch)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        motion.stopAccelerometerUpdates()
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        queue.waitUntilAllOperationsAreFinished()
        dispatch.sync {
            timer?.cancel()
            timer = nil
            flush()
        }
        event("stop", "")
        clockEvent()
        dispatch.sync {
            closed = true
            try? rows.synchronize()
            try? events.synchronize()
            try? rows.close()
            try? events.close()
        }
    }

    /// Records something that happened. Safe from any thread.
    func event(_ kind: String, _ detail: String) {
        let mono = Clock.monoNs(), up = Clock.uptimeNs(), wall = Clock.wallMs()
        let clean = detail.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
        dispatch.async { [self] in
            guard !closed else { return }  // a late workout state change can arrive after Stop
            try? events.write(contentsOf: Data("\(kind),\(mono),\(up),\(wall),\(clean)\n".utf8))
        }
    }

    func snapshot() -> [String: StreamStat] {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    func resetRecentRates() {
        statsLock.lock()
        for key in stats.keys {
            stats[key]?.recentIntervalSum = 0
            stats[key]?.recentIntervals = 0
        }
        statsLock.unlock()
    }

    private func row(_ stream: Character, _ ts: Double, _ x: Double, _ y: Double, _ z: Double) {
        let n = seq[stream, default: 0]
        seq[stream] = n + 1
        buffer.append(contentsOf: "\(stream),\(n),\(ts),\(Clock.uptimeNs()),\(x),\(y),\(z)\n".utf8)
        statsLock.lock()
        var s = stats[String(stream), default: StreamStat()]
        s.count += 1
        if s.lastTs > 0 {
            s.recentIntervalSum += ts - s.lastTs
            s.recentIntervals += 1
        }
        s.lastTs = ts
        stats[String(stream)] = s
        statsLock.unlock()
    }

    private func tick() {
        let now = Clock.uptimeNs()
        // uptime stops during sleep, so a jump here means this process didn't run while the device was awake
        if now - lastTick > 5_000_000_000 { event("process_stall", "uptime_gap_ms=\((now - lastTick) / 1_000_000)") }
        lastTick = now
        ticks += 1
        flush()
        if ticks % 15 == 0 { clockEvent() }
    }

    private func clockEvent() {
        event("clock", "sleep_offset_ns=\(Clock.sleepOffsetNs())")
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        do {
            try rows.write(contentsOf: buffer)
            try rows.synchronize()
            buffer.removeAll(keepingCapacity: true)
        } catch {
            event("write_error", String(describing: error))  // the file can't be written while locked if protection is wrong
        }
    }
}

enum ProbeFiles {
    /// Writable while the device is locked, once it has been unlocked since boot.
    static var protection: [FileAttributeKey: Any] { [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication] }

    static var runs: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: protection)
        return dir
    }

    static func listRuns() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
