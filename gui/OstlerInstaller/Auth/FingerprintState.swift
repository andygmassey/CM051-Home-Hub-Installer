// FingerprintState.swift
//
// On-disk state for the device-registration flow, living alongside the
// licence directory under ~/.ostler/.
//
// Three files:
//
//   ~/.ostler/state/fingerprint.txt
//       Single line: the Mac's fingerprint as returned by
//       HardwareFingerprint.compute(). Present once registration has
//       succeeded against the Worker. Read on subsequent installer
//       launches so we do not re-POST a registration we already know
//       is in the Worker's set.
//
//   ~/.ostler/state/pending_registration.json
//       {"license_id": "...", "fingerprint": "...", "queued_at": "..."}
//       Written when register-device fails with a network error during
//       install. The Hub-side deferred-register script picks this up
//       from ~/.ostler/bin/deferred-register-device.sh on a launchd
//       cadence and retries until it succeeds. On 200 the file is
//       deleted; on 409 it is also deleted and a separate warning
//       state file is written for the Doctor surface to read.
//
//   ~/.ostler/state/registration_warning.txt
//       Written by the deferred-register script if the deferred attempt
//       hits 409 (cap reached after the install proceeded fail-open).
//       Read by HR015's Doctor tab to surface a banner.
//
// Mode is 0600 on files, 0700 on the directory, matching the licence
// persistence side. The state dir is sibling to ~/.ostler/license/ on
// purpose -- enforcement state is not licence content and should not
// move when we rotate the licence persistence format.

import Foundation

enum FingerprintStateError: Error {
    case homeNotResolvable
    case directoryCreate(Error)
    case write(Error)
    case encode(Error)
}

struct FingerprintState {

    /// Directory under the user's home that holds the fingerprint cache
    /// and the pending-registration queue.
    static let stateDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".ostler", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
    }()

    static let fingerprintCachePath: URL =
        stateDir.appendingPathComponent("fingerprint.txt")

    static let pendingRegistrationPath: URL =
        stateDir.appendingPathComponent("pending_registration.json")

    // MARK: - Cache (post-success)

    /// Returns the cached fingerprint, or nil if registration has not
    /// completed on this machine yet.
    static func cachedFingerprint(
        at url: URL = fingerprintCachePath
    ) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Persist the fingerprint after the Worker has acknowledged it.
    /// The installer reads this back on subsequent launches to avoid
    /// re-POSTing a registration we already know is recorded.
    static func writeCachedFingerprint(
        _ fingerprint: String,
        to url: URL = fingerprintCachePath
    ) throws {
        try ensureDirectory(parent: url.deletingLastPathComponent())
        let data = Data((fingerprint + "\n").utf8)
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw FingerprintStateError.write(error)
        }
    }

    // MARK: - Pending queue (fail-open deferred retry)

    struct PendingRegistration: Codable, Equatable {
        let licenseId: String
        let fingerprint: String
        let queuedAt: String  // ISO-8601 UTC

        enum CodingKeys: String, CodingKey {
            case licenseId = "license_id"
            case fingerprint
            case queuedAt = "queued_at"
        }
    }

    /// Read the pending-registration queue, if any. Returns nil if the
    /// file does not exist or fails to parse (a corrupt queue entry is
    /// treated as "no pending" -- worst case the customer's Mac never
    /// registers and a future support touch will fix it; better than
    /// a permanent boot loop).
    static func readPending(
        at url: URL = pendingRegistrationPath
    ) -> PendingRegistration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingRegistration.self, from: data)
    }

    /// Queue a registration for later retry by the Hub-side scheduler.
    /// Called when the install-time POST hits a network failure -- the
    /// install proceeds (fail-open policy) and the Hub picks the queue
    /// up at next launch.
    static func writePending(
        licenseId: String,
        fingerprint: String,
        at url: URL = pendingRegistrationPath,
        clock: () -> Date = Date.init
    ) throws {
        try ensureDirectory(parent: url.deletingLastPathComponent())
        let queuedAt = isoFormatter.string(from: clock())
        let entry = PendingRegistration(
            licenseId: licenseId,
            fingerprint: fingerprint,
            queuedAt: queuedAt
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(entry)
        } catch {
            throw FingerprintStateError.encode(error)
        }
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw FingerprintStateError.write(error)
        }
    }

    /// Remove the pending queue once a registration has resolved. Safe
    /// to call when the file does not exist.
    static func clearPending(at url: URL = pendingRegistrationPath) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    private static func ensureDirectory(parent: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FingerprintStateError.directoryCreate(error)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
