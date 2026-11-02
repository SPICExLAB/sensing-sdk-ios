import Foundation
import SensingCore
import SensingProto
import SensingStorage
import XCTest
@testable import SensingEngine

/// A real process recording at full rate with the real timer, killed with SIGKILL the way iOS would kill the app. Nothing
/// gets to clean up, so this is what A7 asks of the phone: every .tmp recovered, and at most about 3 s lost.
final class ProcessKillTests: XCTestCase {
    private func writerBinary() throws -> URL {
        var dir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("sensing-compat")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let built = dir.appendingPathComponent(".build/debug/sensing-compat")
        guard FileManager.default.isExecutableFile(atPath: built.path) else {
            throw XCTSkip("run `swift build` first: no sensing-compat at \(built.path)")
        }
        return built
    }

    func testKilledAtFullRateNothingBeforeTheLastSecondsIsLost() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sensing-kill-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }

        let process = Process()
        process.executableURL = try writerBinary()
        process.arguments = ["writer", parent.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        addTeardownBlock { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        // Waits until it has really begun.
        _ = out.fileHandleForReading.availableData

        try await Task.sleep(for: .seconds(5))
        let killedAtMono = Clock.monoNs()
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)

        let root = try StorageRoot(parent: parent)
        let engine = CollectionEngine(root: root, deviceId: "d")
        let result = await engine.recover()
        XCTAssertGreaterThan(result.sealed, 0, "the open chunks were recovered")
        let tmps = FileManager.default.enumerator(at: root.chunks, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix(ChunkWriter.tmpSuffix) } ?? []
        XCTAssertTrue(tmps.isEmpty, "no .tmp left behind")

        let all = try samples(in: root)
        for i in 0..<8 {
            let stream = all.stream("motion.stream\(i)")
            // A batch reaches the file every 2 to 2.5 s, so one or two have landed by now. The count alone proves little:
            // what matters is that there are no holes and that the loss is bounded.
            XCTAssertGreaterThan(stream.count, 100, "motion.stream\(i)")
            XCTAssertEqual(stream.map(\.seq), (0..<UInt64(stream.count)).map { $0 }, "motion.stream\(i): contiguous from 0, no holes or duplicates")
            let lost = Double(killedAtMono - (stream.last?.tsMonoNs ?? 0)) / 1e9
            XCTAssertLessThan(lost, 3.0, "motion.stream\(i): \(lost) s before the kill was lost")
        }
        XCTAssertEqual(all.events("device.session", "start").count, 1)
        XCTAssertEqual(all.stream("label.session").first?.event.kind, "session_start", "written more than 2 s before the kill, so it reached the file")

        // The next process finds the session still open, and writes its events again in case: the ingest's projection doesn't mind.
        let sessions = ActivitySessions(root: root)
        XCTAssertNotNil(sessions.active)
        XCTAssertEqual(sessions.pendingEvents, 2)
    }
}
