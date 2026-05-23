// LicenseEntryDropzoneTests.swift
//
// Byte-by-byte regression tests for the drag-drop licence-file path on
// LicenseEntryView. Pins the EXACT silent-fail shapes that previously
// produced misleading customer-facing messages, so future refactors
// of `loadFromURL` / `readLicenceFile(at:)` cannot resurrect them.
//
// Locked memory `feedback_silent_bail_regression_test_shape` (2026-05-21):
// happy-path tests do not guard the axis -- every silent-fail bug needs
// a test that walks the assembled output byte-by-byte (or AST-node-by-
// node) asserting the EXACT failure shape never recurs.
//
// The two failure shapes pinned here:
//
//   Shape 1 -- read throws, error is swallowed.
//   Pre-fix `loadFromURL` used `try? Data(contentsOf:)` which collapsed
//   permission errors, missing-file, quarantine xattr conflicts on
//   Sequoia, and disconnected network volumes into the same generic
//   "Could not read the licence file at <filename>" message. That was a
//   dead end for both customer and support.
//
//   Shape 2 -- read succeeds, file is zero bytes.
//   Pre-fix path let an empty `Data` slide into the verifier where
//   `JSONSerialization` reported it as malformed. The bytes were not
//   malformed, there just were not any. The mismatched cause-and-effect
//   was almost certainly what Andy's prior-retest "the previous time it
//   said the file was empty or something" memory referred to.

import XCTest
@testable import OstlerInstaller

final class LicenseEntryDropzoneTests: XCTestCase {

    // MARK: - readLicenceFile(at:) byte-by-byte behaviour

    func testReadLicenceFileReturnsBytesForNonEmptyFile() throws {
        // Happy path -- non-empty file reads through unchanged.
        let tmp = try writeTempFile(name: "happy.json", contents: "{\"version\":1}")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data = try readLicenceFile(at: tmp)

        XCTAssertEqual(data, "{\"version\":1}".data(using: .utf8))
        XCTAssertEqual(data.count, 13)
    }

    func testReadLicenceFileThrowsEmptyForZeroByteFile() throws {
        // Shape 2 -- zero-byte file must throw the empty-file error
        // (not slide into the verifier where it would be reported as
        // malformed JSON).
        let tmp = try writeTempFile(name: "empty.json", contents: "")
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try readLicenceFile(at: tmp)) { error in
            guard let err = error as? LicenceFileError else {
                XCTFail("Expected LicenceFileError, got \(type(of: error)): \(error)")
                return
            }
            XCTAssertEqual(err, .empty(filename: "empty.json"),
                "Empty-file path must throw `.empty` with the FILENAME (not full path) for the customer copy.")
        }
    }

    func testReadLicenceFileEmptyErrorCarriesUrlLastPathComponent() throws {
        // Pin the exact filename shape used in the customer-facing copy:
        // `url.lastPathComponent`, not the full /var/folders/... path
        // (which would leak the random temp directory + look bizarre to a
        // customer reading the error).
        let tmp = try writeTempFile(name: "ostler-licence.json", contents: "")
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try readLicenceFile(at: tmp)) { error in
            guard case .empty(let filename) = error as? LicenceFileError else {
                XCTFail("Expected .empty case, got \(error)")
                return
            }
            XCTAssertEqual(filename, "ostler-licence.json",
                "Filename must be url.lastPathComponent, not the full file path.")
            XCTAssertFalse(filename.contains("/"),
                "Filename must NEVER contain a path separator -- it is shown verbatim to the customer.")
        }
    }

    func testReadLicenceFileSurfacesUnderlyingErrorForMissingFile() throws {
        // Shape 1 -- read throws, error must be surfaced (Foundation
        // throws a CocoaError(.fileReadNoSuchFile) here, which the view
        // layer renders via `error.localizedDescription`).
        let missing = URL(fileURLWithPath: "/var/folders/this/path/does/not/exist/\(UUID().uuidString).json")

        XCTAssertThrowsError(try readLicenceFile(at: missing)) { error in
            // We do NOT assert against a specific Foundation error code
            // (it shifts between macOS versions). We assert that the
            // error is NOT swallowed (Shape 1 guard).
            XCTAssertFalse(error is LicenceFileError,
                "Underlying read errors must propagate as the original error, NOT be collapsed into LicenceFileError.")
        }
    }

    // MARK: - ViewCopy catalogue contract for the drop-zone error keys
    //
    // If any of these keys disappear or change shape, every drop-zone
    // failure goes silent again (errorMessage = nil because the lookup
    // returns the empty fallback). Catalogue contract pins it down.

    func testCatalogueHasReadFileErrorWithFilenameAndReasonPlaceholders() {
        let msg = ViewCopy.shared.string(
            for: "license_entry.read_file_error",
            fills: ["filename": "ostler-licence.json", "reason": "Permission denied"]
        )
        XCTAssertTrue(msg.contains("ostler-licence.json"),
            "read_file_error must interpolate {filename} so the customer knows which file failed.")
        XCTAssertTrue(msg.contains("Permission denied"),
            "read_file_error must interpolate {reason} so the customer (and support) get the underlying cause -- Shape 1 silent-bail guard.")
        XCTAssertFalse(msg.contains("{filename}"), "Placeholder must be interpolated, not left literal.")
        XCTAssertFalse(msg.contains("{reason}"), "Placeholder must be interpolated, not left literal.")
    }

    func testCatalogueHasDropFileEmptyErrorWithFilenamePlaceholder() {
        let msg = ViewCopy.shared.string(
            for: "license_entry.drop_file_empty_error",
            fills: ["filename": "ostler-licence.json"]
        )
        XCTAssertTrue(msg.contains("ostler-licence.json"),
            "drop_file_empty_error must interpolate {filename}.")
        XCTAssertTrue(msg.lowercased().contains("empty") || msg.lowercased().contains("zero"),
            "drop_file_empty_error must say the file is empty/zero -- Shape 2 silent-bail guard.")
        XCTAssertTrue(msg.lowercased().contains("re-download") || msg.lowercased().contains("welcome email"),
            "drop_file_empty_error must steer the customer to the welcome email re-download.")
    }

    // MARK: - Customer-facing copy hygiene (locked memories)

    func testDropFileEmptyErrorContainsNoEmDashes() {
        // Locked memory `feedback_em_dash_rule_scope`: em-dashes banned
        // in customer-facing strings.
        let msg = ViewCopy.shared.string(
            for: "license_entry.drop_file_empty_error",
            fills: ["filename": "ostler-licence.json"]
        )
        XCTAssertFalse(msg.contains("\u{2014}"), "drop_file_empty_error must not contain em-dashes (U+2014).")
        XCTAssertFalse(msg.contains("\u{2013}"), "drop_file_empty_error must not contain en-dashes (U+2013) inside a customer message.")
    }

    func testReadFileErrorContainsNoEmDashes() {
        let msg = ViewCopy.shared.string(
            for: "license_entry.read_file_error",
            fills: ["filename": "ostler-licence.json", "reason": "test"]
        )
        XCTAssertFalse(msg.contains("\u{2014}"), "read_file_error must not contain em-dashes (U+2014).")
    }

    // MARK: - Helpers

    private func writeTempFile(name: String, contents: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ostler-licenseentry-dropzone-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }
}
