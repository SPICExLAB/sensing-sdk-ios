import HealthKit
import SwiftUI
import WatchKit

@main
struct ExampleWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchDelegate

    var body: some Scene {
        WindowGroup {
            WatchDiagnosticsView(probe: WatchProbe.shared)
                #if DEBUG
                .task { WatchProbe.shared.runLaunchArguments() }
                #endif
        }
    }
}

/// The iPhone opens this app with HKHealthStore.startWatchApp, and the system reopens it if it dies mid-workout.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        _ = WatchProbe.shared
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WatchProbe.shared.handle(workoutConfiguration)
    }

    func handleActiveWorkoutRecovery() {
        WatchProbe.shared.recover()
    }
}
