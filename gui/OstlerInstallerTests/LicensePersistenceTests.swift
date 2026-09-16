// LicensePersistenceTests.swift
//
// Round-trip tests for `LicensePersistence`. Uses a unique
// per-test temp directory so the real `~/.ostler/license/` is
// never touched by the test target.

import Foundation
import XCTest
@testable import OstlerInstaller

final class LicensePersistenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("LicensePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    func testWriteThenReadRoundTrip() throws {
        let path = tempDir.appendingPathComponent("license.json")
        let payload = Data(#"{"version":1}"#.utf8)
        try LicensePersistence.write(licenseData: payload, to: path)
        let readBack = LicensePersistence.readExisting(at: path)
        XCTAssertEqual(readBack, payload)
    }

    func testReadMissingFileReturnsNil() {
        let path = tempDir.appendingPathComponent("absent.json")
        XCTAssertNil(LicensePersistence.readExisting(at: path))
    }

    func testWriteCreatesIntermediateDirectories() throws {
        let path = tempDir
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("license.json")
        let payload = Data("{}".utf8)
        try LicensePersistence.write(licenseData: payload, to: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testWriteSetsFileMode0600() throws {
        let path = tempDir.appendingPathComponent("license.json")
        try LicensePersistence.write(licenseData: Data("{}".utf8), to: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.uint16Value, 0o600,
                       "Licence file should be readable/writable only by owner")
    }

    // MARK: - The OVERWRITE path, which the test above cannot see

    /// 🔴 `testWriteSetsFileMode0600` above passed for the life of this
    /// file while the shipped licence was 0644, because it only ever
    /// wrote to a path that did not exist yet. That is the one case
    /// `FileManager.replaceItem` gets right.
    ///
    /// `replaceItem` replaces a DOCUMENT, so it carries the ORIGINAL
    /// item's metadata onto the replacement, POSIX mode included. The
    /// temp sibling is chmodded to 0600 before the swap and
    /// `replaceItem` threw that away, restoring the destination's own
    /// mode. Measured before the fix, one standalone program mirroring
    /// `write`:
    ///
    ///     destination ABSENT, temp 0600, replaceItem -> 600
    ///     destination 0644,   temp 0600, replaceItem -> 644
    ///     destination 0644,   temp 0600, rename(2)   -> 600
    ///
    /// The overwrite case is not exotic. It is every re-install, and
    /// it is every customer who followed the installer's own
    /// `cp ~/Downloads/ostler-licence.json ...` instruction under the
    /// default umask and then opened the app. The file carries
    /// `issued_to_email` and `stripe_payment_id`, so 0644 hands every
    /// other local account the customer's email address and the id of
    /// their payment.
    ///
    /// MUTATION-TESTED, and the result is the reason this case had to
    /// be written rather than the existing one extended. With
    /// `replaceItem` restored and the post-condition disabled, this
    /// suite was built and run against the reverted source:
    ///
    ///     testWriteOverAWorldReadableFileEndsAt0600   FAILED
    ///     testWriteSetsFileMode0600                   passed
    ///
    /// The older test passes ON THE DEFECT. It is not wrong, it is
    /// blind: it writes to a path that does not exist yet, and a test
    /// that only ever exercises the case an API gets right will report
    /// green for as long as the API is wrong about every other case.
    func testWriteOverAWorldReadableFileEndsAt0600() throws {
        let path = tempDir.appendingPathComponent("license.json")

        // Stand in for the `cp` the installer tells the customer to run:
        // a real file, at the mode a default umask actually produces.
        try Data(#"{"version":1,"stale":true}"#.utf8).write(to: path)
        XCTAssertEqual(chmod(path.path, 0o644), 0, "could not set up the 0644 precondition")

        // CONTROL: the precondition is really 0644, or the assertion
        // below is satisfied by a file that was never permissive.
        let before = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((before[.posixPermissions] as? NSNumber)?.uint16Value, 0o644,
                       "precondition did not take: this test would pass vacuously")

        let payload = Data(#"{"version":1,"fresh":true}"#.utf8)
        try LicensePersistence.write(licenseData: payload, to: path)

        let after = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((after[.posixPermissions] as? NSNumber)?.uint16Value, 0o600,
                       "a re-install left the licence readable by every other local account")

        // And the replacement really happened -- a mode assertion over
        // the OLD bytes would be the wrong file passing the right test.
        XCTAssertEqual(LicensePersistence.readExisting(at: path), payload,
                       "the new payload did not land; the mode check above is on stale bytes")
    }

    /// The parent directory is the other half of the same exposure: a
    /// 0600 file inside a 0755 directory still leaks its NAME and its
    /// existence, and `createDirectory` only applies `attributes` when
    /// it is the call that creates the directory.
    func testWriteTightensAPreExistingParentDirectory() throws {
        let parent = tempDir.appendingPathComponent("license", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o755), 0, "could not set up the 0755 precondition")

        let before = try FileManager.default.attributesOfItem(atPath: parent.path)
        XCTAssertEqual((before[.posixPermissions] as? NSNumber)?.uint16Value, 0o755,
                       "precondition did not take: this test would pass vacuously")

        try LicensePersistence.write(
            licenseData: Data("{}".utf8),
            to: parent.appendingPathComponent("license.json")
        )

        let after = try FileManager.default.attributesOfItem(atPath: parent.path)
        XCTAssertEqual((after[.posixPermissions] as? NSNumber)?.uint16Value, 0o700,
                       "the licence directory stayed readable by other local accounts")
    }
}
