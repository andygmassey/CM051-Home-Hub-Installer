// LicensePersistence.swift
//
// Reads and writes the verified customer licence to disk at the
// canonical engine-zone path `~/.ostler/license/license.json`
// (mode 0600, parent dir 0700). Hub services (the Sparkle
// auto-update delegate in ostler-assistant, future Doctor
// introspection, the Hub gateway) read this path at runtime to
// confirm the install is licensed.
//
// Engine-zone vs customer surface naming:
//   - The customer-facing file (the email attachment, the drop
//     zone hint, the welcome page download) is named
//     `ostler-licence.json`. That string is preserved in the
//     customer-rendered copy at gui/OstlerInstaller/Resources/
//     ViewCopy.json so the customer sees the same filename
//     they downloaded.
//   - On disk, after verification, we rename to `license.json`
//     so the engine-zone canonical path matches the contract
//     read by ostler-assistant PR #49's Sparkle delegate and any
//     future service that wants a single source of truth.
//
// We deliberately persist AFTER `LicenseVerifier` returns `.valid`
// -- the file on disk is therefore always a previously-verified
// licence. We re-verify on every app launch anyway, because the
// embedded public key could rotate in a future installer release
// (rotation = recompiled .app + re-notarised = a new ship event;
// existing licences signed under the old key would correctly fail
// verification and prompt for a renewed copy).
//
// Atomic write contract:
//   1. Write payload to a `.tmp.<uuid>` sibling inside the same
//      directory (must be on the same filesystem for rename to be
//      atomic).
//   2. `fsync` the file descriptor so payload bytes are durable
//      before the rename.
//   3. `rename(2)` the temp file onto the final path. On macOS
//      this is an atomic directory-entry swap.
//   4. `fsync` the parent directory so the new entry is durable
//      even across a power loss immediately after rename.
//   5. Read the final mode back and refuse if it is not 0600.
//   6. On any failure, unlink the temp sibling so a partial write
//      is never left behind for a future re-install to confuse
//      itself over.
//
// 🔴 STEP 3 USED TO BE `FileManager.replaceItem`, AND THAT IS WHY
// THE 0600 IN THE HEADER ABOVE WAS A CLAIM RATHER THAN A FACT.
// `replaceItem` exists to replace a DOCUMENT, so it deliberately
// carries the ORIGINAL item's metadata onto the replacement --
// including its POSIX mode. The temp sibling is chmodded to 0600
// before the swap, and on a re-install `replaceItem` threw that
// away and restored whatever mode the destination already had.
//
// MEASURED, three cases, one standalone program mirroring this
// function, on the Swift 6.3.3 toolchain shipped with macOS 26:
//
//     destination ABSENT, temp 0600, replaceItem  -> final 600
//     destination 0644,   temp 0600, replaceItem  -> final 644   <- the defect
//     destination 0644,   temp 0600, rename(2)    -> final 600   <- the fix
//
// The first row is why LicensePersistenceTests' original
// `testWriteSetsFileMode0600` passed for the life of the file: it
// only ever wrote to a fresh path, which is the ONE case
// `replaceItem` gets right. The overwrite case is not exotic --
// it is every re-install, and it is also every customer who
// followed the installer's own `cp ~/Downloads/...` instruction
// (default umask, 0644) and then ran the app.
//
// What is in this file matters: `issued_to_email` and
// `stripe_payment_id` are both required v1 licence fields, so a
// world-readable licence hands every other local account the
// customer's email address and the id of their payment.
//
// `rename(2)` has no such metadata rule: it swaps a directory
// entry, and the inode that lands is the temp file's, mode and
// all. It is also exactly what the comment above already claimed
// step 3 did. Do NOT "modernise" this back to replaceItem.

import Darwin
import Foundation

enum LicensePersistenceError: Error {
    case homeNotResolvable
    case directoryCreate(Error)
    case write(Error)
    /// The file landed but its mode is not 0600. Raised rather than
    /// logged: a licence carrying the customer's email address and
    /// Stripe payment id must not sit readable by other local
    /// accounts, and a caller that swallows this would be right back
    /// to the silent 0644 this case was added to stop.
    case modeNotRestricted(path: String, mode: UInt16)
}

struct LicensePersistence {
    /// Default on-disk location. Hub services read from this
    /// path during their own boot.
    static let defaultLicensePath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".ostler", isDirectory: true)
            .appendingPathComponent("license", isDirectory: true)
            .appendingPathComponent("license.json")
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
    /// directory if it does not exist. Uses an explicit
    /// tmp + fsync + rename + parent-fsync sequence so a power
    /// loss between any two steps leaves either the old file or
    /// the new file -- never a partially-written one.
    ///
    /// On re-install (file already present), the rename overwrites
    /// the previous contents and a `license_persist_overwrite` log
    /// line is emitted so the audit trail records the replacement.
    /// Customer is paying again or replacing a corrupt install --
    /// both legitimate paths.
    static func write(licenseData: Data, to url: URL = defaultLicensePath) throws {
        guard !licenseData.isEmpty else {
            // Defence in depth -- verifier should have rejected this.
            throw LicensePersistenceError.write(
                NSError(
                    domain: "LicensePersistence",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "refusing to persist empty licence payload"]
                )
            )
        }

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

        // Tighten the parent directory mode in case it pre-existed
        // with a more permissive mode (createDirectory only sets
        // attributes when it creates).
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )

        let willOverwrite = FileManager.default.fileExists(atPath: url.path)

        let tmpURL = parent.appendingPathComponent(
            ".license.json.tmp.\(UUID().uuidString)"
        )

        do {
            // Step 1: write payload to a temp sibling.
            try licenseData.write(to: tmpURL, options: [])

            // Step 2: tighten mode on the temp file BEFORE rename so
            // there is no observable window in which a future
            // rename-target sits at the default umask-derived mode.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tmpURL.path
            )

            // Step 3: fsync the file so payload bytes are durable
            // before the rename completes. POSIX rename does not
            // imply fsync of the file contents.
            let tmpFD = open(tmpURL.path, O_WRONLY)
            if tmpFD >= 0 {
                _ = fsync(tmpFD)
                close(tmpFD)
            }

            // Step 4: atomic rename. On the same filesystem this is
            // a directory-entry swap; readers see either the old
            // file or the new one, never a partial state -- and the
            // entry that lands points at the temp file's inode, so
            // the 0600 set in step 2 is the mode the customer gets.
            // See the 🔴 block in the header for the measurement that
            // says why this is not `FileManager.replaceItem`.
            if rename(tmpURL.path, url.path) != 0 {
                let code = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(code),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "rename of licence temp file onto \(url.path) failed: "
                            + String(cString: strerror(code))
                    ]
                )
            }

            // Step 5: fsync the parent directory so the rename
            // itself is durable across a power loss immediately
            // after the call returns.
            let parentFD = open(parent.path, O_RDONLY)
            if parentFD >= 0 {
                _ = fsync(parentFD)
                close(parentFD)
            }
        } catch {
            // Best-effort cleanup of any stray temp file so a
            // future re-install does not see a partial sibling.
            try? FileManager.default.removeItem(at: tmpURL)
            throw LicensePersistenceError.write(error)
        }

        // Step 6: the POST-CONDITION, and the only reason the 0600 in
        // this file's header is now a fact rather than a promise.
        //
        // The chmod is belt and braces -- after a `rename(2)` the mode
        // is already the temp file's -- but the READ-BACK is the part
        // that matters. Every previous version of this function
        // asserted its own intent and never once asked the filesystem
        // what it had actually done, which is how a 0644 licence
        // shipped under a header paragraph promising 0600.
        _ = chmod(url.path, 0o600)
        let landedMode: UInt16 = {
            var st = stat()
            guard stat(url.path, &st) == 0 else { return 0 }
            return UInt16(st.st_mode & 0o7777)
        }()
        if landedMode != 0o600 {
            throw LicensePersistenceError.modeNotRestricted(
                path: url.path, mode: landedMode
            )
        }

        if willOverwrite {
            // Audit trail: the overwrite path is rare (paying again
            // or replacing a corrupt install). Surface it on stderr
            // so the install.sh log channel captures it.
            FileHandle.standardError.write(Data(
                "[ostler] license_persist_overwrite: replaced existing licence at \(url.path)\n".utf8
            ))
        }
    }
}
