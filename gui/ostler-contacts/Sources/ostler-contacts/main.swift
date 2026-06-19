import Foundation
import Contacts
import OstlerContactsCore

// ostler-contacts: native macOS CNContact helper (Big Win BW-A).
//
// Step 1 (PR #351) shipped READ + BACKUP. This PR adds the DESTRUCTIVE
// write half (spec §9 item 3): the `merge` (atomic union + delete) and
// `undo` subcommands. They are gated three ways before anything is written:
//   1. OSTLER_TIDY_CONTACTS_ENABLED must be true (flag OFF by default).
//   2. A valid one-shot --confirm-token bound to THIS exact group.
//   3. The undo-journal entry is written + fsynced BEFORE the CNSaveRequest
//      (journal-first ordering, spec §6).
//
// Subcommands:
//   ostler-contacts backup [--out <dir>]    full-Contacts vCard backup (spec §3)
//   ostler-contacts list                    count + identifiers (proves read access)
//   ostler-contacts preview --survivor <id> --victims <id,...>
//                                           before/after union diff, NO write (spec §2.2)
//   ostler-contacts merge   --survivor <id> --victims <id,...>
//                           --confirm-token <tok> [--journal <path>]
//                                           atomic union+delete CNSaveRequest (spec §2.2/§6)
//   ostler-contacts undo    --journal <path>
//                                           restore survivor + re-create victims (spec §6)
//   ostler-contacts version
//   ostler-contacts help

let toolVersion = "0.2.0-bwA-merge"

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

// MARK: - fetch by identifier (for preview / merge)

/// Fetch a single contact by CNContact identifier with the full vCard key
/// set, so the union sees every field and the undo journal captures a
/// complete pre-merge vCard. Returns nil if the id no longer resolves
/// (deleted / synced away), which the caller treats as a refusal: we never
/// write a guessed target.
func fetchContact(_ store: CNContactStore, identifier: String) -> CNContact? {
    let keys = VCardBackup.vcardKeys
    return try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
}

/// Resolve a survivor + victim ids to live contacts, refusing loudly if any
/// member cannot be resolved (spec §5.2: a group whose members cannot ALL be
/// resolved is never written).
func resolveGroup(
    _ store: CNContactStore,
    survivorID: String,
    victimIDs: [String]
) -> (survivor: CNContact, victims: [CNContact]) {
    guard let survivor = fetchContact(store, identifier: survivorID) else {
        fail("survivor contact \(survivorID) could not be resolved (deleted or synced away). "
             + "Refusing to merge.", code: 14)
    }
    var victims: [CNContact] = []
    for vid in victimIDs {
        guard let v = fetchContact(store, identifier: vid) else {
            fail("victim contact \(vid) could not be resolved. Refusing to merge a "
                 + "partially-resolved group.", code: 14)
        }
        victims.append(v)
    }
    return (survivor, victims)
}

// MARK: - preview (read-only union diff, spec §2.2)

func runPreview(survivorID: String, victimIDs: [String]) {
    let store = ensureReadAccess()
    let group = resolveGroup(store, survivorID: survivorID, victimIDs: victimIDs)
    let result = FieldUnion.union(survivor: group.survivor, victims: group.victims)

    // group_hash / confirm-token are the same value; surface it so a caller
    // can see exactly which token would authorise THIS preview's merge.
    let token = ConfirmToken.derive(survivorID: survivorID, victimIDs: victimIDs)

    var out: [String: Any] = [
        "survivor_id": survivorID,
        "victim_ids": victimIDs,
        "group_hash": token,
        "confirm_token": token,
        "conflicts": result.conflicts.map {
            ["field": $0.field, "kept": $0.kept, "discarded": $0.discarded]
        },
        "adds": result.additions.map {
            ["field": $0.field, "value": $0.value]
        },
    ]
    out["wrote"] = false
    emitJSON(out)
}

// MARK: - merge (atomic union + delete, spec §2.2 / §6)

func runMerge(
    survivorID: String,
    victimIDs: [String],
    confirmToken: String?,
    journalOverride: URL?
) {
    // ---- GATE (rules 3 + 4): flag + token + structural sanity ----
    let decision = MergeGate.evaluate(
        flagEnabled: FeatureFlag.isEnabled(),
        survivorID: survivorID,
        victimIDs: victimIDs,
        presentedToken: confirmToken)
    guard decision.isAllowed else {
        fail(decision.message, code: decision.exitCode)
    }

    let store = ensureReadAccess()
    let group = resolveGroup(store, survivorID: survivorID, victimIDs: victimIDs)

    // ---- capture pre-merge vCards for the undo journal ----
    let survivorBefore: Data
    let victimVcards: [Data]
    do {
        survivorBefore = try VCardBackup.serialise([group.survivor])
        victimVcards = try group.victims.map { try VCardBackup.serialise([$0]) }
    } catch {
        fail("failed to serialise pre-merge vCards for the undo journal: \(error). "
             + "Refusing to write without a recorded undo.", code: 15)
    }

    // ---- build the union (lossless toward survivor) ----
    let union = FieldUnion.union(survivor: group.survivor, victims: group.victims)

    // ---- JOURNAL FIRST (spec §6): durable undo record BEFORE the save ----
    let now = Date()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let sessionDir = journalOverride?.deletingLastPathComponent()
        ?? BackupPaths.sessionDirectory(homeDirectory: home, date: now)
    let journalURL = journalOverride ?? UndoJournal.journalFile(in: sessionDir)
    let backupPath = BackupPaths.vcardFile(in: sessionDir).path

    let groupHash = ConfirmToken.derive(survivorID: survivorID, victimIDs: victimIDs)
    let entry = UndoEntry(
        ts: ISO8601DateFormatter().string(from: now),
        survivorBeforeVcard: String(data: survivorBefore, encoding: .utf8) ?? "",
        victimsVcards: victimVcards.map { String(data: $0, encoding: .utf8) ?? "" },
        survivorID: survivorID,
        victimIDs: victimIDs,
        groupHash: groupHash,
        backupPath: backupPath)
    do {
        try UndoJournal.append(entry, to: journalURL)
    } catch {
        fail("failed to write the undo journal at \(journalURL.path): \(error). "
             + "Refusing to merge without a durable undo record.", code: 16)
    }

    // ---- atomic save: .update(survivor) AND .delete(victim) in ONE request ----
    let save = CNSaveRequest()
    save.update(union.merged)
    for victim in group.victims {
        guard let mutableVictim = victim.mutableCopy() as? CNMutableContact else {
            fail("could not prepare victim \(victim.identifier) for deletion.", code: 17)
        }
        save.delete(mutableVictim)
    }
    do {
        try store.execute(save)
    } catch {
        fail("CNSaveRequest failed: \(error). The undo journal entry was already "
             + "written at \(journalURL.path); no partial state should persist, but "
             + "verify before retrying.", code: 18)
    }

    var out: [String: Any] = [
        "status": "merged",
        "survivor_id": survivorID,
        "victim_ids": victimIDs,
        "journal_path": journalURL.path,
        "group_hash": groupHash,
        "conflicts": union.conflicts.map {
            ["field": $0.field, "kept": $0.kept, "discarded": $0.discarded]
        },
        "adds": union.additions.map { ["field": $0.field, "value": $0.value] },
    ]
    out["wrote"] = true
    emitJSON(out)
}

// MARK: - undo (restore survivor + re-create victims, spec §6)

func runUndo(journalURL: URL) {
    // Undo restores DATA from the journal. It is intentionally NOT gated on
    // the feature flag: turning the feature off must never trap a user with
    // an un-undoable merge. It is also non-destructive in the dangerous
    // sense (it adds/updates, the only delete it could do is none).
    let entries: [UndoEntry]
    do {
        entries = try UndoJournal.readAll(from: journalURL)
    } catch {
        fail("could not read undo journal: \(error)", code: 19)
    }
    // Undo the most recent entry (LIFO): the inline "Undo" right after a
    // merge targets the merge that just happened.
    guard let entry = entries.last else {
        fail("undo journal \(journalURL.path) has no entries.", code: 19)
    }

    let store = ensureReadAccess()
    let save = CNSaveRequest()

    // ---- restore the survivor to its pre-merge vCard ----
    guard let survivorData = entry.survivorBeforeVcard.data(using: .utf8),
          let restoredSurvivors = try? VCardBackup.parse(survivorData),
          let restoredSurvivor = restoredSurvivors.first else {
        fail("survivor's pre-merge vCard in the journal did not parse; cannot restore.",
             code: 20)
    }
    // Fetch the live survivor so we update the existing record (preserving
    // its identifier) rather than creating a duplicate. If it is gone, we
    // re-create it (field-lossless, identity-lossy, like the victims).
    if let liveSurvivor = fetchContact(store, identifier: entry.survivorID),
       let mutableLive = liveSurvivor.mutableCopy() as? CNMutableContact {
        copyFields(from: restoredSurvivor, into: mutableLive)
        save.update(mutableLive)
    } else if let asMutable = restoredSurvivor.mutableCopy() as? CNMutableContact {
        save.add(asMutable, toContainerWithIdentifier: nil)
    }

    // ---- re-create each deleted victim from its pre-merge vCard ----
    var recreated = 0
    for vcard in entry.victimsVcards {
        guard let data = vcard.data(using: .utf8),
              let parsed = try? VCardBackup.parse(data),
              let victim = parsed.first,
              let mutableVictim = victim.mutableCopy() as? CNMutableContact else {
            fail("a victim vCard in the journal did not parse; cannot fully restore.",
                 code: 20)
        }
        save.add(mutableVictim, toContainerWithIdentifier: nil)
        recreated += 1
    }

    do {
        try store.execute(save)
    } catch {
        fail("undo CNSaveRequest failed: \(error)", code: 21)
    }

    var out: [String: Any] = [
        "status": "restored",
        "survivor_id": entry.survivorID,
        "victims_recreated": recreated,
        "journal_path": journalURL.path,
    ]
    // Spec §6 caveat: re-created victims get NEW CNContact identifiers. State
    // it plainly so any caller/UI can surface "restored as a new card".
    out["note"] = "Re-created contacts receive NEW identifiers (field-lossless, "
        + "identity-lossy per spec §6). Data is restored; the original CNContact "
        + "identifier of a deleted contact cannot be."
    emitJSON(out)
}

/// Copy the field set of one (parsed) contact onto a live mutable contact,
/// preserving the live contact's identifier. Used by undo to restore the
/// survivor in place.
func copyFields(from source: CNContact, into target: CNMutableContact) {
    target.givenName = source.givenName
    target.familyName = source.familyName
    target.middleName = source.middleName
    target.namePrefix = source.namePrefix
    target.nameSuffix = source.nameSuffix
    target.nickname = source.nickname
    target.organizationName = source.organizationName
    target.departmentName = source.departmentName
    target.jobTitle = source.jobTitle
    target.note = source.note
    target.phoneNumbers = source.phoneNumbers
    target.emailAddresses = source.emailAddresses
    target.postalAddresses = source.postalAddresses
    target.urlAddresses = source.urlAddresses
    target.instantMessageAddresses = source.instantMessageAddresses
    target.socialProfiles = source.socialProfiles
    target.dates = source.dates
    target.birthday = source.birthday
    target.imageData = source.imageData
}

// MARK: - JSON output helper

func emitJSON(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        fail("internal error: could not encode JSON output", code: 99)
    }
    emit(text)
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

/// Parse a single `--name <value>` string flag from the argument slice.
func parseStringFlag(_ name: String, _ args: ArraySlice<String>) -> String? {
    var it = args.makeIterator()
    while let arg = it.next() {
        if arg == name {
            guard let value = it.next() else {
                fail("\(name) requires a value", code: 2)
            }
            return value
        }
    }
    return nil
}

/// Parse a comma-separated `--victims a,b,c` id list.
func parseVictimIDs(_ args: ArraySlice<String>) -> [String] {
    guard let raw = parseStringFlag("--victims", args) else { return [] }
    return raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Parse a `--journal <path>` flag into an expanded file URL.
func parseJournalFlag(_ args: ArraySlice<String>) -> URL? {
    guard let path = parseStringFlag("--journal", args) else { return nil }
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false)
}

func printUsage() {
    emit("""
    ostler-contacts \(toolVersion) native Contacts read/backup + merge/undo helper

    USAGE:
      ostler-contacts backup [--out <dir>]   Export a full vCard backup of all
                                             Contacts (default:
                                             ~/Documents/Ostler/Backups/Contacts/<ts>/)
      ostler-contacts list                   Print a summary (count + identifiers)
      ostler-contacts preview --survivor <id> --victims <id,...>
                                             Show the before/after union diff. NO write.
      ostler-contacts merge   --survivor <id> --victims <id,...>
                              --confirm-token <tok> [--journal <path>]
                                             DESTRUCTIVE. Atomic union + delete.
                                             Refuses unless \(FeatureFlag.envName)=true
                                             AND a valid --confirm-token for this exact
                                             group is presented. Writes the undo journal
                                             BEFORE the save (journal-first, spec §6).
      ostler-contacts undo    --journal <path>
                                             Restore the survivor + re-create victims
                                             from the journal (re-created cards get NEW
                                             identifiers, spec §6 caveat).
      ostler-contacts version
      ostler-contacts help

    Feature flag: \(FeatureFlag.envName) (default OFF; gates the merge write path).
    The one-shot --confirm-token equals the group_hash printed by `preview`.
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
case "preview":
    guard let survivor = parseStringFlag("--survivor", rest) else {
        fail("preview requires --survivor <id>", code: 2)
    }
    let victims = parseVictimIDs(rest)
    guard !victims.isEmpty else {
        fail("preview requires --victims <id,...>", code: 2)
    }
    runPreview(survivorID: survivor, victimIDs: victims)
case "merge":
    guard let survivor = parseStringFlag("--survivor", rest) else {
        fail("merge requires --survivor <id>", code: 2)
    }
    let victims = parseVictimIDs(rest)
    let token = parseStringFlag("--confirm-token", rest)
    runMerge(
        survivorID: survivor,
        victimIDs: victims,
        confirmToken: token,
        journalOverride: parseJournalFlag(rest))
case "undo":
    guard let journal = parseJournalFlag(rest) else {
        fail("undo requires --journal <path>", code: 2)
    }
    runUndo(journalURL: journal)
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
