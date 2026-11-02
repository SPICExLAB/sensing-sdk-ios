import SwiftUI

@main
struct ExampleApp: App {
    @State private var probe = PhoneProbe()
    // Created here, not with the first screen: WatchConnectivity can launch this app in the background to hand it a chunk.
    @State private var model = RecordModel()
    // In debug builds, `-tab 2` opens on a tab, for screenshots.
    @State private var tab = UserDefaults.standard.integer(forKey: "tab")

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                RecordView(model: model).tabItem { Label("Record", systemImage: "record.circle") }.tag(0)
                RecordingsView(model: model).tabItem { Label("Recordings", systemImage: "list.bullet") }.tag(1)
                SensorsView(model: model).tabItem { Label("Sensors", systemImage: "slider.horizontal.3") }.tag(2)
                PermissionsView(model: model).tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(3)
                DiagnosticsView(probe: probe, model: model)
                    #if DEBUG
                    .task { probe.runLaunchArguments() }
                    #endif
                    .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                    .tag(4)
            }
        }
    }
}
