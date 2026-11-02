#if os(iOS)
import AVFAudio
@preconcurrency import CoreBluetooth
import CoreLocation
@preconcurrency import CoreMotion
import Foundation
import HealthKit

public enum SensingPermission: String, CaseIterable, Sendable, Identifiable {
    case motion
    case location
    case workouts
    case microphone
    case bluetooth

    public var id: String { rawValue }
}

public enum PermissionState: Sendable, Equatable {
    case notAsked
    case granted
    case denied
    case unavailable
}

/// What each sensor needs, asked for only when someone chooses to. iOS shows each prompt once: after that, a "denied" can only be
/// changed in Settings.
@MainActor
enum Permissions {
    static func state(of permission: SensingPermission, location: CLAuthorizationStatus) -> PermissionState {
        switch permission {
        case .motion:
            guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
            return switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .location:
            return switch location {
            case .authorizedWhenInUse, .authorizedAlways: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .workouts:
            guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
            return switch HKHealthStore().authorizationStatus(for: HKObjectType.workoutType()) {
            case .sharingAuthorized: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        case .microphone:
            return switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .undetermined: .notAsked
            default: .denied
            }
        case .bluetooth:
            return switch CBCentralManager.authorization {
            case .allowedAlways: .granted
            case .notDetermined: .notAsked
            default: .denied
            }
        }
    }

    /// A query is what makes iOS ask for motion: there's no request call.
    static func requestMotion() async {
        let pedometer = CMPedometer()
        let done: Void = await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: Date(timeIntervalSinceNow: -60), to: Date()) { _, _ in continuation.resume() }
        }
        _ = done
        _ = pedometer
    }

    static func requestMicrophone() async {
        _ = await AVAudioApplication.requestRecordPermission()
    }

    /// Creating a manager is what makes iOS ask for Bluetooth, and its answer arrives through the delegate.
    static func requestBluetooth() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let prompt = BluetoothPrompt(continuation)
            prompt.begin()
        }
    }
}

private final class BluetoothPrompt: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var manager: CBCentralManager?
    private var keepAlive: BluetoothPrompt?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func begin() {
        keepAlive = self  // until the answer comes: the manager holds its delegate weakly
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBCentralManager.authorization != .notDetermined else { return }
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
        keepAlive = nil
    }
}
#endif
