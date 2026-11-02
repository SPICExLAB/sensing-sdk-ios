import Foundation

/// A stable sensor id, `<group>.<name>` such as `motion.accelerometer`. It's the `sensor_id` on every sample, so an
/// id is permanent once data exists, and it means the same thing as on Android.
public struct SensorID: Hashable, Sendable, CustomStringConvertible, Codable {
    public let value: String

    /// Reserved, as on Android: health data is out of scope, and nothing may register here.
    public static let healthGroup = "health"

    public init?(_ value: String) {
        guard Self.isValid(value) else { return nil }
        self.value = value
    }

    /// For the ids this SDK declares itself: a bad one is a programming error.
    public init(known value: String) {
        precondition(Self.isValid(value), "bad sensor id \(value)")
        self.value = value
    }

    public var group: String { String(value.prefix { $0 != "." }) }
    public var description: String { value }

    /// Android's `[a-z]+(\.[a-z0-9_]+)+`, refusing the health group.
    static func isValid(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] != healthGroup[...] else { return false }
        guard parts[0].allSatisfy({ $0.isASCII && $0.isLowercase }), !parts[0].isEmpty else { return false }
        return parts.dropFirst().allSatisfy { p in
            !p.isEmpty && p.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
        }
    }
}
