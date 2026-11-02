@preconcurrency import CoreMotion
import Foundation
import HealthKit
import SensingCore
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

/// What this device says it can do: the facts Phase 1 has to confirm on real hardware.
@MainActor
enum ProbeAPI {
    static func report() -> [(String, String)] {
        let motion = CMMotionManager()
        var out: [(String, String)] = []
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        out.append(("device", "\(device.model) \(device.systemName) \(device.systemVersion)"))
        #else
        let device = UIDevice.current
        out.append(("device", "\(device.model) \(device.systemName) \(device.systemVersion)"))
        #endif
        out.append(("accelerometer", "\(motion.isAccelerometerAvailable)"))
        out.append(("gyro", "\(motion.isGyroAvailable)"))
        out.append(("magnetometer", "\(motion.isMagnetometerAvailable)"))
        out.append(("deviceMotion", "\(motion.isDeviceMotionAvailable)"))
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        out.append(("frame.arbitrary", "\(frames.contains(.xArbitraryZVertical))"))
        out.append(("frame.arbitraryCorrected", "\(frames.contains(.xArbitraryCorrectedZVertical))"))
        out.append(("frame.magneticNorth", "\(frames.contains(.xMagneticNorthZVertical))"))
        out.append(("frame.trueNorth", "\(frames.contains(.xTrueNorthZVertical))"))
        out.append(("altimeter.relative", "\(CMAltimeter.isRelativeAltitudeAvailable())"))
        out.append(("altimeter.absolute", "\(CMAltimeter.isAbsoluteAltitudeAvailable())"))
        out.append(("pedometer.steps", "\(CMPedometer.isStepCountingAvailable())"))
        out.append(("activity", "\(CMMotionActivityManager.isActivityAvailable())"))
        #if os(watchOS)
        out.append(("batched.accelerometer", "\(CMBatchedSensorManager.isAccelerometerSupported)"))
        out.append(("batched.deviceMotion", "\(CMBatchedSensorManager.isDeviceMotionSupported)"))
        #endif
        out.append(("health.available", "\(HKHealthStore.isHealthDataAvailable())"))
        out.append(("health.workoutAuth", "\(HKHealthStore().authorizationStatus(for: HKObjectType.workoutType()).rawValue)"))
        out.append(("clock.sleepOffsetNs", "\(Clock.sleepOffsetNs())"))
        out.append(("lowPower", "\(ProcessInfo.processInfo.isLowPowerModeEnabled)"))
        out.append(("thermal", "\(ProcessInfo.processInfo.thermalState.rawValue)"))
        return out
    }

    static func write(to directory: URL) {
        let lines = report().map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: directory.appendingPathComponent("api.txt").path, contents: Data(lines.utf8), attributes: ProbeFiles.protection)
    }
}

extension ProbeRecorder.StreamStat {
    /// The rate since the UI last asked, from the samples' own timestamps.
    var recentHz: Double { recentIntervalSum > 0 ? Double(recentIntervals) / recentIntervalSum : 0 }
}
