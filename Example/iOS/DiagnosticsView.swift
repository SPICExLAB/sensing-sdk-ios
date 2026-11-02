import SensingKit
import SensingStorage
import SwiftUI

/// Storage, and Phase 1's screen: pick how the app stays alive, record with the phone locked with no SDK in the way, and see what
/// kept running.
struct DiagnosticsView: View {
    @Bindable var probe: PhoneProbe
    let model: RecordModel
    @State private var storage: ChunkStore.Status?
    @State private var orphans: Int64 = 0

    var body: some View {
        NavigationStack {
            List {
                if let facts = model.sensing?.status.linkFacts, !facts.isEmpty {
                    Section("Watch link") { Text(facts).font(.caption) }
                }
                Section("Storage") {
                    if let storage {
                        LabeledContent("Used", value: ByteCountFormatter.string(fromByteCount: storage.bytesOnDisk, countStyle: .file))
                        LabeledContent("Quota", value: ByteCountFormatter.string(fromByteCount: storage.quotaBytes, countStyle: .file))
                        LabeledContent("Free on this phone", value: ByteCountFormatter.string(fromByteCount: storage.freeBytes, countStyle: .file))
                    }
                    if orphans > 0 {
                        Button("Delete \(orphans) chunks no recording claims", role: .destructive) {
                            Task {
                                await model.sensing?.deleteOrphanChunks()
                                await refreshStorage()
                            }
                        }
                    }
                }
                Section("Record") {
                    Picker("Keep-alive", selection: $probe.mode) {
                        ForEach(KeepAliveMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(probe.recording)
                    Picker("Phone rate", selection: $probe.hz) {
                        Text("25 Hz").tag(25.0)
                        Text("50 Hz").tag(50.0)
                        Text("100 Hz").tag(100.0)
                    }
                    .disabled(probe.recording)
                    if probe.recording {
                        Button("Stop", role: .destructive) { probe.stop() }
                        if let startedAt = probe.startedAt {
                            Text(startedAt, style: .timer).monospacedDigit()
                        }
                    } else {
                        Button("Start") { probe.start() }
                    }
                    Button("Ask for permissions") { probe.requestPermissions() }.disabled(probe.recording)
                }
                if probe.recording {
                    Section("Live") {
                        ForEach(probe.rates, id: \.0) { stream, count, hz in
                            LabeledContent("\(stream): \(count)", value: "\(hz.formatted(.number.precision(.fractionLength(1)))) Hz")
                        }
                        Text(probe.note).font(.caption)
                    }
                }
                Section("Log") {
                    ForEach(Array(probe.log.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                }
                Section("Runs") {
                    ForEach(probe.runs, id: \.self) { run in
                        let files = (try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []
                        ShareLink(items: files) { Text(run.lastPathComponent).font(.caption) }
                            .swipeActions { Button("Delete", role: .destructive) { probe.delete(run) } }
                    }
                }
                Section("This device") {
                    ForEach(probe.api, id: \.0) { LabeledContent($0.0, value: $0.1).font(.caption) }
                }
            }
            .navigationTitle("Sensing diagnostics")
            .task { await refreshStorage() }
        }
    }

    private func refreshStorage() async {
        storage = await model.sensing?.storageStatus()
        orphans = Int64(await model.sensing?.orphanChunks().count ?? 0)
    }
}
