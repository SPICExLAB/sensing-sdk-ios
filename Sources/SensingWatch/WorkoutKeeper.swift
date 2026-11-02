#if os(watchOS)
import Foundation
import HealthKit
import SensingLink

/// Keeps the watch app running with the screen off: a workout session is the only way to get continuous motion data on
/// Apple Watch. It writes nothing to Health (there's no workout builder) and never reads heart rate.
///
/// Failures aren't silent: everything that goes wrong reaches `onEvent`, and `start` throws.
public final class WorkoutKeeper: NSObject, @unchecked Sendable {
    /// Things worth recording: kind, then detail.
    public var onEvent: (@Sendable (String, String) -> Void)?

    private let store = HKHealthStore()
    private let lock = NSLock()
    private var session: HKWorkoutSession?

    public var isRunning: Bool { lock.withLock { session != nil } }

    public var authorizationStatus: HKAuthorizationStatus {
        store.authorizationStatus(for: HKObjectType.workoutType())
    }

    /// Asks for permission to run workout sessions: workouts only, and no read access.
    public func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
    }

    public static func defaultConfiguration() -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        return config
    }

    public func start() throws { try start(Self.defaultConfiguration()) }

    public func start(_ configuration: HKWorkoutConfiguration) throws {
        guard !isRunning else { return }
        let s = try HKWorkoutSession(healthStore: store, configuration: configuration)
        s.delegate = self  // set before starting, so no state change is missed
        lock.withLock { session = s }
        s.startActivity(with: Date())
        onEvent?("workout_start", "auth=\(authorizationStatus.rawValue)")
    }

    /// Reattaches to a session the system kept running after this app died. Returns whether there was one.
    public func recover() async throws -> Bool {
        guard let recovered = try await store.recoverActiveWorkoutSession() else { return false }
        recovered.delegate = self  // the property is weak, and this object outlives the session
        lock.withLock { session = recovered }
        onEvent?("workout_recovered", "state=\(recovered.state.rawValue)")
        return true
    }

    public func stop() {
        let s = lock.withLock { () -> HKWorkoutSession? in
            defer { session = nil }
            return session
        }
        s?.end()
    }
}

extension WorkoutKeeper: WatchKeepAlive {}

extension WorkoutKeeper: HKWorkoutSessionDelegate {
    public func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) {
        onEvent?("workout_state", "\(from.rawValue)->\(to.rawValue)")
    }

    public func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        onEvent?("workout_error", String(describing: error))
    }
}
#endif
