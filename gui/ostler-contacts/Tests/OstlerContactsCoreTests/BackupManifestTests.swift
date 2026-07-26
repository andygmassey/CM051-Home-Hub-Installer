import XCTest
@testable import OstlerContactsCore

final class BackupManifestTests: XCTestCase {

    func testSha256HexMatchesKnownVector() {
        // SHA-256 of the empty string.
        XCTAssertEqual(
            BackupManifest.sha256Hex(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // SHA-256 of "abc".
        XCTAssertEqual(
            BackupManifest.sha256Hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testMakePopulatesAllFields() {
        let bytes = Data("BEGIN:VCARD\nEND:VCARD\n".utf8)
        let when = Date(timeIntervalSince1970: 1_780_000_000)
        let m = BackupManifest.make(
            vcardData: bytes,
            contactCount: 3,
            createdAt: when,
            vcardFilename: "AllContacts.vcf",
            toolVersion: "0.1.0-test")

        XCTAssertEqual(m.contactCount, 3)
        XCTAssertEqual(m.vcardFilename, "AllContacts.vcf")
        XCTAssertEqual(m.toolVersion, "0.1.0-test")
        XCTAssertEqual(m.sha256, BackupManifest.sha256Hex(of: bytes))
        XCTAssertFalse(m.createdAt.isEmpty)
    }

    func testJsonRoundTrips() throws {
        let m = BackupManifest(
            createdAt: "2026-06-19T14:05:32Z",
            contactCount: 42,
            sha256: "deadbeef",
            vcardFilename: "AllContacts.vcf",
            toolVersion: "0.1.0")
        let data = try m.jsonData()
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: data)
        XCTAssertEqual(decoded, m)
        // Sorted keys -> stable serialisation.
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"contactCount\" : 42"))
    }
}
