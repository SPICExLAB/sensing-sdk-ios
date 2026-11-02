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
