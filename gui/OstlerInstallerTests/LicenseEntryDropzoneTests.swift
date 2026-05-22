// LicenseEntryDropzoneTests.swift
//
// Pins the contract from TNM_CM051_DROPZONE_DEEP_DIVE_2026-05-22.md:
// every failure shape on the drop-zone path must reach the customer
// with an accurate error string, not a swallowed `try?` or a
// misleading "malformed JSON" emitted by `verify(data:)` after an
// empty Data slides through.
//
// Three failure shapes the deep-dive identified:
//   1. URL read throws (permissions, missing file, quarantine xattr
//      conflict on Sequoia, network volume disconnect, etc.) -- the
//      underlying error.localizedDescription must surface, not be
//      swallowed into a generic "Could not read the licence file"
//      message.
//   2. URL read succeeds with zero bytes -- previously, the empty
//      Data slid into `verify(data:)` and emitted the misleading
//      "Could not parse licence JSON" malformed-error. Must now
//      surface as a distinct `drop_file_empty_error` so the
//      customer is told to re-download.
//   3. URL read succeeds with non-empty data -- the data must reach
//      `verify(data:source:"drop-file")` byte-for-byte.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// every fix gets a byte-by-byte regression test pinning the failure
// shape so a future "tidy-up" cannot silently reintroduce the
// swallow.

import Foundation
import XCTest
@testable import OstlerInstaller

final class LicenseEntryDropzoneTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        // Per-test UUID suffix avoids parallel-runner collisions
        // when XCTest schedules these alongside other tests sharing
        // a PID-based temp dir (locked-memory pattern from the
        // LicensePersistence test scaffold).
        tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("LicenseEntryDropzoneTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: - Shape 1: URL read failure surfaces underlying error

    func testReadLicenceFileMissingFileThrowsUnderlyingError() {
        // No file written at this path. `Data(contentsOf:)` should
        // throw an NSCocoaError. The deep-dive fix promotes `try?`
        // to `try` so this error propagates rather than being
        // collapsed into a generic "could not read" message.
        let missing = tempDir.appendingPathComponent("never-existed.json")
        XCTAssertThrowsError(try readLicenceFile(at: missing)) { error in
            // We deliberately do NOT match on a specific NSError
            // domain/code -- macOS may evolve the underlying type
            // (URLError vs NSCocoaError vs POSIXError) across
            // releases. What matters is the error survives the
            // throw boundary so the caller can call
            // .localizedDescription on it.
            let description = (error as NSError).localizedDescription
            XCTAssertFalse(
                description.isEmpty,
                "underlying read error must carry a non-empty localizedDescription"
            )
            // And it must NOT be the sentinel-empty marker -- a
            // missing file is not the same shape as an empty file.
            XCTAssertFalse(
                error is LicenceFileEmpty,
                "missing file should NOT be reported as the empty-file shape"
            )
        }
    }

    // MARK: - Shape 2: 0-byte file -> distinct empty-file error

    func testReadLicenceFileZeroByteFileThrowsLicenceFileEmpty() throws {
        // Pre-fix shape: `try? Data(contentsOf:)` succeeded with an
        // empty Data, then `verify(data:)` JSON-parsed it and the
        // customer saw "Could not parse licence JSON". The deep-dive
        // fix raises `LicenceFileEmpty` BEFORE the data reaches the
        // verifier so the customer sees the empty-file message.
        let empty = tempDir.appendingPathComponent("ostler-licence.json")
        FileManager.default.createFile(atPath: empty.path, contents: Data(), attributes: nil)
        XCTAssertEqual(
            try Data(contentsOf: empty).count, 0,
            "fixture sanity: the file must actually be zero bytes"
        )
        XCTAssertThrowsError(try readLicenceFile(at: empty)) { error in
            XCTAssertTrue(
                error is LicenceFileEmpty,
                "0-byte file must throw LicenceFileEmpty, not the generic read error"
            )
        }
    }

    // MARK: - Shape 3: valid file -> byte-for-byte passthrough

    func testReadLicenceFileNonEmptyFileReturnsBytesUnchanged() throws {
        let valid = tempDir.appendingPathComponent("ostler-licence.json")
        // Synthetic JSON (pi_TEST_* / synthetic UUID per locked
        // testing convention). Not a real licence -- this test does
        // not exercise the verifier, only the disk-read path.
        let payload = Data(#"{"version":1,"license_id":"00000000-0000-4000-8000-000000000000","pi":"pi_TEST_dropzone_deep_dive"}"#.utf8)
        try payload.write(to: valid)
        let readBack = try readLicenceFile(at: valid)
        XCTAssertEqual(
            readBack, payload,
            "valid file must round-trip byte-for-byte"
        )
        XCTAssertGreaterThan(
            readBack.count, 0,
            "guard against a future regression where the empty-check is moved before the read"
        )
    }

    // MARK: - String catalogue contract

    // These tests pin the customer-facing message shape. If the
    // English copy is rewritten, the assertions must be updated
    // deliberately; they should not silently drift.

    func testReadFileErrorSurfacesBothFilenameAndReason() {
        // Pre-fix: only {filename} was substituted. Post-fix the
        // catalogue value MUST include {reason} so the underlying
        // error.localizedDescription is shown to the customer (and
        // to support@ostler.ai screenshots).
        let rendered = ViewCopy.shared.string(
            for: "license_entry.read_file_error",
            fills: [
                "filename": "ostler-licence.json",
                "reason": "Permission denied (test fixture)"
            ]
        )
        XCTAssertTrue(
            rendered.contains("ostler-licence.json"),
            "rendered message must surface the filename: got \(rendered)"
        )
        XCTAssertTrue(
            rendered.contains("Permission denied (test fixture)"),
            "rendered message must surface the underlying reason: got \(rendered)"
        )
    }

    func testDropFileEmptyErrorIsDistinctFromMalformedError() {
        // Pin: the empty-file message must NOT be the same string as
        // the malformed-JSON message. The pre-fix bug was that empty
        // bytes triggered the malformed-JSON path, and any future
        // attempt to "consolidate" these two strings would reintroduce
        // that misleading cause-and-effect mapping.
        let empty = ViewCopy.shared.string(
            for: "license_entry.drop_file_empty_error",
            fills: ["filename": "ostler-licence.json"]
        )
        let malformed = ViewCopy.shared.string(
            for: "license_entry.malformed_error",
            fills: ["reason": "Unexpected end of input"]
        )
        XCTAssertNotEqual(empty, malformed)
        XCTAssertTrue(
            empty.contains("ostler-licence.json"),
            "empty-file message must surface the filename: got \(empty)"
        )
        XCTAssertTrue(
            empty.lowercased().contains("empty"),
            "empty-file message must mention emptiness so the customer knows the file (not the content) is the problem: got \(empty)"
        )
    }

    func testDropFileEmptyErrorAdvisesReDownload() {
        // Customer-action contract: an empty licence file is almost
        // always a Mail download truncation or a save-as that lost
        // the content. The remediation is to re-download from the
        // welcome email, not to retry the same broken file.
        let rendered = ViewCopy.shared.string(
            for: "license_entry.drop_file_empty_error",
            fills: ["filename": "ostler-licence.json"]
        )
        XCTAssertTrue(
            rendered.lowercased().contains("re-download")
                || rendered.lowercased().contains("redownload")
                || rendered.lowercased().contains("download"),
            "empty-file message must advise re-downloading: got \(rendered)"
        )
    }
}
