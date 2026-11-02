import SwiftUI

/// Phase 1's watch screen.
struct WatchDiagnosticsView: View {
    @Bindable var probe: WatchProbe

    var body: some View {
        List {
            if probe.recording {
                Button("Stop", role: .destructive) { probe.stop() }
                if let startedAt = probe.startedAt {
                    Text(startedAt, style: .timer).monospacedDigit()
                }
                ForEach(probe.rates, id: \.0) { stream, count, hz in
                    Text("\(stream) \(hz.formatted(.number.precision(.fractionLength(1)))) Hz, \(count)").font(.footnote)
                }
                Text(probe.note).font(.footnote)
            } else {
                Picker("Rate", selection: $probe.hz) {
                    Text("25 Hz").tag(25.0)
                    Text("50 Hz").tag(50.0)
                    Text("100 Hz").tag(100.0)
                }
                Button("Start here") { probe.startManually() }
                Section("Permission, status \(probe.authStatus)") {
                    Button("Try with no permission") { probe.probeWithoutPermission() }
                    Button("Ask for permission") { probe.requestPermission() }
                }
            }
            Section("Log") {
                ForEach(Array(probe.log.enumerated()), id: \.offset) { Text($0.element).font(.footnote) }
            }
            Section("This device") {
                ForEach(probe.api, id: \.0) { Text("\($0.0)=\($0.1)").font(.footnote) }
            }
        }
    }
}
