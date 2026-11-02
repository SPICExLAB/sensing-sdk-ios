import XCTest
@testable import SensingStorage

final class StreamStatsTests: XCTestCase {
    private func regular(_ n: UInt64, periodMs: Int64 = 20) -> [(seq: UInt64, tsMonoNs: Int64)] {
        (0..<n).map { (seq: $0, tsMonoNs: 1_000_000_000 + Int64($0) * periodMs * 1_000_000) }
    }

    func testARegularStream() {
        let s = StreamStats.compute(regular(3001))
        XCTAssertEqual(s.samples, 3001)
        XCTAssertEqual(s.rateHz, 50, accuracy: 0.001)
        XCTAssertEqual(s.durationSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(s.medianIntervalMs, 20, accuracy: 0.001)
        XCTAssertEqual(s.maxGapMs, 20, accuracy: 0.001)
        XCTAssertEqual(s.gaps, 0)
        XCTAssertEqual(s.missingSeq, 0)
    }

    func testAPlantedHoleIsFoundAndIsNotCountedAsLostSeqWhenNumbersContinue() {
        var samples = regular(1000)
        for i in 500..<samples.count { samples[i].tsMonoNs += 2_000_000_000 }  // the device stalled, but nothing was dropped
        let s = StreamStats.compute(samples)
        XCTAssertEqual(s.gaps, 1)
        XCTAssertEqual(s.maxGapMs, 2020, accuracy: 0.001)
        XCTAssertEqual(s.missingSeq, 0)
        XCTAssertEqual(s.medianIntervalMs, 20, accuracy: 0.001)
    }

    func testDroppedSamplesShowAsMissingSeq() {
        var samples = regular(100)
        samples.removeSubrange(40..<50)
        let s = StreamStats.compute(samples)
        XCTAssertEqual(s.missingSeq, 10)
        XCTAssertEqual(s.maxGapMs, 220, accuracy: 0.001)
    }

    func testDuplicatesAndBackwardsTimeAreCounted() {
        var samples = regular(10)
        samples.append(samples[3])
        samples[7].tsMonoNs = 0
        let s = StreamStats.compute(samples)
        XCTAssertEqual(s.duplicateSeq, 1)
        XCTAssertEqual(s.backwards, 1)
    }

    func testOrderOfArrivalDoesNotMatter() {
        XCTAssertEqual(StreamStats.compute(regular(500).reversed()), StreamStats.compute(regular(500)))
    }

    func testEmptyAndSingleSample() {
        XCTAssertEqual(StreamStats.compute([]).samples, 0)
        let one = StreamStats.compute(regular(1))
        XCTAssertEqual(one.samples, 1)
        XCTAssertEqual(one.rateHz, 0)
    }
}
