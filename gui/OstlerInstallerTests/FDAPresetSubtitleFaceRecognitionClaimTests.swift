// FDAPresetSubtitleFaceRecognitionClaimTests.swift
//
// Regression test for CLAIMS_RECHECK_2026-10-07.md Q3: the GUI's "Everything"
// preset subtitle (ViewCopy.json key fda_preset_everything_subtitle) claimed
// "Adds Photos library (including face recognition)". It does not. Photos
// face recognition (photos_faces) is opt-in, default OFF in every preset, and
// reachable ONLY through the per-source Customise loop in install.sh
// (`_ask_source "photos_faces" "Photos face recognition (Art. 9)" N`,
// install.sh ~11392). Neither RECOMMENDED nor EVERYTHING ever add it.
//
// This pins the rule structurally rather than as an exact-string match, so
// it survives future copy edits: no preset subtitle may claim face
// recognition is included unless install.sh's preset-definition block (the
// span from `RECOMMENDED=` to the `case "$PRESET" in` dispatch, which is
// where RECOMMENDED and EVERYTHING are actually built) literally contains
// "photos_faces". A subtitle may still MENTION face recognition as long as
// it is clearly disclaiming it (e.g. "stays off", "under Customise") -- that
// is exactly what the Recommended subtitle already does correctly, and what
// the fixed Everything subtitle now does too.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`: the
// failure asserts the offending key and the full string so the fix is
// point-and-click.

import Foundation
import XCTest
@testable import OstlerInstaller

final class FDAPresetSubtitleFaceRecognitionClaimTests: XCTestCase {

    /// Phrases that disclaim inclusion: the subtitle is being honest that
    /// face recognition is off, optional, or gated behind Customise. Any
    /// mention of "face recognition" accompanied by one of these is NOT a
    /// false "it's included" claim. Lowercase; matched against lowercased
    /// subtitle text.
    private static let disclaimers = [
        "stay off", "stays off", "off until", "off by default", "optional",
        "customise",
    ]

    /// True if `subtitle` tells the customer face recognition is part of
    /// what this preset adds, with no disclaimer that it is actually off.
    private static func claimsFaceRecognitionIsIncluded(_ subtitle: String) -> Bool {
        let lower = subtitle.lowercased()
        guard lower.contains("face recognition") else { return false }
        return !disclaimers.contains { lower.contains($0) }
    }

    /// Ground truth from install.sh. RECOMMENDED and EVERYTHING are both
    /// built entirely within the span from the first `RECOMMENDED="` literal
    /// to the `case "$PRESET" in` dispatch; `photos_faces` is only ever
    /// referenced inside the Customise per-source loop, which lives AFTER
    /// that dispatch. A literal scan of that span is therefore a correct,
    /// cheap ground truth for "does either preset enable photos_faces" --
    /// it does not need to parse bash semantics, only to see whether the
    /// identifier appears where the preset definitions live.
    ///
    /// If this structure changes (e.g. install.sh is refactored so the
    /// anchors below no longer exist), the test fails loudly via XCTFail
    /// AND treats faces as NOT enabled, so a genuine false claim is still
    /// caught rather than silently waved through by a broken anchor.
    private func presetDefinitionsEnableFaces() throws -> Bool {
        let url = try StringsCatalogueEmDashTest.repoFile(relative: "install.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let recommendedRange = text.range(of: "RECOMMENDED=\"") else {
            XCTFail("install.sh: could not find the RECOMMENDED=\" anchor. The preset-definition shape changed; update this test's anchors.")
            return false
        }
        guard let caseRange = text.range(
            of: "case \"$PRESET\" in",
            range: recommendedRange.upperBound..<text.endIndex
        ) else {
            XCTFail("install.sh: could not find 'case \"$PRESET\" in' after RECOMMENDED=. The preset-definition shape changed; update this test's anchors.")
            return false
        }
        let presetDefinitionBlock = text[recommendedRange.lowerBound..<caseRange.lowerBound]
        return presetDefinitionBlock.contains("photos_faces")
    }

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

    private func assertSubtitleHonest(key: String, enabled: Bool) throws {
        let root = try loadViewCopy()
        guard let subtitle = lookup(key, in: root) else {
            XCTFail("ViewCopy.json missing key '\(key)'")
            return
        }
        let claims = Self.claimsFaceRecognitionIsIncluded(subtitle)
        XCTAssertFalse(
            claims && !enabled,
            """
            ViewCopy.json key '\(key)' claims face recognition is included \
            ('\(subtitle)'), but install.sh's preset-definition block (RECOMMENDED \
            / EVERYTHING) does not add photos_faces -- it is opt-in, default off, \
            and reachable only via the Customise per-source loop \
            (install.sh ~11392). CLAIMS_RECHECK_2026-10-07.md Q3.
            """
        )
    }

    // MARK: - Everything

    /// The original defect: fda_preset_everything_subtitle said "Adds Photos
    /// library (including face recognition)" while EVERYTHING never adds
    /// photos_faces. RED on main before the copy fix.
    func testEverythingSubtitleDoesNotClaimFaceRecognitionUnlessEnabled() throws {
        let enabled = try presetDefinitionsEnableFaces()
        try assertSubtitleHonest(
            key: "onboarding_question.fda_preset_everything_subtitle",
            enabled: enabled
        )
    }

    // MARK: - Recommended

    /// Sanity / regression control: the Recommended subtitle already
    /// disclaims face recognition correctly ("Sensitive sources like Photos
    /// face recognition stay off"). This should already pass and stay
    /// passing; it would catch a future edit that drops the disclaimer.
    func testRecommendedSubtitleDoesNotClaimFaceRecognitionUnlessEnabled() throws {
        let enabled = try presetDefinitionsEnableFaces()
        try assertSubtitleHonest(
            key: "onboarding_question.fda_preset_recommended_subtitle",
            enabled: enabled
        )
    }

    // MARK: - Predicate self-test

    /// A mutation-tested control on the predicate itself, per the standing
    /// evidence-discipline rule that a fixture can encode the flag rather
    /// than the property: proves claimsFaceRecognitionIsIncluded can read
    /// BOTH the original false claim and the fixed, disclaimed text
    /// correctly, independent of what is currently in ViewCopy.json.
    func testPredicateDistinguishesClaimFromDisclaimer() {
        XCTAssertTrue(
            Self.claimsFaceRecognitionIsIncluded(
                "Every data source Ostler supports. Adds Photos library (including face recognition), Mail attachments."
            ),
            "predicate must flag the original unqualified inclusion claim"
        )
        XCTAssertFalse(
            Self.claimsFaceRecognitionIsIncluded(
                "Photos face recognition stays off until you tick it deliberately under Customise."
            ),
            "predicate must not flag text that discloses face recognition is off"
        )
        XCTAssertFalse(
            Self.claimsFaceRecognitionIsIncluded(
                "Most people start here. Includes Contacts and Calendar."
            ),
            "predicate must not flag text that never mentions face recognition at all"
        )
    }
}
