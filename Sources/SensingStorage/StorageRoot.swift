import Foundation

/// Where everything lives, all excluded from backup:
///
///     <base>/sensing/identity.json
///     <base>/sensing/chunks/<session_id>/<sensor_id>_<first_seq>.pb.gz[.tmp]
///     <base>/sensing/chunks/<session_id>/<sensor_id>_<first_seq>.meta.json
///     <base>/sensing/incoming/     watch files awaiting verification on the phone
///     <base>/sensing/recordings/   one JSON file per recording
///     <base>/sensing/state/        outboxes and the active recording
public struct StorageRoot: Sendable {
    public let base: URL

    public init(parent: URL) throws {
        base = parent.appendingPathComponent("sensing", isDirectory: true)
        for dir in [base, chunks, incoming, recordings, state] { try Self.ensureDirectory(dir) }
        Self.excludeFromBackup(base)
    }

    /// Application Support, the default home.
    public static func standard() throws -> StorageRoot {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try StorageRoot(parent: support)
    }

    public var chunks: URL { base.appendingPathComponent("chunks", isDirectory: true) }
    public var incoming: URL { base.appendingPathComponent("incoming", isDirectory: true) }
    public var recordings: URL { base.appendingPathComponent("recordings", isDirectory: true) }
    public var state: URL { base.appendingPathComponent("state", isDirectory: true) }
    public func sessionDirectory(_ sessionId: String) -> URL { chunks.appendingPathComponent(sessionId, isDirectory: true) }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        protect(url)
    }

    /// Readable and writable after the first unlock, including while locked. `.complete` would fail while locked, and
    /// `.completeUnlessOpen` can't reopen a file to seal and hash it. No-op on macOS, where tests run.
    static func protect(_ url: URL) {
        #if !os(macOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    /// For other modules' files under this root.
    public static func protectFile(_ url: URL) { protect(url) }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}

public enum FreeSpace {
    /// Bytes free for this app on the volume holding `url`. iOS's raw free figure can be near zero while plenty is
    /// purgeable, which would wrongly shrink the quota, so it asks for important-usage capacity. watchOS doesn't have
    /// that API.
    public static func available(at url: URL) -> Int64 {
        #if os(watchOS)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
        #else
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
        #endif
    }
}
