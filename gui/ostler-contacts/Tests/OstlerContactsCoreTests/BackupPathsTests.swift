import XCTest
@testable import OstlerContactsCore

final class BackupPathsTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/testuser", isDirectory: true)

    func testBackupsRootIsUserFacingZoneNotHidden() {
        let root = BackupPaths.backupsRoot(homeDirectory: home)
        XCTAssertEqual(
            root.path,
            "/Users/testuser/Documents/Ostler/Backups/Contacts")
        // Spec §3: MUST NOT be under hidden ~/.ostler.
        XCTAssertFalse(root.path.contains("/.ostler"))
    }

    func testSessionTimestampIsFilesystemCleanAndSortable() {
        // 2026-06-19 14:05:32 UTC
        let comps = DateComponents(
            year: 2026, month: 6, day: 19, hour: 14, minute: 5, second: 32)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!

        let ts = BackupPaths.sessionTimestamp(date: date)
        XCTAssertEqual(ts, "2026-06-19T140532Z")
        // No colons (Finder-safe), ends in Z (UTC).
        XCTAssertFalse(ts.contains(":"))
        XCTAssertTrue(ts.hasSuffix("Z"))
    }

    func testSessionTimestampZeroPads() {
        let comps = DateComponents(
            year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!
        XCTAssertEqual(
            BackupPaths.sessionTimestamp(date: date), "2026-01-02T030405Z")
    }

    func testSessionDirectoryComposesRootAndTimestamp() {
        let comps = DateComponents(
            year: 2026, month: 6, day: 19, hour: 14, minute: 5, second: 32)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!

        let dir = BackupPaths.sessionDirectory(homeDirectory: home, date: date)
        XCTAssertEqual(
            dir.path,
            "/Users/testuser/Documents/Ostler/Backups/Contacts/2026-06-19T140532Z")
    }

    func testVcardAndManifestFilenames() {
        let dir = URL(fileURLWithPath: "/tmp/session", isDirectory: true)
        XCTAssertEqual(
            BackupPaths.vcardFile(in: dir).lastPathComponent, "AllContacts.vcf")
        XCTAssertEqual(
            BackupPaths.manifestFile(in: dir).lastPathComponent, "manifest.json")
    }
}
