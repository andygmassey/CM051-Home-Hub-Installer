// LicenseEntryShortIdHeuristicTests.swift
//
// Pins the contract from TNM_BRIEF_CM051_LICENCE_ID_UX_2026-05-17.md:
// when a customer pastes their short Licence ID (the inline-text
// fallback from the welcome email) into the JSON-paste field, the
// installer must recognise the shape and show the friendly guidance
// message rather than the meaningless "JSON malformed" verifier error.
//
// The heuristic is `looksLikeShortLicenceId(_:)`, a top-level
// internal helper in LicenseEntryView.swift -- pure String -> Bool,
// no SwiftUI state required, so we test it directly via
// `@testable import OstlerInstaller`.

import XCTest
@testable import OstlerInstaller

final class LicenseEntryShortIdHeuristicTests: XCTestCase {

    // MARK: - Positive cases (should trigger friendly guidance)

    func testEightCharHexIsRecognisedAsShortId() {
        XCTAssertTrue(looksLikeShortLicenceId("a1b2c3d4"))
    }

    func testSixteenCharHexIsRecognisedAsShortId() {
        XCTAssertTrue(looksLikeShortLicenceId("a1b2c3d4e5f60718"))
    }

    func testMixedCaseHexIsRecognisedAsShortId() {
        XCTAssertTrue(looksLikeShortLicenceId("A1B2C3D4"))
    }

    func testUppercaseHexIsRecognisedAsShortId() {
        XCTAssertTrue(looksLikeShortLicenceId("DEADBEEF"))
    }

    func testHexWithDashIsRecognisedAsShortId() {
        // Customer might copy with a trailing dash from a hyphenated UUID
        XCTAssertTrue(looksLikeShortLicenceId("a1b2c3d4-"))
    }

    func testLeadingAndTrailingWhitespaceIsTrimmed() {
        XCTAssertTrue(looksLikeShortLicenceId("  a1b2c3d4  "))
        XCTAssertTrue(looksLikeShortLicenceId("\na1b2c3d4\n"))
    }

    // MARK: - Negative cases (should NOT trigger; falls through to
    // existing JSON-parse path or existing empty-paste guard)

    func testRealLicenceJsonIsNotRecognisedAsShortId() {
        let json = "{\"version\":1,\"license_id\":\"8c7e3f9a-1234-4abc-9def-0123456789ab\"}"
        XCTAssertFalse(looksLikeShortLicenceId(json))
    }

    func testShortJunkWithBraceIsNotRecognisedAsShortId() {
        // Contains `{` -- falls through to verifier, which fails
        // with the existing malformed-JSON error message.
        XCTAssertFalse(looksLikeShortLicenceId("{junk}"))
    }

    func testEmptyStringIsNotRecognisedAsShortId() {
        // Empty must NOT trigger the friendly guidance, because the
        // existing empty-paste guard has its own (better) error.
        XCTAssertFalse(looksLikeShortLicenceId(""))
        XCTAssertFalse(looksLikeShortLicenceId("   "))
    }

    func testStringLongerThanSixteenCharsIsNotRecognised() {
        // 17 hex chars: too long to be a short ID, almost certainly
        // a paste error or the start of real JSON.
        XCTAssertFalse(looksLikeShortLicenceId("a1b2c3d4e5f6071829"))
    }

    func testStringWithSpacesInsideIsNotRecognised() {
        // Internal whitespace rules it out (hex chars don't have
        // spaces between them).
        XCTAssertFalse(looksLikeShortLicenceId("a1b2 c3d4"))
    }

    func testStringWithNonHexLettersIsNotRecognised() {
        // 'g' isn't a hex char, so the all-satisfy check fails.
        XCTAssertFalse(looksLikeShortLicenceId("a1g2c3d4"))
    }

    func testStringWithQuoteIsNotRecognised() {
        // Defensive: `"` indicates JSON, falls through to verifier.
        XCTAssertFalse(looksLikeShortLicenceId("\"a1b2c3d4\""))
    }

    func testGuidanceMessageMentionsCorrectFileName() {
        // The customer needs to know what file to look for.
        XCTAssertTrue(LicenseEntryView.shortIdGuidanceMessage.contains("ostler-licence.json"))
    }

    func testGuidanceMessageMentionsSupportEmail() {
        // Customer must have an out if they cannot find the email.
        XCTAssertTrue(LicenseEntryView.shortIdGuidanceMessage.contains("hello@ostler.ai"))
    }
}
