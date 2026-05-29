// ReuseSettingsExplanationTests.swift
//
// CX-96 regression tests (DMG #48g+1, 2026-05-29).
//
// Andy reported on the DMG #48g Studio retest:
//
//   the user will get pissed off when it reopens and they *appear*
//   to be doing the same stuff over again -- we need to be more
//   upfront that the previous answers will be used; the "Continue
//   with these settings" I imagine is supposed to be that, but
//   there's no further explanation which is bad UX.
//
// Three failure axes to pin so the bare-yesno regression cannot
// silently come back:
//
//   1. The reuse_settings prompt MUST carry a non-empty
//      MSG_PROMPT_REUSE_SETTINGS_HELP body.
//   2. The prompt MUST carry a per-prompt yes/no label override so
//      the toggle row reads "Use my previous answers" / "Start over
//      from the first question" instead of bare "Yes" / "No". The
//      generic Yes/No is the bug Andy is complaining about.
//   3. The install.sh call site MUST pass both the help text and a
//      printf-built summary line of the three values being reused.
//      A future refactor that drops the help arg back to "" would
//      silently regress the UX.

import Foundation
import XCTest
@testable import OstlerInstaller

final class ReuseSettingsExplanationTests: XCTestCase {

    private func loadStringsCatalogue() throws -> String {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "install.sh.strings.en-GB.sh"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Pin the explanatory help body is present + non-empty.
    /// Pre-fix the reuse_settings prompt was a bare yesno with no
    /// help text -- the customer had no idea their previous answers
    /// were about to be reused. The body needs to actually say so.
    func testReuseSettingsHelpKeyExistsAndExplainsReuse() throws {
        let text = try loadStringsCatalogue()
        guard let helpLine = text.split(separator: "\n").first(where: {
            $0.hasPrefix("MSG_PROMPT_REUSE_SETTINGS_HELP=")
        }).map(String.init) else {
            return XCTFail(
                "MSG_PROMPT_REUSE_SETTINGS_HELP must be defined in the strings catalogue. Pre-fix the reuse_settings prompt landed bare (title only) with no explanation that the customer's previous answers were about to be auto-applied. Andy: \"there's no further explanation which is bad UX.\""
            )
        }
        // The body must actually convey re-use + the customer's
        // earlier answers, not just be a generic Continue prompt.
        let lower = helpLine.lowercased()
        XCTAssertTrue(
            lower.contains("previous") || lower.contains("earlier"),
            "MSG_PROMPT_REUSE_SETTINGS_HELP must explicitly call out that PREVIOUS / EARLIER answers will be reused. Got: \(helpLine)"
        )
        XCTAssertTrue(
            lower.contains("re-enter") || lower.contains("reuse") || lower.contains("reused") || lower.contains("from where you left off"),
            "MSG_PROMPT_REUSE_SETTINGS_HELP must explain that the customer will NOT need to re-enter answers (or equivalent reuse-the-state phrasing). Got: \(helpLine)"
        )
    }

    /// Pin the summary-format key is present. install.sh uses it to
    /// build a one-line "previous values" summary that gets folded
    /// into the help body so the customer can see WHAT is being
    /// reused at a glance.
    func testReuseSettingsSummaryFormatKeyExists() throws {
        let text = try loadStringsCatalogue()
        let line = text.split(separator: "\n").first {
            $0.hasPrefix("MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT=")
        }
        XCTAssertNotNil(
            line,
            "MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT must be defined so install.sh can render a printf summary of the three values being reused (name / assistant / timezone)."
        )
        if let line {
            // Three %s placeholders -- one per reused value.
            let placeholderCount = line.components(separatedBy: "%s").count - 1
            XCTAssertEqual(
                placeholderCount, 3,
                "MSG_PROMPT_REUSE_SETTINGS_SUMMARY_FORMAT must carry exactly three %s placeholders (USER_NAME, ASSISTANT_NAME, USER_TZ). Got: \(line)"
            )
        }
    }

    /// Pin the per-prompt yes/no label overrides are present in
    /// ViewCopy. install.sh's reuse_settings remains a yesno control;
    /// the GUI just needs the toggle row to say "Use my previous
    /// answers" / "Start over from the first question" instead of
    /// generic "Yes" / "No" so the action of either branch is
    /// unambiguous.
    func testReuseSettingsYesNoOverridesInViewCopy() throws {
        XCTAssertEqual(
            ViewCopy.shared.string(for: "onboarding_question.yes_label_per_prompt.reuse_settings"),
            "Use my previous answers",
            "Yes-branch label for reuse_settings must be an action verb the customer understands (\"Use my previous answers\"), not the generic \"Yes\". The bare toggle was the source of Andy's CX-96 frustration."
        )
        XCTAssertEqual(
            ViewCopy.shared.string(for: "onboarding_question.no_label_per_prompt.reuse_settings"),
            "Start over from the first question",
            "No-branch label for reuse_settings must spell out the alternative (\"Start over from the first question\"), not the generic \"No\"."
        )
    }

    /// Pin the install.sh call-site shape so a future refactor that
    /// drops the help arg back to "" can't silently regress the UX.
    /// We walk the actual install.sh source for the gui_read line
    /// that emits the reuse_settings PROMPT and assert it passes a
    /// non-empty help string referencing the catalogue key.
    func testInstallShPassesHelpToReuseSettingsPrompt() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(relative: "install.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        // Find the gui_read line for reuse_settings.
        guard let callLine = text.split(separator: "\n").first(where: {
            $0.contains("\"reuse_settings\"") && $0.contains("gui_read")
        }).map(String.init) else {
            return XCTFail(
                "Could not find the gui_read call site for reuse_settings in install.sh."
            )
        }
        // Should reference the new help var (or the literal catalogue
        // key) and NOT the empty-string-fourth-arg pattern that
        // shipped pre-fix.
        XCTAssertTrue(
            callLine.contains("$_reuse_help") || callLine.contains("MSG_PROMPT_REUSE_SETTINGS_HELP"),
            "install.sh reuse_settings gui_read call must pass the help text as the 4th arg (either via $_reuse_help or MSG_PROMPT_REUSE_SETTINGS_HELP). Pre-fix the 4th arg was the empty string \"\" and the customer saw a bare yesno with no explanation. Got: \(callLine.trimmingCharacters(in: .whitespaces))"
        )
        XCTAssertFalse(
            callLine.contains("yesno \"\" \"\" \"\""),
            "install.sh reuse_settings gui_read must NOT pass three consecutive empty strings -- that is the pre-fix shape that stripped the help + summary from the customer. Got: \(callLine.trimmingCharacters(in: .whitespaces))"
        )
    }
}
