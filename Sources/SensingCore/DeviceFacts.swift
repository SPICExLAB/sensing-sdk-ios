import Foundation

public enum SDK {
    public static let version = "0.1.0"
}

public enum DeviceModel {
    /// The hardware id, such as iPhone16,1.
    public static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// UIDevice and WKInterfaceDevice are main-thread only, and the engine must never wait for the main thread. So the main thread
/// refreshes this copy, and the engine's heartbeat reads it.
public final class BatterySnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = -1
    private var charging = false

    public init() {}

    public func store(level: Float, charging: Bool) {
        lock.withLock {
            self.level = level
            self.charging = charging
        }
    }

    public var pct: Int64? {
        let level = lock.withLock { level }
        return level >= 0 ? Int64((level * 100).rounded()) : nil
    }

    public func attributes() -> [String: String] {
        let charging = lock.withLock { charging }
        let info = ProcessInfo.processInfo
        var attrs = ["low_power": info.isLowPowerModeEnabled ? "true" : "false", "thermal_state": String(info.thermalState.rawValue), "is_charging": charging ? "true" : "false"]
        if let pct { attrs["battery_pct"] = String(pct) }
        return attrs
    }
}
