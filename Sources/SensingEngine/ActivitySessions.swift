import Foundation
import SensingCore
import SensingStorage

/// An activity session: someone doing something for a while, with labels. Not the engine's collection session (`session_id`
/// on every sample), which restarts with the engine. Everything here is generic; what an activity is, with its questions
/// and its taxonomy id, is the app's.
public struct SessionSpec: Codable, Sendable, Equatable {
    public var sessionId: String
    /// Shown to the person, and on the watch.
    public var label: String
    /// The session ends by itself after this, so a forgotten one doesn't run all day.
    public var maxDurationMs: Int64
    /// `session_start` attributes besides id and times: config_id, config_version, module, taxonomy_version.
    public var startAttrs: [String: String]
    /// The session's own interval label (label_id, kind, taxonomy_id, …), opened at start and closed at the end. Empty for none.
    public var labelAttrs: [String: String]
    /// This device's sensors while it runs. They only add.
    public var sensors: [String: SensorOverride]
    /// The paired device's sensors.
    public var peerSensors: [String: SensorOverride]

    public init(sessionId: String, label: String, maxDurationMs: Int64, startAttrs: [String: String], labelAttrs: [String: String],
                sensors: [String: SensorOverride] = [:], peerSensors: [String: SensorOverride] = [:]) {
        self.sessionId = sessionId
        self.label = label
        self.maxDurationMs = maxDurationMs
        self.startAttrs = startAttrs
        self.labelAttrs = labelAttrs
        self.sensors = sensors
        self.peerSensors = peerSensors
    }
}

/// `mirrored`: a watch running the phone's session, with the same sensors and no events. The phone records the labels.
public struct ActiveSession: Codable, Sendable, Equatable {
    public var spec: SessionSpec
    public var startWallMs: Int64
    public var startMonoNs: Int64
    public var mirrored = false

    public var deadlineWallMs: Int64 { startWallMs + spec.maxDurationMs }

    public init(spec: SessionSpec, startWallMs: Int64, startMonoNs: Int64, mirrored: Bool = false) {
        self.spec = spec
        self.startWallMs = startWallMs
        self.startMonoNs = startMonoNs
        self.mirrored = mirrored
    }

    /// What the paired device needs to run the same session: its sensors and the limit.
    public func peerCopy(nowMonoNs: Int64) -> ActiveSession {
        ActiveSession(spec: SessionSpec(sessionId: spec.sessionId, label: spec.label, maxDurationMs: spec.maxDurationMs, startAttrs: [:], labelAttrs: [:],
                                        sensors: spec.peerSensors, peerSensors: [:]),
                      startWallMs: startWallMs, startMonoNs: nowMonoNs, mirrored: true)
    }
}

/// `endMonoNs` is nil when a reboot reset the monotonic clock in between. `answered`: nothing left to ask.
public struct EndedSession: Codable, Sendable, Equatable {
    public var session: ActiveSession
    public var endWallMs: Int64
    public var endMonoNs: Int64?
    public var reason: String
    public var answered: Bool

    public init(session: ActiveSession, endWallMs: Int64, endMonoNs: Int64?, reason: String, answered: Bool) {
        self.session = session
        self.endWallMs = endWallMs
        self.endMonoNs = endMonoNs
        self.reason = reason
        self.answered = answered
    }
}

public typealias SessionEvent = (kind: String, attrs: [String: String])

/// The events a session writes, with the attribute names the ingest reads. Pure.
public enum SessionEvents {
    public static func start(_ a: ActiveSession) -> [SessionEvent] {
        var start = a.spec.startAttrs.merging(times("start", a.startWallMs, a.startMonoNs)) { _, new in new }
        start["session_id"] = a.spec.sessionId
        var out: [SessionEvent] = [("session_start", start)]
        if !a.spec.labelAttrs.isEmpty { out.append(("label_upsert", openLabel(a))) }
        return out
    }

    public static func end(_ e: EndedSession, answers: [String: String]) -> [SessionEvent] {
        let spec = e.session.spec
        var out: [SessionEvent] = []
        if !spec.labelAttrs.isEmpty {
            if e.reason == ActivitySessions.discarded {
                out.append(("label_delete", ["session_id": spec.sessionId, "label_id": spec.labelAttrs["label_id"] ?? ""]))
            } else {
                out.append(("label_upsert", closedLabel(e, answers: answers)))
            }
        }
        var end = times("end", e.endWallMs, e.endMonoNs)
        end["session_id"] = spec.sessionId
        end["end_reason"] = e.reason
        out.append(("session_end", end))
        return out
    }

    public static func closedLabel(_ e: EndedSession, answers: [String: String]) -> [String: String] {
        var label = openLabel(e.session).merging(times("end", e.endWallMs, e.endMonoNs)) { _, new in new }
        for (key, value) in answers { label["attr.\(key)"] = value }
        return label
    }

    private static func openLabel(_ a: ActiveSession) -> [String: String] {
        var label = a.spec.labelAttrs.merging(times("start", a.startWallMs, a.startMonoNs)) { _, new in new }
        label["session_id"] = a.spec.sessionId
        return label
    }

    private static func times(_ prefix: String, _ wallMs: Int64, _ monoNs: Int64?) -> [String: String] {
        var out = ["\(prefix)_wall_ms": String(wallMs)]
        if let monoNs { out["\(prefix)_mono_ns"] = String(monoNs) }
        return out
    }
}

/// Labels are the product, so their events mustn't be lost on the way in. The engine refuses an event while stopped, and a
/// written event sits in a batch for up to 2 s before it reaches the chunk file. So an entry stays until this process wrote
/// it 30 s ago, or until the chunk holding it sealed; a process that dies first leaves it to the next one. Writing twice is
/// harmless: the ingest's projection is idempotent and keeps the newest edit.
struct LabelOutbox {
    struct Entry: Codable, Equatable {
        var id: String
        var kind: String
        var attrs: [String: String]
        var emittedBy = ""
        var emittedAtMonoMs: Int64 = 0
    }

    static let keepMs: Int64 = 30_000

    let processId: String
    private(set) var entries: [Entry]

    init(processId: String, entries: [Entry] = []) {
        self.processId = processId
        self.entries = entries
    }

    mutating func add(_ events: [SessionEvent]) {
        entries += events.map { Entry(id: UUID().uuidString.lowercased(), kind: $0.kind, attrs: $0.attrs) }
    }

    /// In order. A dead process's writes count as not written.
    func due() -> [Entry] { entries.filter { $0.emittedBy != processId } }

    mutating func markEmitted(_ ids: Set<String>, nowMonoMs: Int64) {
        for i in entries.indices where ids.contains(entries[i].id) {
            entries[i].emittedBy = processId
            entries[i].emittedAtMonoMs = nowMonoMs
        }
    }

    mutating func prune(nowMonoMs: Int64) {
        entries.removeAll { $0.emittedBy == processId && nowMonoMs - $0.emittedAtMonoMs >= Self.keepMs }
    }

    /// The chunk holding everything written so far has sealed, so nothing written by this process can be lost.
    mutating func pruneAllEmitted() {
        entries.removeAll { $0.emittedBy == processId }
    }
}

/// The running activity session, persisted so it survives process death. The app starts and stops it; whoever owns the
/// engine calls `flush` to write the due events into the stream. Thread-safe.
public final class ActivitySessions: @unchecked Sendable {
    public static let stopped = "stopped"
    public static let timeLimit = "time_limit"
    public static let discarded = "discarded"

    public enum SessionError: Error, Equatable {
        case alreadyRunning
    }

    private struct Persisted: Codable {
        var active: ActiveSession?
        var lastEnded: EndedSession?
        var outbox: [LabelOutbox.Entry] = []
    }

    private let url: URL
    private let clock: any EngineClock
    private let lock = NSLock()
    private var currentActive: ActiveSession?
    private var currentLastEnded: EndedSession?
    private var outbox: LabelOutbox

    public init(root: StorageRoot, clock: any EngineClock = SystemClock()) {
        url = root.state.appendingPathComponent("activity_session.json")
        self.clock = clock
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) } ?? Persisted()
        currentActive = stored.active
        currentLastEnded = stored.lastEnded
        outbox = LabelOutbox(processId: UUID().uuidString.lowercased(), entries: stored.outbox)
    }

    public var active: ActiveSession? { lock.withLock { currentActive } }
    /// The last session to end, so the app can ask its questions when it ended on its own.
    public var lastEnded: EndedSession? { lock.withLock { currentLastEnded } }
    public var pendingEvents: Int64 { lock.withLock { Int64(outbox.entries.count) } }

    /// Starts `spec` now. Refused while another runs: one at a time.
    @discardableResult
    public func start(_ spec: SessionSpec) throws -> ActiveSession {
        try lock.withLock {
            guard currentActive == nil else { throw SessionError.alreadyRunning }
            let a = ActiveSession(spec: spec, startWallMs: clock.wallMs(), startMonoNs: clock.monoNs())
            outbox.add(SessionEvents.start(a))
            currentActive = a
            persist()
            return a
        }
    }

    /// Ends the session now. `answers` become attributes of its label (`attr.<key>`).
    public func stop(answers: [String: String] = [:]) {
        end(reason: Self.stopped, answers: answers, wallMs: clock.wallMs(), monoNs: clock.monoNs())
    }

    /// Ends it and deletes its label: it was started by mistake.
    public func discard() {
        end(reason: Self.discarded, answers: [:], wallMs: clock.wallMs(), monoNs: clock.monoNs())
    }

    /// A session past its limit ends at its deadline, also if the process died meanwhile. Returns whether it did.
    @discardableResult
    public func expireIfDue() -> Bool {
        guard let a = active, clock.wallMs() >= a.deadlineWallMs else { return false }
        let endMono = a.startMonoNs + a.spec.maxDurationMs * 1_000_000
        end(reason: Self.timeLimit, answers: [:], wallMs: a.deadlineWallMs, monoNs: endMono <= clock.monoNs() ? endMono : nil)
        return true
    }

    /// Answers given after the session ended on its own: its label is written again with them.
    public func answerLast(_ answers: [String: String]) {
        closeLast { e in
            if !e.session.spec.labelAttrs.isEmpty, !answers.isEmpty {
                outbox.add([("label_upsert", SessionEvents.closedLabel(e, answers: answers))])
            }
        }
    }

    /// The person chose not to answer.
    public func skipLast() { closeLast { _ in } }

    /// Watch: the phone's session, or nil when it ended. Its sensors run here too; labels are the phone's to record.
    public func mirror(_ incoming: ActiveSession?) {
        lock.withLock {
            guard incoming?.spec.sessionId != currentActive?.spec.sessionId else { return }
            if let cur = currentActive, !cur.mirrored { return }  // a session of this device's own is never replaced
            currentActive = incoming
            persist()
        }
    }

    /// Writes the due events into the stream, in order, stopping at the first one the engine refuses because it's stopped.
    /// Returns how many were written.
    @discardableResult
    public func flush(emit: (String, [String: String]) async -> Bool) async -> Int64 {
        let due: [LabelOutbox.Entry] = lock.withLock {
            outbox.prune(nowMonoMs: clock.monoNs() / 1_000_000)
            persist()
            return outbox.due()
        }
        var written: Set<String> = []
        for entry in due {
            guard await emit(entry.kind, entry.attrs) else { break }
            written.insert(entry.id)
        }
        if !written.isEmpty {
            lock.withLock {
                outbox.markEmitted(written, nowMonoMs: clock.monoNs() / 1_000_000)
                persist()
            }
        }
        return Int64(written.count)
    }

    /// Call after the engine sealed its chunks: everything written so far is safe.
    public func chunksSealed() {
        lock.withLock {
            outbox.pruneAllEmitted()
            persist()
        }
    }

    private func end(reason: String, answers: [String: String], wallMs: Int64, monoNs: Int64?) {
        lock.withLock {
            guard let a = currentActive else { return }
            let answered = reason != Self.timeLimit
            let e = EndedSession(session: a, endWallMs: wallMs, endMonoNs: monoNs, reason: reason, answered: answered)
            if !a.mirrored { outbox.add(SessionEvents.end(e, answers: answers)) }
            currentActive = nil
            currentLastEnded = e
            persist()
        }
    }

    private func closeLast(_ write: (EndedSession) -> Void) {
        lock.withLock {
            guard var e = currentLastEnded, !e.answered else { return }
            write(e)
            e.answered = true
            currentLastEnded = e
            persist()
        }
    }

    private func persist() {
        let state = Persisted(active: currentActive, lastEnded: currentLastEnded, outbox: outbox.entries)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        StorageRoot.protectFile(url)
    }
}
