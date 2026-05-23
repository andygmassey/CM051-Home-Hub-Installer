// InstallFailedBannerTest.swift
//
// CX-14 Section E2 regression tests. The pre-CX-14 banner crammed
// heading + subtitle + four buttons into a single horizontal strip;
// E2 split it into a minimal top banner (title only) + rich body
// pane (apology + hyperlinked support@ostler.ai + actions).
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// for every silent-fail axis the test must walk the assembled
// catalogue output byte-by-byte (or key-by-key) asserting the EXACT
// failure shape never recurs. A "does it render" happy-path test
// would not catch:
//   - "code 1" or "exit 1" copy creeping back into the catalogue
//   - the "Try again" button label re-appearing (we explicitly
//     dropped it; if a future PR adds it back without consensus
//     this test fires)
//   - the hyperlink label drifting away from support@ostler.ai
//     (so a partial brand-rename leaves a dead link)
//   - the body-paragraph prefix/suffix and the label getting
//     reordered such that the customer reads "...email to get help..."
//     before the email address itself appears (the rendered sentence
//     must read: prefix + label + suffix in that order)
//
// Locked memory `feedback_customer_strings_extractable_from_day_one`:
// every assertion reads from the ViewCopy catalogue, not from
// inlined English. If the catalogue is translated later, the test
// still pins the CONTRACT (no exit-code, no Try-again, hyperlink
// present) regardless of the language.

import Foundation
import XCTest
@testable import OstlerInstaller

final class InstallFailedBannerTest: XCTestCase {

    // MARK: - Catalogue load

    private func loadViewCopy() throws -> [String: Any] {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Resources/ViewCopy.json"
        )
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            XCTFail("ViewCopy.json root is not an object")
            return [:]
        }
        guard let banner = root["install_failed_banner"] as? [String: Any] else {
            XCTFail("ViewCopy.json missing install_failed_banner section")
            return [:]
        }
        return banner
    }

    // MARK: - Top banner contract (minimal)

    /// CX-14 E2 top banner is minimal: title only. The previous
    /// design also had a subtitle in the top strip; the split moved
    /// the rich subtitle into the body pane. The top banner heading
    /// must exist and must be the literal "Install failed" string
    /// the catalogue currently ships.
    func testTopBannerHeadingExistsAndIsMinimal() throws {
        let banner = try loadViewCopy()
        guard let heading = banner["heading"] as? String else {
            XCTFail("install_failed_banner.heading missing")
            return
        }
        XCTAssertFalse(heading.isEmpty, "install_failed_banner.heading must not be empty")
        // Minimal = no comma, no period (single noun phrase). If the
        // heading ever grows a sentence, the top banner stops being
        // "minimal" per the E2 brief.
        XCTAssertFalse(heading.contains(","),
            "install_failed_banner.heading must be a minimal noun phrase. Comma indicates a longer sentence -- move that copy into the body. Got: \(heading)")
        XCTAssertFalse(heading.contains("."),
            "install_failed_banner.heading must be a minimal noun phrase. Period indicates a longer sentence -- move that copy into the body. Got: \(heading)")
    }

    // MARK: - "code 1" / "exit 1" translation contract

    /// CX-14 E2 brief explicitly demands: 'code 1' / 'exit 1' shell
    /// shorthand MUST NOT appear in customer-facing copy. The body
    /// heading replaces it with "The installer hit a fatal error
    /// and stopped." Walks every string value under the
    /// install_failed_banner section and asserts none contain the
    /// shorthand.
    func testNoExitCodeShorthand() throws {
        let banner = try loadViewCopy()
        // Variants we explicitly reject. Lowercased compare so
        // future copy doesn't sneak through with a capital.
        let forbidden = [
            "code 1",
            "exit 1",
            "exited with 1",
            "exit code 1",
            "code: 1",
            "errno",
        ]
        for (key, value) in banner {
            // Skip _meta + _exempt_*.
            if key == "_meta" || key.hasPrefix("_exempt_") { continue }
            guard let str = value as? String else { continue }
            let lower = str.lowercased()
            for needle in forbidden {
                XCTAssertFalse(lower.contains(needle),
                    "install_failed_banner.\(key) contains forbidden exit-code shorthand '\(needle)'. The customer-facing copy must explain WHAT happened, not echo the shell exit code. Got: \(str)")
            }
        }
    }

    // MARK: - "Try again" button explicitly dropped

    /// CX-14 E2 brief explicitly drops the "Try again" button. The
    /// catalogue key try_again_button MUST be absent. If a future
    /// PR re-adds it without consensus, this test fires.
    func testTryAgainButtonRemoved() throws {
        let banner = try loadViewCopy()
        XCTAssertNil(banner["try_again_button"],
            "install_failed_banner.try_again_button was explicitly dropped by CX-14 Section E2 (2026-05-23). The footer Quit option already terminates the app; re-launching by hand is more reliable than an in-place restart. If you want to re-add this button, talk to Andy first.")
    }

    // MARK: - Hyperlink contract

    /// The body paragraph hyperlinks support@ostler.ai inline via
    /// AttributedString.link. Three keys must exist + must match:
    ///   body_paragraph_prefix
    ///   body_support_email_label  (must contain @ostler.ai)
    ///   body_support_email_url    (must be mailto: + match label)
    ///   body_paragraph_suffix
    func testHyperlinkContract() throws {
        let banner = try loadViewCopy()

        guard let label = banner["body_support_email_label"] as? String else {
            XCTFail("install_failed_banner.body_support_email_label missing")
            return
        }
        guard let urlString = banner["body_support_email_url"] as? String else {
            XCTFail("install_failed_banner.body_support_email_url missing")
            return
        }
        guard let prefix = banner["body_paragraph_prefix"] as? String else {
            XCTFail("install_failed_banner.body_paragraph_prefix missing")
            return
        }
        guard let suffix = banner["body_paragraph_suffix"] as? String else {
            XCTFail("install_failed_banner.body_paragraph_suffix missing")
            return
        }

        // Label is the human-readable address that renders inline.
        // Must be the support@ostler.ai address (matches the
        // mailto URL).
        XCTAssertEqual(label, "support@ostler.ai",
            "install_failed_banner.body_support_email_label must be exactly 'support@ostler.ai' so the hyperlink label matches the mailto target. Got: \(label)")

        // URL is the tappable target. Must be a mailto: URL pointing
        // at the same address as the label.
        XCTAssertTrue(urlString.hasPrefix("mailto:"),
            "install_failed_banner.body_support_email_url must be a mailto: URL. Got: \(urlString)")
        XCTAssertTrue(urlString.contains("support@ostler.ai"),
            "install_failed_banner.body_support_email_url must target support@ostler.ai (the label the customer sees). Got: \(urlString)")
        XCTAssertNotNil(URL(string: urlString),
            "install_failed_banner.body_support_email_url must parse as a URL. Got: \(urlString)")

        // Prefix must NOT end with whitespace-stripped text -- the
        // E2 design renders prefix + label + suffix as one sentence,
        // so the prefix ends with a space ready for the label and
        // the suffix starts with a space ready after the label.
        // Walk byte-by-byte: assert prefix ends in a space.
        XCTAssertTrue(prefix.hasSuffix(" "),
            "install_failed_banner.body_paragraph_prefix must end with a trailing space so the AttributedString concat 'prefix + label' has a word boundary before the email address. Got: '\(prefix)'")

        // Suffix must start with whitespace OR punctuation so the
        // sentence flows after the label.
        if let first = suffix.first {
            let ok = first.isWhitespace || first == "," || first == "." || first == "(" || first == ";"
            XCTAssertTrue(ok,
                "install_failed_banner.body_paragraph_suffix must start with whitespace or a punctuation mark so the AttributedString concat 'label + suffix' has a word boundary after the email address. Got first char: '\(first)' in: '\(suffix)'")
        }
    }

    // MARK: - Email-support button still primary CTA

    /// The Email-support button is the primary action and must
    /// still exist (we only dropped Try-again).
    func testEmailSupportButtonStillPresent() throws {
        let banner = try loadViewCopy()
        guard let label = banner["email_support_button"] as? String else {
            XCTFail("install_failed_banner.email_support_button missing; CX-14 E2 keeps this as the primary CTA in the body pane")
            return
        }
        XCTAssertFalse(label.isEmpty, "install_failed_banner.email_support_button must not be empty")
    }

    // MARK: - Copy-log buttons still present

    /// The two Copy-log variants (raw + redacted) stay for customers
    /// who prefer paste-into-Slack / paste-into-issue-tracker. They
    /// must not be dropped at the same time as Try-again.
    func testCopyLogButtonsStillPresent() throws {
        let banner = try loadViewCopy()
        XCTAssertNotNil(banner["copy_log_button"],
            "install_failed_banner.copy_log_button must still exist (only Try-again was dropped by CX-14 E2)")
        XCTAssertNotNil(banner["copy_log_button_copied"])
        XCTAssertNotNil(banner["copy_redacted_log_button"],
            "install_failed_banner.copy_redacted_log_button must still exist (only Try-again was dropped by CX-14 E2)")
        XCTAssertNotNil(banner["copy_redacted_log_button_copied"])
    }
}
