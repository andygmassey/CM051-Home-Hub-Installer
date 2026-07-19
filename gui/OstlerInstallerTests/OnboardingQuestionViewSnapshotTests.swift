// OnboardingQuestionViewSnapshotTests.swift
//
// Render-crash regression net for OnboardingQuestionView (#353).
// Drives ImageRenderer through the four rendering states the
// customer sees during onboarding:
//
//   1. Early text prompt -- Y not yet known, header shows "Question X"
//   2. Choice prompt after channel_choice committed -- header shows
//      "Question X of Y"
//   3. Yes/No prompt with help text
//   4. Back-review of a previously-answered text prompt (read-only)
//
// ImageRenderer is headless, so AppKit-backed control styles fall
// back to a placeholder under XCTest. The assertion is therefore
// "the view did not crash during render" rather than a pixel-perfect
// diff. Visual verification is a manual install. The test still
// catches the obvious regressions: missing environment object,
// SwiftUI tree shape errors, force-unwrap crashes, view-builder
// branch divergence.

import XCTest
import SwiftUI
@testable import OstlerInstaller

@MainActor
final class OnboardingQuestionViewSnapshotTests: XCTestCase {

    private func makeCoordinator() -> InstallerCoordinator {
        InstallerCoordinator()
    }

    /// Forces the SwiftUI view to render once. Returns the CGImage
    /// so callers can sanity-check non-nil; the bytes themselves
    /// are not compared.
    @MainActor
    private func render<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 560, height: 360))
        renderer.scale = 2.0
        return renderer.cgImage
    }

    private func emitPrompt(
        _ coord: InstallerCoordinator,
        id: String,
        kind: String = "text",
        title: String = "Prompt",
        help: String? = nil
    ) {
        var line = "#OSTLER\tPROMPT\tid=\(id)\tkind=\(kind)\ttitle=\(title)"
        if let help = help {
            line += "\thelp=\(help)"
        }
        coord.simulateLineForTests(line)
    }

    // 1. Early text prompt -- Y unknown.
    func testRendersEarlyTextPromptWithoutTotal() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "user_name",
            kind: "text",
            title: "What is your first name?",
            help: "Used as the speaker name in conversation summaries."
        )
        let image = render(
            OnboardingQuestionView().environmentObject(coord)
        )
        XCTAssertNotNil(image, "Early text-prompt render should not crash.")
        XCTAssertNil(coord.totalQuestionCount, "Sanity: Y stays nil pre-channel_choice.")
    }

    // 2. Choice prompt after channel_choice committed.
    func testRendersChoicePromptWithTotal() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "channel_choice", kind: "choice", title: "Pick channels")
        coord.applyAnswerForTests(promptId: "channel_choice", answer: "3")
        emitPrompt(
            coord,
            id: "imessage_allowed_contacts",
            kind: "text",
            title: "Which contacts can talk to your assistant?",
            help: "Comma-separated phone numbers, or 'me' for just you."
        )
        let image = render(
            OnboardingQuestionView().environmentObject(coord)
        )
        XCTAssertNotNil(image, "Text-with-total render should not crash.")
        XCTAssertNotNil(coord.totalQuestionCount, "Sanity: Y populated by channel_choice.")
    }

    // 3. Yes/No prompt with help text.
    func testRendersYesNoPromptWithHelp() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "filevault_skip",
            kind: "yesno",
            title: "Continue without FileVault?",
            help: "FileVault encrypts your disk. Strongly recommended."
        )
        let image = render(
            OnboardingQuestionView().environmentObject(coord)
        )
        XCTAssertNotNil(image, "Yes/No render should not crash.")
    }

    // 4. Back-review of a previously-answered text prompt.
    func testRendersBackReviewReadOnlyState() {
        let coord = makeCoordinator()
        emitPrompt(coord, id: "user_name", title: "What is your first name?")
        coord.applyAnswerForTests(promptId: "user_name", answer: "Alice")
        emitPrompt(coord, id: "assistant_name", title: "What is your assistant's name?")
        coord.enterBackReview()
        XCTAssertNotNil(coord.backReviewIndex, "Sanity: review mode entered.")

        let image = render(
            OnboardingQuestionView().environmentObject(coord)
        )
        XCTAssertNotNil(image, "Back-review read-only render should not crash.")
    }

    // 5. Q12 passkey_ack with modality-branched body.
    //
    // LAUNCH BLOCKER regression net (2026-05-22): the Q12 branch
    // routes its help text through `passkeyAckBody()` which reads
    // BiometricProbe.cachedModality and picks a catalogue key. The
    // test below feeds the prompt with the bash-side help string and
    // asserts the view renders -- the body itself comes from
    // ViewCopy.json, not the bash help, so the customer never reads
    // "Touch ID" on a Mac Studio.
    func testRendersPasskeyAckPromptWithoutCrashing() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "passkey_ack",
            kind: "acknowledge",
            title: "Ready to set up disk encryption",
            // Note: this bash-emitted help is deliberately IGNORED by
            // the Q12 branch; the view reads from ViewCopy.json
            // keyed by BiometricProbe.cachedModality.
            help: "Ostler's sensitive databases are encrypted with SQLCipher using a passphrase you choose. A recovery key can optionally be wrapped by Touch ID (if available on this Mac) or by your login password."
        )
        let image = render(
            OnboardingQuestionView().environmentObject(coord)
        )
        XCTAssertNotNil(image, "Q12 passkey_ack render should not crash.")
    }
}
