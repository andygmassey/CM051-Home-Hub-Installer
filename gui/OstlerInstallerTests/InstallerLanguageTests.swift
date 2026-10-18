// InstallerLanguageTests.swift
//
// The installer's language choice drives three catalogues at once
// (ViewCopy, HintCopy, install.sh strings). These pin the choice and the
// English fallback, which is what keeps a partial or broken translation
// from showing a customer dotted keys or an empty screen.

import XCTest
@testable import OstlerInstaller

final class InstallerLanguageTests: XCTestCase {

    func testFirstShippedPreferenceWins() {
        XCTAssertEqual(InstallerLanguage.resolve(preferred: ["de-DE", "en-GB"], override: nil), "de")
        XCTAssertEqual(InstallerLanguage.resolve(preferred: ["sv-SE", "fr-FR"], override: nil), "fr")
        XCTAssertEqual(InstallerLanguage.resolve(preferred: ["ja-JP"], override: nil), "ja")
    }

    func testEnglishAbovePreferredTranslationMeansEnglish() {
        XCTAssertEqual(InstallerLanguage.resolve(preferred: ["en-US", "de-DE"], override: nil), "en-GB")
    }

    func testNothingShippedMeansEnglish() {
        XCTAssertEqual(InstallerLanguage.resolve(preferred: ["sv-SE", "fi-FI"], override: nil), "en-GB")
        XCTAssertEqual(InstallerLanguage.resolve(preferred: [], override: nil), "en-GB")
    }

    func testChineseScriptAndRegion() {
        XCTAssertEqual(InstallerLanguage.map("zh-Hans-CN"), "zh-Hans")
        XCTAssertEqual(InstallerLanguage.map("zh-Hant-HK"), "zh-HK")
        XCTAssertEqual(InstallerLanguage.map("zh-Hant-TW"), "zh-HK")
        XCTAssertEqual(InstallerLanguage.map("zh-HK"), "zh-HK")
        XCTAssertEqual(InstallerLanguage.map("zh-CN"), "zh-Hans")
    }

    func testPortugueseAndRegionStripping() {
        XCTAssertEqual(InstallerLanguage.map("pt-PT"), "pt-BR")
        XCTAssertEqual(InstallerLanguage.map("pt-BR"), "pt-BR")
        XCTAssertEqual(InstallerLanguage.map("nl-BE"), "nl")
        XCTAssertEqual(InstallerLanguage.map("es-419"), "es")
        XCTAssertNil(InstallerLanguage.map("sv-SE"))
    }

    func testOverrideOnlyAcceptsShippedValues() {
        XCTAssertEqual(InstallerLanguage.resolve(preferred: ["de-DE"], override: "ko"), "ko")
        XCTAssertEqual(InstallerLanguage.resolve(preferred: ["de-DE"], override: "en-GB"), "en-GB")
        // An unknown override must not strand the installer on a file that
        // does not exist; it is ignored and the Mac's languages decide.
        XCTAssertEqual(InstallerLanguage.resolve(preferred: ["de-DE"], override: "xx"), "de")
    }

    func testBaseLanguageHasNoSuffixedResource() {
        XCTAssertNil(InstallerLanguage.resourceName("ViewCopy", lang: "en-GB"))
        XCTAssertEqual(InstallerLanguage.resourceName("ViewCopy", lang: "de"), "ViewCopy.de")
    }

    func testViewCopyPrefersTranslationAndFallsBackPerKey() {
        let copy = ViewCopy(
            root: ["footer": ["quit_button": "Quit", "done_button": "Done"]],
            localized: ["footer": ["quit_button": "Beenden"]]
        )
        XCTAssertEqual(copy.string(for: "footer.quit_button"), "Beenden")
        XCTAssertEqual(copy.string(for: "footer.done_button"), "Done")
        XCTAssertEqual(copy.string(for: "footer.unknown"), "footer.unknown")
    }

    func testStepOverlayReplacesOnlyKnownIds() {
        let base = ["a": StepMeta(id: "a", title: "Checking your Mac", subtitle: nil, why: nil,
                                  durationEstimateSeconds: 5, longRunningThresholdSeconds: nil,
                                  longRunningCopy: nil, illustration: nil, needsFDA: false)]
        let loc = ["a": StepMeta(id: "a", title: "Dein Mac wird geprüft", subtitle: nil, why: nil,
                                 durationEstimateSeconds: 5, longRunningThresholdSeconds: nil,
                                 longRunningCopy: nil, illustration: nil, needsFDA: false),
                   "ghost": StepMeta(id: "ghost", title: "x", subtitle: nil, why: nil,
                                     durationEstimateSeconds: nil, longRunningThresholdSeconds: nil,
                                     longRunningCopy: nil, illustration: nil, needsFDA: nil)]
        let out = StepCatalog.overlay(base: base, localized: loc)
        XCTAssertEqual(out["a"]?.title, "Dein Mac wird geprüft")
        XCTAssertNil(out["ghost"])
    }

    /// Every shipped language has all three catalogues in the source tree
    /// (bundling is asserted by tests/test_install_strings_translations.sh).
    func testEveryTranslatedLanguageHasItsFiles() throws {
        for lang in InstallerLanguage.translated {
            for rel in ["install.sh.strings.\(lang).sh",
                        "gui/OstlerInstaller/Resources/ViewCopy.\(lang).json",
                        "gui/OstlerInstaller/Resources/HintCopy.\(lang).json"] {
                let url = try StringsCatalogueEmDashTest.repoFile(relative: rel)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(rel)")
            }
        }
    }
}
