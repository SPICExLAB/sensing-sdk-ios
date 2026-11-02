#if os(iOS) || os(watchOS)
import Foundation
import Network
import SensingCore
import SensingProto
#if os(iOS)
import UIKit
#else
import WatchKit
#endif

private func eventNow(_ sink: SampleSink, _ kind: String, _ attrs: [String: String] = [:], clock: any EngineClock) {
    sink.event(kind, attrs, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
}

/// `device.battery`: at the start and on each change. The watch has no change notifications, so it's polled.
public final class BatteryAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.battery]
    private static let watchPollSeconds: TimeInterval = 60

    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var last: [String: String]?

    public init() {}

    public func availability(of sensor: SensorID) -> Availability { .available }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.battery] else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { begin(sink: sink, clock: clock) }
        }
    }

    @MainActor
    private func begin(sink: SampleSink, clock: any EngineClock) {
        // Monitoring first: until it's on, the level reads -1.
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        report(sink: sink, clock: clock)
        let names = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        let added = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(sink: sink, clock: clock) }
            }
        }
        lock.withLock { observers = added }
        #else
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        report(sink: sink, clock: clock)
        let poll = Timer.scheduledTimer(withTimeInterval: Self.watchPollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(sink: sink, clock: clock) }
        }
        lock.withLock { timer = poll }
        #endif
    }

    @MainActor
    private func report(sink: SampleSink, clock: any EngineClock) {
        #if os(iOS)
        let device = UIDevice.current
        let level = device.batteryLevel
        let charge: BatteryEvent.Charge = switch device.batteryState {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        default: .unknown
        }
        #else
        let device = WKInterfaceDevice.current()
        let level = device.batteryLevel
        let charge: BatteryEvent.Charge = switch device.batteryState {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        default: .unknown
        }
        #endif
        let info = ProcessInfo.processInfo
        let attrs = BatteryEvent.attributes(levelFraction: level, charge: charge, lowPower: info.isLowPowerModeEnabled, thermalState: Int64(info.thermalState.rawValue))
        let changed = lock.withLock { () -> Bool in
            defer { last = attrs }
            return last != attrs
        }
        if changed { eventNow(sink, "battery", attrs, clock: clock) }
    }

    public func stop() {
        let (added, poll) = lock.withLock { () -> ([NSObjectProtocol], Timer?) in
            defer {
                observers = []
                timer = nil
                last = nil
            }
            return (observers, timer)
        }
        added.forEach(NotificationCenter.default.removeObserver)
        DispatchQueue.main.async { poll?.invalidate() }
    }
}

/// `device.screen`, which is approximate on iOS: real screen wake isn't visible to apps. The phone reports its lock state and
/// the watch whether this app is active, each marked with `source`.
public final class ScreenAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.screen]

    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func availability(of sensor: SensorID) -> Availability { .available }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.screen] else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { begin(sink: sink, clock: clock) }
        }
    }

    @MainActor
    private func begin(sink: SampleSink, clock: any EngineClock) {
        #if os(iOS)
        let source = "data_protection"
        let on = UIApplication.shared.isProtectedDataAvailable
        let pairs: [(Notification.Name, String)] = [(UIApplication.protectedDataWillBecomeUnavailableNotification, "screen_off"),
                                                    (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked")]
        #else
        let source = "app_active"
        let on = WKApplication.shared().applicationState == .active
        let pairs: [(Notification.Name, String)] = [(WKApplication.willResignActiveNotification, "screen_off"),
                                                    (WKApplication.didBecomeActiveNotification, "screen_on")]
        #endif
        eventNow(sink, on ? "screen_on" : "screen_off", ["initial": "true", "source": source], clock: clock)
        let added = pairs.map { name, kind in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                eventNow(sink, kind, ["source": source], clock: clock)
            }
        }
        lock.withLock { observers = added }
    }

    public func stop() {
        let added = lock.withLock { () -> [NSObjectProtocol] in
            defer { observers = [] }
            return observers
        }
        added.forEach(NotificationCenter.default.removeObserver)
    }
}

/// `device.network`: at the start and whenever one of its three fields changes.
public final class NetworkAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.network]

    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    public init() {}

    public func availability(of sensor: SensorID) -> Availability { .available }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.network] else { return }
        let m = NWPathMonitor()
        let last = LastValue()
        m.pathUpdateHandler = { path in
            let attrs = Self.attributes(of: path)
            if last.changed(to: attrs) { eventNow(sink, "network", attrs, clock: clock) }
        }
        lock.withLock { monitor = m }
        m.start(queue: DispatchQueue(label: "sensing.network", qos: .utility))
    }

    public func stop() {
        let m = lock.withLock { () -> NWPathMonitor? in
            defer { monitor = nil }
            return monitor
        }
        m?.cancel()
    }

    private static func attributes(of path: NWPath) -> [String: String] {
        guard path.status != .unsatisfied else { return NetworkEvent.none }
        let transport: String
        if path.usesInterfaceType(.wifi) {
            transport = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            transport = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            transport = "ethernet"
        } else {
            transport = "other"  // includes the watch's link through the phone
        }
        return NetworkEvent.attributes(transport: transport, metered: path.isExpensive, validated: path.status == .satisfied)
    }

    private final class LastValue: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: String]?

        func changed(to new: [String: String]) -> Bool {
            lock.withLock {
                defer { value = new }
                return value != new
            }
        }
    }
}
#endif
