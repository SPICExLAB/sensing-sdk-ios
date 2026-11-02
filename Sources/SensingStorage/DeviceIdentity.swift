import Foundation

/// This install's `device_id`: a lower-case UUID that lasts until the app is reinstalled, as on Android. It also salts
/// the identifier hash, so scanned ids hash differently on every install.
public enum DeviceIdentity {
    private struct Stored: Codable {
        var deviceId: String
    }

    public static func load(root: StorageRoot) throws -> String {
        let url = root.base.appendingPathComponent("identity.json")
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data), !stored.deviceId.isEmpty {
            return stored.deviceId
        }
        let id = UUID().uuidString.lowercased()
        try JSONEncoder().encode(Stored(deviceId: id)).write(to: url, options: .atomic)
        StorageRoot.protect(url)
        return id
    }
}
