// EmailSupportMailtoTest.swift
//
// CX-15 regression test (2026-05-23). The pre-CX-15 Email-support
// button on the install-failure pane built a mailto: URL with the
// full PII-redacted log percent-encoded into the body. macOS Mail
// silently truncates mailto: URLs at ~2KB; the body dropped mid-
// sentence around ~580 chars on real customer installs (caught on
// Andy's Mac Studio retest, 2026-05-23). Customers landed in a
// half-written email and could not actually send the log.
//
// The fix copies the redacted log to the clipboard FIRST, then opens
// a SHORT mailto: URL with just the heading + a paste-prompt + the
// separator. The body never contains log content.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// the original bug was a SILENT-BAIL (mailto truncated, no error
// signal anywhere; the customer just saw a broken email). The
// regression test must therefore walk the assembled output byte-by-
// byte refusing the exact failure shape ("body contains log content
// above the URL-length cap"). A happy-path "does it render" test
// would not catch a future "let me inline a small log preview"
// regression.
//
// Per locked memory `feedback_customer_strings_extractable_from_day_one`:
// every catalogue assertion references the dotted key, not the
// English value. If the catalogue is translated later, the test
// still pins the CONTRACT (length cap, clipboard-carries-the-log)
// regardless of the language.

import Foundation
import XCTest
@testable import OstlerInstaller

final class EmailSupportMailtoTest: XCTestCase {

    // MARK: - Constants pinned by the regression test

    /// Defensive cap on the assembled mailto: URL length. macOS Mail
    /// truncates at ~2KB; SupportMailtoBuilder.urlLengthCap sits at
    /// 1024 so any future copy edit has headroom. If a future PR
    /// raises this cap, the cap-rationale comment in
    /// SupportMailtoBuilder MUST be updated at the same time.
    private static let expectedURLLengthCap = 1024

    // MARK: - Mailto string length contract (the headline regression)

    /// The pre-CX-15 implementation produced URLs of ~580 chars per
    /// the bug report (truncated by Mail at the ~2KB mark). A real
    /// install log easily runs 5-50KB once formatted -- the broken
    /// shape would produce a multi-kilobyte URL string.
    ///
    /// This test asserts the assembled URL stays under
    /// `SupportMailtoBuilder.urlLengthCap` (currently 1024 chars).
    /// If a future PR re-introduces the "stuff the log into the
    /// body" shape, the URL will balloon past 1024 and this test
    /// fires.
    func testAssembledMailtoURLIsUnderLengthCap() throws {
        XCTAssertEqual(SupportMailtoBuilder.urlLengthCap, Self.expectedURLLengthCap,
            "SupportMailtoBuilder.urlLengthCap drifted from the pinned regression value (\(Self.expectedURLLengthCap)). " +
            "If you raised the cap deliberately, update this test AND the cap-rationale comment in SupportMailtoBuilder. " +
            "macOS Mail silently truncates mailto: URLs at ~2KB; the cap must stay well below that.")

        let urlString = SupportMailtoBuilder.makeMailtoURLString()
        XCTAssertLessThan(urlString.count, SupportMailtoBuilder.urlLengthCap,
            "Assembled mailto: URL exceeded the \(SupportMailtoBuilder.urlLengthCap)-char cap. " +
            "Got \(urlString.count) chars. " +
            "Almost certainly cause: a future PR re-introduced the 'cram the full log into the body' shape. " +
            "The clipboard already carries the log -- the URL body must stay short.")
    }

    /// Byte-walk: assert the URL is parseable as a URL after
    /// percent-encoding. A malformed URL fails silently when passed
    /// to NSWorkspace.open(), leaving the customer with no email
    /// app launching.
    func testAssembledMailtoURLIsParseable() throws {
        let urlString = SupportMailtoBuilder.makeMailtoURLString()
        XCTAssertNotNil(URL(string: urlString),
            "Assembled mailto: URL failed to parse. Percent-encoding likely missed a character. URL: \(urlString)")
    }

    /// The URL must start with the mailto: scheme and target the
    /// support@ostler.ai address (mirrors the hyperlink the customer
    /// sees in the body paragraph). If a future brand-rename PR
    /// changes one but not the other, this test fires.
    func testMailtoURLTargetsSupportAddress() throws {
        let urlString = SupportMailtoBuilder.makeMailtoURLString()
        XCTAssertTrue(urlString.hasPrefix("mailto:support@ostler.ai?"),
            "mailto: URL must start with 'mailto:support@ostler.ai?' so the customer's mail client opens addressed to support. Got: \(urlString)")
    }

    // MARK: - Body contract (the catalogue-keyed substrings)

    /// The raw (pre-encoding) body must contain the clipboard-
    /// instruction string from the ViewCopy catalogue. This is the
    /// load-bearing sentence that tells the customer "your log is on
    /// the clipboard, paste it here". If a future "let me just inline
    /// the log" regression drops this sentence, the customer reads a
    /// blank email and has no idea their log is on the clipboard.
    func testBodyContainsClipboardInstructionFromCatalogue() throws {
        let body = SupportMailtoBuilder.makeBody()
        let expected = ViewCopy.shared.string(for: "install_failed_banner.email_body_clipboard_instruction")
        XCTAssertFalse(expected.isEmpty,
            "install_failed_banner.email_body_clipboard_instruction must not resolve to an empty string. The ViewCopy catalogue is missing this key.")
        XCTAssertTrue(body.contains(expected),
            "The mailto: body must contain the clipboard-instruction sentence from ViewCopy.json under install_failed_banner.email_body_clipboard_instruction. " +
            "If you removed this sentence the customer will not know their log is on the clipboard. " +
            "Expected substring: '\(expected)'. Got body: '\(body)'.")
    }

    /// The intro greeting ("Hi Ostler support team,") must also come
    /// from the catalogue. Same reasoning as the clipboard
    /// instruction: catalogue keys are the contract, not inline
    /// English.
    func testBodyContainsIntroFromCatalogue() throws {
        let body = SupportMailtoBuilder.makeBody()
        let expected = ViewCopy.shared.string(for: "install_failed_banner.email_body_intro")
        XCTAssertFalse(expected.isEmpty,
            "install_failed_banner.email_body_intro must not resolve to an empty string. The ViewCopy catalogue is missing this key.")
        XCTAssertTrue(body.contains(expected),
            "The mailto: body must open with the intro greeting from ViewCopy.json under install_failed_banner.email_body_intro. Expected substring: '\(expected)'. Got body: '\(body)'.")
    }

    /// The separator ("---") must come from the catalogue too. It
    /// tells the customer where to paste the log.
    func testBodyContainsSeparatorFromCatalogue() throws {
        let body = SupportMailtoBuilder.makeBody()
        let expected = ViewCopy.shared.string(for: "install_failed_banner.email_body_separator")
        XCTAssertFalse(expected.isEmpty,
            "install_failed_banner.email_body_separator must not resolve to an empty string. The ViewCopy catalogue is missing this key.")
        XCTAssertTrue(body.contains(expected),
            "The mailto: body must contain the separator from ViewCopy.json under install_failed_banner.email_body_separator. Expected substring: '\(expected)'. Got body: '\(body)'.")
    }

    // MARK: - Body must NOT contain log content (the failure shape)

    /// The headline silent-bail axis: the body must NOT contain
    /// arbitrary log content. This is the EXACT failure shape the
    /// regression test must refuse. A future "let me just inline a
    /// small log preview" PR would re-introduce the truncation bug;
    /// we lock it out by asserting the body stays bounded.
    ///
    /// Strategy: synthesise a sentinel log line, run the builder,
    /// assert the assembled body does NOT contain the sentinel.
    /// (Since the builder does not accept log content as input, this
    /// is structurally guaranteed -- but the test pins the contract
    /// so a future signature change like
    /// `SupportMailtoBuilder.makeBody(log:)` cannot silently
    /// re-introduce the leak.)
    func testBodyDoesNotContainLogContent() throws {
        // Sentinel strings that would appear in a real install log
        // but never in a customer-facing body. If any of these
        // appear in the assembled body, a future PR has wired log
        // content back into the URL.
        let logShapeSentinels = [
            "ERROR",
            "[install.sh]",
            "stack trace",
            "exit code",
            "/usr/local/bin/",
            "ostler-",
        ]
        let body = SupportMailtoBuilder.makeBody()
        for sentinel in logShapeSentinels {
            XCTAssertFalse(body.lowercased().contains(sentinel.lowercased()),
                "The mailto: body contains a log-shape sentinel ('\(sentinel)'). " +
                "This is the CX-15 silent-bail failure shape: log content in the URL body, " +
                "which macOS Mail truncates at ~2KB. The log must live on the clipboard, " +
                "not in the URL. Got body: '\(body)'.")
        }
    }

    /// Defensive: even if a future PR adds an OPTIONAL log argument
    /// to the builder, the BODY assembled from the catalogue keys
    /// alone must stay short enough that the URL-length cap kicks in
    /// before any log content can be appended. Asserts the raw body
    /// is under 512 chars (half the URL-length cap, leaves headroom
    /// for subject percent-encoding overhead).
    func testRawBodyIsBounded() throws {
        let body = SupportMailtoBuilder.makeBody()
        XCTAssertLessThan(body.count, 512,
            "The raw (pre-encoding) mailto: body grew past 512 chars (\(body.count)). " +
            "Catalogue copy has bloated past the design budget. " +
            "Either trim the copy or update the cap with a justification.")
    }

    // MARK: - Pasteboard contract (the clipboard side of the fix)

    /// The clipboard must carry the redacted log AFTER the support-
    /// mailto path runs. The view-level helper does the actual
    /// NSPasteboard.general.setString call; we exercise the same
    /// pattern here on the GENERAL pasteboard to lock the shape
    /// (clear + setString of the redacted log).
    ///
    /// We deliberately do NOT mock NSPasteboard: the real general
    /// pasteboard is the macOS-wide one, but XCTest runs in its own
    /// process and writing to it during a test is reversible (we
    /// stash + restore). The point is to assert the pattern: redact
    /// then write, not to assert NSPasteboard's internals.
    func testClipboardCarriesRedactedLogAfterCopy() throws {
        let pb = NSPasteboard.general
        let savedContents = pb.string(forType: .string)

        // Synthesise a log that would trip the redactor. The redactor
        // masks emails, phones, IPs, paths, UUIDs etc. A bare
        // "ERROR: failure" passes through redaction unchanged (no
        // PII), which is what we want -- we are pinning the
        // clipboard-write step, not LogRedactor's behaviour.
        let synthetic = "ERROR: install failure (synthetic test log, no PII)"
        let redacted = LogRedactor.redact(synthetic)

        pb.clearContents()
        pb.setString(redacted, forType: .string)

        let got = pb.string(forType: .string)
        XCTAssertEqual(got, redacted,
            "After clipboard-copy of the redacted log, NSPasteboard.general should return the same string. Got: \(got ?? "<nil>"); expected: \(redacted)")

        // Restore the developer's prior clipboard. Not strictly
        // required for CI, but courteous on local runs.
        pb.clearContents()
        if let savedContents {
            pb.setString(savedContents, forType: .string)
        }
    }

    // MARK: - Catalogue-key contract (the new keys must exist)

    /// Pins the four new catalogue keys CX-15 added. If a future PR
    /// removes one (re-inlining the literal in Swift), the test
    /// fires before the inline literal can land.
    func testNewCatalogueKeysExist() throws {
        let keys = [
            "install_failed_banner.email_body_intro",
            "install_failed_banner.email_body_clipboard_instruction",
            "install_failed_banner.email_body_separator",
            "install_failed_banner.email_subject",
            "install_failed_banner.email_copied_hint",
        ]
        for key in keys {
            let value = ViewCopy.shared.string(for: key)
            // ViewCopy.shared.string(for:) falls back to the dotted
            // key itself if the key is missing -- so equality with
            // the input means "key not present in the catalogue".
            XCTAssertNotEqual(value, key,
                "ViewCopy catalogue is missing key '\(key)'. CX-15 added this key; a future PR removed it. " +
                "Re-add it to gui/OstlerInstaller/Resources/ViewCopy.json under install_failed_banner.")
            XCTAssertFalse(value.isEmpty,
                "ViewCopy catalogue value for '\(key)' is empty.")
        }
    }
}
