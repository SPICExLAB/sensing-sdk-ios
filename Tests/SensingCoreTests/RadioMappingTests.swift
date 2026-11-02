import Network
import XCTest
@testable import SensingCore

/// What the radio adapters compute. The adapters themselves are too thin to be wrong in the same ways.
final class RadioMappingTests: XCTestCase {
    func testRadioNamesAreSharedWithAndroid() {
        XCTAssertEqual(CellularEvent.radioName("CTRadioAccessTechnologyLTE"), "lte")
        XCTAssertEqual(CellularEvent.radioName("CTRadioAccessTechnologyNR"), "nr")
        XCTAssertEqual(CellularEvent.radioName("CTRadioAccessTechnologyNRNSA"), "nr_nsa")
        XCTAssertEqual(CellularEvent.radioName("CTRadioAccessTechnologyWCDMA"), "wcdma")
        XCTAssertEqual(CellularEvent.radioName("CTRadioAccessTechnologyCDMAEVDORevA"), "evdo")
        XCTAssertEqual(CellularEvent.radioName(nil), "none", "no SIM, or airplane mode")
        XCTAssertEqual(CellularEvent.radioName("CTRadioAccessTechnologySomethingNew"), "unknown")
    }

    func testCellularAttributesNameNoSim() {
        let a = CellularEvent.attributes(technology: "CTRadioAccessTechnologyLTE", services: 2, restriction: .notRestricted)
        XCTAssertEqual(a, ["radio": "lte", "services": "2", "data_restricted": "not_restricted"])
    }

    func testWifiIdentifiersAreHashedAndNeverRaw() {
        let hash = IdentifierHash(salt: "s")
        let a = WifiConnectionEvent.attributes(ssid: "Home Network", bssid: "AA:BB:CC:DD:EE:FF", security: .personal, hash: hash)
        XCTAssertEqual(a["ssid_hash"], hash.hash("Home Network"))
        XCTAssertEqual(a["bssid_hash"]?.count, 16)
        XCTAssertEqual(a["bssid_hash"], hash.hash("aa:bb:cc:dd:ee:ff"), "the same address however it's written")
        XCTAssertEqual(a["security"], "personal")
        XCTAssertFalse(a.values.contains { $0.contains("Home") || $0.lowercased().contains("aa:bb") })
    }

    func testWifiHashesDontLinkAcrossDevices() {
        let one = WifiConnectionEvent.attributes(ssid: "x", bssid: "y", security: .open, hash: IdentifierHash(salt: "device-a"))
        let two = WifiConnectionEvent.attributes(ssid: "x", bssid: "y", security: .open, hash: IdentifierHash(salt: "device-b"))
        XCTAssertNotEqual(one["ssid_hash"], two["ssid_hash"])
    }

    func testAProbeReportsWhatItMeasuredAndLeavesOutWhatItDidnt() {
        let a = NetworkProbeEvent.attributes(ok: true, transport: "wifi", connectMs: 18.44, smoothedMs: 19, minMs: 0, varianceMs: 0, radio: "wifi_ax", host: "h")
        XCTAssertEqual(a["ok"], "true")
        XCTAssertEqual(a["connect_ms"], "18.4")
        XCTAssertEqual(a["smoothed_ms"], "19.0")
        XCTAssertNil(a["min_ms"], "0 means the system took no sample")
        XCTAssertNil(a["variance_ms"])
        XCTAssertEqual(a["radio"], "wifi_ax")
        XCTAssertEqual(a["host"], "h")
    }

    func testAFailedProbeSaysWhy() {
        let a = NetworkProbeEvent.attributes(ok: false, transport: "none", connectMs: nil, host: "h", reason: "timeout")
        XCTAssertEqual(a["ok"], "false")
        XCTAssertEqual(a["reason"], "timeout")
        XCTAssertNil(a["connect_ms"])
    }

    func testNumbersUsePointsWhateverTheLocale() {
        XCTAssertEqual(AttributeNumber.format(1.5, places: 1), "1.5")
        XCTAssertEqual(AttributeNumber.format(2, places: 2), "2.00")
    }

    func testRadioTypesNameTheBand() {
        XCTAssertEqual(RadioNames.name(of: .wifi(.ax)), "wifi_ax")
        XCTAssertEqual(RadioNames.name(of: .wifi(.ac)), "wifi_ac")
        XCTAssertEqual(RadioNames.name(of: .cell(.lte)), "lte")
        XCTAssertEqual(RadioNames.name(of: .cell(.dualConnectivity5G(.sub6GHz))), "nr_nsa_sub6")
        XCTAssertEqual(RadioNames.name(of: .cell(.standalone5G(.mmWave))), "nr_mmw")
    }

    func testLocationStateSaysWhenPreciseLocationIsOff() {
        XCTAssertEqual(LocationStateEvent.attributes(fullAccuracy: true, floor: nil), ["accuracy": "full"])
        XCTAssertEqual(LocationStateEvent.attributes(fullAccuracy: false, floor: 3), ["accuracy": "reduced", "floor": "3"])
    }

    func testAHeadingCoreLocationDoesntHaveIsLeftOut() {
        let good = HeadingEvent.attributes(magnetic: 271.54, trueHeading: 273, accuracy: 10, x: 1, y: -2, z: 3.456)
        XCTAssertEqual(good["magnetic"], "271.5")
        XCTAssertEqual(good["true"], "273.0")
        XCTAssertEqual(good["z"], "3.46")
        let noTrue = HeadingEvent.attributes(magnetic: 10, trueHeading: -1, accuracy: 5, x: 0, y: 0, z: 0)
        XCTAssertNil(noTrue["true"], "true north needs a location")
        XCTAssertEqual(noTrue["magnetic"], "10.0")
        let invalid = HeadingEvent.attributes(magnetic: 0, trueHeading: -1, accuracy: -1, x: 1, y: 2, z: 3)
        XCTAssertNil(invalid["magnetic"], "a negative accuracy means this heading is invalid")
        XCTAssertEqual(invalid["x"], "1.00", "the raw field is still real")
    }

    func testARelayPassesTokensBothWays() {
        let relay = PeerTokenRelay()
        let sent = Box()
        let received = Box()
        relay.send(Data([1]))
        relay.receive(Data([2]))  // nobody listening yet: dropped, and it doesn't crash
        relay.onSend { sent.value = $0 }
        relay.onReceive { received.value = $0 }
        relay.send(Data([3]))
        relay.receive(Data([4]))
        XCTAssertEqual(sent.value, Data([3]))
        XCTAssertEqual(received.value, Data([4]))
        relay.onReceive(nil)
        relay.receive(Data([5]))
        XCTAssertEqual(received.value, Data([4]))
    }

    func testDefaultsOnlyTurnOnWhatsPassive() {
        func on(_ id: SensorID) -> Bool? { SensingCatalog.phone.first { $0.id == id }?.defaultOn }
        XCTAssertEqual(on(SensingCatalog.cellular), true)
        XCTAssertEqual(on(SensingCatalog.wifi), true)
        XCTAssertEqual(on(SensingCatalog.networkRtt), false, "it contacts an outside server")
        XCTAssertEqual(on(SensingCatalog.heading), false)
        XCTAssertEqual(on(SensingCatalog.peerDistance), false)
    }

    func testTheWatchOffersOnlyWhatItCanDo() {
        let watch = Set(SensingCatalog.watch.map(\.id))
        XCTAssertFalse(watch.contains(SensingCatalog.cellular), "no CoreTelephony on the watch")
        XCTAssertFalse(watch.contains(SensingCatalog.wifi))
        XCTAssertFalse(watch.contains(SensingCatalog.networkRtt), "watchOS restricts low-level networking")
        XCTAssertTrue(watch.contains(SensingCatalog.peerDistance))
        XCTAssertTrue(watch.contains(SensingCatalog.heading))
    }

    func testTheProbeHostIsAChangeableSetting() {
        let entry = SensingCatalog.phone.first { $0.id == SensingCatalog.networkRtt }
        XCTAssertEqual(entry?.setting.extras["host"], "captive.apple.com")
        XCTAssertEqual(entry?.setting.samplingPeriodUs, 300_000_000)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var value: Data? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
