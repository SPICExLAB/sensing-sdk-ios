#if os(watchOS)
import Foundation
import HealthKit
import Observation
import SensingAdapters
import SensingCore
import SensingEngine
import SensingLink
import SensingStorage
import WatchKit

/// The watch's public API. It records what the phone asks for, under a workout session that keeps it running wrist-down, and
/// sends its chunks to the phone. A recording starts on the phone; the watch can only stop one (S-010).
@MainActor
@Observable
public final class WatchSensing {
    public struct Status: Sendable, Equatable {
        public var recording: RecordingSummary?
        public var streams: [String: CollectionEngine.StreamLive] = [:]
        public var dropped: Int64 = 0
        public var phoneReachable = false
        public var chunks = ChunkDrainer.Status()
        public var batteryPct: Int64?
    }

    public private(set) var status = Status()
    public let root: StorageRoot

    private let keeper = WorkoutKeeper()
    private let battery = BatterySnapshot()
    private let controller: RecordingController
    private let link: WatchLink
    private var timer: Timer?

    public init(appVersion: String = "") throws {
        root = try StorageRoot.standard()
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let battery = battery
        var options = CollectionEngine.Options()
        options.deviceKind = .watch
        options.highWater = 12_500
        options.hardCeiling = 50_000
        options.heartbeatExtras = { @Sendable in battery.attributes() }
        let deviceId = try DeviceIdentity.load(root: root)
        let uwbRelay = PeerTokenRelay()
        controller = RecordingController(
            root: root, deviceId: deviceId, catalog: SensingCatalog.watch,
            adapters: [MotionAdapter(), AltimeterAdapter(), PedometerAdapter(), LocationAdapter(), ActivityAdapter(), BatteryAdapter(), ScreenAdapter(), NetworkAdapter(), AudioLevelAdapter(),
                       HeadingAdapter(), UwbDistanceAdapter(relay: uwbRelay)],
            device: DeviceDescription(platform: "watchos", model: DeviceModel.machine(), os: "\(device.systemName) \(device.systemVersion)", appVersion: appVersion, sdkVersion: SDK.version,
                                      extras: ["wrist": device.wristLocation == .left ? "left" : "right", "crown": device.crownOrientation == .left ? "left" : "right"]),
            options: options)
        link = WatchLink(transport: WCLinkTransport(), controller: controller, keepAlive: keeper, root: root, deviceId: deviceId, batteryPct: { @Sendable in battery.pct })
        keeper.onEvent = { [weak self] kind, detail in
            Task { @MainActor in await self?.keepAliveEvent(kind, detail) }
        }
        link.onChange = { [weak self] in self?.refresh() }
        let link = link
        uwbRelay.onSend { token in Task { @MainActor in link.sendUwbToken(token) } }
        link.onUwbToken = { uwbRelay.receive($0) }
        link.activate()
        refreshBattery()
    }

    /// Call at launch, and from `handleActiveWorkoutRecovery`.
    public func prepare() async {
        await link.prepare()
        startTimer()
        refresh()
    }

    /// From `handle(_ workoutConfiguration:)`: the phone opened this app with `startWatchApp`. The workout has to start here and
    /// now; what to record arrives over the link.
    public func handle(_ configuration: HKWorkoutConfiguration) {
        do {
            try keeper.start(configuration)
            link.workoutLaunched()
        } catch {
            let detail = String(describing: error)
            Task { await link.note("keepalive_failed", detail) }
        }
    }

    public var workoutAuthorization: HKAuthorizationStatus { keeper.authorizationStatus }
    public func requestWorkoutPermission() async throws { try await keeper.requestAuthorization() }

    /// Stops this device, and asks the phone to stop too.
    public func stop() async {
        await link.stopPressed()
        refresh()
    }

    public func recordings() -> [RecordingSummary] { controller.recordings.all() }

    private func keepAliveEvent(_ kind: String, _ detail: String) async {
        await link.note(kind, detail)
        let ended = kind == "workout_state" && (detail.hasSuffix("->\(HKWorkoutSessionState.ended.rawValue)") || detail.hasSuffix("->\(HKWorkoutSessionState.stopped.rawValue)"))
        if kind == "workout_error" || ended { await link.keepAliveFailed(detail) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshBattery()
                Task { @MainActor in
                    await self.link.tick()
                    self.refresh()
                }
            }
        }
    }

    private func refreshBattery() {
        let device = WKInterfaceDevice.current()
        battery.store(level: device.batteryLevel, charging: device.batteryState == .charging || device.batteryState == .full)
    }

    private func refresh() {
        let controller = controller
        let link = link
        let battery = battery
        Task { @MainActor in
            let stats = await controller.engine.stats()
            let chunks = await link.drainer.status
            let s = Status(recording: controller.current, streams: stats.streams, dropped: stats.dropped, phoneReachable: link.isReachable, chunks: chunks, batteryPct: battery.pct)
            if status != s { status = s }
        }
    }
}
#endif
