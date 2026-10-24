// EnglishPrevailsNoteTests.swift
//
// Andy, 2026-10-24: "localisation with English prevails". A legal/consent
// screen shown in a translation carries the reviewed "English version
// prevails" line; a screen whose legal wording is English carries nothing.
// The line being translated in ViewCopy.<lang>.json is the signal, because
// l10n/ostler_l10n.py ships it (and any legal translation) only once a native
// reviewer has passed it.

import XCTest
@testable import OstlerInstaller

final class EnglishPrevailsNoteTests: XCTestCase {
    private let english = "This is a translation. If it differs from the English version, the English version prevails."
    private let reviewed = "Dies ist eine Übersetzung. Weicht sie von der englischen Fassung ab, gilt die englische Fassung."

    private func copy(localized: String?) -> ViewCopy {
        let root: [String: Any] = ["legal": ["english_prevails": english]]
        var loc: [String: Any] = [:]
        if let localized { loc = ["legal": ["english_prevails": localized]] }
        return ViewCopy(root: root, localized: loc)
    }

    func testReviewedTranslationShowsTheNote() {
        XCTAssertEqual(copy(localized: reviewed).englishPrevailsNote(), reviewed)
    }

    func testNoTranslationShowsNothing() {
        // en-GB, or a language whose prevails line is not reviewed yet: the
        // catalogue lacks it, so the legal wording is English and no note is due.
        XCTAssertNil(copy(localized: nil).englishPrevailsNote())
    }

    func testEnglishCarriedInTheLanguageFileShowsNothing() {
        // the l10n writer emits the full tree, English where unreviewed
        XCTAssertNil(copy(localized: english).englishPrevailsNote())
    }

    func testEmptyTranslationShowsNothing() {
        XCTAssertNil(copy(localized: "").englishPrevailsNote())
    }

    func testTheShippedEnglishCatalogueCarriesTheLine() {
        // the key the view reads exists in Resources/ViewCopy.json
        let s = ViewCopy.shared.string(for: ViewCopy.englishPrevailsKey)
        XCTAssertNotEqual(s, ViewCopy.englishPrevailsKey)
        XCTAssertTrue(s.contains("English version prevails"))
    }

    func testEveryLegalPromptIdGetsTheNote() {
        // install.sh gui_read ids with legal/consent wording (2026-10-24)
        for id in ["consent_install", "consent_third_party", "consent_article_9", "consent_spoken_capture",
                   "consent_voice_eu", "consent_enrichment", "terms_personal_use", "whatsapp_consent",
                   "autologin_consent"] {
            XCTAssertTrue(ViewCopy.isLegalPrompt(id), id)
        }
    }

    func testNonLegalPromptsDoNot() {
        for id in ["assistant_name", "passkey_ack", "recovery_passphrase", "whatsapp", "whatsapp_history",
                   "autologin_password", "reuse_settings"] {
            XCTAssertFalse(ViewCopy.isLegalPrompt(id), id)
        }
    }
}
