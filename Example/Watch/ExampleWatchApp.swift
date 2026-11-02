import HealthKit
import SwiftUI
import WatchKit

@main
struct ExampleWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchDelegate

    var body: some Scene {
        WindowGroup {
            WatchRecordView(model: WatchModel.shared)
        }
    }
}

/// The iPhone opens this app with HKHealthStore.startWatchApp, and the system reopens it if it dies mid-workout.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchModel.shared.prepare()
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WatchModel.shared.sensing?.handle(workoutConfiguration)
        WatchModel.shared.prepare()
    }

    func handleActiveWorkoutRecovery() {
        WatchModel.shared.prepare()
    }
}
