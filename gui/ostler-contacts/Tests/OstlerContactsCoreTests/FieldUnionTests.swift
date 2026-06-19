import XCTest
import Contacts
@testable import OstlerContactsCore

/// The lossless-toward-survivor union policy (spec §2.2). All synthetic
/// in-memory contacts; no CNContactStore, no TCC.
final class FieldUnionTests: XCTestCase {

    private func phone(_ s: String, label: String = CNLabelPhoneNumberMobile)
        -> CNLabeledValue<CNPhoneNumber> {
        CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: s))
    }
    private func email(_ s: String, label: String = CNLabelWork)
        -> CNLabeledValue<NSString> {
        CNLabeledValue(label: label, value: s as NSString)
    }

    // ---- multi-value: union, never drop a survivor value ----

    func testUnionAddsVictimPhoneKeepsSurvivorPhone() {
        let survivor = CNMutableContact()
        survivor.givenName = "Jay"
        survivor.phoneNumbers = [phone("+447700900111")]

        let victim = CNMutableContact()
        victim.phoneNumbers = [phone("+447700900222")]

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        let numbers = r.merged.phoneNumbers.map { $0.value.stringValue }
        XCTAssertTrue(numbers.contains("+447700900111"), "survivor value must never be dropped")
        XCTAssertTrue(numbers.contains("+447700900222"), "victim value must be added")
        XCTAssertEqual(r.merged.phoneNumbers.count, 2)
        XCTAssertTrue(r.additions.contains(FieldUnion.Addition(field: "phone", value: "+447700900222")))
    }

    func testIdenticalLabelledPhoneDeDuped() {
        let survivor = CNMutableContact()
        survivor.phoneNumbers = [phone("+44 7700 900111")]   // formatted
        let victim = CNMutableContact()
        victim.phoneNumbers = [phone("+447700900111")]        // same digits

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.phoneNumbers.count, 1,
                       "same number differing only in formatting must de-dupe")
    }

    func testEmailUnionCaseInsensitiveDedup() {
        let survivor = CNMutableContact()
        survivor.emailAddresses = [email("John@Example.com")]
        let victim = CNMutableContact()
        victim.emailAddresses = [email("john@example.com"), email("other@example.com")]

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.emailAddresses.count, 2,
                       "case-different duplicate de-dupes; genuinely new email is added")
    }

    // ---- photo policy ----

    func testKeepsSurvivorPhoto() {
        let survivor = CNMutableContact()
        survivor.imageData = Data([1, 2, 3])
        let victim = CNMutableContact()
        victim.imageData = Data([9, 9, 9])

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.imageData, Data([1, 2, 3]), "survivor photo must win")
    }

    func testFillsEmptyPhotoFromVictim() {
        let survivor = CNMutableContact()   // no photo
        let victim = CNMutableContact()
        victim.imageData = Data([9, 9, 9])

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.imageData, Data([9, 9, 9]),
                       "empty survivor photo is filled from a victim")
    }

    // ---- single-value conflict policy: survivor wins, discard surfaced ----

    func testConflictingOrgKeepsSurvivorAndSurfacesDiscard() {
        let survivor = CNMutableContact()
        survivor.organizationName = "Acme"
        let victim = CNMutableContact()
        victim.organizationName = "Globex"

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.organizationName, "Acme", "survivor single-value wins")
        XCTAssertTrue(r.conflicts.contains(
            FieldUnion.Conflict(field: "organizationName", kept: "Acme", discarded: "Globex")),
            "discarded victim value must be surfaced, never silently dropped")
    }

    func testEmptySurvivorSingleValueFilledFromVictimIsAddNotConflict() {
        let survivor = CNMutableContact()   // no org
        let victim = CNMutableContact()
        victim.organizationName = "Globex"

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.organizationName, "Globex")
        XCTAssertTrue(r.additions.contains(
            FieldUnion.Addition(field: "organizationName", value: "Globex")))
        XCTAssertTrue(r.conflicts.isEmpty, "filling a blank is an add, not a conflict")
    }

    func testBirthdayConflictKeepsSurvivor() {
        let survivor = CNMutableContact()
        survivor.birthday = DateComponents(year: 1980, month: 1, day: 1)
        let victim = CNMutableContact()
        victim.birthday = DateComponents(year: 1990, month: 2, day: 2)

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.birthday?.year, 1980)
        XCTAssertTrue(r.conflicts.contains { $0.field == "birthday" })
    }

    // ---- identifier preserved (needed for CNSaveRequest.update) ----

    func testMergedKeepsSurvivorIdentifier() {
        let survivor = CNMutableContact()
        let survivorID = survivor.identifier
        let victim = CNMutableContact()
        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.identifier, survivorID,
                       "merged contact must carry the survivor's identifier for .update")
    }

    // ---- the contract in one assertion: nothing the survivor had is lost ----

    func testNoSurvivorValueEverDropped() {
        let survivor = CNMutableContact()
        survivor.givenName = "Jay"
        survivor.familyName = "Livens"
        survivor.organizationName = "Acme"
        survivor.phoneNumbers = [phone("+447700900111")]
        survivor.emailAddresses = [email("jay@acme.com")]
        survivor.note = "survivor note"

        let victim = CNMutableContact()
        victim.organizationName = "Globex"          // conflict
        victim.phoneNumbers = [phone("+447700900999")]
        victim.jobTitle = "Engineer"                // fills blank

        let r = FieldUnion.union(survivor: survivor, victims: [victim])
        XCTAssertEqual(r.merged.givenName, "Jay")
        XCTAssertEqual(r.merged.familyName, "Livens")
        XCTAssertEqual(r.merged.organizationName, "Acme")    // survivor won
        XCTAssertEqual(r.merged.note, "survivor note")
        XCTAssertTrue(r.merged.phoneNumbers.map { $0.value.stringValue }.contains("+447700900111"))
        XCTAssertTrue(r.merged.emailAddresses.map { $0.value as String }.contains("jay@acme.com"))
        XCTAssertEqual(r.merged.jobTitle, "Engineer")        // blank filled from victim
    }
}
