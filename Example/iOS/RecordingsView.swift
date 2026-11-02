import SensingEngine
import SensingKit
import SensingStorage
import SwiftUI
import UIKit

struct RecordingsView: View {
    let model: RecordModel

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                ForEach(model.recordings) { r in
                    HStack {
                        NavigationLink(value: r.id) {
                            VStack(alignment: .leading) {
                                Text(r.label)
                                Text("\(Date(timeIntervalSince1970: Double(r.startWallMs) / 1000).formatted()) · \(Self.duration(r)) · \(r.endReason ?? "running")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ExportButton(model: model, recording: r, title: nil)
                    }
                }
                if let failure = model.exportFailure { Text(failure).font(.caption).foregroundStyle(.red) }
            }
            .overlay {
                if model.recordings.isEmpty { ContentUnavailableView("No recordings yet", systemImage: "waveform.path.ecg") }
            }
            .navigationTitle("Recordings")
            .navigationDestination(for: String.self) { RecordingDetailView(id: $0, model: model) }
            .onAppear { model.reload() }
            #if DEBUG
            .task { await model.runExportArgument() }
            #endif
            .sheet(item: $model.exportFile, onDismiss: model.removeExport) { ShareSheet(url: $0.url) }
        }
    }

    static func duration(_ r: RecordingSummary) -> String {
        guard let end = r.endWallMs else { return "—" }
        return Duration.seconds(Double(end - r.startWallMs) / 1000).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Writes the recording to a zip and opens the share sheet. A recording still running can't be exported yet.
struct ExportButton: View {
    let model: RecordModel
    let recording: RecordingSummary
    /// Nil for just the icon, as in the list.
    let title: String?

    var body: some View {
        let busy = model.exportingId != nil
        Button { model.export(id: recording.id) } label: {
            if model.exportingId == recording.id {
                ProgressView()
            } else if let title {
                Label(title, systemImage: "square.and.arrow.up")
            } else {
                Label("Export \(recording.label)", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderless)  // or a tap anywhere in a list row would press it
        .disabled(busy || recording.endWallMs == nil)
    }
}

struct RecordingDetailView: View {
    let id: String
    let model: RecordModel
    @State private var details: RecordingDetails?
    @State private var failure: String?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let details {
                summary(details)
                let phone = details.streams.filter { $0.deviceId == details.deviceId }
                let watch = details.streams.filter { $0.deviceId != details.deviceId }
                if !phone.isEmpty { streams("iPhone", phone) }
                if !watch.isEmpty { streams("Watch", watch) }
                Section {
                    ExportButton(model: model, recording: details.recording, title: "Export")
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("An export is a zip of the chunks and a manifest. It's someone's data: only share it where it belongs.")
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                if let failure = model.exportFailure { Text(failure).font(.caption).foregroundStyle(.red) }
            } else {
                ProgressView("Reading chunks…")
            }
        }
        .navigationTitle(details?.recording.label ?? "Recording")
        .navigationBarTitleDisplayMode(.inline)
        .task { details = await model.sensing?.details(of: id) }
        .confirmationDialog("Delete this recording from this phone? This can't be undone.", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    private func summary(_ d: RecordingDetails) -> some View {
        Section {
            LabeledContent("Started", value: Date(timeIntervalSince1970: Double(d.recording.startWallMs) / 1000).formatted())
            LabeledContent("Duration", value: RecordingsView.duration(d.recording))
            LabeledContent("Ended", value: d.recording.endReason ?? "running")
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file))
            LabeledContent("Chunks", value: String(d.chunks))
            if let peer = d.recording.peer {
                LabeledContent("Watch ended", value: peer.endReason)
            }
            if !d.missingWatchChunks.isEmpty {
                LabeledContent("Watch chunks still to come", value: String(d.missingWatchChunks.count)).foregroundStyle(.orange)
            }
        }
    }

    private func streams(_ title: String, _ rows: [ChunkInspector.Stream]) -> some View {
        Section(title) {
            ForEach(rows) { row in
                VStack(alignment: .leading) {
                    Text(row.sensorId).font(.caption)
                    Text("\(row.stats.samples) samples · \(row.stats.rateHz.formatted(.number.precision(.fractionLength(2)))) Hz · longest gap \(Int64(row.stats.maxGapMs)) ms · \(row.stats.gaps) gaps · \(row.stats.missingSeq) lost")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func delete() {
        guard let sensing = model.sensing else { return }
        Task {
            do {
                try await sensing.delete(id: id)
                model.reload()
                dismiss()
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
