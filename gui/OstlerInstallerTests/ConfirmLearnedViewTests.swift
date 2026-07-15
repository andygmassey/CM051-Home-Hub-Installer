// ConfirmLearnedViewTests.swift
//
// Tests for the end-of-install "Confirm what we learned" screen
// (ConfirmLearnedView + its OnboardingQuestionView dispatch).
//
// Three nets, mirroring the established shapes in this target:
//
//   1. Render regression (OnboardingQuestionViewSnapshotTests
//      shape): drive the coordinator with the exact PROMPT lines
//      install.sh's confirmation block emits and ImageRenderer the
//      view tree. Assertion is "did not crash"; headless AppKit
//      falls back to placeholders so pixels are not compared.
//
//   2. Wire-value contract (TypedInstallGateTest shape): the pure
//      module-scope helpers must produce exactly the answers
//      install.sh's case arms consume ("y"/"n" for the collapse
//      yesno, "different"/"me" for the namesake choice, the raw
//      calendar types, the owner name with default fallback).
//      tests/test_confirm_ui_gui_answer_contract.sh pins the same
//      values against install.sh + the decision writer from the
//      bash/python side, so a drift on either side fails a test.
//
//   3. Catalogue keys (PermissionsIntroCatalogueKeysTest shape):
//      every confirm_learned.* key the view resolves must exist in
//      ViewCopy.json -- a missing key renders the dotted key
//      fallback without crashing, the worst kind of silent bail.

import Foundation
import XCTest
import SwiftUI
@testable import OstlerInstaller

@MainActor
final class ConfirmLearnedViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeCoordinator() -> InstallerCoordinator {
        InstallerCoordinator()
    }

    @MainActor
    private func render<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 560, height: 420))
        renderer.scale = 2.0
        return renderer.cgImage
    }

    private func emitPrompt(
        _ coord: InstallerCoordinator,
        id: String,
        kind: String,
        title: String,
        defaultValue: String? = nil,
        help: String? = nil,
        choices: String? = nil
    ) {
        var line = "#OSTLER\tPROMPT\tid=\(id)\tkind=\(kind)\ttitle=\(title)"
        if let d = defaultValue { line += "\tdefault=\(d)" }
        if let h = help { line += "\thelp=\(h)" }
        if let c = choices { line += "\tchoices=\(c)" }
        coord.simulateLineForTests(line)
    }

    // MARK: - 1. Render regression

    func testRendersCalendarOwnerPrompt() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "calendar_owner",
            kind: "text",
            title: "Whose calendar is 'Robin Carter'?",
            defaultValue: "Robin Carter",
            help: "14 events, e.g. Flight to Osaka; School run"
        )
        XCTAssertNotNil(coord.pendingPrompt, "Sanity: prompt is pending.")
        let image = render(OnboardingQuestionView().environmentObject(coord))
        XCTAssertNotNil(image, "calendar_owner render should not crash.")
    }

    func testRendersCalendarTypePrompt() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "calendar_type",
            kind: "choice",
            title: "What sort of calendar is 'Robin Carter'?",
            defaultValue: "family",
            help: "14 events, e.g. Flight to Osaka; School run",
            choices: "personal,work,family,shared,other"
        )
        let image = render(OnboardingQuestionView().environmentObject(coord))
        XCTAssertNotNil(image, "calendar_type render should not crash.")
    }

    func testRendersIdentityCollapsePrompt() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "identity_collapse",
            kind: "yesno",
            title: "We found what looks like two copies of you",
            defaultValue: "yes",
            help: "Jane Doe + Jane A Doe (shared email domain; shared LinkedIn)"
        )
        let image = render(OnboardingQuestionView().environmentObject(coord))
        XCTAssertNotNil(image, "identity_collapse render should not crash.")
    }

    func testRendersIdentityNamesakePrompt() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "identity_namesake",
            kind: "choice",
            title: "Is this you, or someone else with your name?",
            defaultValue: "different",
            help: "Jane Doe (different LinkedIn profile; no shared identifiers)",
            choices: "different,me"
        )
        let image = render(OnboardingQuestionView().environmentObject(coord))
        XCTAssertNotNil(image, "identity_namesake render should not crash.")
    }

    func testRendersBackReviewOfConfirmationPrompt() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "identity_collapse",
            kind: "yesno",
            title: "We found what looks like two copies of you",
            defaultValue: "yes",
            help: "Jane Doe + Jane A Doe (shared email domain)"
        )
        coord.applyAnswerForTests(promptId: "identity_collapse", answer: "y")
        emitPrompt(
            coord,
            id: "identity_namesake",
            kind: "choice",
            title: "Is this you, or someone else with your name?",
            defaultValue: "different",
            choices: "different,me"
        )
        coord.enterBackReview()
        XCTAssertNotNil(coord.backReviewIndex, "Sanity: review mode entered.")
        let image = render(OnboardingQuestionView().environmentObject(coord))
        XCTAssertNotNil(image, "Back-review of a confirmation prompt should not crash.")
    }

    // MARK: - 2. Wire-value contract

    func testConfirmationPromptIdSetMatchesInstallShIds() {
        // The four gui_read ids in install.sh's end-of-install
        // confirmation block. tests/test_confirm_ui_gui_answer_contract.sh
        // greps install.sh for the same set, so a rename on either
        // side breaks a test.
        XCTAssertEqual(
            confirmLearnedPromptIds,
            ["calendar_owner", "calendar_type", "identity_collapse", "identity_namesake"]
        )
    }

    func testCollapseCardsCarryCanonicalYesNoWireValues() {
        let opts = confirmLearnedOptions(promptId: "identity_collapse", choices: [])
        XCTAssertEqual(opts.map(\.value), ["y", "n"],
                       "install.sh matches yes|true|y|Y for the collapse accept; the reject arm must not look like an accept.")
    }

    func testNamesakeCardsPreserveBashChoiceOrderAndValues() {
        let opts = confirmLearnedOptions(
            promptId: "identity_namesake",
            choices: ["different", "me"]
        )
        XCTAssertEqual(opts.map(\.value), ["different", "me"],
                       "install.sh writes --distinct on 'different'; 'me' must pass through verbatim.")
    }

    func testCalendarTypeCardsPassChoicesThrough() {
        let choices = ["personal", "work", "family", "shared", "other"]
        let opts = confirmLearnedOptions(promptId: "calendar_type", choices: choices)
        XCTAssertEqual(opts.map(\.value), choices)
    }

    func testOwnerPromptHasNoCards() {
        XCTAssertTrue(confirmLearnedOptions(promptId: "calendar_owner", choices: []).isEmpty)
    }

    func testDefaultSelectionPreselectsBashProposal() {
        // Collapse: bash default "yes" -> the "y" card.
        XCTAssertEqual(
            confirmLearnedDefaultSelection(promptId: "identity_collapse", defaultValue: "yes", choices: []),
            "y"
        )
        // Collapse: a missing default still counts as accept (bash
        // treats enter-on-empty as accept).
        XCTAssertEqual(
            confirmLearnedDefaultSelection(promptId: "identity_collapse", defaultValue: nil, choices: []),
            "y"
        )
        // Namesake: fail-safe default is "different" (veto, never a
        // merge) exactly as bash proposes.
        XCTAssertEqual(
            confirmLearnedDefaultSelection(
                promptId: "identity_namesake",
                defaultValue: "different",
                choices: ["different", "me"]
            ),
            "different"
        )
        // Calendar type: the helper's prefill wins when valid...
        XCTAssertEqual(
            confirmLearnedDefaultSelection(
                promptId: "calendar_type",
                defaultValue: "family",
                choices: ["personal", "work", "family", "shared", "other"]
            ),
            "family"
        )
        // ...and an out-of-range default falls back to the first choice.
        XCTAssertEqual(
            confirmLearnedDefaultSelection(
                promptId: "calendar_type",
                defaultValue: "bogus",
                choices: ["personal", "work"]
            ),
            "personal"
        )
    }

    func testWireAnswerAcceptAndCorrectPaths() {
        // Accept: card selection posts verbatim.
        XCTAssertEqual(
            confirmLearnedWireAnswer(promptId: "identity_collapse", selection: "y", typedText: "", defaultValue: "yes"),
            "y"
        )
        // Correct: the reject card posts "n" (which install.sh's
        // accept arm does NOT match -- no merge is recorded).
        XCTAssertEqual(
            confirmLearnedWireAnswer(promptId: "identity_collapse", selection: "n", typedText: "", defaultValue: "yes"),
            "n"
        )
        // Owner accept: empty edit falls back to the proposed name.
        XCTAssertEqual(
            confirmLearnedWireAnswer(promptId: "calendar_owner", selection: "", typedText: "   ", defaultValue: "Robin Carter"),
            "Robin Carter"
        )
        // Owner correct: a typed name wins, trimmed.
        XCTAssertEqual(
            confirmLearnedWireAnswer(promptId: "calendar_owner", selection: "", typedText: "  Sam Carter ", defaultValue: "Robin Carter"),
            "Sam Carter"
        )
        // Namesake correct: "me" passes through verbatim so install.sh
        // does NOT write the distinct veto.
        XCTAssertEqual(
            confirmLearnedWireAnswer(promptId: "identity_namesake", selection: "me", typedText: "", defaultValue: "different"),
            "me"
        )
    }

    // MARK: - 3. Catalogue keys

    /// Every ViewCopy key ConfirmLearnedView can resolve. Update in
    /// lockstep with the view; the test fails when a key is missing
    /// from ViewCopy.json (which would render the dotted key
    /// fallback on a customer screen).
    private static let requiredKeys: [String] = [
        "confirm_learned.header_label",
        "confirm_learned.evidence_heading",
        "confirm_learned.calendar_owner_hint",
        "confirm_learned.calendar_type_personal_title",
        "confirm_learned.calendar_type_personal_subtitle",
        "confirm_learned.calendar_type_work_title",
        "confirm_learned.calendar_type_work_subtitle",
        "confirm_learned.calendar_type_family_title",
        "confirm_learned.calendar_type_family_subtitle",
        "confirm_learned.calendar_type_shared_title",
        "confirm_learned.calendar_type_shared_subtitle",
        "confirm_learned.calendar_type_other_title",
        "confirm_learned.calendar_type_other_subtitle",
        "confirm_learned.identity_collapse_y_title",
        "confirm_learned.identity_collapse_y_subtitle",
        "confirm_learned.identity_collapse_n_title",
        "confirm_learned.identity_collapse_n_subtitle",
        "confirm_learned.identity_namesake_different_title",
        "confirm_learned.identity_namesake_different_subtitle",
        "confirm_learned.identity_namesake_me_title",
        "confirm_learned.identity_namesake_me_subtitle",
        // Shared keys the view reuses from the generic question body.
        "onboarding_question.header_review_suffix",
        "onboarding_question.continue_button",
        "onboarding_question.return_button",
    ]

    func testAllConfirmLearnedCatalogueKeysPresent() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Resources/ViewCopy.json"
        )
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("ViewCopy.json root is not an object")
            return
        }
        for key in Self.requiredKeys {
            var node: Any = root
            var found = true
            for part in key.split(separator: ".") {
                guard let dict = node as? [String: Any], let next = dict[String(part)] else {
                    found = false
                    break
                }
                node = next
            }
            XCTAssertTrue(found && node is String,
                          "ViewCopy.json missing catalogue key: \(key)")
        }
    }

    /// The derived card catalogue keys (per prompt id + wire value)
    /// must resolve too -- confirmLearnedOptions builds them by
    /// string interpolation, so a typo would only surface as a raw
    /// dotted key on screen.
    func testDerivedCardKeysResolveToCatalogueStrings() {
        let cases: [(String, [String])] = [
            ("identity_collapse", []),
            ("identity_namesake", ["different", "me"]),
            ("calendar_type", ["personal", "work", "family", "shared", "other"]),
        ]
        for (promptId, choices) in cases {
            for opt in confirmLearnedOptions(promptId: promptId, choices: choices) {
                for key in [opt.titleKey, opt.subtitleKey] {
                    let resolved = ViewCopy.shared.string(for: key)
                    XCTAssertNotEqual(resolved, key,
                                      "Derived card key does not resolve: \(key)")
                }
            }
        }
    }
}
