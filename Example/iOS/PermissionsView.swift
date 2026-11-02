import SensingKit
import SwiftUI
import UIKit

struct PermissionsView: View {
    let model: RecordModel

    var body: some View {
        NavigationStack {
            List {
                if let sensing = model.sensing {
                    // Read so that this redraws when an answer arrives.
                    let _ = sensing.permissionAnswers
                    ForEach(SensingPermission.allCases) { permission in
                        row(permission, sensing)
                    }
                }
                Section {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } footer: {
                    Text("iOS asks each of these once. After that, a change has to be made in Settings. The watch has its own: open the app there and tap Allow workouts, and it asks for motion on its first recording.")
                }
            }
            .navigationTitle("Permissions")
        }
    }

    private func row(_ permission: SensingPermission, _ sensing: Sensing) -> some View {
        let state = sensing.state(of: permission)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.title(permission))
                Spacer()
                switch state {
                case .granted: Text("Allowed").foregroundStyle(.green)
                case .denied: Text("Denied").foregroundStyle(.red)
                case .unavailable: Text("Not on this device").foregroundStyle(.secondary)
                case .notAsked: Button("Ask") { Task { await sensing.request(permission) } }.buttonStyle(.borderedProminent)
                }
            }
            Text(Self.why(permission)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func title(_ p: SensingPermission) -> String {
        switch p {
        case .motion: "Motion"
        case .location: "Location"
        case .workouts: "Workouts"
        case .microphone: "Microphone"
        case .bluetooth: "Bluetooth"
        }
    }

    private static func why(_ p: SensingPermission) -> String {
        switch p {
        case .motion: "Steps, barometer and activity."
        case .location: "Needed for every recording: it keeps the app running with the screen locked. The location indicator shows while recording."
        case .workouts: "Starts the watch app. Nothing is saved to Health, and heart rate is never read."
        case .microphone: "Only if Sound level is on. Measures loudness. No audio is kept."
        case .bluetooth: "Only if Bluetooth is on. Counts nearby devices. Their identifiers are hashed."
        }
    }
}
