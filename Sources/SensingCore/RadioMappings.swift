import Foundation
#if canImport(Network)
import Network
#endif

/// POSIX formatting for numbers in attributes, whatever the phone's locale.
public enum AttributeNumber {
    public static func format(_ value: Double, places: Int64) -> String {
        String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// `device.cellular`. iOS gives the radio type and little else: no signal strength, cell ids or neighbours, and the carrier's
/// name is deprecated. The SIM's service id is never recorded.
public enum CellularEvent {
    public enum DataRestriction: String, Sendable {
        case unknown
        case restricted
        case notRestricted = "not_restricted"
    }

    /// CoreTelephony's `CTRadioAccessTechnology…` constants are these strings. The names are shared with Android.
    public static func radioName(_ technology: String?) -> String {
        guard let technology else { return "none" }
        switch technology.replacingOccurrences(of: "CTRadioAccessTechnology", with: "") {
        case "NR": return "nr"
        case "NRNSA": return "nr_nsa"
        case "LTE": return "lte"
        case "WCDMA": return "wcdma"
        case "HSDPA": return "hsdpa"
        case "HSUPA": return "hsupa"
        case "Edge": return "edge"
        case "GPRS": return "gprs"
        case "CDMA1x": return "cdma"
        case "CDMAEVDORev0", "CDMAEVDORevA", "CDMAEVDORevB": return "evdo"
        case "eHRPD": return "ehrpd"
        default: return "unknown"
        }
    }

    /// `technology` is the data SIM's. `services` is how many have a radio, so that dual SIM shows without naming either.
    public static func attributes(technology: String?, services: Int64, restriction: DataRestriction) -> [String: String] {
        ["radio": radioName(technology), "services": String(services), "data_restricted": restriction.rawValue]
    }
}

/// `device.wifi`: the joined network. Names and addresses are hashed here, before they can reach a sample.
public enum WifiConnectionEvent {
    public enum Security: String, Sendable {
        case open
        case wep
        case personal
        case enterprise
        case unknown
    }

    public static let disconnected = "disconnected"
    public static let connected = "connected"

    public static func attributes(ssid: String, bssid: String, security: Security, hash: IdentifierHash) -> [String: String] {
        ["ssid_hash": hash.hash(ssid), "bssid_hash": hash.hash(bssid), "security": security.rawValue]
    }

    /// On Wi-Fi, but iOS won't say which network: no entitlement, or no precise location. It isn't the same as being off Wi-Fi.
    public static let identityUnavailable = ["identity": "unavailable"]
}

/// `device.network_rtt`: one TCP connect to a known host. A reading of 0 means the system took no sample, so it's left out.
public enum NetworkProbeEvent {
    public static func attributes(ok: Bool, transport: String, connectMs: Double?, smoothedMs: Double? = nil, minMs: Double? = nil, varianceMs: Double? = nil,
                                  radio: String? = nil, host: String, reason: String? = nil) -> [String: String] {
        var a = ["ok": ok ? "true" : "false", "transport": transport, "host": host]
        func put(_ key: String, _ value: Double?) {
            if let value, value > 0 { a[key] = AttributeNumber.format(value, places: 1) }
        }
        put("connect_ms", connectMs)
        put("smoothed_ms", smoothedMs)
        put("min_ms", minMs)
        put("variance_ms", varianceMs)
        if let radio { a["radio"] = radio }
        if let reason { a["reason"] = reason }
        return a
    }
}

#if canImport(Network)
public enum RadioNames {
    /// What Network.framework says carried a connection. It can tell 5G sub-6 from mmWave, which CoreTelephony can't.
    public static func name(of radio: NWInterface.RadioType) -> String {
        switch radio {
        case .wifi(let wifi):
            switch wifi {
            case .a: return "wifi_a"
            case .b: return "wifi_b"
            case .g: return "wifi_g"
            case .n: return "wifi_n"
            case .ac: return "wifi_ac"
            case .ax: return "wifi_ax"
            @unknown default: return "wifi_unknown"
            }
        case .cell(let cell):
            switch cell {
            case .lte: return "lte"
            case .dualConnectivity5G(let band): return "nr_nsa_\(name(of: band))"
            case .standalone5G(let band): return "nr_\(name(of: band))"
            case .wcdma: return "wcdma"
            case .gsm: return "gsm"
            case .cdma: return "cdma"
            case .evdo: return "evdo"
            @unknown default: return "cell_unknown"
            }
        @unknown default:
            return "unknown"
        }
    }

    private static func name(of band: NWInterface.RadioType.Cellular.NewRadio5GVariant) -> String {
        switch band {
        case .sub6GHz: return "sub6"
        case .mmWave: return "mmw"
        @unknown default: return "unknown"
        }
    }
}
#endif

/// `loc.fused`'s `state` event: what a fix's numbers can't say. Reduced accuracy means someone turned off Precise Location.
public enum LocationStateEvent {
    public static func attributes(fullAccuracy: Bool, floor: Int64?) -> [String: String] {
        var a = ["accuracy": fullAccuracy ? "full" : "reduced"]
        if let floor { a["floor"] = String(floor) }
        return a
    }
}

/// `loc.heading`. CoreLocation marks a heading it doesn't have as negative, and those are left out.
public enum HeadingEvent {
    public static func attributes(magnetic: Double, trueHeading: Double, accuracy: Double, x: Double, y: Double, z: Double) -> [String: String] {
        var a = ["x": AttributeNumber.format(x, places: 2), "y": AttributeNumber.format(y, places: 2), "z": AttributeNumber.format(z, places: 2)]
        if accuracy >= 0 {
            a["accuracy"] = AttributeNumber.format(accuracy, places: 1)
            a["magnetic"] = AttributeNumber.format(magnetic, places: 1)
        }
        if trueHeading >= 0 { a["true"] = AttributeNumber.format(trueHeading, places: 1) }
        return a
    }
}

/// Carries UWB discovery tokens between the adapter and whatever link the app has, so the adapter knows nothing about the link.
public final class PeerTokenRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var outgoing: (@Sendable (Data) -> Void)?
    private var incoming: (@Sendable (Data) -> Void)?

    public init() {}

    /// The link sets this: how a token leaves.
    public func onSend(_ send: @escaping @Sendable (Data) -> Void) { lock.withLock { outgoing = send } }
    /// The adapter sets this while it runs: where a peer's token goes.
    public func onReceive(_ receive: (@Sendable (Data) -> Void)?) { lock.withLock { incoming = receive } }

    public func send(_ token: Data) { lock.withLock { outgoing }?(token) }
    public func receive(_ token: Data) { lock.withLock { incoming }?(token) }
}

extension SensingCatalog {
    public static let cellular = SensorID(known: "device.cellular")
    public static let wifi = SensorID(known: "device.wifi")
    public static let networkRtt = SensorID(known: "device.network_rtt")
    public static let heading = SensorID(known: "loc.heading")
    public static let peerDistance = SensorID(known: "device.peer_distance")

    /// The default target of `device.network_rtt`, the host iOS itself uses to test connectivity.
    public static let probeHost = "captive.apple.com"

    static func radioEntries(watch: Bool) -> [CatalogEntry] {
        var entries = [
            CatalogEntry(id: heading, title: "Compass heading", detail: "once a second", setting: .hz(1), defaultOn: false),
            CatalogEntry(id: peerDistance, title: watch ? "UWB distance to the phone" : "UWB distance to the watch", detail: "may stop when the phone is locked", setting: .hz(1), defaultOn: false),
        ]
        if !watch {
            entries += [
                CatalogEntry(id: cellular, title: "Cellular", detail: "radio type, on each change. iOS gives no signal strength", setting: SensorSetting(), defaultOn: true),
                CatalogEntry(id: wifi, title: "Wi-Fi network", detail: "the joined network, hashed. iOS gives no signal strength or scans", setting: SensorSetting(samplingPeriodUs: 30_000_000), defaultOn: true),
                // Off by default: it's the one sensor that contacts anything outside the device.
                CatalogEntry(id: networkRtt, title: "Network latency", detail: "connects to \(probeHost) every 5 min", setting: SensorSetting(samplingPeriodUs: 300_000_000, extras: ["host": probeHost, "port": "80"]), defaultOn: false),
            ]
        }
        return entries
    }
}
