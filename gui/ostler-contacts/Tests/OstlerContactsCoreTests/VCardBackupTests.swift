import XCTest
import Contacts
@testable import OstlerContactsCore

final class VCardBackupTests: XCTestCase {

    /// Synthetic contacts — these are in-memory CNMutableContact objects,
    /// never fetched from or saved to a live CNContactStore, so no TCC
    /// authorisation is required to exercise serialisation.
    private func makeContacts() -> [CNContact] {
        let a = CNMutableContact()
        a.givenName = "Jay"
        a.familyName = "Livens"
        a.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile,
                           value: CNPhoneNumber(stringValue: "+447700900111"))
        ]

        let b = CNMutableContact()
        b.givenName = "John"
        b.familyName = "Chan"
        b.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "john@example.com" as NSString)
        ]
        return [a, b]
    }

    func testSerialiseProducesVCardBytes() throws {
        let data = try VCardBackup.serialise(makeContacts())
        XCTAssertFalse(data.isEmpty)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("BEGIN:VCARD"))
        XCTAssertTrue(text.contains("END:VCARD"))
        XCTAssertTrue(text.contains("Livens"))
        XCTAssertTrue(text.contains("Chan"))
    }

    func testRoundTripParseBack() throws {
        let original = makeContacts()
        let data = try VCardBackup.serialise(original)
        let parsed = try VCardBackup.parse(data)
        XCTAssertEqual(parsed.count, original.count)
    }

    func testVerifyRoundTripOK() throws {
        let contacts = makeContacts()
        let data = try VCardBackup.serialise(contacts)
        let result = VCardBackup.verifyRoundTrip(
            data: data, expectedCount: contacts.count)
        XCTAssertTrue(result.isOK)
        if case .ok(let n) = result {
            XCTAssertEqual(n, contacts.count)
        } else {
            XCTFail("expected .ok")
        }
    }

    func testVerifyRoundTripRejectsEmpty() {
        let result = VCardBackup.verifyRoundTrip(data: Data(), expectedCount: 0)
        XCTAssertFalse(result.isOK)
        if case .failed(let reason) = result {
            XCTAssertTrue(reason.lowercased().contains("empty"))
        } else {
            XCTFail("expected .failed")
        }
    }

    func testVerifyRoundTripRejectsGarbage() {
        // Random non-vCard bytes should fail to parse back.
        let garbage = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let result = VCardBackup.verifyRoundTrip(data: garbage, expectedCount: 1)
        XCTAssertFalse(result.isOK)
    }

    func testVerifyRoundTripRejectsShortCount() throws {
        let contacts = makeContacts()
        let data = try VCardBackup.serialise(contacts)
        // Claim we expected MORE contacts than were serialised -> corruption signal.
        let result = VCardBackup.verifyRoundTrip(
            data: data, expectedCount: contacts.count + 100)
        XCTAssertFalse(result.isOK)
    }
}
