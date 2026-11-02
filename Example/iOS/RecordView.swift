import SensingCore
import SensingEngine
import SensingKit
import SwiftUI
import UIKit

/// The app's one piece of shared state: the SDK, what the person chose, and what the screens show.
@MainActor
@Observable
final class RecordModel {
    private(set) var sensing: Sensing?
    private(set) var message = "" {
        didSet {
            #if DEBUG
            print("record: \(message)")
            #endif
        }
    }
    private(set) var recordings: [RecordingSummary] = []
    var activity: TaxonomyNode?
    let taxonomy = Taxonomy.load()
    /// Motion rates in Hz, and which sensors are on, for each device. Saved between launches.
    var phoneChoices = SensorChoices.load(key: "phone")
    var watchChoices = SensorChoices.load(key: "watch")

    init() {
        do {
            var options = Sensing.Options()
            options.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            #if DEBUG
            // A14: `devicectl device process launch … -debugQuotaMiB 16 -deleteOldest YES`
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: "debugQuotaMiB") > 0 { options.quotaBytes = Int64(defaults.integer(forKey: "debugQuotaMiB")) * 1024 * 1024 }
            if defaults.bool(forKey: "deleteOldest") { options.retentionMode = .evictOldest }
            #endif
            let s = try Sensing(options: options)
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
        guard let sensing, let activity else { return }
        phoneChoices.save(key: "phone")
        watchChoices.save(key: "watch")
        sensing.overrides = phoneChoices.overrides
        sensing.watchOverrides = watchChoices.overrides
        Task {
            do {
                try await sensing.start(Self.spec(activity: activity, taxonomyVersion: taxonomy.version))
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

    func discard() {
        guard let sensing else { return }
        Task {
            await sensing.discard()
            message = "Discarded: its label is gone. The sensor data is kept."
            reload()
        }
    }

    func reload() { recordings = sensing?.recordings() ?? [] }

    /// The same attributes as the lab app's activities (`Activities.kt`), so that a recording here projects the same way.
    static func spec(activity: TaxonomyNode, taxonomyVersion: Int64) -> RecordingSpec {
        RecordingSpec(label: activity.name,
                      startAttrs: ["config_id": "free/\(activity.id)", "config_version": "1", "module": "free", "taxonomy_version": String(taxonomyVersion)],
                      labelAttrs: ["label_id": UUID().uuidString.lowercased(), "kind": "interval", "taxonomy_id": activity.id,
                                   "taxonomy_version": String(taxonomyVersion), "source": "tap", "confidence": "1"])
    }

    #if DEBUG
    /// `devicectl device process launch … -- -recordAutostart YES -recordSeconds 60 -recordHz 100 -recordWatch NO`
    func runLaunchArguments() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "recordAutostart") else { return }
        let hz = Int64(defaults.integer(forKey: "recordHz"))
        if hz > 0 { phoneChoices.setAllMotion(hz: hz) }
        if defaults.object(forKey: "recordWatch") != nil { sensing?.recordWatch = defaults.bool(forKey: "recordWatch") }
        activity = activity ?? taxonomy.nodes.first { $0.id == "locomotion/walking" } ?? taxonomy.nodes.first
        let seconds = max(defaults.double(forKey: "recordSeconds"), 3)
        Task {
            // This runs before the scene is active, and keep-alive can only begin in the foreground.
            while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(100)) }
            start()
            Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { print("record: link \(self?.sensing?.status.linkFacts ?? "")") }
            }
            Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }
    #endif
}

struct RecordView: View {
    let model: RecordModel
    @State private var picking = false
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            List {
                if let sensing = model.sensing {
                    controls(sensing)
                    let status = sensing.status
                    if status.recording != nil { live(status) }
                    if status.watchInstalled { watch(status) }
                }
                if !model.message.isEmpty { Section { Text(model.message).font(.caption) } }
            }
            .navigationTitle("Record")
            .sheet(isPresented: $picking) {
                TaxonomyPicker(taxonomy: model.taxonomy) { node in
                    model.activity = node
                    picking = false
                }
            }
            #if DEBUG
            .task { model.runLaunchArguments() }
            #endif
        }
    }

    @ViewBuilder
    private func controls(_ sensing: Sensing) -> some View {
        Section {
            if let recording = sensing.status.recording {
                LabeledContent("Activity", value: recording.label)
                Text(Date(timeIntervalSince1970: Double(recording.startWallMs) / 1000), style: .timer).monospacedDigit().font(.largeTitle)
                Button("Stop", role: .destructive) { model.stop() }
                Button("Started by mistake: discard") { confirmingDiscard = true }
                    .confirmationDialog("Discard this recording's label? The sensor data stays.", isPresented: $confirmingDiscard) {
                        Button("Discard", role: .destructive) { model.discard() }
                    }
            } else {
                Button { picking = true } label: {
                    LabeledContent("Activity", value: model.activity?.name ?? "Choose")
                }
                if sensing.status.watchInstalled {
                    Toggle("Also record on the watch", isOn: Binding(get: { sensing.recordWatch }, set: { sensing.recordWatch = $0 }))
                }
                Button("Start") { model.start() }.disabled(model.activity == nil)
            }
            ForEach(sensing.status.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
        }
    }

    private func live(_ status: Sensing.Status) -> some View {
        Section("This phone") {
            ForEach(status.streams.keys.sorted().filter(Self.isData), id: \.self) { name in
                let s = status.streams[name]!
                LabeledContent(name, value: "\(s.hz.formatted(.number.precision(.fractionLength(1)))) Hz · \(s.count)").font(.caption)
            }
            LabeledContent("Waiting / dropped", value: "\(status.pending) / \(status.dropped)").font(.caption)
        }
    }

    private func watch(_ status: Sensing.Status) -> some View {
        Section("Watch") {
            LabeledContent("Link", value: status.peer.reachable ? "Reachable" : "Not reachable").font(.caption)
            LabeledContent("Chunks received", value: String(status.peer.received)).font(.caption)
            if status.peer.refused > 0 { LabeledContent("Chunks refused", value: String(status.peer.refused)).font(.caption).foregroundStyle(.red) }
            if let peer = status.peer.status, peer.recordingId != nil, status.recording != nil {
                ForEach(peer.hz.keys.sorted().filter(Self.isData), id: \.self) { name in
                    LabeledContent(name, value: "\(peer.hz[name]!.formatted(.number.precision(.fractionLength(1)))) Hz").font(.caption)
                }
                LabeledContent("Waiting to send / dropped", value: "\(peer.chunksWaiting) / \(peer.dropped)").font(.caption)
                if let pct = peer.batteryPct { LabeledContent("Battery", value: "\(pct)%").font(.caption) }
            }
        }
    }

    private static func isData(_ name: String) -> Bool { name.hasPrefix("motion.") || name.hasPrefix("env.") || name.hasPrefix("loc.") || name == "device.audio_level" }
}

struct TaxonomyPicker: View {
    let taxonomy: Taxonomy
    let chosen: (TaxonomyNode) -> Void
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(taxonomy.roots(matching: search), id: \.root) { group in
                    Section(group.root) {
                        ForEach(group.nodes) { node in
                            Button { chosen(node) } label: {
                                VStack(alignment: .leading) {
                                    Text(node.name)
                                    Text(node.id).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
