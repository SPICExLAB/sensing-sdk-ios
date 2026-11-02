import SensingCore
import SensingKit
import SwiftUI

/// What a person changed from the defaults, for one device.
struct SensorChoices: Codable, Equatable {
    /// By sensor id. A sensor that isn't here keeps its default.
    var enabled: [String: Bool] = [:]
    var hz: [String: Int64] = [:]
    /// For what's slower than once a second, like location.
    var seconds: [String: Int64]? = [:]

    var overrides: [SensorID: SensorOverride] {
        var out: [SensorID: SensorOverride] = [:]
        for key in Set(enabled.keys).union(hz.keys).union((seconds ?? [:]).keys) {
            guard let id = SensorID(key) else { continue }
            let period = seconds?[key].map { $0 * 1_000_000 } ?? hz[key].map { 1_000_000 / $0 }
            out[id] = SensorOverride(enabled: enabled[key], samplingPeriodUs: period)
        }
        return out
    }

    mutating func setAllMotion(hz value: Int64) {
        for entry in SensingCatalog.phone where entry.id.value.hasPrefix("motion.") && entry.setting.samplingPeriodUs != nil {
            hz[entry.id.value] = value
        }
    }

    static func load(key: String) -> SensorChoices {
        guard let data = UserDefaults.standard.data(forKey: "sensors.\(key)"), let saved = try? JSONDecoder().decode(SensorChoices.self, from: data) else { return SensorChoices() }
        return saved
    }

    func save(key: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "sensors.\(key)") }
    }
}

struct SensorsView: View {
    @Bindable var model: RecordModel
    @State private var device = 0

    var body: some View {
        NavigationStack {
            List {
                Picker("Device", selection: $device) {
                    Text("iPhone").tag(0)
                    Text("Watch").tag(1)
                }
                .pickerStyle(.segmented)
                if device == 0 {
                    SensorList(catalog: SensingCatalog.phone, choices: $model.phoneChoices)
                } else {
                    SensorList(catalog: SensingCatalog.watch, choices: $model.watchChoices)
                }
                Section {
                    Button("Back to defaults") {
                        if device == 0 { model.phoneChoices = SensorChoices() } else { model.watchChoices = SensorChoices() }
                    }
                } footer: {
                    Text("Changes apply to the next recording.")
                }
            }
            .navigationTitle("Sensors")
            .disabled(model.sensing?.status.recording != nil)
        }
    }
}

private struct SensorList: View {
    let catalog: [CatalogEntry]
    @Binding var choices: SensorChoices

    private static let rates: [Int64] = [10, 25, 50, 100]
    private static let locationSeconds: [Int64] = [1, 5, 10, 30, 60]

    var body: some View {
        ForEach(catalog, id: \.id) { entry in
            let key = entry.id.value
            let on = choices.enabled[key] ?? entry.defaultOn
            VStack(alignment: .leading) {
                Toggle(entry.title, isOn: Binding(get: { on }, set: { choices.enabled[key] = $0 }))
                if key.hasPrefix("motion."), let period = entry.setting.samplingPeriodUs {
                    let standard = 1_000_000 / period
                    // Its default has to be on the list, or the picker shows nothing: the phone's magnetometer defaults to 20 Hz.
                    Picker("Rate", selection: Binding(get: { choices.hz[key] ?? standard }, set: { choices.hz[key] = $0 })) {
                        ForEach(Array(Set(Self.rates + [standard])).sorted(), id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                    .disabled(!on)
                } else if key == SensingCatalog.location.value, let period = entry.setting.samplingPeriodUs {
                    Picker("Every", selection: Binding(get: { choices.seconds?[key] ?? period / 1_000_000 }, set: { value in
                        var seconds = choices.seconds ?? [:]
                        seconds[key] = value
                        choices.seconds = seconds
                    })) {
                        ForEach(Self.locationSeconds, id: \.self) { Text("\($0) s").tag($0) }
                    }
                    .disabled(!on)
                } else if !entry.detail.isEmpty {
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
