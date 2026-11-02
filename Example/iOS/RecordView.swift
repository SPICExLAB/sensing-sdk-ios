import SensingCore
import SensingEngine
import SensingKit
import SwiftUI
import UIKit

/// Phase 4's minimal recording screen, on the real SDK. The full app comes in Phase 7.
@MainActor
@Observable
final class RecordModel {
    var motionHz: Int64 = 50
    private(set) var sensing: Sensing?
    private(set) var message = "" {
        didSet {
            #if DEBUG
            print("record: \(message)")
            #endif
        }
    }
    private(set) var recordings: [RecordingSummary] = []

    init() {
        do {
            let s = try Sensing(options: {
                var o = Sensing.Options()
                o.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                return o
            }())
            s.onEnded = { [weak self] summary in
                self?.message = "Ended: \(summary.endReason ?? "")"
                self?.reload()
            }
            sensing = s
            Task {
                await s.prepare()
                reload()
            }
        } catch {
            message = "Couldn't open storage: \(error)"
        }
    }

    func start() {
        guard let sensing else { return }
        applyRate()
        Task {
            do {
                try await sensing.start(RecordingSpec(label: "Test"))
                message = "Recording. Lock the phone whenever you like."
            } catch {
                message = String(describing: error)
            }
        }
    }

    func stop() {
        guard let sensing else { return }
        Task {
            await sensing.stop()
            message = "Stopped."
            reload()
        }
    }

    func reload() { recordings = sensing?.recordings() ?? [] }

    #if DEBUG
    /// `devicectl device process launch … -recordAutostart YES -recordSeconds 60 -recordHz 100`
    func runLaunchArguments() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "recordAutostart") else { return }
        let hz = Int64(defaults.integer(forKey: "recordHz"))
        if hz > 0 { motionHz = hz }
        if defaults.object(forKey: "recordWatch") != nil { sensing?.recordWatch = defaults.bool(forKey: "recordWatch") }
        let seconds = max(defaults.double(forKey: "recordSeconds"), 3)
        Task {
            // This runs before the scene is active, and keep-alive can only begin in the foreground.
            while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(100)) }
            start()
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }
    #endif

    /// A3 needs everything at one rate.
    private func applyRate() {
        guard let sensing, motionHz != 50 else {
            sensing?.overrides = [:]
            return
        }
        let period = 1_000_000 / motionHz
        let motion = [SensingCatalog.accelerometer, SensingCatalog.gyroscope, SensingCatalog.linearAcceleration, SensingCatalog.magnetometer, SensingCatalog.rotation, SensingCatalog.gravity]
        sensing.overrides = Dictionary(uniqueKeysWithValues: motion.map { ($0, SensorOverride(samplingPeriodUs: period)) })
    }
}

struct RecordView: View {
    let model: RecordModel

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    if let sensing = model.sensing {
                        if sensing.status.recording != nil {
                            Button("Stop", role: .destructive) { model.stop() }
                            if let start = sensing.status.recording?.startWallMs {
                                Text(Date(timeIntervalSince1970: Double(start) / 1000), style: .timer).monospacedDigit()
                            }
                        } else {
                            Picker("Motion rate", selection: $model.motionHz) {
                                Text("Defaults").tag(Int64(50))
                                Text("All at 100 Hz").tag(Int64(100))
                            }
                            if sensing.status.watchInstalled {
                                Toggle("Also record on the watch", isOn: Binding(get: { sensing.recordWatch }, set: { sensing.recordWatch = $0 }))
                            }
                            Button("Start") { model.start() }
                            if !sensing.hasLocationPermission {
                                Button("Allow location") { sensing.requestLocationPermission() }
                            }
                        }
                        if !model.message.isEmpty { Text(model.message).font(.caption) }
                        ForEach(sensing.status.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
                if let status = model.sensing?.status, status.recording != nil {
                    Section("Live") {
                        ForEach(status.streams.keys.sorted(), id: \.self) { name in
                            let s = status.streams[name]!
                            LabeledContent(name, value: "\(s.hz.formatted(.number.precision(.fractionLength(1)))) Hz · \(s.count)").font(.caption)
                        }
                        LabeledContent("Waiting / dropped", value: "\(status.pending) / \(status.dropped)").font(.caption)
                    }
                }
                if let status = model.sensing?.status, status.watchInstalled {
                    Section("Watch") {
                        LabeledContent("Link", value: status.peer.reachable ? "Reachable" : "Not reachable").font(.caption)
                        LabeledContent("Chunks received", value: String(status.peer.received)).font(.caption)
                        if status.peer.refused > 0 { LabeledContent("Chunks refused", value: String(status.peer.refused)).font(.caption).foregroundStyle(.red) }
                        if let peer = status.peer.status, peer.recordingId != nil, status.recording != nil {
                            ForEach(peer.hz.keys.sorted().filter { $0.hasPrefix("motion.") || $0.hasPrefix("env.") }, id: \.self) { name in
                                LabeledContent(name, value: "\(peer.hz[name]!.formatted(.number.precision(.fractionLength(1)))) Hz").font(.caption)
                            }
                            LabeledContent("Waiting to send / dropped", value: "\(peer.chunksWaiting) / \(peer.dropped)").font(.caption)
                            if let pct = peer.batteryPct { LabeledContent("Battery", value: "\(pct)%").font(.caption) }
                        }
                    }
                }
                Section("Recordings") {
                    ForEach(model.recordings) { r in
                        VStack(alignment: .leading) {
                            Text(r.label)
                            Text("\(Date(timeIntervalSince1970: Double(r.startWallMs) / 1000).formatted()) · \(r.endReason ?? "open")").font(.caption)
                            if let peer = r.peer {
                                Text("Watch: \(peer.endReason), \(peer.chunkIds.count) chunks").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Record")
            #if DEBUG
            .task { model.runLaunchArguments() }
            #endif
        }
    }
}
