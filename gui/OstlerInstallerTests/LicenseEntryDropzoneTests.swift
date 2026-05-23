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

    // MARK: - Branch C public.json item resolution (CX-16, 2026-05-23)
    //
    // The CX-16 bug: Finder drops of a .json file under the public.json
    // representation return a file URL (URL or NSURL), NOT the file
    // bytes. The pre-fix Branch C handler only cast to Data + String,
    // so the URL case fell to the empty-payload branch and customers
    // saw "Could not read the dropped JSON (JSON payload was empty)"
    // on what should have been a valid drop.
    //
    // The dispatcher now walks Data -> String -> URL -> NSURL -> empty
    // via `resolveDroppedJSONItem(_:)`. These tests pin that order
    // byte-by-byte. The axis of failure (per locked memory
    // `feedback_silent_bail_regression_test_shape`) is "what
    // NSItemProvider returns under public.json".

    func testResolveDroppedJSON_DataItem_ResolvesAsData() {
        // First arm: when caller returns raw bytes, dispatcher takes
        // them as-is. Guard against a future refactor that re-encodes
        // the Data through String (which would corrupt non-utf8 bytes).
        let payload = Data(#"{"version":1,"license_id":"abc"}"#.utf8)

        let resolution = resolveDroppedJSONItem(payload)

        XCTAssertEqual(resolution, .data(payload),
            "Data item must resolve to .data(...) without re-encoding.")
    }

    func testResolveDroppedJSON_StringItem_ResolvesAsString() {
        // Second arm: String input is utf8-encoded into Data before
        // the verifier sees it.
        let payload = #"{"version":1}"#

        let resolution = resolveDroppedJSONItem(payload)

        XCTAssertEqual(resolution, .string(Data(payload.utf8)),
            "String item must resolve to .string with utf8-encoded bytes.")
    }

    func testResolveDroppedJSON_URLItem_ResolvesAsURL_WhichLoadsFileBytes() throws {
        // Third arm + the actual CX-16 fix: a URL pointing at the
        // dropped .json file must resolve via .url(...) so the
        // view layer routes through loadFromURL + readLicenceFile,
        // not into the empty-payload branch. Test also asserts
        // readLicenceFile actually reads the file when given the
        // resolved URL (the end-to-end happy path the customer hits
        // when dragging ostler-licence.json out of Finder).
        let tmp = try writeTempFile(name: "ostler-licence.json", contents: #"{"version":1}"#)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolution = resolveDroppedJSONItem(tmp)

        guard case .url(let url) = resolution else {
            XCTFail("URL item must resolve to .url(...), got \(resolution).")
            return
        }
        XCTAssertEqual(url, tmp, "URL passthrough must preserve the original URL value.")

        // End-to-end: the URL must read through readLicenceFile
        // without throwing the empty-file guard (which would re-create
        // the old customer-facing error).
        let data = try readLicenceFile(at: url)
        XCTAssertEqual(data, Data(#"{"version":1}"#.utf8),
            "readLicenceFile must succeed for the URL the dispatcher hands off; otherwise the customer is back to the empty banner.")
    }

    func testResolveDroppedJSON_NSURLItem_ResolvesAsURL() throws {
        // Fourth arm: Foundation occasionally hands back the bridged
        // NSURL class rather than the Swift URL value type (older
        // Cocoa code paths, Objective-C extensions). Customers in
        // that path must NOT silently drop to the empty branch.
        let tmp = try writeTempFile(name: "ostler-licence.json", contents: #"{"version":1}"#)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridged: NSURL = tmp as NSURL

        let resolution = resolveDroppedJSONItem(bridged)

        guard case .url(let url) = resolution else {
            XCTFail("NSURL item must resolve to .url(...), got \(resolution).")
            return
        }
        XCTAssertEqual(url.lastPathComponent, "ostler-licence.json",
            "NSURL fall-through must preserve the path so loadFromURL can read it.")
        XCTAssertFalse(resolution == .empty,
            "NSURL must never fall to .empty; that path resurrects the original CX-16 bug.")
    }

    // MARK: - Branch C empty-data / empty-string / nil regression (original
    //         user-visible behaviour stays when nothing usable comes back)

    func testResolveDroppedJSON_NilItem_ResolvesAsEmpty() {
        // The pre-fix behaviour: nil item -> "JSON payload was empty"
        // error banner. Kept as a regression test so the URL/NSURL
        // additions did NOT swallow the genuinely-empty case (which
        // would advance the verifier with garbage and produce a
        // misleading malformed-JSON banner downstream).
        XCTAssertEqual(resolveDroppedJSONItem(nil), .empty,
            "nil item must resolve to .empty so the view surfaces the existing JSON-payload-was-empty banner.")
    }

    func testResolveDroppedJSON_EmptyData_ResolvesAsEmpty() {
        // A provider that loaded zero bytes is the same shape as
        // nil from the customer's perspective: no licence to verify.
        XCTAssertEqual(resolveDroppedJSONItem(Data()), .empty,
            "Empty Data must not advance to .data; verify would see zero bytes and report malformed JSON.")
    }

    func testResolveDroppedJSON_EmptyString_ResolvesAsEmpty() {
        XCTAssertEqual(resolveDroppedJSONItem(""), .empty,
            "Empty String must not advance to .string; verify would see zero bytes and report malformed JSON.")
    }

    func testResolveDroppedJSON_UnrelatedType_ResolvesAsEmpty() {
        // Defensive: a provider that hands back an unrelated object
        // (e.g. NSNumber from a misbehaving extension) must not crash
        // -- it must fall to .empty so the customer gets the existing
        // error banner.
        XCTAssertEqual(resolveDroppedJSONItem(NSNumber(value: 42)), .empty)
        XCTAssertEqual(resolveDroppedJSONItem([1, 2, 3]), .empty)
        XCTAssertEqual(resolveDroppedJSONItem(["k": "v"]), .empty)
        XCTAssertEqual(resolveDroppedJSONItem(NSObject()), .empty,
            "Unknown types must terminate at .empty so the view shows the error banner.")
    }

    // MARK: - Byte-walk: dispatcher fall-through ORDER
    //
    // Per locked memory `feedback_silent_bail_regression_test_shape`:
    // walk the assembled output node-by-node asserting the EXACT
    // order each type takes through the switch. These tests guarantee
    // that even if a future refactor re-orders the if-let chain, the
    // resolved arm matches the type the runtime hands back.
    //
    // Order: Data -> String -> URL -> NSURL -> empty
    //
    // Each test walks ONE input shape and asserts the EXACT arm fires,
    // not a happy-path "does it work" lookup.

    func testDispatcherOrder_Arm1_DataInputResolvesViaDataArm() {
        // Arm 1: Data. Anything castable as Data resolves through this
        // arm and never falls to .url / .empty. Guard against a future
        // refactor that accidentally puts URL above Data.
        let payload = Data(#"{"version":1}"#.utf8)

        let resolution = resolveDroppedJSONItem(payload)

        guard case .data = resolution else {
            XCTFail("Arm 1 (Data) must fire for Data input, got \(resolution).")
            return
        }
    }

    func testDispatcherOrder_Arm2_StringInputResolvesViaStringArm() {
        // Arm 2: String. A String cannot bridge to URL via `as?`, so
        // this test pins the contract that the dispatcher does NOT
        // try URL(string:) on a String input (which would mis-route
        // a JSON-string payload into the file-load path and almost
        // certainly throw at readLicenceFile).
        let resolution = resolveDroppedJSONItem(#"{"version":1}"#)

        guard case .string = resolution else {
            XCTFail("Arm 2 (String) must fire for String input, got \(resolution).")
            return
        }
    }

    func testDispatcherOrder_Arm3_URLInputResolvesViaURLArm() throws {
        // Arm 3: URL. A native Swift URL value matches the URL arm
        // first; it never falls through to the NSURL arm. The NSURL
        // arm only fires when Foundation hands back the bridged class.
        let tmp = try writeTempFile(name: "ostler-licence.json", contents: "{}")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolution = resolveDroppedJSONItem(tmp)

        guard case .url(let url) = resolution else {
            XCTFail("Arm 3 (URL) must fire for URL input, got \(resolution).")
            return
        }
        XCTAssertEqual(url, tmp, "URL arm must preserve the original URL value.")
    }

    func testDispatcherOrder_Arm4_NSURLInputResolvesViaNSURLArm() throws {
        // Arm 4: NSURL. Foundation-bridged NSURL must fall through
        // to this arm (Swift URL hits Arm 3 first), and must convert
        // via `as URL` so the resulting URL is loadable by
        // readLicenceFile.
        let tmp = try writeTempFile(name: "ostler-licence.json", contents: "{}")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bridged: NSURL = tmp as NSURL

        let resolution = resolveDroppedJSONItem(bridged)

        guard case .url(let url) = resolution else {
            XCTFail("Arm 4 (NSURL) must fire for NSURL input and emit .url, got \(resolution).")
            return
        }
        XCTAssertEqual(url.lastPathComponent, tmp.lastPathComponent,
            "NSURL -> URL conversion must preserve path components.")
        // Sanity check: the converted URL is actually loadable.
        XCTAssertNoThrow(try Data(contentsOf: url),
            "NSURL -> URL conversion must yield a URL that Foundation can read.")
    }

    func testDispatcherOrder_Arm5_UnknownInputResolvesViaEmptyArm() {
        // Arm 5: terminal. Nothing matched. Critical that the
        // dispatcher does not crash + does not silently advance to
        // verify with garbage bytes. The customer-visible behaviour
        // here is the existing JSON-payload-was-empty banner; this
        // test pins the resolution feed-in to that banner.
        let resolution = resolveDroppedJSONItem(NSObject())

        XCTAssertEqual(resolution, .empty,
            "Arm 5 (empty) must fire for unknown types so the customer sees the existing error banner, not a crash or silent advance.")
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
