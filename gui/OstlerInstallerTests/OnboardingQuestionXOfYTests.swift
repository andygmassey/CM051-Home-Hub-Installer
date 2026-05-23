// OnboardingQuestionXOfYTests.swift
//
// Pins the InstallerCoordinator state-machine contract that drives
// the in-window OnboardingQuestionView (#353):
//
//   - X (currentQuestionIndex) strictly increases on each PROMPT
//     event and never rewinds on Back review.
//   - Y (totalQuestionCount) stays nil until channel_choice commits
//     and grows when email_custom_imap commits "y".
//   - answerHistory captures every committed prompt for Back review.
//   - Secret answers are never persisted in plaintext.
//   - A new PROMPT arrival drops a stale backReviewIndex.
//
// Drives the coordinator via its `simulateLineForTests` + new
// `applyAnswerForTests` test seams so we never need a real
// subprocess, fifo, or filesystem to exercise the model.

import XCTest
@testable import OstlerInstaller

@MainActor
final class OnboardingQuestionXOfYTests: XCTestCase {

    private func makeCoordinator() -> InstallerCoordinator {
        InstallerCoordinator()
    }

    /// Emits a synthetic PROMPT marker so the coordinator sees a new
    /// pendingPrompt + advances X. Mirrors the protocol install.sh
    /// emits over stdout.
    private func emitPrompt(
        _ coord: InstallerCoordinator,
        id: String,
        kind: String = "text",
        title: String = "Prompt"
    ) {
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=\(id)\tkind=\(kind)\ttitle=\(title)"
        )
    }

    // MARK: - X increments

    func testXAdvancesMonotonicallyOnEachPromptEvent() {
        let coord = makeCoordinator()
        XCTAssertEqual(coord.currentQuestionIndex, 0)

        emitPrompt(coord, id: "user_name")
        XCTAssertEqual(coord.currentQuestionIndex, 1)

        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name")
        XCTAssertEqual(coord.currentQuestionIndex, 2)

        coord.applyAnswerForTests(promptId: "assistant_name", answer: "Marvin")
        emitPrompt(coord, id: "reuse_settings", kind: "yesno")
        XCTAssertEqual(coord.currentQuestionIndex, 3)
    }

    // MARK: - CX-14 D4: re-emit of same prompt id must NOT advance X
    //
    // install.sh wraps validation-required prompts in `while [[ -z
    // … ]]; do gui_read … done` loops (whatsapp_recipient at
    // install.sh:1514, imessage_allowed at :1563, assistant_name at
    // :1322). When the customer commits empty input, install.sh
    // emits the SAME prompt id again. Pre-fix, that re-emit would
    // bump X from "Question 9" to "Question 10" even though the
    // customer had not committed an answer -- producing Studio
    // retest #8's "Q9 off-by-one" report. Walk every retry-able
    // prompt-id path byte-by-byte so the fix cannot silently
    // regress.

    func testReemittedPromptIdDoesNotAdvanceX() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "whatsapp_recipient")
        let xAfterFirstEmit = coord.currentQuestionIndex
        XCTAssertEqual(xAfterFirstEmit, 1)

        // Simulate install.sh's while-loop retry: same id re-emitted
        // without the customer having advanced. X must stay pinned.
        emitPrompt(coord, id: "whatsapp_recipient")
        XCTAssertEqual(
            coord.currentQuestionIndex, xAfterFirstEmit,
            "Re-emitted prompt id from install.sh validation retry must NOT bump X."
        )
        emitPrompt(coord, id: "whatsapp_recipient")
        XCTAssertEqual(
            coord.currentQuestionIndex, xAfterFirstEmit,
            "Third retry: X still pinned."
        )
    }

    func testReemittedAssistantNamePromptDoesNotAdvanceX() {
        // install.sh:1322 -- assistant_name has its own while-loop
        // validation retry. Same contract as whatsapp_recipient.
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name")
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name")
        let xAfterAssistantFirstEmit = coord.currentQuestionIndex
        XCTAssertEqual(xAfterAssistantFirstEmit, 2)

        emitPrompt(coord, id: "assistant_name")
        XCTAssertEqual(coord.currentQuestionIndex, xAfterAssistantFirstEmit)
    }

    func testReemittedImessageAllowedPromptDoesNotAdvanceX() {
        // install.sh:1563 -- imessage_allowed has its own
        // while-loop validation retry.
        let coord = makeCoordinator()
        emitPrompt(coord, id: "imessage_allowed")
        let xAfter = coord.currentQuestionIndex
        XCTAssertEqual(xAfter, 1)

        emitPrompt(coord, id: "imessage_allowed")
        emitPrompt(coord, id: "imessage_allowed")
        XCTAssertEqual(coord.currentQuestionIndex, xAfter,
                       "Multiple retries must leave X pinned.")
    }

    func testNewUniquePromptStillAdvancesXAfterRetryLoop() {
        // The retry-de-dupe must not break the happy path: a new,
        // never-seen prompt id always advances X by exactly one.
        let coord = makeCoordinator()
        emitPrompt(coord, id: "whatsapp_recipient")
        emitPrompt(coord, id: "whatsapp_recipient") // retry -- X pinned
        XCTAssertEqual(coord.currentQuestionIndex, 1)

        coord.applyAnswerForTests(
            promptId: "whatsapp_recipient",
            answer: "+15551234567"
        )

        emitPrompt(coord, id: "imessage_allowed")
        XCTAssertEqual(coord.currentQuestionIndex, 2,
                       "Fresh prompt id after a retry loop must advance X by exactly one.")
    }

    // MARK: - Y stays nil until channel_choice

    func testYStaysNilBeforeChannelChoiceCommits() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name")
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name")
        coord.applyAnswerForTests(promptId: "assistant_name", answer: "Marvin")

        XCTAssertNil(coord.totalQuestionCount)
    }

    func testChannelChoiceSkipExpectsFewerPromptsThanBoth() {
        let coordSkip = makeCoordinator()
        emitPrompt(coordSkip, id: "channel_choice", kind: "choice")
        coordSkip.applyAnswerForTests(promptId: "channel_choice", answer: "4")

        let coordBoth = makeCoordinator()
        emitPrompt(coordBoth, id: "channel_choice", kind: "choice")
        coordBoth.applyAnswerForTests(promptId: "channel_choice", answer: "3")

        XCTAssertNotNil(coordSkip.totalQuestionCount)
        XCTAssertNotNil(coordBoth.totalQuestionCount)
        XCTAssertLessThan(
            coordSkip.totalQuestionCount!,
            coordBoth.totalQuestionCount!,
            "Skip-all-channels should expect fewer prompts than both-channels."
        )
    }

    func testCustomImapBranchExpandsTotalWhenCommitted() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "channel_choice", kind: "choice")
        coord.applyAnswerForTests(promptId: "channel_choice", answer: "2")
        let baseline = coord.totalQuestionCount

        emitPrompt(coord, id: "email_custom_imap", kind: "yesno")
        coord.applyAnswerForTests(promptId: "email_custom_imap", answer: "y")

        XCTAssertNotNil(baseline)
        XCTAssertNotNil(coord.totalQuestionCount)
        XCTAssertGreaterThan(
            coord.totalQuestionCount!,
            baseline!,
            "Custom IMAP=y should add follow-up prompts to the total."
        )
    }

    func testCustomImapBranchLeavesTotalAloneWhenDeclined() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "channel_choice", kind: "choice")
        coord.applyAnswerForTests(promptId: "channel_choice", answer: "2")
        let baseline = coord.totalQuestionCount

        emitPrompt(coord, id: "email_custom_imap", kind: "yesno")
        coord.applyAnswerForTests(promptId: "email_custom_imap", answer: "n")

        XCTAssertEqual(coord.totalQuestionCount, baseline)
    }

    // MARK: - Back review

    func testEnterBackReviewDoesNotRewindX() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name")
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name")
        let xBefore = coord.currentQuestionIndex

        coord.enterBackReview()
        XCTAssertEqual(coord.backReviewIndex, 0)
        XCTAssertEqual(
            coord.currentQuestionIndex,
            xBefore,
            "Back review must not rewind the X counter."
        )
    }

    func testEnterBackReviewNoOpWhenHistoryEmpty() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name")
        coord.enterBackReview()
        XCTAssertNil(coord.backReviewIndex)
    }

    func testNewPromptArrivalDropsStaleReviewState() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name")
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name")
        coord.applyAnswerForTests(promptId: "assistant_name", answer: "Marvin")

        coord.enterBackReview()
        XCTAssertNotNil(coord.backReviewIndex)

        emitPrompt(coord, id: "reuse_settings", kind: "yesno")
        XCTAssertNil(
            coord.backReviewIndex,
            "New PROMPT must drop the customer back to the live view."
        )
    }

    // MARK: - Secret-answer redaction

    func testSecretAnswersAreNeverStoredInPlaintextHistory() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "passphrase", kind: "secret")
        coord.applyAnswerForTests(promptId: "passphrase", answer: "synth-secret-correct-horse-battery-staple")

        XCTAssertEqual(coord.answerHistory.count, 1)
        let stored = coord.answerHistory[0].answer
        XCTAssertNotEqual(stored, "synth-secret-correct-horse-battery-staple")
        XCTAssertEqual(stored, "(hidden)")
    }

    func testAnswerHistoryRecordsIndexAndPrompt() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name")
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name")
        coord.applyAnswerForTests(promptId: "assistant_name", answer: "Marvin")

        XCTAssertEqual(coord.answerHistory.count, 2)
        XCTAssertEqual(coord.answerHistory[0].index, 1)
        XCTAssertEqual(coord.answerHistory[0].prompt.id, "user_name")
        XCTAssertEqual(coord.answerHistory[0].answer, "Alice")
        XCTAssertEqual(coord.answerHistory[1].index, 2)
        XCTAssertEqual(coord.answerHistory[1].prompt.id, "assistant_name")
        XCTAssertEqual(coord.answerHistory[1].answer, "Marvin")
    }

    func testEnterBackReviewWalksBackThroughHistory() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name")
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name")
        coord.applyAnswerForTests(promptId: "assistant_name", answer: "Marvin")
        emitPrompt(coord, id: "reuse_settings", kind: "yesno")

        coord.enterBackReview()
        XCTAssertEqual(coord.backReviewIndex, 1) // most-recent answered = assistant_name

        coord.enterBackReview()
        XCTAssertEqual(coord.backReviewIndex, 0) // user_name

        coord.enterBackReview()
        XCTAssertEqual(coord.backReviewIndex, 0, "Cannot walk back past the oldest entry.")
    }

    func testExitBackReviewReturnsToLiveAtMostRecent() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name")
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name")

        coord.enterBackReview()
        XCTAssertEqual(coord.backReviewIndex, 0)
        coord.exitBackReview()
        XCTAssertNil(
            coord.backReviewIndex,
            "Exiting past the most-recent history entry must drop review mode."
        )
    }
}
