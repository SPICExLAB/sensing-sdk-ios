import Foundation
import SensingProto
import os

/// A sample as an adapter hands it over, before the engine stamps it. Motion payloads are stored inline, so a push
/// allocates nothing at 800 samples a second.
public enum RawPayload: Sendable {
    case vec3(Float, Float, Float)
    case quat(Float, Float, Float, Float, headingAccuracy: Float)
    case scalar(Float)
    /// Location, events and tensors: low rate, so a heap allocation is fine.
    indirect case message(Sensorlog_V1_SensorSample.OneOf_Payload)
}

/// Where every sample enters. A sensor callback pushes under a short lock and returns: no I/O, no task hop, and no string
/// work. `seq` is assigned here, so a dropped sample still consumes its number, as on Android. The engine swaps the buffer
/// out on its tick. Nothing downstream can slow a callback, and a loss is always recorded.
public final class Intake: @unchecked Sendable {
    public struct Stamped: Sendable {
        public var slot: Int32
        public var seq: Int64
        public var tsMonoNs: Int64
        public var tsWallMs: Int64
        public var accuracy: Sensorlog_V1_Accuracy
        public var payload: RawPayload
    }

    /// Consecutive drops from one stream, which become one `device.gap`.
    public struct DropRun: Sendable, Equatable {
        public var slot: Int32
        public var firstSeq: Int64
        public var lastSeq: Int64
        public var count: Int64
        public var pending: Int64
    }

    public struct Drained: Sendable {
        public var samples: [Stamped]
        public var drops: [DropRun]
    }

    private struct State: @unchecked Sendable {
        var open = false
        var buffer: [Stamped] = []
        var nextSeq: [Int64] = []
        var drops: [DropRun] = []
        var dropped: Int64 = 0
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: State())
    private let ceiling: Int

    /// Past `ceiling` waiting samples, the disk has stalled beyond what memory can hold: drop, and say so.
    public init(ceiling: Int) { self.ceiling = ceiling }

    /// Starts a new session: every stream's seq goes back to 0.
    public func open(slots: Int32) {
        lock.withLockUnchecked {
            $0.open = true
            $0.buffer.removeAll(keepingCapacity: true)
            $0.nextSeq = [Int64](repeating: 0, count: numericCast(slots))
            $0.drops = []
            $0.dropped = 0
        }
    }

    /// Later pushes are ignored.
    public func close() { lock.withLockUnchecked { $0.open = false } }

    public func addSlot() -> Int32 {
        lock.withLockUnchecked {
            $0.nextSeq.append(0)
            return Int32(truncatingIfNeeded: $0.nextSeq.count - 1)
        }
    }

    @inline(__always)
    public func push(slot: Int32, tsMonoNs: Int64, tsWallMs: Int64, accuracy: Sensorlog_V1_Accuracy, payload: RawPayload) {
        let ceiling = ceiling
        lock.withLockUnchecked { s in
            guard s.open else { return }
            let i = Int(slot)  // int-ok: a small index
            let seq = s.nextSeq[i]
            s.nextSeq[i] = seq + 1
            if s.buffer.count >= ceiling {
                s.dropped += 1
                let pending = Int64(s.buffer.count)
                if let last = s.drops.last, last.slot == slot, last.lastSeq == seq - 1 {
                    s.drops[s.drops.count - 1].lastSeq = seq
                    s.drops[s.drops.count - 1].count += 1
                } else {
                    s.drops.append(DropRun(slot: slot, firstSeq: seq, lastSeq: seq, count: 1, pending: pending))
                }
                return
            }
            s.buffer.append(Stamped(slot: slot, seq: seq, tsMonoNs: tsMonoNs, tsWallMs: tsWallMs, accuracy: accuracy, payload: payload))
        }
    }

    /// Takes everything waiting. `spare` is an emptied array to reuse, so a swap doesn't reallocate at this rate.
    public func drain(spare: [Stamped] = []) -> Drained {
        var incoming = spare
        incoming.removeAll(keepingCapacity: true)
        return lock.withLockUnchecked { s in
            let out = Drained(samples: s.buffer, drops: s.drops)
            s.buffer = incoming
            s.drops = []
            return out
        }
    }

    public var pending: Int64 { lock.withLockUnchecked { Int64($0.buffer.count) } }
    public var dropped: Int64 { lock.withLockUnchecked { $0.dropped } }
}

/// What an adapter pushes into. One per stream.
public struct SampleSink: Sendable {
    private let intake: Intake
    private let slot: Int32

    public init(intake: Intake, slot: Int32) {
        self.intake = intake
        self.slot = slot
    }

    @inline(__always)
    public func vec3(_ x: Float, _ y: Float, _ z: Float, tsMonoNs: Int64, tsWallMs: Int64, accuracy: Sensorlog_V1_Accuracy = .unspecified) {
        intake.push(slot: slot, tsMonoNs: tsMonoNs, tsWallMs: tsWallMs, accuracy: accuracy, payload: .vec3(x, y, z))
    }

    @inline(__always)
    public func quat(_ x: Float, _ y: Float, _ z: Float, _ w: Float, headingAccuracy: Float, tsMonoNs: Int64, tsWallMs: Int64, accuracy: Sensorlog_V1_Accuracy = .unspecified) {
        intake.push(slot: slot, tsMonoNs: tsMonoNs, tsWallMs: tsWallMs, accuracy: accuracy, payload: .quat(x, y, z, w, headingAccuracy: headingAccuracy))
    }

    @inline(__always)
    public func scalar(_ value: Float, tsMonoNs: Int64, tsWallMs: Int64, accuracy: Sensorlog_V1_Accuracy = .unspecified) {
        intake.push(slot: slot, tsMonoNs: tsMonoNs, tsWallMs: tsWallMs, accuracy: accuracy, payload: .scalar(value))
    }

    public func message(_ payload: Sensorlog_V1_SensorSample.OneOf_Payload, tsMonoNs: Int64, tsWallMs: Int64, accuracy: Sensorlog_V1_Accuracy = .unspecified) {
        intake.push(slot: slot, tsMonoNs: tsMonoNs, tsWallMs: tsWallMs, accuracy: accuracy, payload: .message(payload))
    }

    public func event(_ kind: String, _ attributes: [String: String] = [:], tsMonoNs: Int64, tsWallMs: Int64) {
        var e = Sensorlog_V1_EventPayload()
        e.kind = kind
        e.attributes = attributes
        message(.event(e), tsMonoNs: tsMonoNs, tsWallMs: tsWallMs)
    }
}
