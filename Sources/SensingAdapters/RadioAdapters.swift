#if os(iOS)
@preconcurrency import CoreTelephony
import Foundation
import Network
@preconcurrency import NetworkExtension
import SensingCore
import SensingProto

/// `device.cellular`: the data SIM's radio type, and whether this app may use cellular data. It's all iOS offers.
public final class CellularAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.cellular]

    private let info = CTTelephonyNetworkInfo()
    private let data = CTCellularData()
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var last: [String: String]?

    public init() {}

    public func availability(of sensor: SensorID) -> Availability { .available }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.cellular] else { return }
        lock.withLock {
            self.sink = sink
            self.clock = clock
            last = nil
        }
        report()
        let added = NotificationCenter.default.addObserver(forName: .CTServiceRadioAccessTechnologyDidChange, object: nil, queue: nil) { [weak self] _ in self?.report() }
        lock.withLock { observer = added }
        data.cellularDataRestrictionDidUpdateNotifier = { [weak self] _ in self?.report() }
    }

    public func stop() {
        data.cellularDataRestrictionDidUpdateNotifier = nil
        let added = lock.withLock { () -> NSObjectProtocol? in
            defer {
                observer = nil
                sink = nil
                clock = nil
            }
            return observer
        }
        if let added { NotificationCenter.default.removeObserver(added) }
    }

    private func report() {
        let technologies = info.serviceCurrentRadioAccessTechnology ?? [:]
        let current = info.dataServiceIdentifier.flatMap { technologies[$0] } ?? technologies.values.first
        let restriction: CellularEvent.DataRestriction = switch data.restrictedState {
        case .restricted: .restricted
        case .notRestricted: .notRestricted
        default: .unknown
        }
        let attrs = CellularEvent.attributes(technology: current, services: Int64(technologies.count), restriction: restriction)
        lock.withLock {
            guard let sink, let clock, attrs != last else { return }
            last = attrs
            sink.event("cellular", attrs, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
        }
    }
}

/// `device.wifi`: the joined network, hashed. A roam to another access point has no notification, so it's also polled.
public final class WifiConnectionAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.wifi]

    private let hash: IdentifierHash
    private let queue = DispatchQueue(label: "sensing.wifi", qos: .utility)
    // All touched only on `queue`.
    private var monitor: NWPathMonitor?
    private var timer: DispatchSourceTimer?
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var onWifi = false
    private var last: String?

    public init(salt: String) { hash = IdentifierHash(salt: salt) }

    public func availability(of sensor: SensorID) -> Availability { .available }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.wifi] else { return }
        let periodMs = (settings[SensingCatalog.wifi]?.samplingPeriodUs ?? 30_000_000) / 1000
        queue.async { [self] in
            self.sink = sink
            self.clock = clock
            last = nil
            let m = NWPathMonitor(requiredInterfaceType: .wifi)
            m.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.onWifi = path.status == .satisfied
                self.check()
            }
            monitor = m
            m.start(queue: queue)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(Int(periodMs)), repeating: .milliseconds(Int(periodMs)))  // int-ok
            t.setEventHandler { [weak self] in self?.check() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            monitor?.cancel()
            monitor = nil
            sink = nil
            clock = nil
        }
    }

    private func check() {
        guard onWifi else {
            report(WifiConnectionEvent.disconnected, [:])
            return
        }
        let hash = hash
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let attrs: [String: String]
            if let network {
                let security: WifiConnectionEvent.Security = switch network.securityType {
                case .open: .open
                case .WEP: .wep
                case .personal: .personal
                case .enterprise: .enterprise
                default: .unknown
                }
                attrs = WifiConnectionEvent.attributes(ssid: network.ssid, bssid: network.bssid, security: security, hash: hash)
            } else {
                attrs = WifiConnectionEvent.identityUnavailable
            }
            self?.queue.async { self?.report(WifiConnectionEvent.connected, attrs) }
        }
    }

    private func report(_ kind: String, _ attrs: [String: String]) {
        guard let sink, let clock else { return }
        let key = "\(kind)|\(attrs.sorted { $0.key < $1.key })"
        guard key != last else { return }
        last = key
        sink.event(kind, attrs, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
    }
}

/// `device.network_rtt`: every few minutes, one TCP connect to a known host, timed by the system, and closed with nothing sent.
/// Phone only: watchOS restricts low-level networking.
public final class NetworkLatencyAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.networkRtt]
    private static let timeoutSeconds = 10

    private let queue = DispatchQueue(label: "sensing.network_rtt", qos: .utility)
    // All touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var current: NWConnection?
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var host = SensingCatalog.probeHost
    private var port: UInt16 = 80

    public init() {}

    public func availability(of sensor: SensorID) -> Availability { .available }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.networkRtt] else { return }
        let setting = settings[SensingCatalog.networkRtt]
        let periodMs = (setting?.samplingPeriodUs ?? 300_000_000) / 1000
        queue.async { [self] in
            self.sink = sink
            self.clock = clock
            host = setting?.extras["host"] ?? SensingCatalog.probeHost
            port = setting?.extras["port"].flatMap(UInt16.init) ?? 80
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(Int(periodMs)))  // int-ok
            t.setEventHandler { [weak self] in self?.probe() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            current?.cancel()
            current = nil
            sink = nil
            clock = nil
        }
    }

    private func probe() {
        guard current == nil, let clock, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        current = connection
        let started = clock.monoNs()
        let wall = clock.wallMs()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.current === connection else { return }
            switch state {
            case .ready:
                self.measure(connection, startedMono: started, startedWall: wall)
            case .failed(let error), .waiting(let error):
                self.fail(connection, reason: String(describing: error), startedMono: started, startedWall: wall)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(Self.timeoutSeconds)) { [weak self, weak connection] in
            guard let self, let connection, self.current === connection, connection.state != .ready else { return }
            self.fail(connection, reason: "timeout", startedMono: started, startedWall: wall)
        }
    }

    private func measure(_ connection: NWConnection, startedMono: Int64, startedWall: Int64) {
        let transport = Self.transport(of: connection.currentPath)
        let elapsedMs = Double((clock?.monoNs() ?? startedMono) - startedMono) / 1e6
        let pending = connection.startDataTransferReport()
        connection.requestEstablishmentReport(queue: queue) { [weak self] establishment in
            // The first handshake is TCP's own, the same thing Android times, so the two can be compared.
            let handshake = establishment?.handshakes.first.map { $0.handshakeRTT * 1000 }
            pending.collect(queue: self?.queue ?? .global()) { [weak self] transfer in
                guard let self else { return }
                let path = transfer.pathReports.first ?? transfer.aggregatePathReport
                self.emit(NetworkProbeEvent.attributes(ok: true, transport: transport, connectMs: handshake ?? elapsedMs, smoothedMs: path.transportSmoothedRTT * 1000,
                                                       minMs: path.transportMinimumRTT * 1000, varianceMs: path.transportRTTVariance * 1000,
                                                       radio: path.radioType.map(RadioNames.name(of:)), host: self.host),
                          startedMono: startedMono, startedWall: startedWall)
                connection.cancel()
                if self.current === connection { self.current = nil }
            }
        }
    }

    private func fail(_ connection: NWConnection, reason: String, startedMono: Int64, startedWall: Int64) {
        emit(NetworkProbeEvent.attributes(ok: false, transport: Self.transport(of: connection.currentPath), connectMs: nil, host: host, reason: reason), startedMono: startedMono, startedWall: startedWall)
        connection.cancel()
        current = nil
    }

    private func emit(_ attrs: [String: String], startedMono: Int64, startedWall: Int64) {
        sink?.event("probe", attrs, tsMonoNs: startedMono, tsWallMs: startedWall)
    }

    private static func transport(of path: NWPath?) -> String {
        guard let path else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
        return path.status == .satisfied ? "other" : "none"
    }
}
#endif
