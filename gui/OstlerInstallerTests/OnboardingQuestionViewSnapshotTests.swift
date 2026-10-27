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

    // 6. consent_article_9 (EU/UK Article-9 special-category) body.
    //
    // Compliance regression net (2026-07-15): the install.sh
    // `region==eu` branch emits a `consent_article_9` yesno PROMPT.
    // Before the fix the GUI had no branch for that id, so it fell
    // through to the default help-text render and showed only the
    // one-line MSG_PROMPT_CONSENT_ARTICLE_9_HELP summary -- the full
    // special-category disclosure never rendered. The Q?? branch now
    // routes through `consentArticle9Body()`, which reads the
    // intro_body + legal_note split from ViewCopy.json (sister to
    // consentThirdPartyBody). The bash-emitted help below is
    // deliberately IGNORED by that branch, mirroring passkey_ack.
    func testRendersConsentArticle9PromptWithoutCrashing() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "consent_article_9",
            kind: "yesno",
            title: "Your decision (Y / N)",
            // This bash-emitted help is deliberately IGNORED by the
            // consent_article_9 branch; the view reads the full
            // disclosure from ViewCopy.json (intro_body + legal_note).
            help: "Article 9 special-category consent (UK GDPR). Required for the lawful basis of processing."
        )
        let image = render(
            OnboardingQuestionView().environmentObject(coord)
        )
        XCTAssertNotNil(image, "consent_article_9 render should not crash.")
    }

    // 7. consent_spoken_capture (spoken-audio recording consent) body.
    //
    // BW3-8 regression net (box-walk-v4, 2026-07-24): the spoken-consent
    // screen had NO dedicated branch, so the whole HELP blob (intro +
    // "What we ask of you" bullet list + "Legal note:") fell through to
    // the default single-Text() render -- mashed together, wrong size,
    // legal note not styled as a distinct block. The branch now routes
    // through `consentSpokenCaptureBody()`, which reads intro_body +
    // ask_heading + bullet_1..3 + legal_note from ViewCopy.json and
    // renders a real bulleted list + a subordinated italic legal block.
    // The bash-emitted help below is deliberately IGNORED by that branch
    // (mirroring passkey_ack / consent_article_9). This asserts the
    // ForEach-bulleted tree renders without crashing.
    func testRendersConsentSpokenCapturePromptWithoutCrashing() {
        let coord = makeCoordinator()
        emitPrompt(
            coord,
            id: "consent_spoken_capture",
            kind: "yesno",
            title: "Record spoken conversations into text?",
            // Deliberately IGNORED by the consent_spoken_capture branch;
            // the view reads the split copy from ViewCopy.json.
            help: "Spoken-audio recording consent. Getting any consent the law requires is your responsibility."
        )
        let image = render(
            OnboardingQuestionView().environmentObject(coord)
        )
        XCTAssertNotNil(image, "consent_spoken_capture render should not crash.")
    }
}

/// The spoken-capture legal note follows the Mac's REGION, not its language
/// (the owner, 2026-10-24). Reads tests/fixtures/legal_region_contract.tsv, the
/// SAME fixture tests/test_spoken_capture_legal_note_follows_region.sh runs
/// install.sh's functions against, so the two sides cannot drift apart.
/// Region lines are best-effort drafts needing local professional sign-off;
/// this pins WHICH lines show, not the law in them.
final class LegalRegionContractTests: XCTestCase {
    private struct Row {
        let locale: String?
        let iso: String?
        let jurisdiction: String
        let keys: [String]
    }

    private func rows() throws -> [Row] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/legal_region_contract.tsv")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        var out: [Row] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("apple_locale\t") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(f.count, 4, "malformed fixture row: \(line)")
            guard f.count == 4 else { continue }
            out.append(Row(
                locale: f[0] == "<unset>" ? nil : f[0],
                iso: f[1] == "-" ? nil : f[1],
                jurisdiction: f[2],
                keys: f[3] == "-" ? [] : f[3].split(separator: ",").map(String.init)
            ))
        }
        return out
    }

    func testEveryFixtureRowPicksTheSameLinesAsInstallSh() throws {
        let all = try rows()
        XCTAssertGreaterThanOrEqual(all.count, 20, "fixture shrank; denominator matters")
        for r in all {
            let iso = LegalRegion.country(fromAppleLocale: r.locale)
            XCTAssertEqual(iso, r.iso, "iso for \(r.locale ?? "<unset>")")
            XCTAssertEqual(LegalRegion.jurisdiction(forCountry: iso).rawValue, r.jurisdiction,
                           "jurisdiction for \(r.locale ?? "<unset>")")
            XCTAssertEqual(LegalRegion.spokenCaptureRegionKeys(forCountry: iso), r.keys,
                           "region lines for \(r.locale ?? "<unset>")")
        }
    }

    /// The rendered note, end to end through ViewCopy.json: a Chinese
    /// (Traditional) language with a GB region gets the UK line and no other.
    func testChineseLanguageWithUKRegionGetsTheUKLine() {
        let copy = ViewCopy.shared
        let k = "consent_spoken_capture."
        let note = LegalRegion.spokenCaptureLegalNote(appleLocale: "zh-Hant_GB", copy: copy)
        XCTAssertTrue(note.hasPrefix(copy.string(for: k + "legal_prefix") + " " + copy.string(for: k + "legal_core")))
        XCTAssertTrue(note.hasSuffix(copy.string(for: k + "legal_responsibility")))
        XCTAssertTrue(note.contains(copy.string(for: k + "legal_region_gb")))
        for other in ["eu", "de", "fr", "hk", "us"] {
            XCTAssertFalse(note.contains(copy.string(for: k + "legal_region_" + other)), "zh-Hant_GB showed \(other)")
        }
        XCTAssertFalse(note.contains("consent_spoken_capture."), "a ViewCopy key did not resolve: \(note)")
    }

    func testUnknownRegionGetsTheNeutralCoreOnly() {
        let copy = ViewCopy.shared
        let k = "consent_spoken_capture."
        let note = LegalRegion.spokenCaptureLegalNote(appleLocale: "ja_JP", copy: copy)
        let want = [k + "legal_prefix", k + "legal_core", k + "legal_local", k + "legal_responsibility"]
            .map { copy.string(for: $0) }.joined(separator: " ")
        XCTAssertEqual(note, want)
    }

    func testTheSeamOverridesTheRealDefault() {
        XCTAssertEqual(LegalRegion.currentAppleLocale(environment: ["OSTLER_APPLE_LOCALE": "en_HK"]), "en_HK")
    }
}

/// Article 9 and third-party-data legal notes (CM051 row L7). SAME fixture
/// tests/test_article_9_third_party_notes_follow_region.sh runs against
/// install.sh: region picks the line, language never does. The XCTest run is
/// CI only; the bash side is the one run locally.
final class LegalRegionBasicContractTests: XCTestCase {
    private func rows() throws -> [(locale: String, variant: String)] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/legal_region_basic_contract.tsv")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        var out: [(String, String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(f.count, 3, "malformed fixture row: \(line)")
            guard f.count == 3 else { continue }
            out.append((f[0], f[1]))
        }
        return out
    }

    func testEveryRowPicksTheSameVariantAsInstallSh() throws {
        let all = try rows()
        XCTAssertGreaterThanOrEqual(all.count, 15, "fixture shrank; denominator matters")
        for r in all {
            let key = LegalRegion.basicRegionKey(forCountry: LegalRegion.country(fromAppleLocale: r.locale))
            XCTAssertEqual(key ?? "core", r.variant, "variant for \(r.locale)")
            for section in ["consent_article_9", "consent_third_party"] {
                let copy = ViewCopy.shared
                let note = LegalRegion.legalNote(section: section, appleLocale: r.locale, copy: copy)
                XCTAssertFalse(note.contains(section + "."), "a ViewCopy key did not resolve: \(note)")
                for other in ["gb", "eu", "hk"] where other != r.variant {
                    XCTAssertFalse(note.contains(copy.string(for: section + ".legal_region_" + other)),
                                   "\(r.locale) showed the \(other) line in \(section)")
                }
            }
        }
    }
}
