#if os(iOS)
@preconcurrency import CoreBluetooth
import Foundation
import SensingCore
import SensingProto
import UIKit

/// `device.bluetooth_scan`: a scan window every 5 minutes, written as one tensor of [RSSI, TX power] named by hashed identifier.
///
/// With the app open it scans for everything, and locked it can only name a fixed list of services, so it sees fewer devices.
/// A `scan_mode` event says which. The identifier is a UUID this phone made up for that device, not a MAC address. It's hashed
/// all the same, and the raw one never leaves this file. Phone only in v1.
public final class BluetoothAdapter: NSObject, SensorAdapter, CBCentralManagerDelegate, @unchecked Sendable {
    public let sensors = [SensingCatalog.bluetooth]

    private let salt: String
    private let queue = DispatchQueue(label: "sensing.bluetooth", qos: .utility)
    // All of this is touched only on `queue`, apart from `foreground`.
    private var central: CBCentralManager?
    private var timer: DispatchSourceTimer?
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var window: BluetoothWindow
    private var windowMs: Int64 = 10_000
    private var periodMs: Int64 = 300_000
    private var scanning = false
    private var scanStartMono: Int64 = 0
    private var scanStartWall: Int64 = 0
    private var lastOff: Bool?
    private var lastMode: String?
    private var observers: [NSObjectProtocol] = []
    private let foregroundLock = NSLock()
    private var foreground = false

    public init(salt: String) {
        self.salt = salt
        window = BluetoothWindow(salt: salt)
    }

    public func availability(of sensor: SensorID) -> Availability {
        switch CBCentralManager.authorization {
        case .allowedAlways: .available
        case .denied, .restricted, .notDetermined: .missingPermission(["bluetooth"])
        @unknown default: .missingPermission(["bluetooth"])
        }
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.bluetooth] else { return }
        let setting = settings[SensingCatalog.bluetooth]
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                setForeground(UIApplication.shared.applicationState != .background)
                let center = NotificationCenter.default
                observers = [
                    center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in self?.setForeground(true) },
                    center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.setForeground(false) },
                ]
            }
        }
        queue.async { [self] in
            self.sink = sink
            self.clock = clock
            window = BluetoothWindow(salt: salt)
            lastOff = nil
            lastMode = nil
            periodMs = (setting?.samplingPeriodUs ?? 300_000_000) / 1000
            windowMs = setting?.extras["windowMs"].flatMap(Int64.init) ?? 10_000
            // Don't nag: a person who's turned Bluetooth off meant it, and it's recorded either way.
            central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if scanning {
                central?.stopScan()
                finishWindow()
            }
            central?.delegate = nil
            central = nil
            sink = nil
            clock = nil
        }
        let added = observers
        DispatchQueue.main.async { added.forEach(NotificationCenter.default.removeObserver) }
    }

    private func setForeground(_ value: Bool) { foregroundLock.withLock { foreground = value } }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let sink, let clock else { return }
        let off = central.state != .poweredOn
        guard central.state != .unknown, central.state != .resetting else { return }
        if off != lastOff {
            lastOff = off
            sink.event(off ? "bluetooth_off" : "bluetooth_on", tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
        }
        if off {
            timer?.cancel()
            timer = nil
            if scanning { finishWindow() }
        } else if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(Int(periodMs)))  // int-ok
            t.setEventHandler { [weak self] in self?.beginWindow() }
            timer = t
            t.resume()
        }
    }

    private func beginWindow() {
        guard let central, let sink, let clock, central.state == .poweredOn, !scanning else { return }
        let open = foregroundLock.withLock { foreground }
        let mode = open ? "all" : "services"
        if mode != lastMode {
            lastMode = mode
            sink.event("scan_mode", ["mode": mode], tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs())
        }
        scanning = true
        scanStartMono = clock.monoNs()
        scanStartWall = clock.wallMs()
        central.scanForPeripherals(withServices: open ? nil : BluetoothServices.common.map { CBUUID(string: $0) }, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(windowMs))) { [weak self] in  // int-ok
            guard let self, self.scanning else { return }
            self.central?.stopScan()
            self.finishWindow()
        }
    }

    private func finishWindow() {
        scanning = false
        guard let sink else { return }
        sink.message(.tensor(window.finish()), tsMonoNs: scanStartMono, tsWallMs: scanStartWall)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let tx = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.int64Value
        window.record(identifier: peripheral.identifier.uuidString.lowercased(), rssi: RSSI.int64Value, txPower: tx)
    }
}
#endif
