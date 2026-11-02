import Foundation
import SensingProto

/// `device.battery`, with Android's attribute names. iOS has no temperature, voltage or health to report.
public enum BatteryEvent {
    public enum Charge: Sendable {
        case unknown
        case unplugged
        case charging
        case full
    }

    /// `levelFraction` is what UIDevice and WKInterfaceDevice report: 0 to 1, or negative when unknown.
    public static func attributes(levelFraction: Float, charge: Charge, lowPower: Bool, thermalState: Int64) -> [String: String] {
        var a = ["scale": "100", "health": "unknown", "present": "true", "low_power": lowPower ? "true" : "false", "thermal_state": String(thermalState)]
        if levelFraction >= 0 {
            let level = Int64((levelFraction * 100).rounded())
            a["level"] = String(level)
            a["pct"] = String(level)
        } else {
            a["level"] = "-1"
        }
        switch charge {
        case .unknown:
            a["status"] = "unknown"
            a["plugged"] = "other"
        case .unplugged:
            a["status"] = "discharging"
            a["plugged"] = "none"
        case .charging:
            a["status"] = "charging"
            a["plugged"] = "other"  // iOS doesn't say what it's plugged into
        case .full:
            a["status"] = "full"
            a["plugged"] = "other"
        }
        return a
    }
}

/// `device.network`: the three fields that define a change, as on Android.
public enum NetworkEvent {
    public static let none = attributes(transport: "none", metered: false, validated: false)

    public static func attributes(transport: String, metered: Bool, validated: Bool) -> [String: String] {
        ["transport": transport, "metered": metered ? "true" : "false", "validated": validated ? "true" : "false"]
    }
}

/// `device.audio_level`: loudness in dBFS, one value per window, from PCM that's discarded as soon as its RMS is taken.
public enum AudioLevel {
    public static let floorDbfs: Float = -120

    /// `rms` of samples in -1...1. Below one 16-bit step counts as silence, as on Android, where that's how a muted mic reads.
    public static func dbfs(rms: Double) -> Float {
        let scaled = rms * 32768
        guard scaled >= 1 else { return floorDbfs }
        return max(Float(20 * log10(rms)), floorDbfs)
    }

    /// Adds up buffers until a window is full, keeping only the running totals.
    public struct Window: Sendable {
        private let frames: Int64
        private var count: Int64 = 0
        private var sumSquares: Double = 0

        public init(sampleRate: Double, milliseconds: Int64) {
            frames = max(Int64(sampleRate * Double(milliseconds) / 1000), 1)
        }

        /// Returns the window's level each time one fills.
        public mutating func add(sumSquares squares: Double, count n: Int64) -> Float? {
            sumSquares += squares
            count += n
            guard count >= frames else { return nil }
            let level = AudioLevel.dbfs(rms: (sumSquares / Double(count)).squareRoot())
            sumSquares = 0
            count = 0
            return level
        }
    }
}

/// `device.bluetooth_scan`: one tensor per window, each device once with its last RSSI, named by hash.
public struct BluetoothWindow: Sendable {
    /// Advertised TX power when absent, and CoreBluetooth's RSSI when it has no reading.
    public static let noValue: Int64 = 127

    private let hash: IdentifierHash
    private var seen: [String: (rssi: Int64, txPower: Int64)] = [:]
    private var order: [String] = []

    public init(salt: String) { hash = IdentifierHash(salt: salt) }

    public mutating func record(identifier: String, rssi: Int64, txPower: Int64?) {
        guard rssi != Self.noValue else { return }
        if seen[identifier] == nil { order.append(identifier) }
        seen[identifier] = (rssi, txPower ?? Self.noValue)
    }

    /// The tensor so far, and a clean slate for the next window. An empty scan is `[0, 2]`, which still says a scan ran.
    public mutating func finish() -> Sensorlog_V1_TensorPayload {
        var t = Sensorlog_V1_TensorPayload()
        t.shape = [UInt32(order.count), 2]
        t.values = order.flatMap { [Float(seen[$0]!.rssi), Float(seen[$0]!.txPower)] }
        t.names = order.map { hash.hash($0) }
        seen = [:]
        order = []
        return t
    }
}

/// `loc.fused`. CoreLocation marks a value it doesn't have as negative, and Android's fields say 0.
public enum LocationMapping {
    public struct Fix: Sendable {
        public var latitude: Double
        public var longitude: Double
        public var ellipsoidalAltitude: Double
        public var horizontalAccuracy: Double
        public var verticalAccuracy: Double
        public var speed: Double
        public var speedAccuracy: Double
        public var course: Double
        public var courseAccuracy: Double
        public var simulated: Bool
        public var accessory: Bool

        public init(latitude: Double, longitude: Double, ellipsoidalAltitude: Double, horizontalAccuracy: Double, verticalAccuracy: Double,
                    speed: Double, speedAccuracy: Double, course: Double, courseAccuracy: Double, simulated: Bool = false, accessory: Bool = false) {
            self.latitude = latitude
            self.longitude = longitude
            self.ellipsoidalAltitude = ellipsoidalAltitude
            self.horizontalAccuracy = horizontalAccuracy
            self.verticalAccuracy = verticalAccuracy
            self.speed = speed
            self.speedAccuracy = speedAccuracy
            self.course = course
            self.courseAccuracy = courseAccuracy
            self.simulated = simulated
            self.accessory = accessory
        }
    }

    /// Nil when the fix has no position: a negative horizontal accuracy means the coordinates mean nothing.
    public static func payload(_ f: Fix) -> Sensorlog_V1_LocationPayload? {
        guard f.horizontalAccuracy >= 0 else { return nil }
        var p = Sensorlog_V1_LocationPayload()
        p.lat = f.latitude
        p.lon = f.longitude
        p.alt = f.verticalAccuracy >= 0 ? f.ellipsoidalAltitude : 0
        p.accuracy = Float(f.horizontalAccuracy)
        p.speed = Float(max(f.speed, 0))
        p.bearing = Float(max(f.course, 0))
        p.provider = f.simulated ? "simulated" : f.accessory ? "accessory" : "corelocation"
        p.verticalAccuracy = Float(max(f.verticalAccuracy, 0))
        p.speedAccuracy = Float(max(f.speedAccuracy, 0))
        p.bearingAccuracy = Float(max(f.courseAccuracy, 0))
        return p
    }
}

/// `loc.activity`. Android reports one activity at a time, entering and leaving, so CoreMotion's flags go through this.
public struct ActivityTransitions: Sendable {
    public struct Flags: Sendable {
        public var stationary = false
        public var walking = false
        public var running = false
        public var cycling = false
        public var automotive = false

        public init(stationary: Bool = false, walking: Bool = false, running: Bool = false, cycling: Bool = false, automotive: Bool = false) {
            self.stationary = stationary
            self.walking = walking
            self.running = running
            self.cycling = cycling
            self.automotive = automotive
        }

        /// CoreMotion can set several at once, such as automotive and stationary at a red light. The most specific wins.
        var activity: String? {
            if automotive { return "in_vehicle" }
            if cycling { return "on_bicycle" }
            if running { return "running" }
            if walking { return "walking" }
            if stationary { return "still" }
            return nil
        }
    }

    private var current: String?

    public init() {}

    /// The transitions this update causes: leaving the old activity, then entering the new. No flags means CoreMotion doesn't
    /// know, which says nothing about what's going on, so the current activity stands.
    public mutating func observe(_ flags: Flags) -> [(activity: String, transition: String)] {
        guard let next = flags.activity, next != current else { return [] }
        var out: [(String, String)] = []
        if let current { out.append((current, "exit")) }
        out.append((next, "enter"))
        current = next
        return out
    }
}

/// The fixed list of services a background Bluetooth scan names, since iOS won't scan for everything when the app isn't open
/// (`CBCentralManager.h`). These are the Bluetooth SIG's common ones.
public enum BluetoothServices {
    public static let common = ["1800", "1801", "180A", "180D", "180F", "1802", "1803", "1804", "1805", "1806", "1807", "1808", "1809", "180E", "1810", "1811", "1812", "1813", "1814", "1816",
                                "1818", "1819", "181A", "181B", "181C", "181D", "181E", "181F", "1820", "1822", "1826", "FEAA", "FE9F", "FD6F"]
}

extension SensingCatalog {
    public static let location = SensorID(known: "loc.fused")
    public static let activity = SensorID(known: "loc.activity")
    public static let battery = SensorID(known: "device.battery")
    public static let screen = SensorID(known: "device.screen")
    public static let network = SensorID(known: "device.network")
    public static let audioLevel = SensorID(known: "device.audio_level")
    public static let bluetooth = SensorID(known: "device.bluetooth_scan")

    static func deviceEntries(watch: Bool) -> [CatalogEntry] {
        var entries = [
            CatalogEntry(id: location, title: "Location", detail: "", setting: SensorSetting(samplingPeriodUs: 30_000_000), defaultOn: !watch),
            CatalogEntry(id: activity, title: "Activity", detail: "on each change", setting: SensorSetting(), defaultOn: !watch),
            CatalogEntry(id: battery, title: "Battery", detail: "on each change", setting: SensorSetting(), defaultOn: true),
            CatalogEntry(id: screen, title: "Screen", detail: "on each change", setting: SensorSetting(), defaultOn: true),
            CatalogEntry(id: network, title: "Network", detail: "on each change", setting: SensorSetting(), defaultOn: true),
            // Off by default (S-008): they change how the device behaves. The mic shows its indicator.
            CatalogEntry(id: audioLevel, title: "Sound level", detail: "loudness only; no audio is kept", setting: SensorSetting(samplingPeriodUs: 1_000_000), defaultOn: false),
        ]
        if !watch {
            entries.append(CatalogEntry(id: bluetooth, title: "Bluetooth", detail: "a scan every 5 min", setting: SensorSetting(samplingPeriodUs: 300_000_000, extras: ["windowMs": "10000"]), defaultOn: false))
        }
        return entries
    }
}
