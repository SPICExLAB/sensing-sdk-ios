#if os(iOS)
import Foundation
import Observation
import SensingAdapters
import SensingCore
import SensingEngine
import SensingLink
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
        public var peer = PhoneLink.PeerState()
        public var watchInstalled = false
    }

    public private(set) var status = Status()
    public let catalog = SensingCatalog.phone
    public var overrides: [SensorID: SensorOverride] = [:] {
        didSet { controller.overrides = overrides }
    }
    public var keepAlive: KeepAliveMode
    /// Also record on the paired watch, when it has this app.
    public var recordWatch = true
    /// The watch's own settings: its defaults are lower than the phone's.
    public var watchOverrides: [SensorID: SensorOverride] = [:]

    /// A recording ended without being asked to, such as a full disk.
    public var onEnded: ((RecordingSummary) -> Void)?

    public let root: StorageRoot
    private let controller: RecordingController
    private let keepAliveController = KeepAliveController()
    private let motion: MotionAdapter
    private let battery: BatterySnapshot
    private let link: PhoneLink
    private let watchStarter = WatchStarter()
    private var peerWarning: String?
    private var preparing: Task<Void, Never>?
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
        let deviceId = try DeviceIdentity.load(root: root)
        controller = RecordingController(
            root: root, deviceId: deviceId, catalog: SensingCatalog.phone,
            adapters: [motion, AltimeterAdapter(), PedometerAdapter(), LocationAdapter(), ActivityAdapter(), BatteryAdapter(), ScreenAdapter(), NetworkAdapter(),
                       AudioLevelAdapter(), BluetoothAdapter(salt: deviceId)],
            device: DeviceDescription(platform: "ios", model: DeviceModel.machine(), os: "\(device.systemName) \(device.systemVersion)", appVersion: options.appVersion, sdkVersion: SDK.version),
            options: engine)
        link = PhoneLink(transport: WCLinkTransport(), root: root, engine: controller.engine, recordings: controller.recordings)
        controller.onEnded = { [weak self] summary in
            guard let self else { return }
            self.endKeepAlive()
            if self.link.desired?.recording != nil { self.link.publish(recording: nil) }
            self.refresh()
            self.onEnded?(summary)
        }
        link.onStopRequested = { [weak self] id in
            guard let self, self.controller.current?.id == id else { return }
            Task { await self.stop(reason: "watch_stop") }
        }
        link.onChange = { [weak self] in self?.refresh() }
        // Now, not at `prepare`: WatchConnectivity can launch this app in the background to hand it a chunk.
        link.activate()
        keepAliveController.onEvent = { [weak self] kind, detail in
            Task { @MainActor in self?.keepAliveEvent(kind, detail) }
        }
        refreshBattery()
    }

    /// Call once at launch: seals what a dead process left, and ends its recording.
    public func prepare() async {
        if preparing == nil {
            preparing = Task { @MainActor in
                await controller.recover()
                link.reconcile(activeRecordingId: controller.current?.id)
                refresh()
            }
        }
        await preparing?.value
    }

    public func requestLocationPermission() { keepAliveController.requestLocationPermission() }
    public func requestWorkoutPermission() async throws { try await keepAliveController.requestWorkoutPermission() }

    public var hasLocationPermission: Bool {
        let s = keepAliveController.locationAuthorization
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    public func start(_ spec: RecordingSpec) async throws {
        await prepare()
        guard UIApplication.shared.applicationState == .active else { throw SensingError.notInForeground }
        if keepAlive == .location100m || keepAlive == .location3km {
            guard hasLocationPermission else { throw SensingError.needsLocationPermission }
        }
        try keepAliveController.start(keepAlive)
        let summary: RecordingSummary
        do {
            summary = try await controller.start(spec)
        } catch {
            keepAliveController.stop()
            throw error
        }
        if !motion.northReferenced {
            await controller.engine.emit(SensorIDs.health, "attitude_frame", ["north": "none"])
        }
        startWatching()
        peerWarning = nil
        // The phone never waits for the watch: it's recording already.
        if recordWatch, link.transport.isCounterpartInstalled {
            link.publish(recording: PeerRecording(id: spec.id, label: spec.label, startWallMs: summary.startWallMs, maxDurationMs: spec.maxDurationMs, overrides: watchOverrides))
            startWatch()
            await link.pairClock()
        }
        refresh()
    }

    public func stop(answers: [String: String] = [:]) async {
        await stop(answers: answers, reason: "user_stop")
    }

    private func stop(answers: [String: String] = [:], reason: String) async {
        await link.pairClock()
        await controller.stop(answers: answers, reason: reason)
        refresh()
    }

    /// Ends it and deletes its label: it was started by mistake. The sensor data stays.
    public func discard() async {
        await controller.discard()
        refresh()
    }

    public func recordings() -> [RecordingSummary] { controller.recordings.all() }

    /// Chunks the watch said it recorded that haven't arrived.
    public func missingWatchChunks(recordingId: String) async -> [String] { await link.missingPeerChunks(recordingId: recordingId) }

    private func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshBattery()
                Task { @MainActor in
                    await self.controller.tick()
                    await self.link.tick()
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

    /// `startWatchApp` wakes the watch app, which begins its workout at once and then does what `link` published.
    private func startWatch() {
        let engine = controller.engine
        watchStarter.start { [weak self] ok, detail in
            guard !ok else { return }
            self?.peerWarning = "The watch didn't start: \(detail). This recording continues on the phone alone."
            Task { await engine.emit(SensorIDs.health, "peer_start_failed", ["detail": detail]) }
            self?.refresh()
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
            s.peer = link.peer
            s.watchInstalled = link.transport.isCounterpartInstalled
            if s.storageFraction >= 0.8 { s.warnings.append("Storage is \(Int64(s.storageFraction * 100))% full. Export and delete recordings; recording stops at 100%.") }
            if let peerWarning, s.recording != nil { s.warnings.append(peerWarning) }
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
}
#endif
