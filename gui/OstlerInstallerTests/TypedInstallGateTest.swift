// TypedInstallGateTest.swift
//
// Pins the contract for `typedInstallInputMatches(sentinel:input:)`,
// the pure validator behind the Q15 typed-INSTALL legal gate
// (PromptKind.textWithCancel). The validator gates the Continue
// button in OnboardingQuestionView's button row + is the
// defence-in-depth check inside the view's validate() method.
//
// Per Andy's brief: this is the "user proactively writes INSTALL
// for Legal reasons" surface. The validator must:
//   - accept ASCII INSTALL (case-insensitive, trimmed)
//   - reject empty input
//   - reject any other text
//   - reject Unicode-lookalike "ＩＮＳＴＡＬＬ" (full-width
//     Halfwidth+Fullwidth Forms block) -- the legal-ceremony
//     intent is "the exact ASCII word", not "anything that
//     looks like it"
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// the failure shapes are pinned byte-by-byte so a future tidy-up
// can't silently relax the validator.

import Foundation
import XCTest
@testable import OstlerInstaller

final class TypedInstallGateTest: XCTestCase {

    // MARK: - Accept shapes

    func testExactAsciiUppercaseAccepts() {
        XCTAssertTrue(typedInstallInputMatches(sentinel: "INSTALL", input: "INSTALL"))
    }

    func testExactAsciiLowercaseAccepts() {
        // Case-insensitive: typing "install" should be enough.
        // The customer's legal-ceremony intent doesn't depend on
        // shift-key engagement.
        XCTAssertTrue(typedInstallInputMatches(sentinel: "INSTALL", input: "install"))
    }

    func testMixedCaseAccepts() {
        XCTAssertTrue(typedInstallInputMatches(sentinel: "INSTALL", input: "InStAlL"))
        XCTAssertTrue(typedInstallInputMatches(sentinel: "INSTALL", input: "Install"))
    }

    func testLeadingTrailingWhitespaceIsTrimmed() {
        XCTAssertTrue(typedInstallInputMatches(sentinel: "INSTALL", input: " INSTALL"))
        XCTAssertTrue(typedInstallInputMatches(sentinel: "INSTALL", input: "INSTALL "))
        XCTAssertTrue(typedInstallInputMatches(sentinel: "INSTALL", input: "  INSTALL  "))
        XCTAssertTrue(typedInstallInputMatches(sentinel: "INSTALL", input: "\tINSTALL\n"))
    }

    func testLowercaseSentinelStillAccepts() {
        // The function uppercases both sides, so a lower-case
        // sentinel ("install") should still match a typed
        // upper-case answer. This guards against an install.sh
        // bug that passes the sentinel in the wrong case.
        XCTAssertTrue(typedInstallInputMatches(sentinel: "install", input: "INSTALL"))
        XCTAssertTrue(typedInstallInputMatches(sentinel: "install", input: "install"))
    }

    // MARK: - Reject shapes

    func testEmptyInputRejects() {
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: ""))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "   "))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "\n\t  \n"))
    }

    func testEmptySentinelRejectsEverything() {
        // Defence-in-depth: if install.sh somehow passes no
        // choices through, the validator must reject every input
        // so the customer can never click Continue.
        XCTAssertFalse(typedInstallInputMatches(sentinel: "", input: "INSTALL"))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "", input: ""))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "", input: "anything"))
    }

    func testCancelDoesNotAcceptAsInstall() {
        // The Cancel button posts "CANCEL" on its own path; the
        // typed-input validator must NOT treat the cancel sentinel
        // as an accept (the legal ceremony is "type INSTALL", not
        // "type anything from the choices list").
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "CANCEL"))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "cancel"))
    }

    func testPartialTypingRejects() {
        // Customer typing toward the sentinel must not trigger
        // accept until they're fully done. The button-disabled
        // state guards this in the view; the validator pins it
        // independently.
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "I"))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "INSTAL"))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "INSTALLL"))
    }

    func testAnyOtherTextRejects() {
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "yes"))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "ok"))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "continue"))
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "Install Ostler"))
    }

    func testUnicodeFullwidthLookalikeRejects() {
        // Full-width INSTALL via the Halfwidth+Fullwidth Forms
        // Unicode block. String.uppercased() does NOT case-fold
        // these to ASCII, so the validator rejects them. The
        // legal ceremony's "exact ASCII word" intent is what makes
        // this test load-bearing: a future "broaden case folding"
        // tweak would silently accept Unicode lookalikes.
        XCTAssertFalse(typedInstallInputMatches(
            sentinel: "INSTALL",
            input: "\u{FF29}\u{FF2E}\u{FF33}\u{FF34}\u{FF21}\u{FF2C}\u{FF2C}"
        ))
        // Same string written literally for the QA reviewer to see:
        XCTAssertFalse(typedInstallInputMatches(
            sentinel: "INSTALL",
            input: "ＩＮＳＴＡＬＬ"
        ))
    }

    func testCyrillicLookalikeRejects() {
        // Cyrillic letters that share Latin glyph shapes
        // (А Н С Т etc.). Same intent as the full-width test --
        // exact ASCII or bust.
        XCTAssertFalse(typedInstallInputMatches(
            sentinel: "INSTALL",
            input: "ІНЅТАLL"
        ))
    }

    func testEmojiRejects() {
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "🟢 INSTALL"))
        // Trailing emoji breaks the trimmed match because the
        // emoji is not whitespace and stays in the compared string.
        XCTAssertFalse(typedInstallInputMatches(sentinel: "INSTALL", input: "INSTALL ✅"))
    }

    // MARK: - Catalogue contract (mismatch message + placeholder)

    // These tests pin the customer-facing strings the view uses.
    // If they're renamed or removed the typed-INSTALL surface
    // would silently render the dotted key as fallback text;
    // we'd rather fail CI.

    func testPlaceholderStringExists() {
        let placeholder = ViewCopy.shared.string(
            for: "onboarding_question.consent_install_typed_placeholder"
        )
        XCTAssertNotEqual(
            placeholder,
            "onboarding_question.consent_install_typed_placeholder",
            "Placeholder key missing from ViewCopy.json -- the typed-input field would render an empty placeholder."
        )
        // Sanity-check: it should mention typing INSTALL.
        XCTAssertTrue(
            placeholder.uppercased().contains("INSTALL"),
            "Placeholder should reference INSTALL so the customer knows what to type: got \(placeholder)"
        )
    }

    func testMismatchStringExists() {
        let mismatch = ViewCopy.shared.string(
            for: "onboarding_question.consent_install_typed_mismatch"
        )
        XCTAssertNotEqual(
            mismatch,
            "onboarding_question.consent_install_typed_mismatch",
            "Mismatch key missing from ViewCopy.json -- the validator would surface the dotted key as fallback."
        )
        XCTAssertTrue(
            mismatch.uppercased().contains("INSTALL"),
            "Mismatch message should tell the customer what to type: got \(mismatch)"
        )
    }
}
