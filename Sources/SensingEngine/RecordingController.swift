import Foundation
import SensingCore
import SensingStorage

/// What a person chose to record.
public struct RecordingSpec: Sendable, Equatable {
    public var id: String
    public var label: String
    /// It ends by itself after this, so a forgotten one doesn't run all day.
    public var maxDurationMs: Int64
    /// `session_start` attributes, e.g. config_id, module, taxonomy_version.
    public var startAttrs: [String: String]
    /// The session's interval label: label_id, kind, taxonomy_id, taxonomy_version, source, confidence. Empty for none.
    public var labelAttrs: [String: String]

    public static let defaultMaxDurationMs: Int64 = 8 * 60 * 60 * 1000

    public init(id: String = UUID().uuidString.lowercased(), label: String, maxDurationMs: Int64 = RecordingSpec.defaultMaxDurationMs,
                startAttrs: [String: String] = [:], labelAttrs: [String: String] = [:]) {
        self.id = id
        self.label = label
        self.maxDurationMs = maxDurationMs
        self.startAttrs = startAttrs
        self.labelAttrs = labelAttrs
    }
}

public struct RecordingSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var taxonomyId: String?
    public var startWallMs: Int64
    public var endWallMs: Int64?
    public var endReason: String?
    /// Engine sessions on this device, in order. Normally one.
    public var engineSessions: [String]

    public init(id: String, label: String, taxonomyId: String?, startWallMs: Int64, endWallMs: Int64? = nil, endReason: String? = nil, engineSessions: [String] = []) {
        self.id = id
        self.label = label
        self.taxonomyId = taxonomyId
        self.startWallMs = startWallMs
        self.endWallMs = endWallMs
        self.endReason = endReason
        self.engineSessions = engineSessions
    }
}

/// One JSON file per recording. A recording with no end is the one running, or the one a dead process left behind.
public final class RecordingStore: @unchecked Sendable {
    private let directory: URL

    public init(root: StorageRoot) { directory = root.recordings }

    public func all() -> [RecordingSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(RecordingSummary.self, from: $0) } }
            .sorted { $0.startWallMs > $1.startWallMs }
    }

    public var unfinished: RecordingSummary? { all().first { $0.endWallMs == nil } }

    public func save(_ r: RecordingSummary) throws {
        let url = directory.appendingPathComponent("\(r.id).json")
        try JSONEncoder().encode(r).write(to: url, options: .atomic)
        StorageRoot.protectFile(url)
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }
}

/// What a device says about itself on `device.session start`: the envelope has no field for the platform.
public struct DeviceDescription: Sendable, Equatable {
    public var platform: String
    public var model: String
    public var os: String
    public var appVersion: String
    public var sdkVersion: String

    public init(platform: String, model: String, os: String, appVersion: String, sdkVersion: String) {
        self.platform = platform
        self.model = model
        self.os = os
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
    }

    var attributes: [String: String] {
        ["platform": platform, "model": model, "os": os, "app_version": appVersion, "sdk_version": sdkVersion]
    }
}

/// Start, stop and recovery, with no platform code in it, so the whole flow is tested on macOS with fake sensors. The
/// platform's facade adds what keeps the device awake.
@MainActor
public final class RecordingController {
    public enum State: Sendable, Equatable {
        case stopped
        case recording
    }

    public enum ControllerError: Error, Equatable {
        case alreadyRecording
    }

    public private(set) var state = State.stopped
    public private(set) var current: RecordingSummary?
    public var overrides: [SensorID: SensorOverride] = [:]
    /// The recording ended without being asked to: its reason, such as a full disk or the time limit.
    public var onEnded: ((RecordingSummary) -> Void)?

    public let engine: CollectionEngine
    public let sessions: ActivitySessions
    public let recordings: RecordingStore

    private let clock: any EngineClock
    private let catalog: [CatalogEntry]
    private let adapters: [any SensorAdapter]
    private let device: DeviceDescription
    private let commands = CommandQueue()

    public init(root: StorageRoot, deviceId: String, catalog: [CatalogEntry], adapters: [any SensorAdapter], device: DeviceDescription,
                clock: any EngineClock = SystemClock(), options: CollectionEngine.Options = CollectionEngine.Options()) {
        self.clock = clock
        self.catalog = catalog
        self.adapters = adapters
        self.device = device
        sessions = ActivitySessions(root: root, clock: clock)
        recordings = RecordingStore(root: root)
        let box = StopRelay()
        engine = CollectionEngine(root: root, deviceId: deviceId, clock: clock, options: options) { reason in box.fire(reason) }
        box.handler = { [weak self] reason in
            Task { @MainActor in await self?.engineStoppedItself(reason) }
        }
    }

    public func effectiveConfig() -> CollectionConfig {
        CollectionConfig.resolve(catalog: catalog, overrides: overrides)
    }

    /// At launch: seals what a dead process left, and ends its recording. A crash ends the recording rather than resuming it
    /// (S-011). A short session writes what's owed, since no engine is running to write it.
    public func recover() async {
        try? await commands.run { [self] in await recoverNow() }
    }

    @discardableResult
    public func start(_ spec: RecordingSpec) async throws -> RecordingSummary {
        try await commands.run { [self] in try await startNow(spec) }
    }

    public func stop(answers: [String: String] = [:], reason: String = "user_stop") async {
        try? await commands.run { [self] in await stopNow(answers: answers, reason: reason, discard: false) }
    }

    /// Ends it and deletes its label: it was started by mistake. The sensor data stays.
    public func discard() async {
        try? await commands.run { [self] in await stopNow(answers: [:], reason: "discarded", discard: true) }
    }

    /// Call about once a second while recording: the time limit, and label events still owed.
    public func tick() async {
        try? await commands.run { [self] in
            guard state == .recording else { return }
            if sessions.expireIfDue() {
                await finish(reason: ActivitySessions.timeLimit)
                return
            }
            await flushLabels()
        }
    }

    // MARK: - The commands

    private func startNow(_ spec: RecordingSpec) async throws -> RecordingSummary {
        guard state == .stopped else { throw ControllerError.alreadyRecording }
        let session = SessionSpec(sessionId: spec.id, label: spec.label, maxDurationMs: spec.maxDurationMs, startAttrs: spec.startAttrs, labelAttrs: spec.labelAttrs)
        try sessions.start(session)
        var attrs = device.attributes
        attrs["activity_session_id"] = spec.id
        var summary = RecordingSummary(id: spec.id, label: spec.label, taxonomyId: spec.labelAttrs["taxonomy_id"], startWallMs: clock.wallMs())
        try recordings.save(summary)  // first, so a crash from here on is recovered
        let engineSession = await engine.start(effectiveConfig(), adapters: adapters, attrs: attrs)
        if let engineSession { summary.engineSessions.append(engineSession) }
        try recordings.save(summary)
        current = summary
        state = .recording
        await flushLabels()
        return summary
    }

    private func stopNow(answers: [String: String], reason: String, discard: Bool) async {
        guard state == .recording else { return }
        if discard { sessions.discard() } else { sessions.stop(answers: answers) }
        await finish(reason: reason)
    }

    /// The session has ended, or is about to be: write what's owed, stop, and close the books.
    private func finish(reason: String) async {
        await flushLabels()
        await engine.stop(reason: reason)
        sessions.chunksSealed()
        state = .stopped
        guard var summary = current else { return }
        summary.endWallMs = clock.wallMs()
        summary.endReason = reason
        try? recordings.save(summary)
        current = nil
        onEnded?(summary)
    }

    private func flushLabels() async {
        let engine = engine
        await sessions.flush { kind, attrs in await engine.emit(SensorIDs.label, kind, attrs) }
    }

    private func engineStoppedItself(_ reason: String) async {
        try? await commands.run { [self] in
            guard state == .recording else { return }
            // The engine has already stopped and sealed. Labels written from here wait in the outbox for the next session.
            sessions.stop()
            state = .stopped
            guard var summary = current else { return }
            summary.endWallMs = clock.wallMs()
            summary.endReason = reason
            try? recordings.save(summary)
            current = nil
            onEnded?(summary)
        }
    }

    private func recoverNow() async {
        await engine.recover()
        let dead = recordings.unfinished
        if let dead, sessions.active != nil {
            let chunks = await engine.chunks().filter { dead.engineSessions.contains($0.sessionId) }
            let lastWall = chunks.map(\.lastWallMs).max() ?? dead.startWallMs
            let lastMono = chunks.map(\.lastTsMono).max()
            sessions.endAfterProcessDeath(wallMs: lastWall, monoNs: lastMono)
        }
        guard dead != nil || sessions.pendingEvents > 0 else { return }
        var attrs = device.attributes
        if let dead { attrs["activity_session_id"] = dead.id }
        await engine.start(CollectionConfig(sensors: [:]), adapters: [], reason: "recovery", attrs: attrs)
        if let dead {
            await engine.emit(SensorIDs.gap, "process_death", ["recording_id": dead.id, "from_wall_ms": String(lastWall(dead, await engine.chunks())), "to_wall_ms": String(clock.wallMs())])
        }
        await flushLabels()
        await engine.stop(reason: "recovery_done")
        sessions.chunksSealed()
        if var dead {
            let chunks = await engine.chunks().filter { dead.engineSessions.contains($0.sessionId) }
            dead.endWallMs = chunks.map(\.lastWallMs).max() ?? dead.startWallMs
            dead.endReason = "process_died"
            try? recordings.save(dead)
        }
    }

    private func lastWall(_ dead: RecordingSummary, _ chunks: [ChunkRecord]) -> Int64 {
        chunks.filter { dead.engineSessions.contains($0.sessionId) }.map(\.lastWallMs).max() ?? dead.startWallMs
    }
}

/// Lets the engine's stop callback reach the controller it's created before.
private final class StopRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (String) -> Void)?

    var handler: (@Sendable (String) -> Void)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func fire(_ reason: String) { handler?(reason) }
}
