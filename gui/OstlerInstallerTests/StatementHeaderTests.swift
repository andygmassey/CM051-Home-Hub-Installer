// StatementHeaderTests.swift
//
// Pins the B3 (CX-14) contract for the OnboardingQuestionView
// statement-screen header: info-only prompts (no user input field,
// just text + Continue) render "FOR YOUR INFORMATION" in the
// strap-line instead of "QUESTION X".
//
// Path A per Andy's pre-answered default: hard-code a Set<String>
// of statement-prompt ids inside the view, no metadata protocol
// extension (which would have churned the contract tests).
//
// This test pins the OBSERVABLE part of the contract:
//   - the catalogue key the header reads from exists
//   - the catalogue value is the agreed customer string (case + tone)
//
// The private Set itself is exercised indirectly via the snapshot
// test next door (which renders the actual view). The hard part of
// the silent-fail axis is the catalogue key going missing -- if the
// view looked up a key the catalogue didn't have, ViewCopy returns
// the dotted key as fallback and the header would silently render
// "ONBOARDING_QUESTION.HEADER_STATEMENT_LABEL".

import XCTest
@testable import OstlerInstaller

final class StatementHeaderTests: XCTestCase {

    func testStatementLabelKeyExists() {
        let label = ViewCopy.shared.string(
            for: "onboarding_question.header_statement_label"
        )
        XCTAssertNotEqual(
            label,
            "onboarding_question.header_statement_label",
            "Catalogue key missing -- statement-shaped screens would render the dotted key as fallback."
        )
    }

    func testStatementLabelMentionsInformation() {
        // The strap-line replaces "QUESTION X" so the customer
        // understands they're being shown information, not asked
        // for input. The exact wording is "For your information"
        // (uppercased at render time by the header function).
        let label = ViewCopy.shared.string(
            for: "onboarding_question.header_statement_label"
        )
        XCTAssertTrue(
            label.lowercased().contains("information"),
            "Statement label should reference 'information' so the screen reads as info-only: got \(label)"
        )
    }

    func testStatementLabelDoesNotReferenceQuestion() {
        // Crucial regression axis: if a future tweak accidentally
        // puts "Question" back into this key, the surface silently
        // becomes "QUESTION X" again and B3 regresses. Pin the
        // negative explicitly.
        let label = ViewCopy.shared.string(
            for: "onboarding_question.header_statement_label"
        )
        XCTAssertFalse(
            label.lowercased().contains("question"),
            "Statement label must not contain 'question' -- that's the surface B3 fixes: got \(label)"
        )
    }

    func testStatementLabelDoesNotContainCurrentPlaceholder() {
        // Statement screens have no question index; the label
        // must not template `{current}` (a leftover from copying
        // header_without_total).
        let label = ViewCopy.shared.string(
            for: "onboarding_question.header_statement_label"
        )
        XCTAssertFalse(
            label.contains("{current}"),
            "Statement label must not template the question index: got \(label)"
        )
    }
}
