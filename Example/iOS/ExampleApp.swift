import SwiftUI

@main
struct ExampleApp: App {
    @State private var probe = PhoneProbe()

    var body: some Scene {
        WindowGroup {
            TabView {
                RecordView().tabItem { Label("Record", systemImage: "record.circle") }
                DiagnosticsView(probe: probe)
                    #if DEBUG
                    .task { probe.runLaunchArguments() }
                    #endif
                    .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            }
        }
    }
}
