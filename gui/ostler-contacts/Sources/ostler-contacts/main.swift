import Foundation
import Contacts
import OstlerContactsCore

// ostler-contacts — native macOS CNContact helper (Big Win BW-A, step 1).
//
// READ + BACKUP ONLY. This binary contains NO write path:
//   * no CNSaveRequest
//   * no .update / .delete
//   * no field-union / merge
//   * no undo journal write
// The destructive half (merge/undo) is a deliberately separate later PR
// (spec §9 item 3). Search this package for "CNSaveRequest" — there are
// zero matches by design, and a test in OstlerContactsCoreTests would be
// the place to pin that once the merge code is proposed.
//
// Subcommands implemented in THIS step:
//   ostler-contacts backup [--out <dir>]   full-Contacts vCard backup (spec §3)
//   ostler-contacts list                   count + identifiers (proves read access)
//   ostler-contacts version
//   ostler-contacts help

let toolVersion = "0.1.0-bwA-step1"

// MARK: - Tiny exit/log helpers

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("ostler-contacts: " + message + "\n").utf8))
    exit(code)
}

func emit(_ message: String) {
    print(message)
}

// MARK: - Authorisation

/// Request Contacts read access. On a signed, entitled binary this fires
/// the TCC prompt the first time; in CI / unsigned local runs it returns
/// the cached status (typically .notDetermined -> denied without a prompt).
/// That is expected and is exercised on-box, not here (see PR notes).
func ensureReadAccess() -> CNContactStore {
    let store = CNContactStore()
    let status = CNContactStore.authorizationStatus(for: .contacts)
    switch status {
    case .authorized:
        return store
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        store.requestAccess(for: .contacts) { ok, _ in
            granted = ok
            sem.signal()
        }
        sem.wait()
        if granted { return store }
        fail("Contacts access was not granted. Grant it in System Settings > "
             + "Privacy & Security > Contacts, then re-run.", code: 3)
    case .denied, .restricted:
        fail("Contacts access is denied/restricted. Enable it in System "
             + "Settings > Privacy & Security > Contacts.", code: 3)
    @unknown default:
        fail("Contacts authorisation status is unknown (\(status.rawValue)).", code: 3)
    }
}

/// Fetch every unified contact with the keys needed for a full vCard backup.
func fetchAllContacts(_ store: CNContactStore) throws -> [CNContact] {
    let request = CNContactFetchRequest(keysToFetch: VCardBackup.vcardKeys)
    request.unifyResults = true
    var contacts: [CNContact] = []
    try store.enumerateContacts(with: request) { contact, _ in
        contacts.append(contact)
    }
    return contacts
}

// MARK: - backup

func runBackup(outOverride: URL?) {
    let store = ensureReadAccess()

    let contacts: [CNContact]
    do {
        contacts = try fetchAllContacts(store)
    } catch {
        fail("failed to read Contacts: \(error)", code: 4)
    }

    let data: Data
    do {
        data = try VCardBackup.serialise(contacts)
    } catch {
        fail("failed to serialise vCard backup: \(error)", code: 5)
    }

    let now = Date()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let sessionDir = outOverride
        ?? BackupPaths.sessionDirectory(homeDirectory: home, date: now)
    let vcardURL = BackupPaths.vcardFile(in: sessionDir)
    let manifestURL = BackupPaths.manifestFile(in: sessionDir)

    do {
        try FileManager.default.createDirectory(
            at: sessionDir, withIntermediateDirectories: true)
        try data.write(to: vcardURL, options: .atomic)
    } catch {
        fail("failed to write backup to \(vcardURL.path): \(error)", code: 6)
    }

    // Round-trip integrity: a backup that cannot be read back is not a
    // backup (spec §3). Refuse to report success on a corrupt write.
    switch VCardBackup.verifyRoundTrip(data: data, expectedCount: contacts.count) {
    case .failed(let reason):
        fail("backup integrity check FAILED: \(reason). "
             + "Wrote \(vcardURL.path) but it is not a trustworthy backup.",
             code: 7)
    case .ok:
        break
    }

    let manifest = BackupManifest.make(
        vcardData: data,
        contactCount: contacts.count,
        createdAt: now,
        vcardFilename: vcardURL.lastPathComponent,
        toolVersion: toolVersion)
    do {
        try manifest.jsonData().write(to: manifestURL, options: .atomic)
    } catch {
        fail("wrote vCard but failed to write manifest \(manifestURL.path): \(error)",
             code: 8)
    }

    // Surface the path (spec §3: printed to stdout, captured by the daemon).
    emit("Backup complete.")
    emit("  contacts: \(contacts.count)")
    emit("  vcard:    \(vcardURL.path)")
    emit("  manifest: \(manifestURL.path)")
    emit("  sha256:   \(manifest.sha256)")
}

// MARK: - list

func runList() {
    let store = ensureReadAccess()
    // Only the identifier + name keys are needed to prove read access and
    // print a summary — we do NOT pull the full vCard key set here.
    let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
    ]
    let request = CNContactFetchRequest(keysToFetch: keys)
    request.unifyResults = true

    var count = 0
    do {
        try store.enumerateContacts(with: request) { contact, _ in
            count += 1
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let label = name.isEmpty
                ? (contact.organizationName.isEmpty ? "(no name)" : contact.organizationName)
                : name
            emit("\(contact.identifier)\t\(label)")
        }
    } catch {
        fail("failed to read Contacts: \(error)", code: 4)
    }
    emit("---")
    emit("total: \(count) contacts")
}

// MARK: - argument parsing

func parseOutFlag(_ args: ArraySlice<String>) -> URL? {
    var it = args.makeIterator()
    while let arg = it.next() {
        if arg == "--out" {
            guard let path = it.next() else {
                fail("--out requires a directory path", code: 2)
            }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
    }
    return nil
}

func printUsage() {
    emit("""
    ostler-contacts \(toolVersion) — native Contacts read + vCard backup helper

    USAGE:
      ostler-contacts backup [--out <dir>]   Export a full vCard backup of all
                                             Contacts (default:
                                             ~/Documents/Ostler/Backups/Contacts/<ts>/)
      ostler-contacts list                   Print a summary (count + identifiers)
      ostler-contacts version
      ostler-contacts help

    This is the READ + BACKUP foundation for the Tidy Contacts feature.
    It contains NO merge/write/delete code (Big Win BW-A, step 1 of N).
    Feature flag: \(FeatureFlag.envName) (defined; does not gate these reads).
    """)
}

// MARK: - dispatch

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    printUsage()
    exit(0)
}

let subcommand = arguments[1]
let rest = arguments.dropFirst(2)

switch subcommand {
case "backup":
    runBackup(outOverride: parseOutFlag(rest))
case "list":
    runList()
case "version", "--version", "-v":
    emit(toolVersion)
case "help", "--help", "-h":
    printUsage()
default:
    FileHandle.standardError.write(
        Data(("ostler-contacts: unknown subcommand '\(subcommand)'\n").utf8))
    printUsage()
    exit(2)
}
