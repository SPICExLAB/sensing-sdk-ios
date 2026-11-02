import Foundation

/// How one sensor should run. A nil period means it's event-driven or delivers at its own rate.
public struct SensorSetting: Sendable, Equatable, Codable {
    public var samplingPeriodUs: Int64?
    public var extras: [String: String]

    public init(samplingPeriodUs: Int64? = nil, extras: [String: String] = [:]) {
        self.samplingPeriodUs = samplingPeriodUs
        self.extras = extras
    }

    public static func hz(_ hz: Int64) -> SensorSetting { SensorSetting(samplingPeriodUs: 1_000_000 / hz) }
}

public enum Availability: Sendable, Equatable {
    case available
    case missingHardware
    case missingPermission([String])

    /// `device.health adapter_unavailable`'s `reason`, the same words as Android's.
    public var reason: String {
        switch self {
        case .available: "available"
        case .missingHardware: "missing_hardware"
        case let .missingPermission(names): "missing_permission:" + names.joined(separator: ",")
        }
    }
}

/// One source of samples. It can feed several streams: device motion alone supplies the gyroscope, gravity, linear
/// acceleration, rotation and magnetometer.
///
/// Rules, as on Android: one sample per event, never touch the disk or the network, and never block the callback. Adding a
/// sensor means one adapter and one catalog entry.
public protocol SensorAdapter: AnyObject, Sendable {
    /// Every stream this can produce.
    var sensors: [SensorID] { get }
    func availability(of sensor: SensorID) -> Availability
    /// Starts the given streams. Throwing is recorded, and the engine retries with backoff.
    func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws
    /// Stops delivery. A late sample after this is ignored.
    func stop()
}

/// One sensor this build can run.
public struct CatalogEntry: Sendable, Equatable {
    public var id: SensorID
    public var title: String
    /// How the rate reads when it has no period, e.g. "on each step".
    public var detail: String
    public var setting: SensorSetting
    public var defaultOn: Bool

    public init(id: SensorID, title: String, detail: String, setting: SensorSetting, defaultOn: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.setting = setting
        self.defaultOn = defaultOn
    }
}

/// A change to one sensor's catalog defaults. Nil fields keep them.
public struct SensorOverride: Sendable, Equatable, Codable {
    public var enabled: Bool?
    public var samplingPeriodUs: Int64?
    public var extras: [String: String]?

    public init(enabled: Bool? = nil, samplingPeriodUs: Int64? = nil, extras: [String: String]? = nil) {
        self.enabled = enabled
        self.samplingPeriodUs = samplingPeriodUs
        self.extras = extras
    }

    func apply(to base: SensorSetting) -> SensorSetting {
        SensorSetting(samplingPeriodUs: samplingPeriodUs ?? base.samplingPeriodUs, extras: extras.map { base.extras.merging($0) { _, new in new } } ?? base.extras)
    }
}

/// Which sensors run and how: the catalog, then the app's choices, then a running activity session.
public struct CollectionConfig: Sendable, Equatable {
    public var sensors: [SensorID: SensorSetting]

    public init(sensors: [SensorID: SensorSetting]) { self.sensors = sensors }

    /// The same config restricted to what the predicate admits, used to apply permissions.
    public func filter(_ allowed: (SensorID) -> Bool) -> CollectionConfig {
        CollectionConfig(sensors: sensors.filter { allowed($0.key) })
    }

    /// An override can switch a catalog sensor on or off and replace its rate. A sensor it doesn't mention keeps its
    /// default, and a sensor the catalog lacks can't be switched on. A session only adds: every sensor it lists runs, at
    /// least as fast as it would without the session.
    public static func resolve(catalog: [CatalogEntry], overrides: [SensorID: SensorOverride] = [:], session: [SensorID: SensorOverride] = [:]) -> CollectionConfig {
        var out: [SensorID: SensorSetting] = [:]
        for entry in catalog where (overrides[entry.id]?.enabled ?? entry.defaultOn) || session[entry.id] != nil {
            let base = overrides[entry.id]?.apply(to: entry.setting) ?? entry.setting
            out[entry.id] = session[entry.id].map { faster(base, $0) } ?? base
        }
        return CollectionConfig(sensors: out)
    }

    /// `base` sped up by `o`: the shorter period wins, and extras merge with `o`'s on top. An event-driven sensor stays one.
    public static func faster(_ base: SensorSetting, _ o: SensorOverride) -> SensorSetting {
        var period = base.samplingPeriodUs
        if let b = base.samplingPeriodUs, let n = o.samplingPeriodUs { period = min(b, n) }
        return SensorSetting(samplingPeriodUs: period, extras: o.extras.map { base.extras.merging($0) { _, new in new } } ?? base.extras)
    }

    /// "50 Hz", "every 5 min", or the catalog's words for an event-driven sensor. POSIX, so it reads the same everywhere.
    public static func rateLabel(_ setting: SensorSetting, detail: String) -> String {
        guard let p = setting.samplingPeriodUs else { return detail }
        if p >= 60_000_000 { return "every \(p / 60_000_000) min" }
        if p >= 1_000_000 { return "every \(p / 1_000_000) s" }
        return "\((1_000_000 + p / 2) / p) Hz"
    }
}
