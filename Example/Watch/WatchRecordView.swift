import HealthKit
import SensingWatch
import SwiftUI

@MainActor
@Observable
final class WatchModel {
    static let shared = WatchModel()

    private(set) var sensing: WatchSensing?
    private(set) var message = ""

    private init() {
        do {
            sensing = try WatchSensing(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        } catch {
            message = "Couldn't open storage: \(error)"
        }
    }

    func prepare() {
        guard let sensing else { return }
        Task { await sensing.prepare() }
    }

    func allowWorkouts() {
        guard let sensing else { return }
        Task {
            do {
                try await sensing.requestWorkoutPermission()
            } catch {
                message = String(describing: error)
            }
        }
    }

    func stop() {
        guard let sensing else { return }
        Task { await sensing.stop() }
    }
}

/// Recordings start on the phone. This shows what's running, and has the Stop button.
struct WatchRecordView: View {
    let model: WatchModel

    var body: some View {
        List {
            if let sensing = model.sensing {
                let status = sensing.status
                if let recording = status.recording {
                    Section {
                        Text(recording.label).font(.headline)
                        Text(Date(timeIntervalSince1970: Double(recording.startWallMs) / 1000), style: .timer).monospacedDigit()
                        Button("Stop", role: .destructive) { model.stop() }
                    }
                    Section("Live") {
                        ForEach(status.streams.keys.sorted().filter { $0.hasPrefix("motion.") || $0.hasPrefix("env.") }, id: \.self) { name in
                            LabeledContent(String(name.split(separator: ".").last ?? ""), value: status.streams[name]!.hz.formatted(.number.precision(.fractionLength(1))))
                                .font(.caption2)
                        }
                        if status.dropped > 0 { Text("Dropped \(status.dropped)").font(.caption2).foregroundStyle(.red) }
                    }
                } else {
                    Text("Start a recording on the iPhone.")
                    if sensing.workoutAuthorization == .notDetermined {
                        Button("Allow workouts") { model.allowWorkouts() }
                    }
                }
                Section("Status") {
                    LabeledContent("Phone", value: status.phoneReachable ? "Reachable" : "Not reachable").font(.caption2)
                    LabeledContent("Chunks to send", value: String(status.chunks.waiting)).font(.caption2)
                    LabeledContent("Sent", value: String(status.chunks.delivered)).font(.caption2)
                    if let pct = status.batteryPct { LabeledContent("Battery", value: "\(pct)%").font(.caption2) }
                    if let failure = status.chunks.lastFailure { Text(failure).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            if !model.message.isEmpty { Text(model.message).font(.caption2) }
            #if DEBUG
            Section("Debug") {
                // A8: the system should bring this app back within 30 s, with the workout alive and the gap recorded.
                Button("Crash now", role: .destructive) { fatalError("A8: a deliberate crash") }
            }
            #endif
        }
    }
}
