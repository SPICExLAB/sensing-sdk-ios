#if os(iOS) || os(watchOS)
@preconcurrency import CoreMotion
import Foundation
import SensingCore
import SensingProto
import simd

/// The motion core, from one `CMMotionManager`. The raw accelerometer has its own subscription; everything else comes from
/// device motion, decimated per stream.
///
/// Gyroscope and magnetometer come from device motion on purpose: its rotation rate has the drift removed and its field is
/// calibrated, as Android's `TYPE_GYROSCOPE` and `TYPE_MAGNETIC_FIELD` are. And it's the only way on the watch, where a
/// Series 9 reports the raw gyroscope and magnetometer unavailable yet device motion supplies both (S-015).
public final class MotionAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.accelerometer, SensingCatalog.gyroscope, SensingCatalog.magnetometer,
                          SensingCatalog.linearAcceleration, SensingCatalog.gravity, SensingCatalog.rotation]

    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private let underlying = DispatchQueue(label: "sensing.motion", qos: .userInitiated)

    public init() {
        queue.underlyingQueue = underlying
        queue.maxConcurrentOperationCount = 1
        queue.name = "sensing.motion"
    }

    /// Whether rotation can be north-referenced, as Android's is. Without it, rotations have an arbitrary heading, and the
    /// recording has to say so.
    public var northReferenced: Bool { CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical) }

    public func availability(of sensor: SensorID) -> Availability {
        let hardware = sensor == SensingCatalog.accelerometer ? motion.isAccelerometerAvailable : motion.isDeviceMotionAvailable
        return hardware ? .available : .missingHardware
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        let tracker = SleepOffsetTracker(uptimeNs: clock.uptimeNs(), offsetNs: clock.monoNs() - clock.uptimeNs())
        if let sink = sinks[SensingCatalog.accelerometer], let period = settings[SensingCatalog.accelerometer]?.samplingPeriodUs {
            startAccelerometer(period: period, sink: sink, tracker: tracker, clock: clock)
        }
        startDeviceMotion(settings, sinks: sinks, tracker: tracker, clock: clock)
    }

    public func stop() {
        motion.stopAccelerometerUpdates()
        motion.stopDeviceMotionUpdates()
        queue.waitUntilAllOperationsAreFinished()
    }

    private func startAccelerometer(period: Int64, sink: SampleSink, tracker: SleepOffsetTracker, clock: any EngineClock) {
        motion.accelerometerUpdateInterval = Double(period) / 1e6
        motion.startAccelerometerUpdates(to: queue) { data, _ in
            guard let d = data else { return }
            tracker.observe(uptimeNs: clock.uptimeNs(), offsetNs: clock.monoNs() - clock.uptimeNs())
            let mono = tracker.monoNs(forTimestamp: d.timestamp)
            sink.vec3(Conversions.metresPerSecondSquared(d.acceleration.x), Conversions.metresPerSecondSquared(d.acceleration.y), Conversions.metresPerSecondSquared(d.acceleration.z),
                      tsMonoNs: mono, tsWallMs: Conversions.wallMs(forMonoNs: mono, clock: clock), accuracy: .high)
        }
    }

    private func startDeviceMotion(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], tracker: SleepOffsetTracker, clock: any EngineClock) {
        let streams = [SensingCatalog.gyroscope, SensingCatalog.gravity, SensingCatalog.linearAcceleration, SensingCatalog.rotation, SensingCatalog.magnetometer]
        let periods = streams.compactMap { id in sinks[id] != nil ? settings[id]?.samplingPeriodUs : nil }
        guard let fastest = periods.min() else { return }
        func stream(_ id: SensorID) -> Stream? {
            guard let sink = sinks[id], let period = settings[id]?.samplingPeriodUs else { return nil }
            return Stream(sink: sink, decimator: Decimator(periodUs: period, sourcePeriodUs: fastest))
        }
        // Touched only on the serial queue the handler runs on.
        let state = DeviceMotionState(gyroscope: stream(SensingCatalog.gyroscope), gravity: stream(SensingCatalog.gravity), linear: stream(SensingCatalog.linearAcceleration),
                                      rotation: stream(SensingCatalog.rotation), magnetometer: stream(SensingCatalog.magnetometer))
        let north = northReferenced
        let frame: CMAttitudeReferenceFrame = north ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
        motion.deviceMotionUpdateInterval = Double(fastest) / 1e6
        motion.startDeviceMotionUpdates(using: frame, to: queue) { data, _ in
            guard let d = data else { return }
            tracker.observe(uptimeNs: clock.uptimeNs(), offsetNs: clock.monoNs() - clock.uptimeNs())
            let mono = tracker.monoNs(forTimestamp: d.timestamp)
            let wall = Conversions.wallMs(forMonoNs: mono, clock: clock)
            state.deliver(d, north: north, mono: mono, wall: wall)
        }
    }
}

private struct Stream {
    let sink: SampleSink
    var decimator: Decimator
}

private final class DeviceMotionState: @unchecked Sendable {
    var gyroscope: Stream?
    var gravity: Stream?
    var linear: Stream?
    var rotation: Stream?
    var magnetometer: Stream?

    init(gyroscope: Stream?, gravity: Stream?, linear: Stream?, rotation: Stream?, magnetometer: Stream?) {
        self.gyroscope = gyroscope
        self.gravity = gravity
        self.linear = linear
        self.rotation = rotation
        self.magnetometer = magnetometer
    }

    func deliver(_ d: CMDeviceMotion, north: Bool, mono: Int64, wall: Int64) {
        if let sink = gyroscope?.sink, gyroscope?.decimator.take(tsNs: mono) == true {
            sink.vec3(Float(d.rotationRate.x), Float(d.rotationRate.y), Float(d.rotationRate.z), tsMonoNs: mono, tsWallMs: wall, accuracy: .high)
        }
        if let sink = gravity?.sink, gravity?.decimator.take(tsNs: mono) == true {
            sink.vec3(Conversions.metresPerSecondSquared(d.gravity.x), Conversions.metresPerSecondSquared(d.gravity.y), Conversions.metresPerSecondSquared(d.gravity.z),
                      tsMonoNs: mono, tsWallMs: wall, accuracy: .high)
        }
        if let sink = linear?.sink, linear?.decimator.take(tsNs: mono) == true {
            sink.vec3(Conversions.metresPerSecondSquared(d.userAcceleration.x), Conversions.metresPerSecondSquared(d.userAcceleration.y), Conversions.metresPerSecondSquared(d.userAcceleration.z),
                      tsMonoNs: mono, tsWallMs: wall, accuracy: .high)
        }
        if let sink = rotation?.sink, rotation?.decimator.take(tsNs: mono) == true {
            let q = d.attitude.quaternion
            let turned = Conversions.orientation(coreMotion: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w), northReferenced: north)
            sink.quat(turned.imag.x, turned.imag.y, turned.imag.z, turned.real, headingAccuracy: Self.headingAccuracy(d), tsMonoNs: mono, tsWallMs: wall, accuracy: .high)
        }
        if let sink = magnetometer?.sink, magnetometer?.decimator.take(tsNs: mono) == true {
            let f = d.magneticField
            // All zeros means no reading yet, not a zero field.
            if f.field.x != 0 || f.field.y != 0 || f.field.z != 0 {
                sink.vec3(Float(f.field.x), Float(f.field.y), Float(f.field.z), tsMonoNs: mono, tsWallMs: wall, accuracy: Conversions.accuracy(magneticCalibration: f.accuracy.rawValue))
            }
        }
    }

    private static func headingAccuracy(_ d: CMDeviceMotion) -> Float {
        #if os(iOS)
        if #available(iOS 27.0, *) { return Conversions.headingAccuracy(degrees: d.headingAccuracy) }
        #endif
        return -1
    }
}

/// Air pressure. `CMAltimeter` has no rate to set: measured, it delivers about every 1.06 s on an iPhone 15 Pro and every
/// 2.56 s on a Series 9.
public final class AltimeterAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.barometer]

    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()

    public init() {
        queue.maxConcurrentOperationCount = 1
        queue.name = "sensing.altimeter"
    }

    public func availability(of sensor: SensorID) -> Availability {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return .missingHardware }
        let status = CMAltimeter.authorizationStatus()
        return status == .denied || status == .restricted ? .missingPermission(["motion"]) : .available
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.barometer] else { return }
        let tracker = SleepOffsetTracker(uptimeNs: clock.uptimeNs(), offsetNs: clock.monoNs() - clock.uptimeNs())
        altimeter.startRelativeAltitudeUpdates(to: queue) { data, _ in
            guard let d = data else { return }
            tracker.observe(uptimeNs: clock.uptimeNs(), offsetNs: clock.monoNs() - clock.uptimeNs())
            let mono = tracker.monoNs(forTimestamp: d.timestamp)
            sink.scalar(d.pressure.floatValue * 10, tsMonoNs: mono, tsWallMs: Conversions.wallMs(forMonoNs: mono, clock: clock), accuracy: .high)  // kPa to hPa
        }
    }

    public func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        queue.waitUntilAllOperationsAreFinished()
    }
}

/// Steps, cumulative since this recording started, which differs from Android's since-boot count. Differencing gives the
/// same answer, and a new session's reset looks like Android's reboot drop.
public final class PedometerAdapter: SensorAdapter, @unchecked Sendable {
    public let sensors = [SensingCatalog.steps]

    private let pedometer = CMPedometer()
    private let lock = NSLock()
    private var sink: SampleSink?
    private var clock: (any EngineClock)?
    private var startDate: Date?

    public init() {}

    public func availability(of sensor: SensorID) -> Availability {
        guard CMPedometer.isStepCountingAvailable() else { return .missingHardware }
        let status = CMPedometer.authorizationStatus()
        return status == .denied || status == .restricted ? .missingPermission(["motion"]) : .available
    }

    public func start(_ settings: [SensorID: SensorSetting], sinks: [SensorID: SampleSink], clock: any EngineClock) throws {
        guard let sink = sinks[SensingCatalog.steps] else { return }
        let start = Date()
        lock.withLock {
            self.sink = sink
            self.clock = clock
            startDate = start
        }
        sink.scalar(0, tsMonoNs: clock.monoNs(), tsWallMs: clock.wallMs(), accuracy: .high)
        pedometer.startUpdates(from: start) { [weak self] data, _ in
            guard let data else { return }
            self?.deliver(count: data.numberOfSteps, at: data.endDate)
        }
    }

    public func stop() {
        pedometer.stopUpdates()
        // Updates can lag, so the final count comes from a query. The engine waits for no one: it arrives or it doesn't.
        guard let start = lock.withLock({ startDate }) else { return }
        let done = DispatchSemaphore(value: 0)
        pedometer.queryPedometerData(from: start, to: Date()) { [weak self] data, _ in
            if let data { self?.deliver(count: data.numberOfSteps, at: data.endDate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + .seconds(1))
        lock.withLock {
            sink = nil
            clock = nil
            startDate = nil
        }
    }

    private func deliver(count: NSNumber, at end: Date) {
        lock.withLock {
            guard let sink, let clock else { return }
            // CMPedometerData's dates are wall time, so its age on the wall clock gives the mono time.
            let ageMs = max(0, clock.wallMs() - Int64(end.timeIntervalSince1970 * 1000))
            sink.scalar(count.floatValue, tsMonoNs: clock.monoNs() - ageMs * 1_000_000, tsWallMs: clock.wallMs() - ageMs, accuracy: .high)
        }
    }
}
#endif
