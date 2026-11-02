import Foundation

/// Decides what to delete when storage is over quota. Pure, so the arithmetic and ordering are unit-tested.
///
/// Quota is the smaller of `hardCapBytes` and `freeFraction` of free space, never below `minQuotaBytes`. Deletion is
/// strictly oldest first across sensors. The same as Android, except that "oldest" here is wall time, because
/// `ts_mono_ns` resets at reboot.
public struct RetentionPolicy: Sendable {
    public static let defaultHardCap: Int64 = 2 * 1024 * 1024 * 1024
    public static let defaultFreeFraction = 0.10
    public static let minQuota: Int64 = 8 * 1024 * 1024

    public var hardCapBytes: Int64
    public var freeFraction: Double
    public var minQuotaBytes: Int64

    public init(hardCapBytes: Int64 = RetentionPolicy.defaultHardCap, freeFraction: Double = RetentionPolicy.defaultFreeFraction,
                minQuotaBytes: Int64 = RetentionPolicy.minQuota) {
        self.hardCapBytes = hardCapBytes
        self.freeFraction = freeFraction
        self.minQuotaBytes = minQuotaBytes
    }

    public func quotaBytes(freeBytes: Int64) -> Int64 {
        max(min(hardCapBytes, Int64(Double(freeBytes) * freeFraction)), minQuotaBytes)
    }

    /// The prefix of `candidates` (oldest first) whose removal brings `onDiskBytes` to or under the quota.
    public func select(onDiskBytes: Int64, freeBytes: Int64, candidates: [ChunkRecord]) -> [ChunkRecord] {
        var excess = onDiskBytes - quotaBytes(freeBytes: freeBytes)
        guard excess > 0 else { return [] }
        var out: [ChunkRecord] = []
        for candidate in candidates {
            guard excess > 0 else { break }
            out.append(candidate)
            excess -= candidate.bytes
        }
        return out
    }
}

/// What the store does at the quota. Android always deletes the oldest, which suits data already being uploaded. On a
/// device holding the only copy, that would silently cost someone an old recording, so the example app stops instead
/// (S-007).
public enum RetentionMode: Sendable {
    case stopWhenFull
    case evictOldest
}

/// One chunk removed by retention. It becomes a `device.storage_evicted` event with its seq range.
public struct EvictedChunk: Codable, Sendable, Equatable {
    public var chunkId: String
    public var sensorId: String
    public var firstSeq: Int64
    public var lastSeq: Int64
    public var bytes: Int64
    public var reason: String
}

/// Evictions not yet written to the stream. Persisted before the file goes, so a loss is always reported, even if the
/// engine is stopped or the process dies right after. Android's in-memory flow can lose them.
public final class EvictionOutbox {
    private let url: URL

    public init(root: StorageRoot) { url = root.state.appendingPathComponent("evictions.json") }

    public func pending() -> [EvictedChunk] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([EvictedChunk].self, from: data)) ?? []
    }

    public func append(_ evicted: [EvictedChunk]) throws {
        try write(pending() + evicted)
    }

    /// Call once the events are safely in a sealed chunk.
    public func remove(_ chunkIds: Set<String>) throws {
        try write(pending().filter { !chunkIds.contains($0.chunkId) })
    }

    private func write(_ items: [EvictedChunk]) throws {
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
        StorageRoot.protect(url)
    }
}
