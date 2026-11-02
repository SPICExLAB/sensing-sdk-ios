import SwiftUI

@main
struct ExampleApp: App {
    @State private var probe = PhoneProbe()
    // Created here, not with the first screen: WatchConnectivity can launch this app in the background to hand it a chunk.
    @State private var model = RecordModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                RecordView(model: model).tabItem { Label("Record", systemImage: "record.circle") }
                DiagnosticsView(probe: probe)
                    #if DEBUG
                    .task { probe.runLaunchArguments() }
                    #endif
                    .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            }
        }
    }
}
