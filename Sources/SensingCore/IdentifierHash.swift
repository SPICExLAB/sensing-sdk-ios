import CryptoKit
import Foundation

/// Scanned identifiers never leave the device in the clear. It's SHA-256 over `<salt>:<lowercased id>`, truncated to
/// 16 hex characters, the same as Android's `IdentifierHash`: an id hashes the same on one device across days, and to
/// something unrelated on another.
public struct IdentifierHash: Sendable {
    private let salt: String

    public init(salt: String) { self.salt = salt }

    public func hash(_ identifier: String) -> String {
        let digest = SHA256.hash(data: Data("\(salt):\(identifier.lowercased())".utf8))
        return digest.prefix(8).map { hex2($0) }.joined()
    }
}

/// A byte as two lower-case hex characters, with no locale involved.
@inline(__always) func hex2(_ b: UInt8) -> String {
    let digits = Array("0123456789abcdef")
    return String([digits[numericCast(b >> 4)], digits[numericCast(b & 0x0f)]])
}

public enum Hex {
    /// Bytes as lower-case hex, with no locale involved.
    public static func lower<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { hex2($0) }.joined()
    }
}
