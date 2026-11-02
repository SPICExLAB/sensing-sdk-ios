import Foundation
import HealthKit
import Observation
import SensingKit
import UIKit

/// Drives Phase 1's locked-recording test on the iPhone.
@MainActor
@Observable
final class PhoneProbe {
    var mode: KeepAliveMode = .location100m
    var hz: Double = 50
    var watchHz: Double = 50
    var alsoWatch = true

    private(set) var recording = false
    private(set) var startedAt: Date?
    private(set) var rates: [(String, Int64, Double)] = []
    private(set) var note = ""
    private(set) var log: [String] = []
    private(set) var runs: [URL] = []
    let api = ProbeAPI.report()

    private let keepAlive = KeepAliveController()
    private var recorder: ProbeRecorder?
    private var observers: [NSObjectProtocol] = []
    private var generation = Int64(Date().timeIntervalSince1970)
    private let health = HKHealthStore()
    private var timer: Timer?
    private var ticks: Int64 = 0

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        ProbeLink.shared.onTransfer = { [weak self] text in
            Task { @MainActor in self?.say(text); self?.refreshRuns() }
        }
        ProbeLink.shared.onMessage = { [weak self] message in
            guard message["request"] as? String == "stop" else { return }
            Task { @MainActor in self?.stop() }
        }
        ProbeLink.shared.activate()
        refreshRuns()
    }

    func requestPermissions() {
        keepAlive.requestLocationPermission()
        Task {
            do {
                try await keepAlive.requestWorkoutPermission()
                say("workout permission answered; status \(health.authorizationStatus(for: HKObjectType.workoutType()).rawValue)")
            } catch {
                say("workout permission failed: \(error)")
            }
        }
    }

    func start() {
        guard !recording else { return }
        do {
            let r = try ProbeRecorder(settings: .init(hz: hz, label: "phone-\(mode.rawValue)"), runsDirectory: ProbeFiles.runs)
            ProbeAPI.write(to: r.directory)
            recorder = r
            r.start()
            observeAppState(r)
            // Written straight to this run's file, so an event during Stop isn't lost.
            keepAlive.onEvent = { [weak self] kind, detail in
                r.event(kind, detail)
                if kind != "location_fixes" { Task { @MainActor in self?.say("\(kind) \(detail)") } }
            }
            try keepAlive.start(mode)
            recording = true
            startedAt = Date()
            r.event("device", Self.deviceNote())
            startTimer()
            say("started \(mode.rawValue) at \(Int64(hz)) Hz")
            if alsoWatch { startWatch(run: r.directory.lastPathComponent) }
        } catch {
            say("start failed: \(error)")
            recorder?.event("start_failed", String(describing: error))
        }
    }

    func stop() {
        guard recording else { return }
        generation += 1
        ProbeLink.shared.publish(["gen": generation, "desired": "stopped"])
        keepAlive.stop()
        recorder?.event("device", Self.deviceNote())
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        recording = false
        startedAt = nil
        rates = []
        say("stopped")
        refreshRuns()
    }

    private func startTimer() {
        ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
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

    func refreshRuns() { runs = ProbeFiles.listRuns() }

    #if DEBUG
    /// Smoke test without touching the screen: `-probeAutostart none -probeSeconds 8`.
    func runLaunchArguments() {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "probeAutostart"), let wanted = KeepAliveMode(rawValue: name) else { return }
        mode = wanted
        alsoWatch = false
        start()
        let seconds = max(defaults.double(forKey: "probeSeconds"), 3)
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
    #endif

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshRuns()
    }

    private func startWatch(run: String) {
        generation += 1
        ProbeLink.shared.publish(["gen": generation, "desired": "recording", "hz": watchHz, "run": run])
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        health.startWatchApp(with: config) { [weak self] ok, error in
            let text = "startWatchApp ok=\(ok) \(error.map { String(describing: $0) } ?? "")"
            Task { @MainActor in
                self?.say(text)
                self?.recorder?.event("start_watch", text)
            }
        }
    }

    private func observeAppState(_ r: ProbeRecorder) {
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "app_background"),
            (UIApplication.willEnterForegroundNotification, "app_foreground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked"),
            (UIApplication.willTerminateNotification, "app_terminate"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal"),
            (Notification.Name.NSProcessInfoPowerStateDidChange, "low_power"),
        ]
        observers = names.map { name, kind in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { r.event(kind, Self.deviceNote()) }
            }
        }
    }

    private func say(_ text: String) {
        log.insert(text, at: 0)
        if log.count > 30 { log.removeLast() }
    }

    private static func deviceNote() -> String {
        let info = ProcessInfo.processInfo
        let d = UIDevice.current
        return "battery=\(d.batteryLevel) charging=\(d.batteryState.rawValue) low_power=\(info.isLowPowerModeEnabled) thermal=\(info.thermalState.rawValue)"
    }
}
