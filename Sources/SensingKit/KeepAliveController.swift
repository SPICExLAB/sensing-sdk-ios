#if os(iOS)
import CoreLocation
import Foundation
import HealthKit

/// How the iPhone stays alive while a recording runs with the screen locked. CoreMotion stops delivering once the app
/// is suspended, so something has to keep the process running. Phase 1 measures these against each other.
public enum KeepAliveMode: String, Sendable, CaseIterable, Identifiable {
    /// The control: nothing keeps the app alive.
    case none
    /// The location background mode at 100 m accuracy.
    case location100m
    /// The same at 3 km, which should cost less if it holds.
    case location3km
    /// A workout session on the iPhone itself. iOS 26 or later.
    case workout

    public var id: String { rawValue }
}

/// Keeps the app running while recording. Start it in the foreground: `CLBackgroundActivitySession` and background
/// location can only begin there.
@MainActor
public final class KeepAliveController: NSObject {
    /// Things worth recording: kind, then detail. Never coordinates.
    public var onEvent: (@Sendable (String, String) -> Void)?

    private let location = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private let health = HKHealthStore()
    private var workout: AnyObject?  // HKWorkoutSession, which only has a public initialiser on iOS 26
    private var workoutDelegate: WorkoutDelegate?
    private var mode: KeepAliveMode = .none
    private var fixes: Int64 = 0

    public override init() {
        super.init()
        location.delegate = self
    }

    public var locationAuthorization: CLAuthorizationStatus { location.authorizationStatus }

    public func requestLocationPermission() {
        location.requestWhenInUseAuthorization()
    }

    public func requestWorkoutPermission() async throws {
        try await health.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
    }

    public func start(_ mode: KeepAliveMode) throws {
        stop()
        self.mode = mode
        fixes = 0
        onEvent?("keepalive_start", mode.rawValue)
        switch mode {
        case .none:
            break
        case .location100m:
            startLocation(accuracy: kCLLocationAccuracyHundredMeters)
        case .location3km:
            startLocation(accuracy: kCLLocationAccuracyThreeKilometers)
        case .workout:
            try startWorkout()
        }
    }

    public func stop() {
        guard mode != .none || backgroundSession != nil || workout != nil else { return }
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        if #available(iOS 26.0, *), let session = workout as? HKWorkoutSession { session.end() }
        workout = nil
        workoutDelegate = nil
        onEvent?("keepalive_stop", "\(mode.rawValue) fixes=\(fixes)")
        mode = .none
    }

    private func startLocation(accuracy: CLLocationAccuracy) {
        backgroundSession = CLBackgroundActivitySession()
        location.allowsBackgroundLocationUpdates = true
        location.pausesLocationUpdatesAutomatically = false
        location.showsBackgroundLocationIndicator = true
        location.desiredAccuracy = accuracy
        location.distanceFilter = kCLDistanceFilterNone
        location.startUpdatingLocation()
    }

    private func startWorkout() throws {
        guard #available(iOS 26.0, *) else { throw KeepAliveError.workoutNeedsIOS26 }
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        let session = try HKWorkoutSession(healthStore: health, configuration: config)
        let delegate = WorkoutDelegate(onEvent: onEvent)
        session.delegate = delegate  // weak, so this class holds it
        workoutDelegate = delegate
        session.startActivity(with: Date())
        workout = session
    }
}

public enum KeepAliveError: Error, CustomStringConvertible {
    case workoutNeedsIOS26

    public var description: String { "a workout session on iPhone needs iOS 26" }
}

extension KeepAliveController: CLLocationManagerDelegate {
    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let count = locations.count
        MainActor.assumeIsolated {
            fixes += Int64(count)
            if fixes % 60 == 1 { onEvent?("location_fixes", "\(fixes)") }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let text = String(describing: error)
        MainActor.assumeIsolated { onEvent?("location_error", text) }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus.rawValue
        MainActor.assumeIsolated { onEvent?("location_authorization", "\(status)") }
    }
}

private final class WorkoutDelegate: NSObject, HKWorkoutSessionDelegate, @unchecked Sendable {
    let onEvent: (@Sendable (String, String) -> Void)?

    init(onEvent: (@Sendable (String, String) -> Void)?) { self.onEvent = onEvent }

    func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) {
        onEvent?("workout_state", "\(from.rawValue)->\(to.rawValue)")
    }

    func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        onEvent?("workout_error", String(describing: error))
    }
}
#endif
