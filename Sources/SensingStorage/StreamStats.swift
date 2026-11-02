import Foundation

/// Rate and gaps for one stream, from each sample's own `ts_mono_ns` and `seq`. Never from arrival time: Wi-Fi bunching
/// once produced dozens of fake dropouts.
public struct StreamStats: Sendable, Equatable {
    public var samples: Int64 = 0
    public var durationSeconds: Double = 0
    public var rateHz: Double = 0
    public var medianIntervalMs: Double = 0
    public var p5IntervalMs: Double = 0
    public var p95IntervalMs: Double = 0
    public var maxGapMs: Double = 0
    /// Intervals longer than `gapThresholdMs`.
    public var gaps: Int64 = 0
    /// Seq numbers that never arrived. A drop consumes its number, so these are real losses.
    public var missingSeq: Int64 = 0
    public var duplicateSeq: Int64 = 0
    /// Samples whose time goes backwards in seq order.
    public var backwards: Int64 = 0

    public static let defaultGapThresholdMs = 100.0

    /// `samples` are (seq, ts_mono_ns) pairs, in any order.
    public static func compute(_ samples: [(seq: UInt64, tsMonoNs: Int64)], gapThresholdMs: Double = defaultGapThresholdMs) -> StreamStats {
        var s = StreamStats()
        s.samples = Int64(samples.count)
        guard !samples.isEmpty else { return s }
        let ordered = samples.sorted { $0.seq < $1.seq }
        var intervals: [Double] = []
        intervals.reserveCapacity(ordered.count)
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            if b.seq == a.seq {
                s.duplicateSeq += 1
                continue
            }
            s.missingSeq += Int64(truncatingIfNeeded: b.seq - a.seq - 1)
            if b.tsMonoNs < a.tsMonoNs { s.backwards += 1 }
            intervals.append(Double(b.tsMonoNs - a.tsMonoNs) / 1e6)
        }
        guard !intervals.isEmpty else { return s }
        s.durationSeconds = Double(ordered.last!.tsMonoNs - ordered.first!.tsMonoNs) / 1e9
        if s.durationSeconds > 0 { s.rateHz = Double(intervals.count) / s.durationSeconds }
        s.gaps = Int64(intervals.lazy.filter { $0 > gapThresholdMs }.count)
        intervals.sort()
        s.maxGapMs = intervals.last!
        s.medianIntervalMs = percentile(intervals, 0.5)
        s.p5IntervalMs = percentile(intervals, 0.05)
        s.p95IntervalMs = percentile(intervals, 0.95)
        return s
    }

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        let at = Int((Double(sorted.count - 1) * q).rounded())  // int-ok: an index into an array that's in memory
        return sorted[at]
    }
}
