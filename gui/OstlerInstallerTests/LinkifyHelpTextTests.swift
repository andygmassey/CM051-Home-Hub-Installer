// LinkifyHelpTextTests.swift
//
// Pins the contract for `linkifyHelpText(_:)` and its sibling
// detection-shape helper `linkifyDetectedURLs(_:)`, the pure URL
// post-processors behind the B2 (CX-14) fix that turns plain help
// copy into an AttributedString with clickable `.link` runs.
//
// Why the fix exists: Studio retest #12 caught customers being unable
// to click `docs.ostler.ai/data-exports` in the EXPORTS_ACK body
// because SwiftUI Text(String) does not auto-linkify. Andy's
// pre-answered default was Option 1: URL-regex post-processor with
// detection restricted to `https://` + bare `docs.ostler.ai/`
// prefixes. The restriction matters because catalogue strings
// already contain underscored tokens that a Markdown-parsing
// alternative would have misrendered as italics
// (e.g. `download_my_data`, `info_and_permissions`).
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// every accept and reject axis the surface depends on is pinned
// byte-by-byte so a future regex tweak can't silently relax the
// detection rules. The shape that matters most:
//   - underscores inside catalogue keys must NOT trigger detection
//   - trailing sentence punctuation must NOT be swallowed into the
//     link target
//   - http:// must NOT be detected (no insecure links in copy)
//
// Companion file: OnboardingQuestionView.swift (the `linkifiedHelp`
// instance method is a thin wrapper around the module-scope
// function exercised here).

import Foundation
import XCTest
import SwiftUI
@testable import OstlerInstaller

final class LinkifyHelpTextTests: XCTestCase {

    // MARK: - docs.ostler.ai detection

    func testBareDocsOstlerAIDetected() {
        let raw = "Read the full list at docs.ostler.ai/data-exports for details."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["docs.ostler.ai/data-exports"]
        )
    }

    func testHTTPSDocsOstlerAIDetected() {
        let raw = "See https://docs.ostler.ai/data-exports for the full list."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["https://docs.ostler.ai/data-exports"]
        )
    }

    func testMultipleURLsInSameStringEachDetected() {
        // Two distinct URLs in body copy should each become their
        // own link run, not collapse into one.
        let raw = "Either https://ostler.ai/terms or docs.ostler.ai/legal applies."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["https://ostler.ai/terms", "docs.ostler.ai/legal"]
        )
    }

    func testHTTPSGenericHostDetected() {
        // Any https://... URL detects, not just docs.ostler.ai.
        let raw = "Open https://example.com/path?q=1 to see it."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["https://example.com/path?q=1"]
        )
    }

    // MARK: - Catalogue-key false-positive guard (load-bearing)

    func testUnderscoredCatalogueKeysAreNotDetected() {
        // EXPORTS_ACK help contains tokens like `download_my_data`
        // and `info_and_permissions` that a Markdown parser would
        // have rendered as italic delimiters. The narrow regex
        // restricts detection to https:// + docs.ostler.ai/ so
        // these underscored fragments stay inert.
        let raw = """
        Look in download_my_data and info_and_permissions for the \
        bits you need. Detailed steps live at docs.ostler.ai/data-exports.
        """
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["docs.ostler.ai/data-exports"],
            "Underscored catalogue keys must not be detected as URLs."
        )
    }

    func testBareDomainsOtherThanDocsAreNotDetected() {
        // We don't auto-detect bare `ostler.ai/...` -- that would
        // double-handle the consent_install body's specialised
        // hyperlink renderer.
        let raw = "Terms at ostler.ai/terms (full text)."
        XCTAssertEqual(linkifyDetectedURLs(raw), [])
    }

    func testHTTPInsecureSchemeIsNotDetected() {
        // Customer copy must not contain insecure links. The
        // detector deliberately excludes http://.
        let raw = "Old site at http://example.com/foo is gone."
        XCTAssertEqual(linkifyDetectedURLs(raw), [])
    }

    func testPlainSentenceWithoutURLsReturnsEmpty() {
        let raw = "Most archives take 1 to 3 days to arrive by email."
        XCTAssertEqual(linkifyDetectedURLs(raw), [])
    }

    // MARK: - Trailing-punctuation handling

    func testTrailingPeriodNotInLink() {
        let raw = "See docs.ostler.ai/data-exports."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["docs.ostler.ai/data-exports"]
        )
    }

    func testTrailingCommaNotInLink() {
        let raw = "See docs.ostler.ai/data-exports, then continue."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["docs.ostler.ai/data-exports"]
        )
    }

    func testMultipleTrailingPunctuationStripped() {
        // e.g. "...docs.ostler.ai/foo!)" should still hit just the
        // bare URL, not include the closing punctuation.
        let raw = "Read docs.ostler.ai/data-exports!"
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["docs.ostler.ai/data-exports"]
        )
    }

    func testQueryStringWithEqualsAndAmpersandPreserved() {
        // Query strings are part of the URL; only sentence
        // punctuation strips.
        let raw = "Open https://example.com/path?q=1&r=2 now."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["https://example.com/path?q=1&r=2"]
        )
    }

    // MARK: - AttributedString shape

    func testAttributedStringHasLinkRunForDocsOstlerAI() {
        // The render path must produce an AttributedString whose
        // detected URL run carries a `.link` attribute. Mirror the
        // body of the view's helper call.
        let raw = "Open docs.ostler.ai/data-exports for the list."
        let attributed = linkifyHelpText(raw)

        // Walk the attributed string runs and look for the link
        // attribute on the URL substring. The link URL value is
        // the auto-https-prefixed form (bare detection still
        // produces an https:// URL for clickability).
        var foundLink: URL? = nil
        for run in attributed.runs {
            if let link = run.link {
                foundLink = link
                break
            }
        }
        XCTAssertEqual(
            foundLink,
            URL(string: "https://docs.ostler.ai/data-exports"),
            "Detected docs.ostler.ai URL must carry an https:// link target."
        )
    }

    func testAttributedStringPreservesSurroundingText() {
        // The plain text on either side of the URL must survive
        // the post-processor untouched (no characters dropped,
        // none duplicated, no reordering).
        let raw = "Read the full list at docs.ostler.ai/data-exports for details."
        let attributed = linkifyHelpText(raw)
        XCTAssertEqual(String(attributed.characters), raw)
    }

    func testAttributedStringWithoutURLsIsPlainCopy() {
        // No URLs => AttributedString carries no link attribute
        // and the rendered character stream equals the input.
        let raw = "Most archives take 1 to 3 days to arrive by email."
        let attributed = linkifyHelpText(raw)
        XCTAssertEqual(String(attributed.characters), raw)

        var anyLink: URL? = nil
        for run in attributed.runs {
            if let link = run.link {
                anyLink = link
                break
            }
        }
        XCTAssertNil(anyLink, "Plain copy must not produce any link runs.")
    }

    // MARK: - Empty + edge inputs

    func testEmptyStringRoundTrips() {
        XCTAssertEqual(linkifyDetectedURLs(""), [])
        let attr = linkifyHelpText("")
        XCTAssertEqual(String(attr.characters), "")
    }

    func testURLAtStartOfString() {
        let raw = "docs.ostler.ai/legal contains the terms."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["docs.ostler.ai/legal"]
        )
    }

    func testURLAtEndOfStringWithoutTrailingPunctuation() {
        let raw = "See docs.ostler.ai/legal"
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["docs.ostler.ai/legal"]
        )
    }

    func testURLAcrossLineBreakIsBoundedAtNewline() {
        // \n is not in the allowed URL character class, so the
        // detection stops at the newline. The trailing line stays
        // plain.
        let raw = "See docs.ostler.ai/data-exports\nfor more."
        XCTAssertEqual(
            linkifyDetectedURLs(raw),
            ["docs.ostler.ai/data-exports"]
        )
    }
}
