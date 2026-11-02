import SwiftUI

@main
struct ExampleApp: App {
    @State private var probe = PhoneProbe()

    var body: some Scene {
        WindowGroup {
            DiagnosticsView(probe: probe)
                #if DEBUG
                .task { probe.runLaunchArguments() }
                #endif
        }
    }
}
