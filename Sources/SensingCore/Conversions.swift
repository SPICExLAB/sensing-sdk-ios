import Foundation
import SensingProto
import simd

/// Android's units and signs. The envelope has no platform field, so values are converted on the device, or an iOS sample
/// would silently mean something different from an Android one. Device axes are never remapped: on both platforms x points
/// right, y points to the top of the device and z out of the screen.
public enum Conversions {
    public static let standardGravity = 9.80665

    /// CoreMotion's magnetic- and true-north frames are x-north, y-west, z-up. Android's rotation vector is x-east, y-north,
    /// z-up. This is the +90° turn about z between them.
    private static let nwuToENU = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))

    /// CoreMotion's acceleration, gravity and user acceleration are in g, with the opposite sign to Android's m/s²: at rest
    /// face up, CoreMotion reads z = -1 and Android reads z = +9.81.
    @inline(__always)
    public static func metresPerSecondSquared(_ g: Double) -> Float { Float(-standardGravity * g) }

    /// CoreMotion attitude (device to reference, x/y/z/w) in Android's frame. An arbitrary-heading frame has no north to turn
    /// from, so it passes through.
    public static func orientation(coreMotion q: simd_quatd, northReferenced: Bool) -> simd_quatf {
        let turned = northReferenced ? nwuToENU * q : q
        return simd_quatf(vector: SIMD4<Float>(simd_normalize(turned).vector))
    }

    /// `CMDeviceMotion.headingAccuracy` is in degrees, and negative when invalid. Android's field is radians, -1 when none.
    @inline(__always)
    public static func headingAccuracy(degrees: Double) -> Float {
        degrees < 0 ? -1 : Float(degrees * .pi / 180)
    }

    /// `CMMagneticFieldCalibrationAccuracy`: -1 uncalibrated, then low, medium, high.
    @inline(__always)
    public static func accuracy(magneticCalibration raw: Int32) -> Sensorlog_V1_Accuracy {
        switch raw {
        case 0: .low
        case 1: .medium
        case 2: .high
        default: .unreliable
        }
    }

    /// `ts_wall_ms` for a sample stamped `tsMonoNs`, by Android's per-sample formula: wall time now, minus the sample's age.
    @inline(__always)
    public static func wallMs(forMonoNs tsMonoNs: Int64, clock: any EngineClock) -> Int64 {
        clock.wallMs() - (clock.monoNs() - tsMonoNs) / 1_000_000
    }
}

/// Thins a stream to its own rate. Device motion is one subscription supplying five streams at the fastest rate any of them
/// wants, so each stream is decimated, by the sample's own time.
public struct Decimator: Sendable {
    private let periodNs: Int64
    private let passThrough: Bool
    private var nextDueNs: Int64?

    /// A stream that wants the source's own rate keeps everything. The source runs slightly off what was asked (19.89 ms
    /// for 20 ms on an iPhone 15 Pro), so thinning it to the nominal rate would add a needless gap every few seconds.
    public init(periodUs: Int64, sourcePeriodUs: Int64? = nil) {
        periodNs = periodUs * 1000
        passThrough = sourcePeriodUs.map { periodUs * 100 <= $0 * 105 } ?? false
    }

    /// Whether this sample belongs to the stream. A little tolerance keeps a source's jitter from skipping a whole period.
    @inline(__always)
    public mutating func take(tsNs: Int64) -> Bool {
        if passThrough { return true }
        guard let due = nextDueNs else {
            nextDueNs = tsNs + periodNs
            return true
        }
        guard tsNs >= due - periodNs / 8 else { return false }
        // After a stall, restart from now rather than bursting to catch up.
        nextDueNs = tsNs - due > periodNs ? tsNs + periodNs : due + periodNs
        return true
    }
}

/// The sensors this SDK's adapters can run, with Android's default rates where they apply.
public enum SensingCatalog {
    public static let accelerometer = SensorID(known: "motion.accelerometer")
    public static let gyroscope = SensorID(known: "motion.gyroscope")
    public static let magnetometer = SensorID(known: "motion.magnetometer")
    public static let linearAcceleration = SensorID(known: "motion.linear_accel")
    public static let gravity = SensorID(known: "motion.gravity")
    public static let rotation = SensorID(known: "motion.rotation_vector")
    public static let steps = SensorID(known: "motion.step_counter")
    public static let barometer = SensorID(known: "env.barometer")

    private static func motion(_ id: SensorID, _ title: String, _ hz: Int64) -> CatalogEntry {
        CatalogEntry(id: id, title: title, detail: "", setting: .hz(hz), defaultOn: true)
    }

    private static let shared = [
        CatalogEntry(id: steps, title: "Steps", detail: "as counted", setting: SensorSetting(), defaultOn: true),
        // CMAltimeter delivers at its own pace, with no rate to set.
        CatalogEntry(id: barometer, title: "Barometer", detail: "as delivered", setting: SensorSetting(), defaultOn: true),
    ]

    public static let phone = [
        motion(accelerometer, "Accelerometer", 50), motion(gyroscope, "Gyroscope", 50), motion(linearAcceleration, "Linear acceleration", 50),
        motion(magnetometer, "Magnetometer", 20), motion(rotation, "Rotation", 20), motion(gravity, "Gravity", 10),
    ] + shared + deviceEntries(watch: false)

    public static let watch = [
        motion(accelerometer, "Accelerometer", 25), motion(gyroscope, "Gyroscope", 25), motion(linearAcceleration, "Linear acceleration", 25),
        motion(magnetometer, "Magnetometer", 10), motion(rotation, "Rotation", 10), motion(gravity, "Gravity", 10),
    ] + shared + deviceEntries(watch: true)
}

/// This process's CPU time so far, which is how A3 measures cost.
public enum ProcessCPU {
    public static func milliseconds() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Int64(usage.ru_utime.tv_sec) * 1000 + Int64(usage.ru_utime.tv_usec) / 1000
        let system = Int64(usage.ru_stime.tv_sec) * 1000 + Int64(usage.ru_stime.tv_usec) / 1000
        return user + system
    }
}
