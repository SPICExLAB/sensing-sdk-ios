#if os(iOS) || os(watchOS)
@preconcurrency import AVFAudio
import Foundation
import SensingCore
import SensingProto

/// `device.audio_level`: loudness in dBFS, one value per window. The buffers are read inside the tap, reduced to a running sum,
/// and dropped there. No audio is ever kept, written or sent, and there's no `AVAudioRecorder` anywhere in this SDK.
public final class AudioLevelAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.audioLevel]

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var windowMs: Int64 = 1000
    private var quiet: Bool?
    private var interrupted = false

    public init() {}

    public func availability(of sensor: SensorID) -> Availability {
        AVAudioApplication.shared.recordPermission == .granted ? .available : .missingPermission(["microphone"])
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.audioLevel] else { return }
        lock.withLock {
            self.sink = sink
            self.clock = clock
            windowMs = min(max((settings[SensingCatalog.audioLevel]?.samplingPeriodUs ?? 1_000_000) / 1000, 100), 10_000)
            quiet = nil
            interrupted = false
        }
        let session = AVAudioSession.sharedInstance()
        #if os(iOS)
        // Measurement turns off the system's gain and noise processing, and mixing leaves other audio alone.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
        #else
        try session.setCategory(.playAndRecord, mode: .measurement)
        #endif
        try session.setActive(true)
        try beginEngine()
        let center = NotificationCenter.default
        let added = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                self?.interruption(note)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                self?.restart(reason: "media_services_reset")
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
                self?.restart(reason: "configuration_change")
            },
        ]
        lock.withLock { observers = added }
    }

    public func stop() {
        let (e, added) = lock.withLock { () -> (AVAudioEngine?, [NSObjectProtocol]) in
            defer {
                engine = nil
                observers = []
                sink = nil
                clock = nil
            }
            return (engine, observers)
        }
        added.forEach(NotificationCenter.default.removeObserver)
        e?.inputNode.removeTap(onBus: 0)
        e?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func beginEngine() throws {
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        let ms = lock.withLock { windowMs }
        // Touched only on the tap's own thread.
        let window = TapWindow(AudioLevel.Window(sampleRate: format.sampleRate, milliseconds: ms))
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = Int64(buffer.frameLength)
            var squares = 0.0
            for i in 0..<n {
                let v = Double(data[0][Int(i)])  // int-ok
                squares += v * v
            }
            if let level = window.value.add(sumSquares: squares, count: n) { self.report(level) }
        }
        e.prepare()
        try e.start()
        lock.withLock { engine = e }
    }

    private func report(_ level: Float) {
        lock.withLock {
            guard let sink, let clock else { return }
            let mono = clock.monoNs()
            let wall = clock.wallMs()
            let nowQuiet = level == AudioLevel.floorDbfs
            if nowQuiet != quiet {
                quiet = nowQuiet
                sink.event(nowQuiet ? "silenced" : "audible", tsMonoNs: mono, tsWallMs: wall)
            }
            sink.scalar(level, tsMonoNs: mono, tsWallMs: wall, accuracy: .high)
        }
    }

    /// A call or Siri took the mic. That's a recorded silence, not a level of -120.
    private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            lock.withLock {
                interrupted = true
                quiet = true
                guard let sink, let clock else { return }
                sink.event("silenced", ["reason": "interruption"], tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
            }
        case .ended:
            lock.withLock { interrupted = false }
            restart(reason: "interruption_ended")
        @unknown default:
            break
        }
    }

    private func restart(reason: String) {
        let old = lock.withLock { () -> AVAudioEngine? in
            guard sink != nil, !interrupted else { return nil }
            defer { engine = nil }
            return engine
        }
        old?.inputNode.removeTap(onBus: 0)
        old?.stop()
        guard lock.withLock({ sink != nil && !interrupted }) else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try beginEngine()
        } catch {
            lock.withLock {
                guard let sink, let clock else { return }
                sink.event("silenced", ["reason": reason, "error": String(describing: error)], tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
            }
        }
    }

    private final class TapWindow: @unchecked Sendable {
        var value: AudioLevel.Window
        init(_ value: AudioLevel.Window) { self.value = value }
    }
}
#endif
