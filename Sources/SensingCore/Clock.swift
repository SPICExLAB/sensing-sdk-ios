import Foundation

/// The clocks every sample is stamped from.
///
/// `ts_mono_ns` means what Android's `elapsedRealtimeNanos` means: time since an arbitrary fixed point, counting deep
/// sleep. On Darwin that's `CLOCK_MONOTONIC_RAW`. `CMLogItem.timestamp` is on `CLOCK_UPTIME_RAW` instead, which stops
/// during sleep, so CoreMotion's times need the difference between the two added.
public enum Clock {
    /// Nanoseconds that keep counting during sleep: `ts_mono_ns`.
    public static func monoNs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) }

    /// Nanoseconds that stop during sleep: the clock `CMLogItem.timestamp` runs on.
    public static func uptimeNs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }

    /// Wall-clock milliseconds since the epoch: `ts_wall_ms`.
    public static func wallMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// How much sleep the two clocks currently differ by. It only grows, by the time spent asleep.
    public static func sleepOffsetNs() -> Int64 {
        let a = uptimeNs()
        let m = monoNs()
        let b = uptimeNs()
        return m - (a + (b - a) / 2)
    }
}

/// The clocks the engine reads, so tests can run minutes of recording in milliseconds.
public protocol EngineClock: Sendable {
    func monoNs() -> Int64
    func uptimeNs() -> Int64
    func wallMs() -> Int64
}

public struct SystemClock: EngineClock {
    public init() {}
    public func monoNs() -> Int64 { Clock.monoNs() }
    public func uptimeNs() -> Int64 { Clock.uptimeNs() }
    public func wallMs() -> Int64 { Clock.wallMs() }
}

/// Converts CoreMotion's uptime timestamps to `ts_mono_ns`. A sample has to get the offset that held when it was taken:
/// one taken before a sleep but delivered after it would otherwise be stamped late by the whole sleep. Thread-safe.
public final class SleepOffsetTracker: @unchecked Sendable {
    private struct Change {
        var uptimeNs: Int64
        var offsetNs: Int64
    }

    /// Reading noise between the two clocks is microseconds; real sleep is far longer.
    private static let significantNs: Int64 = 1_000_000
    private static let keep = 64
    private let lock = NSLock()
    private var changes: [Change]

    public init(uptimeNs: Int64 = Clock.uptimeNs(), offsetNs: Int64 = Clock.sleepOffsetNs()) {
        changes = [Change(uptimeNs: uptimeNs, offsetNs: offsetNs)]
    }

    /// Call with the clocks as they read now, at least on each delivery.
    public func observe(uptimeNs: Int64, offsetNs: Int64) {
        lock.withLock {
            guard let last = changes.last, abs(offsetNs - last.offsetNs) > Self.significantNs else { return }
            changes.append(Change(uptimeNs: uptimeNs, offsetNs: offsetNs))
            if changes.count > Self.keep { changes.removeFirst() }
        }
    }

    /// `ts_mono_ns` for a sample stamped at this uptime.
    public func monoNs(forUptimeNs uptime: Int64) -> Int64 {
        lock.withLock {
            let change = changes.last { $0.uptimeNs <= uptime } ?? changes[0]
            return uptime + change.offsetNs
        }
    }

    /// The same for `CMLogItem.timestamp`, which is in seconds.
    public func monoNs(forTimestamp seconds: Double) -> Int64 {
        monoNs(forUptimeNs: Int64((seconds * 1e9).rounded()))
    }
}
