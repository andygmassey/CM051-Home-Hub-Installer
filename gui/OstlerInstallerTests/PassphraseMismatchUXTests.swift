// PassphraseMismatchUXTests.swift
//
// CX-97 regression tests (DMG #48g+1, 2026-05-29).
//
// Andy reported on the DMG #48g Studio retest:
//
//   The "Choose your passphrase" and "Confirm"s UX should be improved
//   when they don't match too -- at the moment it just repeats, no
//   acknowledgement why, ie. that the passphrases didn't match, and
//   also adds +1 to the question number, so the user thinks they're
//   just being asked again or for something else.
//
// Two failure axes have to be pinned at the state-machine layer so
// the fix cannot silently regress in a future refactor:
//
//   1. Step-counter axis: when install.sh re-emits an EARLIER prompt
//      id after a later prompt has been displayed (e.g.
//      recovery_passphrase re-emitted after recovery_passphrase_confirm
//      landed a mismatch), the X counter MUST restore to the EARLIER
//      prompt's original index. Pre-fix the dedupe correctly stopped
//      X from incrementing on the re-emit, but X stayed pinned at the
//      LATEST seen value, so the customer saw "Question 15" with the
//      "Choose your passphrase" prompt body (originally Q14).
//
//   2. Error-banner axis: the GUI must render the error_text carried
//      on the re-emitted PROMPT marker. Pre-fix the only signal was a
//      warn() into the LogDrawer (hidden by default).
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// each assertion walks the exact state shape so the bug cannot
// silently come back as a similar-looking-but-broken alternative.

import XCTest
@testable import OstlerInstaller

@MainActor
final class PassphraseMismatchUXTests: XCTestCase {

    private func makeCoordinator() -> InstallerCoordinator {
        InstallerCoordinator()
    }

    private func emitPrompt(
        _ coord: InstallerCoordinator,
        id: String,
        kind: String = "text",
        title: String = "Prompt",
        error: String? = nil
    ) {
        var line = "#OSTLER\tPROMPT\tid=\(id)\tkind=\(kind)\ttitle=\(title)"
        if let error {
            line += "\terror=\(error)"
        }
        coord.simulateLineForTests(line)
    }

    // MARK: - CX-97 Step-counter axis

    /// Walk the exact recovery_passphrase mismatch shape:
    ///
    ///   Q14 recovery_passphrase         (first display, X advances to 14)
    ///   Q15 recovery_passphrase_confirm (first display, X advances to 15)
    ///   mismatch -> re-emit recovery_passphrase (X must RESTORE to 14)
    ///   mismatch -> re-emit recovery_passphrase_confirm (X must RESTORE to 15)
    ///
    /// Pre-fix the dedupe correctly froze X at 15 on the re-emit of
    /// recovery_passphrase, but the customer saw "Question 15: Choose
    /// your passphrase" (mismatched header + body) -- the bug Andy
    /// reported as "adds +1 to the question number, so the user
    /// thinks they're being asked... for something else".
    func testReemittedEarlierPromptRestoresXToOriginalIndex() {
        let coord = makeCoordinator()
        // Walk forward to Q14 + Q15 the same way the real flow does.
        // Use 13 throwaway text prompts to land recovery_passphrase
        // at Q14 exactly.
        for i in 1...13 {
            emitPrompt(coord, id: "q\(i)_filler")
            coord.applyAnswerForTests(promptId: "q\(i)_filler", answer: "x")
        }
        XCTAssertEqual(coord.currentQuestionIndex, 13)

        emitPrompt(coord, id: "recovery_passphrase", kind: "secret")
        XCTAssertEqual(coord.currentQuestionIndex, 14,
                       "recovery_passphrase first display should land at Q14")
        coord.applyAnswerForTests(promptId: "recovery_passphrase",
                                  answer: "synth-passphrase-correct-horse")

        emitPrompt(coord, id: "recovery_passphrase_confirm", kind: "secret")
        XCTAssertEqual(coord.currentQuestionIndex, 15,
                       "recovery_passphrase_confirm first display should land at Q15")
        // Simulate the customer entering a mismatched confirm; the
        // FIFO answer commits, then bash detects mismatch and re-emits
        // the original passphrase prompt with an error banner.
        coord.applyAnswerForTests(promptId: "recovery_passphrase_confirm",
                                  answer: "synth-wrong-passphrase")

        // Mismatch loop: install.sh re-emits recovery_passphrase
        // first (the FIRST prompt in the pair). X must STEP BACK to
        // 14 -- pre-fix it stayed at 15 (the off-by-one).
        emitPrompt(coord,
                   id: "recovery_passphrase",
                   kind: "secret",
                   error: "Passphrases don't match. Try again.")
        XCTAssertEqual(coord.currentQuestionIndex, 14,
                       "Re-emit of EARLIER prompt id must RESTORE X to that prompt's original index, not stay pinned at the latest-seen value.")

        coord.applyAnswerForTests(promptId: "recovery_passphrase",
                                  answer: "synth-passphrase-correct-horse")

        // Then re-emit confirm -- X must restore to 15.
        emitPrompt(coord,
                   id: "recovery_passphrase_confirm",
                   kind: "secret",
                   error: "Passphrases don't match. Try again.")
        XCTAssertEqual(coord.currentQuestionIndex, 15,
                       "Re-emit of recovery_passphrase_confirm must restore X to its original index (15).")
    }

    /// Belt-and-braces companion to the recovery_passphrase shape:
    /// the same restore-on-re-emit invariant must hold for any
    /// secret-confirm pair (email_password / email_password_confirm
    /// is the other in-flight call site). If a future contributor
    /// re-shapes the install.sh loop without re-running these tests
    /// the X counter will catch them here.
    func testEmailPasswordMismatchAlsoRestoresXToOriginalIndex() {
        let coord = makeCoordinator()
        for i in 1...7 {
            emitPrompt(coord, id: "q\(i)_filler")
            coord.applyAnswerForTests(promptId: "q\(i)_filler", answer: "x")
        }
        emitPrompt(coord, id: "email_password", kind: "secret")
        XCTAssertEqual(coord.currentQuestionIndex, 8)
        coord.applyAnswerForTests(promptId: "email_password", answer: "p1")

        emitPrompt(coord, id: "email_password_confirm", kind: "secret")
        XCTAssertEqual(coord.currentQuestionIndex, 9)
        coord.applyAnswerForTests(promptId: "email_password_confirm", answer: "p2")

        emitPrompt(coord,
                   id: "email_password",
                   kind: "secret",
                   error: "Passwords did not match (or were empty). Try again.")
        XCTAssertEqual(coord.currentQuestionIndex, 8,
                       "email_password re-emit must restore X to 8 (its original index), not stay at 9.")
    }

    /// Forward walks must still increment X normally even when an
    /// earlier prompt's re-emit caused a step-back. Defends against
    /// a future refactor that hard-pins X to the highest-seen value
    /// instead of the actual displayed prompt's index.
    func testForwardWalkResumesAfterMismatchStepBack() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "a")
        coord.applyAnswerForTests(promptId: "a", answer: "x")
        emitPrompt(coord, id: "b")
        coord.applyAnswerForTests(promptId: "b", answer: "x")
        XCTAssertEqual(coord.currentQuestionIndex, 2)

        // Mismatch shape: re-emit 'a' with an error. X steps back to 1.
        emitPrompt(coord, id: "a", error: "didn't match")
        XCTAssertEqual(coord.currentQuestionIndex, 1)
        coord.applyAnswerForTests(promptId: "a", answer: "x")

        // Re-emit 'b'. X restores to 2 (b's original index).
        emitPrompt(coord, id: "b", error: "didn't match")
        XCTAssertEqual(coord.currentQuestionIndex, 2)
        coord.applyAnswerForTests(promptId: "b", answer: "x")

        // Forward walk to 'c': X advances to 3 (b's index + 1) --
        // NOT 4 (a phantom "highest-ever" was 2, +1 = 3 is correct).
        emitPrompt(coord, id: "c")
        XCTAssertEqual(coord.currentQuestionIndex, 3,
                       "New prompt after a mismatch-restore must advance X by exactly one, not skip the restored position.")
    }

    // MARK: - CX-97 Error-banner axis

    /// install.sh's mismatch loops pass the error message through
    /// gui_read's $7 error_text arg, which gui_emit surfaces on the
    /// PROMPT marker as `error=...`. The decoder must wire that
    /// into the PendingPrompt's `error` slot so the View can render
    /// the oxblood banner above the input field.
    func testPromptMarkerErrorFieldSurfacesOnPendingPrompt() {
        let coord = makeCoordinator()
        emitPrompt(coord,
                   id: "recovery_passphrase",
                   kind: "secret",
                   error: "Passphrases don't match. Try again.")
        XCTAssertNotNil(coord.pendingPrompt)
        XCTAssertEqual(
            coord.pendingPrompt?.error,
            "Passphrases don't match. Try again.",
            "PROMPT marker error= field must wire into PendingPrompt.error."
        )
    }

    /// First display of a prompt (the customer's initial attempt)
    /// must not carry a stale error from a sibling prompt. install.sh
    /// passes an empty error_text on the first attempt; the decoder
    /// must normalise that to nil so the view's `if let err, !err.isEmpty`
    /// guard doesn't render an empty oxblood pill on the happy path.
    func testEmptyErrorFieldNormalisesToNilOnPendingPrompt() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "recovery_passphrase", kind: "secret", error: "")
        XCTAssertNil(
            coord.pendingPrompt?.error,
            "Empty error= field must round-trip as nil on PendingPrompt, not as an empty string."
        )
    }

    /// PROMPT markers with NO error= field at all (the overwhelming
    /// majority of prompts) must leave PendingPrompt.error nil. The
    /// dedupe normalisation must not mis-fire on a missing field.
    func testMissingErrorFieldLeavesPendingPromptErrorNil() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name", kind: "text")
        XCTAssertNotNil(coord.pendingPrompt)
        XCTAssertNil(coord.pendingPrompt?.error)
    }

    // MARK: - CX-97 ProgressDecoder shape

    /// Decoder-level pin: PROMPT marker with error= must produce a
    /// `.prompt` enum value carrying the error string. Lives at the
    /// ProgressDecoder layer (not the coordinator) so a future
    /// schema migration that drops the error field surfaces here
    /// before it can break the higher-layer state machine tests.
    func testProgressDecoderParsesErrorField() {
        let line = "#OSTLER\tPROMPT\tid=recovery_passphrase\tkind=secret\ttitle=Choose your passphrase\terror=Passphrases don't match. Try again."
        let event = ProgressDecoder.decode(line: line)
        switch event {
        case .prompt(_, _, _, _, _, _, let error):
            XCTAssertEqual(error, "Passphrases don't match. Try again.")
        default:
            XCTFail("Expected .prompt event, got: \(event)")
        }
    }
}
