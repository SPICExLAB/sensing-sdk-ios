import Foundation
import SensingCore
import SensingStorage

/// The phone's side of a chunk transfer. A received file is moved into `incoming/` at once, with its metadata beside it, so
/// it survives a crash; `drain` then verifies each file off the delegate's thread and moves it into place. The answer for a
/// chunk it has already taken is the same `ok`, so a resend after a lost ack can't make a duplicate.
public final class ChunkReceiver: @unchecked Sendable {
    public struct Processed: Sendable, Equatable {
        public var ack: ChunkAck
        /// Set when the chunk is new here: the store needs to know about it.
        public var adopted: ChunkRecord?
    }

    private let root: StorageRoot
    private let queue = DispatchQueue(label: "sensing.link.receiver", qos: .utility)
    /// A pair of files appears whole: `drain` must never see metadata whose chunk is still on its way, or it would take it for
    /// what a crash left and delete it.
    private let lock = NSLock()

    public init(root: StorageRoot) { self.root = root }

    /// Call before the delegate returns.
    @discardableResult
    public func accept(file: URL, metadata: Data) -> Bool {
        let id = UUID().uuidString.lowercased()
        let meta = root.incoming.appendingPathComponent("\(id).json")
        let chunk = root.incoming.appendingPathComponent("\(id)\(ChunkWriter.finalSuffix)")
        return lock.withLock {
            do {
                // Metadata first: a chunk with no metadata beside it could never be identified or acked.
                try metadata.write(to: meta, options: .atomic)
                try FileManager.default.moveItem(at: file, to: chunk)
                StorageRoot.protectFile(meta)
                StorageRoot.protectFile(chunk)
                return true
            } catch {
                try? FileManager.default.removeItem(at: meta)
                return false
            }
        }
    }

    /// Everything waiting, including what a crash left. `deliver` is called once per file, off the main thread.
    public func drain(_ deliver: @escaping @Sendable (Processed) -> Void) {
        queue.async { [self] in
            let names = lock.withLock { (try? FileManager.default.contentsOfDirectory(at: root.incoming, includingPropertiesForKeys: nil)) ?? [] }
            for meta in names where meta.pathExtension == "json" {
                let chunk = root.incoming.appendingPathComponent(meta.deletingPathExtension().lastPathComponent + ChunkWriter.finalSuffix)
                guard FileManager.default.fileExists(atPath: chunk.path) else {
                    // A crash between the two writes. The watch still has the chunk, and resends when no ack comes.
                    try? FileManager.default.removeItem(at: meta)
                    continue
                }
                if let processed = process(chunk: chunk, meta: meta) { deliver(processed) }
                try? FileManager.default.removeItem(at: chunk)
                try? FileManager.default.removeItem(at: meta)
            }
        }
    }

    private func process(chunk: URL, meta: URL) -> Processed? {
        guard let data = try? Data(contentsOf: meta), let record = try? JSONDecoder().decode(ChunkRecord.self, from: data) else { return nil }
        let id = record.chunkId
        // These become a path, and they came from another device.
        guard let session = UUID(uuidString: record.sessionId), session.uuidString.lowercased() == record.sessionId,
              SensorID(record.sensorId) != nil, record.firstSeq >= 0,
              id == ChunkRecord.id(session: record.sessionId, sensor: record.sensorId, firstSeq: record.firstSeq) else {
            return Processed(ack: .bad(id, "invalid"))
        }
        guard ChunkFiles.size(of: chunk) == record.bytes else { return Processed(ack: .bad(id, "size")) }
        guard let sha = try? ChunkFiles.sha256(of: chunk), sha == record.sha256 else { return Processed(ack: .bad(id, "sha")) }

        let directory = root.sessionDirectory(record.sessionId)
        let destination = directory.appendingPathComponent("\(record.sensorId)_\(record.firstSeq)\(ChunkWriter.finalSuffix)")
        if FileManager.default.fileExists(atPath: destination.path) {
            let same = (try? ChunkFiles.sha256(of: destination)) == sha
            return Processed(ack: same ? ChunkAck(chunkId: id, result: ChunkAck.ok) : .bad(id, "conflict"))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: chunk, to: destination)
            // A crash here leaves a chunk with no record, which startup recovery rebuilds. The watch gets no ack and resends.
            try ChunkFiles.writeRecord(record, for: destination)
        } catch {
            return Processed(ack: .bad(id, "write"))
        }
        return Processed(ack: ChunkAck(chunkId: id, result: ChunkAck.ok), adopted: record)
    }
}
