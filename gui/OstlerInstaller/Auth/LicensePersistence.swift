// LicensePersistence.swift
//
// Reads and writes the verified customer licence to disk at
// `~/.ostler/license/ostler-licence.json` (mode 0600). Hub
// services read this path at runtime to confirm the install is
// licensed.
//
// We deliberately persist AFTER `LicenseVerifier` returns `.valid`
// -- the file on disk is therefore always a previously-verified
// licence. We re-verify on every app launch anyway, because the
// embedded public key could rotate in a future installer release
// (rotation = recompiled .app + re-notarised = a new ship event;
// existing licences signed under the old key would correctly fail
// verification and prompt for a renewed copy).

import Foundation

enum LicensePersistenceError: Error {
    case homeNotResolvable
    case directoryCreate(Error)
    case write(Error)
}

struct LicensePersistence {
    /// Default on-disk location. Hub services read from this
    /// path during their own boot.
    static let defaultLicensePath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".ostler", isDirectory: true)
            .appendingPathComponent("license", isDirectory: true)
            .appendingPathComponent("ostler-licence.json")
    }()

    /// Read the on-disk licence file if it exists. Returns the raw
    /// bytes so the caller can run `LicenseVerifier.verify` on
    /// every launch (defence in depth -- never trust a "previously
    /// verified" flag in lieu of cryptographic verification).
    static func readExisting(at url: URL = defaultLicensePath) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Persist a freshly-verified licence to disk with restrictive
    /// permissions (owner read+write only). Creates the parent
    /// directory if it does not exist.
    static func write(licenseData: Data, to url: URL = defaultLicensePath) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw LicensePersistenceError.directoryCreate(error)
        }
        do {
            try licenseData.write(to: url, options: [.atomic])
            // Tighten file mode -- the atomic write may use the
            // default umask, so set 0600 explicitly afterwards.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw LicensePersistenceError.write(error)
        }
    }
}
