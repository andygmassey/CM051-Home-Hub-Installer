// PermissionsIntroCatalogueKeysTest.swift
//
// CX-17 (2026-05-23) regression test. Pins Rule 0.9
// (`feedback_customer_strings_extractable_from_day_one`) for the
// new permissions-intro screen. Every customer-visible string on
// PermissionsIntroView MUST be sourced from ViewCopy.json --
// inline literals are forbidden so v1.2 translation is a parallel
// ViewCopy.{lang}.json drop, not a code lift.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// the silent-fail axis here is "a future PR adds inline copy to
// PermissionsIntroView.swift". The test walks the source file
// looking for `Text("...")`, `Button("...")` and `Label("...")`
// callsites with bare string literals. A bare literal inside one
// of those wrappers is a regression even if the intent was
// harmless (a placeholder, a debug stub) -- the i18n pipeline
// cannot extract it later.
//
// Also asserts every catalogue key REFERENCED by PermissionsIntroView
// is actually PRESENT in ViewCopy.json. A typo in a key would
// otherwise render as the dotted key fallback (`permissions_prewarm.intro_heading`)
// without crashing, which is the worst kind of silent bail.

import Foundation
import XCTest
@testable import OstlerInstaller

final class PermissionsIntroCatalogueKeysTest: XCTestCase {

    // MARK: - Required keys

    /// The keys PermissionsIntroView resolves via
    /// `ViewCopy.shared.string(for:)`. If you add or rename a key
    /// in the view, update this list lockstep; the test will fail
    /// if a key is missing from ViewCopy.json.
    private static let requiredKeys: [String] = [
        // Intro screen
        "permissions_prewarm.intro_heading",
        "permissions_prewarm.intro_subheading",
        "permissions_prewarm.intro_contacts_title",
        "permissions_prewarm.intro_contacts_reason",
        "permissions_prewarm.intro_calendar_title",
        "permissions_prewarm.intro_calendar_reason",
        "permissions_prewarm.intro_reminders_title",
        "permissions_prewarm.intro_reminders_reason",
        "permissions_prewarm.intro_photos_title",
        "permissions_prewarm.intro_photos_reason",
        "permissions_prewarm.intro_privacy_note",
        "permissions_prewarm.intro_grant_button",
        "permissions_prewarm.intro_skip_button",
        // Denial summary screen
        "permissions_prewarm.denial_summary_heading",
        "permissions_prewarm.denial_summary_footer",
        "permissions_prewarm.denial_continue_button",
        // Reused per-permission deny copy (also surfaces on the
        // summary screen, not just the LogDrawer)
        "permissions_prewarm.contacts_denied",
        "permissions_prewarm.calendar_denied",
        "permissions_prewarm.reminders_denied",
        "permissions_prewarm.photos_denied",
    ]

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
        return root
    }

    private func lookup(_ key: String, in root: [String: Any]) -> String? {
        var node: Any = root
        for part in key.split(separator: ".") {
            guard let dict = node as? [String: Any], let next = dict[String(part)] else {
                return nil
            }
            node = next
        }
        return node as? String
    }

    // MARK: - Required-keys present

    /// Walks the required-keys list and asserts each one resolves
    /// to a non-empty string in ViewCopy.json. A missing key would
    /// otherwise render as its dotted-key fallback (the ViewCopy
    /// loader's documented behaviour for missing keys) which is
    /// the worst kind of silent bail.
    func testAllRequiredKeysPresentAndNonEmpty() throws {
        let root = try loadViewCopy()
        for key in Self.requiredKeys {
            guard let value = lookup(key, in: root) else {
                XCTFail("ViewCopy.json missing required key '\(key)'. PermissionsIntroView resolves this key at render time; a missing key renders as the dotted-key fallback and is the worst kind of silent bail.")
                continue
            }
            XCTAssertFalse(value.isEmpty,
                           "ViewCopy.json key '\(key)' is empty. Rendering an empty string in the intro screen makes the UI look broken.")
        }
    }

    // MARK: - No inline literals in PermissionsIntroView.swift

    /// Walks the PermissionsIntroView source byte-by-byte looking
    /// for `Text("...")`, `Button("...", ...)`, `Label("...")`
    /// callsites whose argument is a bare string literal. A bare
    /// literal violates Rule 0.9 (customer strings extractable
    /// from day one).
    ///
    /// Allowlist: SF Symbol names (`Image(systemName: "...")`) are
    /// internal identifiers, not customer-visible copy.
    func testNoInlineLiteralStringsInIntroView() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Views/PermissionsIntroView.swift"
        )
        let text = try String(contentsOf: url, encoding: .utf8)

        // Patterns we explicitly reject. Each one carries the WHY.
        // We anchor on the wrapper-paren + opening quote so we
        // skip `Text(someVar)` (already routed through the
        // catalogue) and `Image(systemName: "calendar")` (SF
        // symbol).
        let bannedPatterns: [(needle: String, why: String)] = [
            ("Text(\"", "Bare string literal inside Text() -- route via ViewCopy.shared.string(for:)"),
            ("Button(\"", "Bare string literal inside Button() -- route via ViewCopy.shared.string(for:)"),
            ("Label(\"", "Bare string literal inside Label() -- route via ViewCopy.shared.string(for:)"),
        ]

        for (needle, why) in bannedPatterns {
            if let range = text.range(of: needle) {
                let line = text[..<range.lowerBound].components(separatedBy: "\n").count
                XCTFail("PermissionsIntroView.swift line \(line) contains '\(needle)' with an inline string literal. \(why). Rule 0.9: every customer-visible string lives in ViewCopy.json so v1.2 translation is a parallel catalogue drop, not a code edit.")
            }
        }
    }

    // MARK: - No em-dashes in the new copy

    /// Belt-and-braces against em-dash drift in the new copy.
    /// StringsCatalogueEmDashTest already walks ViewCopy.json
    /// wholesale, but the CX-17 keys are net-new and the em-dash
    /// rule is the kind of thing that slips into freshly-written
    /// copy ("a moment — to read"). Pin per-key here too.
    func testIntroCopyHasNoEmDashes() throws {
        let root = try loadViewCopy()
        let emDash = "\u{2014}"
        for key in Self.requiredKeys {
            guard let value = lookup(key, in: root) else { continue }
            XCTAssertFalse(value.contains(emDash),
                           "ViewCopy.json key '\(key)' contains an em-dash (U+2014). Locked memory feedback_em_dash_rule_scope: customer-rendered copy uses en-dash ' – ' (U+2013) with spaces instead. Got: \(value)")
        }
    }
}
