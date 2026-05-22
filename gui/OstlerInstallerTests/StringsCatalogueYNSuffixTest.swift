// StringsCatalogueYNSuffixTest.swift
//
// Pins the "(Y/n)" purge across customer-facing prompt titles in
// install.sh.strings.en-GB.sh. The toggle UI conveys yes/no without
// a textual cue; carrying "(Y/n)" / "(Y/N)" / "(y/n)" / "(N/y)" /
// "(n/y)" in the title is redundant and looks technical.
//
// Whitelist (intentional, exact-match):
//   - MSG_PROMPT_CONSENT_ARTICLE_9_TITLE -- the Article 9 special-
//     category consent screen renders an explicit "Y / N" decision
//     in the title as part of the legal-record contract. Stripping
//     it there would break the consent_records artefact (and is
//     specifically called out in the brief as the exception).
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// failure messages include the key + the offending substring so
// the fix is obvious.

import Foundation
import XCTest
@testable import OstlerInstaller

final class StringsCatalogueYNSuffixTest: XCTestCase {

    // Exact-match whitelist. Add to this list only when the
    // case for the suffix is as strong as the Article 9 record.
    private static let whitelistedKeys: Set<String> = [
        "MSG_PROMPT_CONSENT_ARTICLE_9_TITLE",
    ]

    // The substrings we ban from prompt titles. Case-insensitive
    // matching: we lower-case the value before scanning.
    private static let bannedSuffixes: [String] = [
        "(y/n)",
        "(n/y)",
    ]

    func testNoYnSuffixInPromptTitles() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(relative: "install.sh.strings.en-GB.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        var checked = 0
        for (lineNum, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let raw = String(line)
            let stripped = raw.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
            // Only scan _TITLE keys; help / message / banner copy
            // can legitimately mention "(Y/n)" inline as a hint.
            guard key.hasPrefix("MSG_PROMPT_") && key.hasSuffix("_TITLE") else { continue }
            if Self.whitelistedKeys.contains(key) { continue }
            let afterEq = raw[raw.index(after: eq)...]
            guard let firstQuote = afterEq.firstIndex(of: "\""),
                  let lastQuote = afterEq.lastIndex(of: "\""),
                  firstQuote < lastQuote
            else { continue }
            let value = String(afterEq[afterEq.index(after: firstQuote)..<lastQuote])
            let lower = value.lowercased()
            for banned in Self.bannedSuffixes {
                XCTAssertFalse(
                    lower.contains(banned),
                    "install.sh.strings.en-GB.sh line \(lineNum + 1) key \(key) contains banned suffix '\(banned)': '\(value)'. Drop the toggle-cue from the title -- the UI control conveys it."
                )
            }
            checked += 1
        }
        // Defence-in-depth: confirm we actually walked some keys.
        // A future refactor that renames _TITLE keys would otherwise
        // pass this test with zero coverage.
        XCTAssertGreaterThan(
            checked, 10,
            "Expected to scan >10 MSG_PROMPT_*_TITLE keys; only scanned \(checked). Did the catalogue convention change?"
        )
    }

    func testArticle9TitleStillHasYnDecisionCue() throws {
        // The whitelist is load-bearing: if Article 9's title ever
        // loses its "Y / N" cue, the consent_records artefact loses
        // a contractual element. Pin the positive shape so a tidy-
        // up can't silently drop it.
        let url = try StringsCatalogueEmDashTest.repoFile(relative: "install.sh.strings.en-GB.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        var found = false
        for line in text.split(separator: "\n") {
            let raw = String(line)
            if raw.hasPrefix("MSG_PROMPT_CONSENT_ARTICLE_9_TITLE=") {
                XCTAssertTrue(
                    raw.contains("Y / N") || raw.contains("Y/N") || raw.contains("(y/n)") || raw.contains("(Y/n)"),
                    "Article 9 title must include a Y/N decision cue for the consent_records artefact contract: \(raw)"
                )
                found = true
                break
            }
        }
        XCTAssertTrue(found, "MSG_PROMPT_CONSENT_ARTICLE_9_TITLE missing from catalogue")
    }
}
