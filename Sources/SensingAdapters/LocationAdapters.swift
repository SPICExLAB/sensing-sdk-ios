#if os(iOS) || os(watchOS)
@preconcurrency import CoreLocation
@preconcurrency import CoreMotion
import Foundation
import SensingCore
import SensingProto

/// `loc.fused`, the one location stream iOS has: CoreLocation doesn't expose raw GPS. It keeps its own manager at higher
/// accuracy than the iPhone's keep-alive, and thins to the configured rate by the fix's own time.
public final class LocationAdapter: NSObject, SensorAdapter, CLLocationManagerDelegate, @unchecked Sendable {
    public let sensors = [SensingCatalog.location]

    private let lock = NSLock()
    private var manager: CLLocationManager?
    private var session: CLBackgroundActivitySession?
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var decimator = Decimator(periodUs: 30_000_000)
    private var gate = ForwardGate()
    private var available: Bool?
    private var lastState: [String: String]?

    public override init() {}

    public func availability(of sensor: SensorID) -> Availability {
        switch CLLocationManager().authorizationStatus {
        case .denied, .restricted, .notDetermined: .missingPermission(["location"])
        default: CLLocationManager.locationServicesEnabled() ? .available : .missingPermission(["location"])
        }
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.location] else { return }
        let periodUs = settings[SensingCatalog.location]?.samplingPeriodUs ?? 30_000_000
        lock.withLock {
            self.sink = sink
            self.clock = clock
            decimator = Decimator(periodUs: periodUs)
            gate = ForwardGate(startNs: clock.monoNs())  // a cached fix from before this recording isn't part of it
            available = nil
            lastState = nil
        }
        sink.event("listening", ["interval_ms": String(periodUs / 1000), "provider_enabled": CLLocationManager.locationServicesEnabled() ? "true" : "false"], tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
        // A location manager needs a thread with a run loop.
        DispatchQueue.main.async { [self] in
            let m = CLLocationManager()
            m.delegate = self
            // A fast rate is for following movement, which ten-metre fixes can't.
            m.desiredAccuracy = periodUs < 10_000_000 ? kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters
            m.distanceFilter = kCLDistanceFilterNone
            if Self.hasBackgroundLocationMode {
                m.allowsBackgroundLocationUpdates = true
                #if os(iOS)
                m.pausesLocationUpdatesAutomatically = false
                #endif
            }
            lock.withLock {
                manager = m
                session = CLBackgroundActivitySession()
            }
            m.startUpdatingLocation()
        }
    }

    public func stop() {
        let (m, s) = lock.withLock { () -> (CLLocationManager?, CLBackgroundActivitySession?) in
            defer {
                manager = nil
                session = nil
                sink = nil
                clock = nil
            }
            return (manager, session)
        }
        DispatchQueue.main.async {
            m?.stopUpdatingLocation()
            s?.invalidate()
        }
    }

    /// Setting `allowsBackgroundLocationUpdates` without the mode in Info.plist is a crash.
    private static var hasBackgroundLocationMode: Bool {
        let keys = ["UIBackgroundModes", "WKBackgroundModes"]
        return keys.contains { (Bundle.main.object(forInfoDictionaryKey: $0) as? [String])?.contains("location") == true }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            let info = l.sourceInformation
            let fix = LocationMapping.Fix(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, ellipsoidalAltitude: l.ellipsoidalAltitude,
                                          horizontalAccuracy: l.horizontalAccuracy, verticalAccuracy: l.verticalAccuracy, speed: l.speed, speedAccuracy: l.speedAccuracy,
                                          course: l.course, courseAccuracy: l.courseAccuracy, simulated: info?.isSimulatedBySoftware == true, accessory: info?.isProducedByAccessory == true)
            guard let payload = LocationMapping.payload(fix) else { continue }
            let wall = Int64(l.timestamp.timeIntervalSince1970 * 1000)
            let state = LocationStateEvent.attributes(fullAccuracy: manager.accuracyAuthorization == .fullAccuracy, floor: l.floor.map { Int64($0.level) })
            lock.withLock {
                guard let sink, let clock else { return }
                let mono = clock.monoNs() - max(clock.wallMs() - wall, 0) * 1_000_000
                guard gate.admit(tsNs: mono) else { return }
                // At the fix's own time, since it's the fix that says so.
                if available != true {
                    available = true
                    sink.event("available", tsMonoNs: mono, tsWallMs: wall)
                }
                if state != lastState {
                    lastState = state
                    sink.event("state", state, tsMonoNs: mono, tsWallMs: wall)
                }
                guard decimator.take(tsNs: mono) else { return }
                sink.message(.location(payload), tsMonoNs: mono, tsWallMs: wall, accuracy: .high)
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lock.withLock {
            guard let sink, let clock, available != false else { return }
            available = false
            let mono = clock.monoNs()
            gate.note(tsNs: mono)
            sink.event("unavailable", ["reason": String((error as NSError).code)], tsMonoNs: mono, tsWallMs: clock.wallMs())
        }
    }
}

/// `loc.heading`: the compass, as CoreLocation calibrates it, with the raw field behind it.
public final class HeadingAdapter: NSObject, SensorAdapter, CLLocationManagerDelegate, @unchecked Sendable {
    public let sensors = [SensingCatalog.heading]

    private let lock = NSLock()
    private var manager: CLLocationManager?
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var decimator = Decimator(periodUs: 1_000_000)
    private var gate = ForwardGate()

    public override init() {}

    public func availability(of sensor: SensorID) -> Availability {
        CLLocationManager.headingAvailable() ? .available : .missingHardware
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.heading] else { return }
        let periodUs = settings[SensingCatalog.heading]?.samplingPeriodUs ?? 1_000_000
        lock.withLock {
            self.sink = sink
            self.clock = clock
            decimator = Decimator(periodUs: periodUs)
            gate = ForwardGate(startNs: clock.monoNs())
        }
        // A location manager needs a thread with a run loop.
        DispatchQueue.main.async { [self] in
            let m = CLLocationManager()
            m.delegate = self
            m.headingFilter = kCLHeadingFilterNone
            lock.withLock { manager = m }
            m.startUpdatingHeading()
        }
    }

    public func stop() {
        let m = lock.withLock { () -> CLLocationManager? in
            defer {
                manager = nil
                sink = nil
                clock = nil
            }
            return manager
        }
        DispatchQueue.main.async { m?.stopUpdatingHeading() }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        let wall = Int64(heading.timestamp.timeIntervalSince1970 * 1000)
        lock.withLock {
            guard let sink, let clock else { return }
            let mono = clock.monoNs() - max(clock.wallMs() - wall, 0) * 1_000_000
            guard gate.admit(tsNs: mono), decimator.take(tsNs: mono) else { return }
            sink.event("heading", HeadingEvent.attributes(magnetic: heading.magneticHeading, trueHeading: heading.trueHeading, accuracy: heading.headingAccuracy, x: heading.x, y: heading.y, z: heading.z),
                       tsMonoNs: mono, tsWallMs: wall)
        }
    }
}

/// `loc.activity`, mapped to Android's activity names and transitions. iOS adds a confidence.
public final class ActivityAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.activity]

    private let manager = CMMotionActivityManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var transitions = ActivityTransitions()
    private var gate = ForwardGate()
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var tracker: SleepOffsetTracker?
    private var lastDate: Date?

    public init() {
        queue.maxConcurrentOperationCount = 1
        queue.name = "sensing.activity"
    }

    public func availability(of sensor: SensorID) -> Availability {
        guard CMMotionActivityManager.isActivityAvailable() else { return .missingHardware }
        let status = CMMotionActivityManager.authorizationStatus()
        return status == .denied || status == .restricted ? .missingPermission(["motion"]) : .available
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.activity] else { return }
        lock.withLock {
            self.sink = sink
            self.clock = clock
            transitions = ActivityTransitions()
            gate = ForwardGate()
            tracker = SleepOffsetTracker(uptimeNs: clock.uptimeNs(), offsetNs: clock.monoNs() - clock.uptimeNs())
            lastDate = Date()
        }
        manager.startActivityUpdates(to: queue) { [weak self] activity in
            if let activity { self?.deliver(activity) }
        }
    }

    public func stop() {
        manager.stopActivityUpdates()
        // Activity is reported late, so what's still owed comes from a query. The engine waits for no one: it arrives or it doesn't.
        if let from = lock.withLock({ lastDate }) {
            let done = DispatchSemaphore(value: 0)
            manager.queryActivityStarting(from: from, to: Date(), to: queue) { [weak self] activities, _ in
                activities?.forEach { self?.deliver($0) }
                done.signal()
            }
            _ = done.wait(timeout: .now() + .seconds(1))
        }
        queue.waitUntilAllOperationsAreFinished()
        lock.withLock {
            sink = nil
            clock = nil
            tracker = nil
            lastDate = nil
        }
    }

    private func deliver(_ a: CMMotionActivity) {
        let flags = ActivityTransitions.Flags(stationary: a.stationary, walking: a.walking, running: a.running, cycling: a.cycling, automotive: a.automotive)
        let confidence = switch a.confidence {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        @unknown default: "unknown"
        }
        lock.withLock {
            guard let sink, let clock, let tracker else { return }
            lastDate = a.startDate
            tracker.observe(uptimeNs: clock.uptimeNs(), offsetNs: clock.monoNs() - clock.uptimeNs())
            let mono = tracker.monoNs(forTimestamp: a.timestamp)
            let wall = Conversions.wallMs(forMonoNs: mono, clock: clock)
            guard gate.admit(tsNs: mono) else { return }
            for t in transitions.observe(flags) {
                sink.event("transition", ["activity": t.activity, "transition": t.transition, "confidence": confidence], tsMonoNs: mono, tsWallMs: wall)
            }
        }
    }
}
#endif
