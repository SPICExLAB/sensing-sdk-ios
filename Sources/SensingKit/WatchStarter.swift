#if os(iOS)
import Foundation
import HealthKit

/// Wakes the watch app with `startWatchApp`, which is the only way to start a workout on the watch from the phone. It's tried
/// again once: the first attempt can fail while the watch is asleep.
@MainActor
final class WatchStarter {
    private let health = HKHealthStore()

    func start(retriesLeft: Int64 = 1, delay: Duration = .seconds(5), _ done: @escaping @MainActor (Bool, String) -> Void) {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        health.startWatchApp(with: config) { ok, error in
            let detail = error.map { String(describing: $0) } ?? ""
            Task { @MainActor [weak self] in
                guard !ok, retriesLeft > 0 else {
                    done(ok, detail)
                    return
                }
                try? await Task.sleep(for: delay)
                self?.start(retriesLeft: retriesLeft - 1, delay: delay, done)
            }
        }
    }
}
#endif
