import Foundation
import CryptoKit

/// Integrity manifest written alongside the vCard backup (spec §3).
///
/// The Doctor confirm-route (a later step, NOT in this PR) verifies
/// `contactCount > 0` and that the .vcf parses back before unlocking any
/// write. Recording the SHA-256 + count here makes that a hard gate rather
/// than a convention.
public struct BackupManifest: Codable, Equatable {
    /// ISO-8601 instant the backup was taken.
    public let createdAt: String
    /// Number of unified contacts captured.
    public let contactCount: Int
    /// SHA-256 (lowercase hex) of the .vcf bytes.
    public let sha256: String
    /// Filename of the vCard (relative to the manifest), for self-description.
    public let vcardFilename: String
    /// Helper version that produced the backup.
    public let toolVersion: String

    public init(
        createdAt: String,
        contactCount: Int,
        sha256: String,
        vcardFilename: String,
        toolVersion: String
    ) {
        self.createdAt = createdAt
        self.contactCount = contactCount
        self.sha256 = sha256
        self.vcardFilename = vcardFilename
        self.toolVersion = toolVersion
    }

    /// Build a manifest from the raw vCard bytes + contact count.
    public static func make(
        vcardData: Data,
        contactCount: Int,
        createdAt: Date,
        vcardFilename: String,
        toolVersion: String
    ) -> BackupManifest {
        BackupManifest(
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            contactCount: contactCount,
            sha256: sha256Hex(of: vcardData),
            vcardFilename: vcardFilename,
            toolVersion: toolVersion)
    }

    /// Lowercase-hex SHA-256 of arbitrary bytes.
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Pretty-printed, stable-key JSON for writing to disk.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
