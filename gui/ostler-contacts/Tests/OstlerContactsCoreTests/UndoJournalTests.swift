import XCTest
import Contacts
@testable import OstlerContactsCore

/// Undo journal (spec §6) + the data-layer merge->undo round-trip that can
/// run headlessly (the live CNContactStore half is a documented manual
/// test). Journal-first ordering is the crash-safety hinge.
final class UndoJournalTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ostler-undo-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeEntry(survivorVcard: String = "S", victims: [String] = ["V1"]) -> UndoEntry {
        UndoEntry(
            ts: "2026-06-19T00:00:00Z",
            survivorBeforeVcard: survivorVcard,
            victimsVcards: victims,
            survivorID: "survivor-id",
            victimIDs: ["victim-id"],
            groupHash: "hash",
            backupPath: "/tmp/AllContacts.vcf")
    }

    func testAppendThenReadRoundTrip() throws {
        let journal = UndoJournal.journalFile(in: tmpDir)
        let entry = makeEntry()
        try UndoJournal.append(entry, to: journal)
        let read = try UndoJournal.readAll(from: journal)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first, entry)
    }

    func testNdjsonIsOnePhysicalLinePerEntry() throws {
        // vCards contain newlines; the NDJSON encoding must escape them so
        // one entry stays one line (otherwise readAll mis-splits).
        let journal = UndoJournal.journalFile(in: tmpDir)
        let multiline = "BEGIN:VCARD\nN:Livens;Jay\nEND:VCARD\n"
        try UndoJournal.append(makeEntry(survivorVcard: multiline), to: journal)
        try UndoJournal.append(makeEntry(survivorVcard: multiline), to: journal)
        let raw = try String(contentsOf: journal, encoding: .utf8)
        let physicalLines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(physicalLines.count, 2, "two entries => two physical lines")
        XCTAssertEqual(try UndoJournal.readAll(from: journal).count, 2)
    }

    func testReadMissingJournalThrows() {
        let missing = tmpDir.appendingPathComponent("nope.ndjson")
        XCTAssertThrowsError(try UndoJournal.readAll(from: missing))
    }

    // ---- JOURNAL-FIRST crash safety (spec §6, test §8.2 #5/#8) ----
    // Simulate the helper appending the journal, then "crashing" before the
    // CNSaveRequest. The undo record must already be on disk + fsynced.
    func testJournalSurvivesIfSaveNeverHappens() throws {
        let journal = UndoJournal.journalFile(in: tmpDir)
        let entry = makeEntry(survivorVcard: "pre-merge survivor")
        try UndoJournal.append(entry, to: journal)
        // ... here the process would issue CNSaveRequest. Simulate a crash by
        // simply NOT doing it. The journal entry must still be readable.
        let read = try UndoJournal.readAll(from: journal)
        XCTAssertEqual(read.first?.survivorBeforeVcard, "pre-merge survivor",
                       "journal-first: the undo record exists even if the save is lost")
    }

    // ---- data-layer merge -> undo round-trip (headless half of test §8.2 #5) ----
    // We cannot exercise CNContactStore.execute headlessly, but we CAN prove
    // the journal captures enough to reconstruct the victim losslessly: take
    // a victim contact, serialise it (as the merge path does pre-save), then
    // parse it back (as undo does) and assert every field survived.
    func testVictimVcardRoundTripIsFieldLossless() throws {
        let victim = CNMutableContact()
        victim.givenName = "John"
        victim.familyName = "Chan"
        victim.organizationName = "Acme"
        victim.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile,
                           value: CNPhoneNumber(stringValue: "+447700900222"))
        ]
        victim.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "john@acme.com" as NSString)
        ]

        // merge path: serialise the victim into the journal entry.
        let vcardData = try VCardBackup.serialise([victim])
        let vcardString = String(data: vcardData, encoding: .utf8)!
        let entry = UndoEntry(
            ts: "t", survivorBeforeVcard: "s",
            victimsVcards: [vcardString],
            survivorID: "s-id", victimIDs: ["v-id"],
            groupHash: "h", backupPath: "/tmp/b.vcf")

        // undo path: read the journal back, parse the victim vCard.
        let journal = UndoJournal.journalFile(in: tmpDir)
        try UndoJournal.append(entry, to: journal)
        let readBack = try UndoJournal.readAll(from: journal).last!
        let restored = try VCardBackup.parse(
            readBack.victimsVcards[0].data(using: .utf8)!)
        XCTAssertEqual(restored.count, 1)
        let r = restored[0]
        XCTAssertEqual(r.givenName, "John")
        XCTAssertEqual(r.familyName, "Chan")
        XCTAssertEqual(r.organizationName, "Acme")
        XCTAssertTrue(r.phoneNumbers.map { $0.value.stringValue }.contains("+447700900222"))
        XCTAssertTrue(r.emailAddresses.map { $0.value as String }.contains("john@acme.com"))
        // Field-lossless; identity-lossy is expected (new id on re-create).
    }

    // ---- the FULL data-layer round trip: survivor union then restore ----
    func testSurvivorRestoreVcardRoundTrip() throws {
        let survivor = CNMutableContact()
        survivor.givenName = "Jay"
        survivor.familyName = "Livens"
        survivor.organizationName = "Acme"

        // pre-merge snapshot (what undo restores TO).
        let beforeData = try VCardBackup.serialise([survivor])
        let beforeString = String(data: beforeData, encoding: .utf8)!

        // simulate a merge that changed the survivor (added a phone).
        let victim = CNMutableContact()
        victim.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile,
                           value: CNPhoneNumber(stringValue: "+447700900999"))
        ]
        let merged = FieldUnion.union(survivor: survivor, victims: [victim]).merged
        XCTAssertEqual(merged.phoneNumbers.count, 1, "merge added the victim phone")

        // undo: parse the before-vcard; it must reconstruct the original survivor.
        let restored = try VCardBackup.parse(beforeString.data(using: .utf8)!)[0]
        XCTAssertEqual(restored.givenName, "Jay")
        XCTAssertEqual(restored.familyName, "Livens")
        XCTAssertEqual(restored.organizationName, "Acme")
        XCTAssertTrue(restored.phoneNumbers.isEmpty,
                      "restore returns the survivor to its pre-merge (phone-free) state")
    }
}
