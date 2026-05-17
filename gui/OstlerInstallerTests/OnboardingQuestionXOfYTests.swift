// OnboardingQuestionXOfYTests.swift
//
// Pins #353's contract: the coordinator advances the "Question X of
// Y" counter monotonically on each PROMPT event and computes Y when
// the customer commits the `channel_choice` answer. Drives the
// coordinator via the `simulateLineForTests` DEBUG-only test seam so
// we never spawn a real subprocess.
//
// Y values are intentionally coarse for v7.1 (the brief calls out
// the imprecision) -- the assertions below cover the "shape" of
// behaviour (X strictly increases, Y is set by channel_choice, Y
// updates on email_custom_imap=Y) rather than locking in a specific
// integer that could drift across install.sh revisions without
// breaking anything visible to the customer.

import XCTest
@testable import OstlerInstaller

@MainActor
final class OnboardingQuestionXOfYTests: XCTestCase {

    private func makeCoordinator() -> InstallerCoordinator {
        InstallerCoordinator()
    }

    func testXAdvancesByOneOnEachPromptEvent() {
        let coord = makeCoordinator()
        XCTAssertEqual(coord.currentQuestionIndex, 0)

        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_name\tkind=text\ttitle=Full name"
        )
        XCTAssertEqual(coord.currentQuestionIndex, 1)

        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_id\tkind=text\ttitle=What to call you"
        )
        XCTAssertEqual(coord.currentQuestionIndex, 2)

        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=assistant_name\tkind=text\ttitle=Assistant name"
        )
        XCTAssertEqual(coord.currentQuestionIndex, 3)
    }

    func testYUnknownUntilChannelChoiceCommits() {
        let coord = makeCoordinator()
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_name\tkind=text\ttitle=Full name"
        )
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_id\tkind=text\ttitle=What to call you"
        )
        XCTAssertNil(coord.totalQuestionCount,
                     "Y should remain nil until channel_choice commits")
    }

    func testChannelChoiceBothExpandsYBeyondSkip() {
        let coord1 = makeCoordinator()
        let coord3 = makeCoordinator()

        let channelPrompt = InstallerCoordinator.PendingPrompt(
            id: "channel_choice",
            kind: .choice,
            title: "Channel choice",
            defaultValue: "3",
            help: nil,
            choices: ["1", "2", "3", "4"]
        )

        // Manually populate pendingPrompt + currentQuestionIndex as
        // if a real PROMPT had arrived, so respond() has the state it
        // expects. We use the public surface (pendingPrompt is a
        // settable @Published var); the production path arrives here
        // via apply(.prompt).
        coord1.pendingPrompt = channelPrompt
        coord3.pendingPrompt = channelPrompt

        // Pump a few prompts so currentQuestionIndex looks realistic.
        for _ in 0 ..< 5 { coord1.currentQuestionIndex += 1 }
        for _ in 0 ..< 5 { coord3.currentQuestionIndex += 1 }

        // skip path
        let coordSkip = makeCoordinator()
        coordSkip.pendingPrompt = channelPrompt
        coordSkip.currentQuestionIndex = 5

        // We can't drive respond() without a FIFO -- but the
        // estimator is the part we want under test, and that's
        // private. So we exercise it via the public seam by feeding
        // a synthetic answer through the same path the GUI uses for
        // a non-FIFO test: pendingPrompt set + manually invoke the
        // public surface. The respond() guard returns early when
        // promptPipeWriteHandle is nil but still updates state on
        // older builds -- we test the state-update half by routing
        // through a small helper instead.
        coord1.applyAnswerForTests(promptId: "channel_choice", answer: "1")
        coord3.applyAnswerForTests(promptId: "channel_choice", answer: "3")
        coordSkip.applyAnswerForTests(promptId: "channel_choice", answer: "4")

        XCTAssertNotNil(coord1.totalQuestionCount)
        XCTAssertNotNil(coord3.totalQuestionCount)
        XCTAssertNotNil(coordSkip.totalQuestionCount)

        XCTAssertGreaterThan(coord3.totalQuestionCount ?? 0,
                             coordSkip.totalQuestionCount ?? 0,
                             "Channel=both should expect more prompts than skip")
        XCTAssertGreaterThanOrEqual(coord1.totalQuestionCount ?? 0,
                                    coordSkip.totalQuestionCount ?? 0,
                                    "Channel=iMessage should expect at least as many as skip")
    }

    func testCustomImapBranchExpandsY() {
        let coord = makeCoordinator()

        // Stage 1: channel_choice commits with "2" (email only).
        coord.pendingPrompt = InstallerCoordinator.PendingPrompt(
            id: "channel_choice", kind: .choice,
            title: "Channel choice", defaultValue: "2",
            help: nil, choices: ["1", "2", "3", "4"]
        )
        coord.currentQuestionIndex = 5
        coord.applyAnswerForTests(promptId: "channel_choice", answer: "2")
        let yBaseline = coord.totalQuestionCount ?? 0
        XCTAssertGreaterThan(yBaseline, 0)

        // Stage 2: email_custom_imap=Y commits -- Y grows.
        coord.pendingPrompt = InstallerCoordinator.PendingPrompt(
            id: "email_custom_imap", kind: .yesno,
            title: "Also configure a custom IMAP+SMTP server?",
            defaultValue: "N", help: nil, choices: []
        )
        coord.currentQuestionIndex = 8
        coord.applyAnswerForTests(promptId: "email_custom_imap", answer: "y")

        XCTAssertGreaterThan(coord.totalQuestionCount ?? 0,
                             yBaseline,
                             "Opting into custom IMAP should expand the expected total")
    }

    func testBackReviewDoesNotRewindXOnReentry() {
        let coord = makeCoordinator()

        // Two PROMPTs come through; X = 2.
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_name\tkind=text\ttitle=Full name"
        )
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alex")
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_id\tkind=text\ttitle=What to call you"
        )

        XCTAssertEqual(coord.currentQuestionIndex, 2)

        // Entering Back review must not roll the X counter back; the
        // header still reports "Question 2" while the review banner
        // shows which historical entry is being looked at.
        coord.enterBackReview()
        XCTAssertEqual(coord.currentQuestionIndex, 2,
                       "Back review must not rewind X")
        XCTAssertEqual(coord.backReviewIndex, 0)

        coord.exitBackReview()
        XCTAssertNil(coord.backReviewIndex)
        XCTAssertEqual(coord.currentQuestionIndex, 2)
    }

    func testIncomingPromptDuringBackReviewDropsReviewState() {
        let coord = makeCoordinator()
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_name\tkind=text\ttitle=Full name"
        )
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alex")
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_id\tkind=text\ttitle=What to call you"
        )
        coord.enterBackReview()
        XCTAssertEqual(coord.backReviewIndex, 0)

        // New PROMPT arrives -- review state must clear so the
        // customer sees the live question, not a stale review.
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=assistant_name\tkind=text\ttitle=Assistant name"
        )
        XCTAssertNil(coord.backReviewIndex)
        XCTAssertEqual(coord.currentQuestionIndex, 3)
    }

    func testAnswerHistoryHidesSecrets() {
        let coord = makeCoordinator()
        coord.pendingPrompt = InstallerCoordinator.PendingPrompt(
            id: "passphrase", kind: .secret,
            title: "Enter passphrase", defaultValue: nil,
            help: nil, choices: []
        )
        coord.currentQuestionIndex = 9
        coord.applyAnswerForTests(promptId: "passphrase", answer: "synth-secret-do-not-store")
        XCTAssertEqual(coord.answerHistory.count, 1)
        XCTAssertEqual(coord.answerHistory[0].answer, "(hidden)",
                       "Secret answers must never round-trip into the history in plaintext")
    }
}
