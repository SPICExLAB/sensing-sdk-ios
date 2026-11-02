import Foundation
import HealthKit
import Observation
import SensingWatch
import WatchKit

/// Drives Phase 1's wrist-down test on the watch: a workout session plus the bare recorder.
@MainActor
@Observable
final class WatchProbe {
    static let shared = WatchProbe()

    var hz: Double = 50
    private(set) var recording = false
    private(set) var startedAt: Date?
    private(set) var rates: [(String, Int64, Double)] = []
    private(set) var note = ""
    private(set) var log: [String] = []
    private(set) var authStatus = 0
    let api = ProbeAPI.report()

    private let keeper = WorkoutKeeper()
    private let pending = EventSink()
    private var recorder: ProbeRecorder?
    private var lastGeneration: Int64 = 0
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var ticks: Int64 = 0

    private init() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        authStatus = keeper.authorizationStatus.rawValue
        keeper.onEvent = { [weak self] kind, detail in
            self?.pending.record(kind, detail)
            Task { @MainActor in self?.say("\(kind) \(detail)") }
        }
        ProbeLink.shared.onContext = { [weak self] context in
            let gen = context["gen"] as? Int64 ?? 0
            let desired = context["desired"] as? String ?? ""
            let hz = context["hz"] as? Double ?? 0
            Task { @MainActor in self?.apply(gen: gen, desired: desired, hz: hz) }
        }
        ProbeLink.shared.onMessage = ProbeLink.shared.onContext
        ProbeLink.shared.onTransfer = { [weak self] text in
            Task { @MainActor in self?.say(text) }
        }
        ProbeLink.shared.activate()
        // A state the phone published while this app wasn't running still applies.
        let context = ProbeLink.shared.receivedContext
        apply(gen: context["gen"] as? Int64 ?? 0, desired: context["desired"] as? String ?? "", hz: context["hz"] as? Double ?? 0, startIfAsked: false)
    }

    /// The phone asked for a recording through startWatchApp. The workout starts at once, with whatever rate has arrived.
    func handle(_ configuration: HKWorkoutConfiguration) {
        let context = ProbeLink.shared.receivedContext
        if let wanted = context["hz"] as? Double, wanted > 0 { hz = wanted }
        start(configuration: configuration, label: "watch-startWatchApp")
    }

    /// The system kept the workout running after this app died.
    func recover() {
        Task {
            do {
                let found = try await keeper.recover()
                say("recovery found a session: \(found)")
                if found { beginRecording(label: "watch-recovered") }
            } catch {
                say("recovery failed: \(error)")
            }
        }
    }

    #if DEBUG
    /// Smoke test without touching the screen: `-probeAutostart 1 -probeSeconds 8`.
    func runLaunchArguments() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "probeAutostart") else { return }
        startManually()
        let seconds = max(defaults.double(forKey: "probeSeconds"), 3)
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(askPhone: false) }
        }
    }
    #endif

    func startManually() { start(configuration: WorkoutKeeper.defaultConfiguration(), label: "watch-manual") }

    func stop(askPhone: Bool = true) {
        guard recording else { return }
        if askPhone { ProbeLink.shared.publishRequestStop() }
        keeper.end()
        let finished = recorder
        finished?.event("device", Self.deviceNote())
        pending.attach(nil)
        finished?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        recording = false
        startedAt = nil
        rates = []
        if let finished { send(finished.directory) }
    }

    /// Does a workout session run with no HealthKit permission? Answers Q4. It must run before permission is granted.
    func probeWithoutPermission() {
        authStatus = keeper.authorizationStatus.rawValue
        say("no-permission probe, status \(authStatus)")
        start(configuration: WorkoutKeeper.defaultConfiguration(), label: "watch-noauth\(authStatus)")
        Task {
            try? await Task.sleep(for: .seconds(20))
            stop(askPhone: false)
        }
    }

    func requestPermission() {
        Task {
            do {
                try await keeper.requestAuthorization()
            } catch {
                say("permission failed: \(error)")
            }
            authStatus = keeper.authorizationStatus.rawValue
            say("permission answered, status \(authStatus)")
        }
    }

    private func apply(gen: Int64, desired: String, hz wanted: Double, startIfAsked: Bool = true) {
        guard gen > lastGeneration else { return }
        lastGeneration = gen
        if wanted > 0 { hz = wanted }
        switch desired {
        case "stopped":
            stop(askPhone: false)
        case "recording":
            guard startIfAsked else { return }
            if recording { return }
            start(configuration: WorkoutKeeper.defaultConfiguration(), label: "watch-context")
        default:
            break
        }
    }

    private func start(configuration: HKWorkoutConfiguration, label: String) {
        guard !recording else { return }
        do {
            try keeper.start(configuration)
            beginRecording(label: label)
        } catch {
            // Recording starts anyway, so the file says what happens without a session.
            say("workout failed to start: \(error)")
            beginRecording(label: label + "-noworkout")
            recorder?.event("workout_start_failed", String(describing: error))
        }
    }

    private func beginRecording(label: String) {
        guard recorder == nil else { return }
        do {
            let r = try ProbeRecorder(settings: .init(hz: hz, label: label), runsDirectory: ProbeFiles.runs)
            ProbeAPI.write(to: r.directory)
            recorder = r
            r.start()
            pending.attach(r)  // the workout starts first, so its first events wait here
            r.event("device", Self.deviceNote())
            observeAppState(r)
            recording = true
            startedAt = Date()
            ticks = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            say("recording \(label) at \(Int64(hz)) Hz")
        } catch {
            say("recorder failed: \(error)")
        }
    }

    private func tick() {
        guard let recorder else { return }
        rates = recorder.snapshot().sorted { $0.key < $1.key }.map { ($0.key, $0.value.count, $0.value.recentHz) }
        recorder.resetRecentRates()
        note = Self.deviceNote()
        ticks += 1
        if ticks % 60 == 0 { recorder.event("device", note) }
    }

    /// The whole run goes to the phone, so results can be copied off in one place. This also measures transferFile.
    private func send(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { ProbeLink.shared.send(file: file, run: directory.lastPathComponent) }
    }

    private func observeAppState(_ r: ProbeRecorder) {
        let names: [(Notification.Name, String)] = [
            (WKApplication.didBecomeActiveNotification, "app_active"),
            (WKApplication.willResignActiveNotification, "app_inactive"),
            (WKApplication.didEnterBackgroundNotification, "app_background"),
            (WKApplication.willEnterForegroundNotification, "app_foreground"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal"),
            (Notification.Name.NSProcessInfoPowerStateDidChange, "low_power"),
        ]
        observers = names.map { name, kind in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { r.event(kind, Self.deviceNote()) }
            }
        }
    }

    private func say(_ text: String) {
        log.insert(text, at: 0)
        if log.count > 20 { log.removeLast() }
    }

    private static func deviceNote() -> String {
        let info = ProcessInfo.processInfo
        let d = WKInterfaceDevice.current()
        return "battery=\(d.batteryLevel) charging=\(d.batteryState.rawValue) low_power=\(info.isLowPowerModeEnabled) thermal=\(info.thermalState.rawValue)"
    }
}

/// Holds workout events until the run's file exists, then passes them straight through. Safe from any thread.
private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: ProbeRecorder?
    private var waiting: [(String, String)] = []

    func record(_ kind: String, _ detail: String) {
        lock.withLock {
            if let recorder { recorder.event(kind, detail) } else { waiting.append((kind, detail)) }
        }
    }

    func attach(_ r: ProbeRecorder?) {
        lock.withLock {
            recorder = r
            guard let r else { return }
            waiting.forEach { r.event($0.0, $0.1) }
            waiting = []
        }
    }
}
