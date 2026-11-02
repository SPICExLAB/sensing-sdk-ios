#if os(iOS)
import Foundation
import Observation
import SensingAdapters
import SensingCore
import SensingEngine
import SensingStorage
import UIKit

/// The iPhone's public API. Recording runs from Start to Stop, with the screen locked: a location session keeps the app
/// alive (S-014), so CoreMotion keeps delivering. Force-quit ends it; the next launch recovers the files and records the gap.
@MainActor
@Observable
public final class Sensing {
    public struct Options: Sendable {
        public var keepAlive: KeepAliveMode = .location100m
        public var appVersion = ""
        public var retentionMode = RetentionMode.stopWhenFull

        public init() {}
    }

    public enum SensingError: Error, Equatable, CustomStringConvertible {
        case notInForeground
        case needsLocationPermission

        public var description: String {
            switch self {
            case .notInForeground: "open the app to start a recording: keep-alive can only begin in the foreground"
            case .needsLocationPermission: "allow location while using the app: it keeps recording alive with the screen locked"
            }
        }
    }

    public struct Status: Sendable, Equatable {
        public var recording: RecordingSummary?
        public var streams: [String: CollectionEngine.StreamLive] = [:]
        public var pending: Int64 = 0
        public var dropped: Int64 = 0
        public var storageFraction = 0.0
        public var warnings: [String] = []
    }

    public private(set) var status = Status()
    public let catalog = SensingCatalog.phone
    public var overrides: [SensorID: SensorOverride] = [:] {
        didSet { controller.overrides = overrides }
    }
    public var keepAlive: KeepAliveMode

    /// A recording ended without being asked to, such as a full disk.
    public var onEnded: ((RecordingSummary) -> Void)?

    public let root: StorageRoot
    private let controller: RecordingController
    private let keepAliveController = KeepAliveController()
    private let motion: MotionAdapter
    private let battery: BatterySnapshot
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    public init(options: Options = Options()) throws {
        root = try StorageRoot.standard()
        keepAlive = options.keepAlive
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        var engine = CollectionEngine.Options()
        engine.deviceKind = .phone
        engine.retentionMode = options.retentionMode
        let battery = BatterySnapshot()
        self.battery = battery
        engine.heartbeatExtras = { @Sendable in battery.attributes() }
        let motion = MotionAdapter()
        self.motion = motion
        controller = RecordingController(
            root: root, deviceId: try DeviceIdentity.load(root: root), catalog: SensingCatalog.phone,
            adapters: [motion, AltimeterAdapter(), PedometerAdapter()],
            device: DeviceDescription(platform: "ios", model: Self.machine(), os: "\(device.systemName) \(device.systemVersion)", appVersion: options.appVersion, sdkVersion: SDK.version),
            options: engine)
        controller.onEnded = { [weak self] summary in
            guard let self else { return }
            self.endKeepAlive()
            self.refresh()
            self.onEnded?(summary)
        }
        keepAliveController.onEvent = { [weak self] kind, detail in
            Task { @MainActor in self?.keepAliveEvent(kind, detail) }
        }
        refreshBattery()
    }

    /// Call once at launch: seals what a dead process left, and ends its recording.
    public func prepare() async {
        await controller.recover()
        refresh()
    }

    public func requestLocationPermission() { keepAliveController.requestLocationPermission() }
    public func requestWorkoutPermission() async throws { try await keepAliveController.requestWorkoutPermission() }

    public var hasLocationPermission: Bool {
        let s = keepAliveController.locationAuthorization
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    public func start(_ spec: RecordingSpec) async throws {
        guard UIApplication.shared.applicationState == .active else { throw SensingError.notInForeground }
        if keepAlive == .location100m || keepAlive == .location3km {
            guard hasLocationPermission else { throw SensingError.needsLocationPermission }
        }
        try keepAliveController.start(keepAlive)
        do {
            try await controller.start(spec)
        } catch {
            keepAliveController.stop()
            throw error
        }
        if !motion.northReferenced {
            await controller.engine.emit(SensorIDs.health, "attitude_frame", ["north": "none"])
        }
        startWatching()
        refresh()
    }

    public func stop(answers: [String: String] = [:]) async {
        await controller.stop(answers: answers)
        endKeepAlive()
        refresh()
    }

    /// Ends it and deletes its label: it was started by mistake. The sensor data stays.
    public func discard() async {
        await controller.discard()
        endKeepAlive()
        refresh()
    }

    public func recordings() -> [RecordingSummary] { controller.recordings.all() }

    private func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshBattery()
                Task { @MainActor in
                    await self.controller.tick()
                    self.refresh()
                }
            }
        }
        let center = NotificationCenter.default
        let notes: [(Notification.Name, String)] = [
            (ProcessInfo.thermalStateDidChangeNotification, "thermal_state"),
            (Notification.Name.NSProcessInfoPowerStateDidChange, "power_state"),
        ]
        observers = notes.map { name, kind in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshBattery()
                    let engine = self.controller.engine
                    let attrs = self.battery.attributes()
                    Task { await engine.emit(SensorIDs.health, kind, attrs) }
                }
            }
        }
    }

    private func endKeepAlive() {
        keepAliveController.stop()
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func refresh() {
        let controller = controller
        Task { @MainActor in
            let stats = await controller.engine.stats()
            var s = Status(recording: controller.current, streams: stats.streams, pending: stats.pending, dropped: stats.dropped, storageFraction: stats.storage.fraction)
            if s.storageFraction >= 0.8 { s.warnings.append("Storage is \(Int64(s.storageFraction * 100))% full. Export and delete recordings; recording stops at 100%.") }
            if status != s { status = s }
        }
    }

    /// Losing location permission mid-recording means the app is about to be suspended, so it stops cleanly while it can.
    private func keepAliveEvent(_ kind: String, _ detail: String) {
        let engine = controller.engine
        guard controller.state == .recording else { return }
        Task { await engine.emit(SensorIDs.health, kind, ["detail": detail]) }
        guard kind == "location_authorization", keepAlive != .none, keepAlive != .workout, !hasLocationPermission else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "sensing.keepalive_lost")
        Task { @MainActor in
            await engine.emit(SensorIDs.health, "keepalive_lost", ["status": detail])
            await controller.stop(reason: "keepalive_lost")
            endKeepAlive()
            refresh()
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// UIDevice is main-thread only, and the engine must never wait for the main thread. So the main thread refreshes this
    /// copy, and the engine's heartbeat reads it.
    private func refreshBattery() {
        let device = UIDevice.current
        battery.store(level: device.batteryLevel, charging: device.batteryState == .charging || device.batteryState == .full)
    }

    private static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

private final class BatterySnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = -1
    private var charging = false

    func store(level: Float, charging: Bool) {
        lock.withLock {
            self.level = level
            self.charging = charging
        }
    }

    func attributes() -> [String: String] {
        let (level, charging) = lock.withLock { (level, charging) }
        let info = ProcessInfo.processInfo
        var attrs = ["low_power": info.isLowPowerModeEnabled ? "true" : "false", "thermal_state": String(info.thermalState.rawValue), "is_charging": charging ? "true" : "false"]
        if level >= 0 { attrs["battery_pct"] = String(Int64((level * 100).rounded())) }
        return attrs
    }
}

public enum SDK {
    public static let version = "0.1.0"
}
#endif
