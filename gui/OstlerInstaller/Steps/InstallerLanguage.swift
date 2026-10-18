// InstallerLanguage.swift
//
// Picks the ONE language the installer speaks, for both halves of it:
//   - the SwiftUI screens (ViewCopy.<lang>.json, HintCopy.<lang>.json)
//   - install.sh's own messages (install.sh.strings.<lang>.sh, selected by
//     the OSTLER_LANG environment variable InstallerCoordinator passes in)
//
// Before this existed both catalogues had a per-language slot and nothing
// ever filled it: OSTLER_LANG was never set, so every customer got en-GB
// whatever their Mac's language. The value returned here is the only input
// to both, so the GUI and the log cannot end up in two different languages.
//
// Resolution: walk the Mac's preferred languages in order and take the
// first one we ship. English (any region) stops the walk and means en-GB,
// so a customer who put English above German gets English. Nothing
// matching means en-GB. OSTLER_LANG in the installer's own environment
// overrides the lot (support / QA), but only with a value we ship.

import Foundation

enum InstallerLanguage {
    /// The catalogue base language. Its files carry no language suffix
    /// for ViewCopy/HintCopy and the `en-GB` suffix for install.sh.
    static let base = "en-GB"

    /// Languages with a shipped translation of all three catalogues.
    static let translated: [String] = [
        "de", "fr", "es", "it", "nl", "pt-BR", "ja", "ko", "zh-Hans", "zh-HK",
    ]

    static let current: String = resolve(
        preferred: Locale.preferredLanguages,
        override: ProcessInfo.processInfo.environment["OSTLER_LANG"]
    )

    static func resolve(preferred: [String], override: String?) -> String {
        if let o = override, o == base || translated.contains(o) {
            return o
        }
        for tag in preferred {
            if let lang = map(tag) {
                return lang
            }
        }
        return base
    }

    /// Map one BCP-47 tag from Locale.preferredLanguages to a shipped
    /// language, or nil if we do not ship it.
    static func map(_ tag: String) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased() else { return nil }
        let rest = parts.dropFirst().map { $0.lowercased() }
        switch primary {
        case "en":
            return base
        case "zh":
            // Script wins over region; with no script, region decides.
            if rest.contains("hans") { return "zh-Hans" }
            if rest.contains("hant") { return "zh-HK" }
            if rest.contains("hk") || rest.contains("mo") || rest.contains("tw") { return "zh-HK" }
            return "zh-Hans"
        case "pt":
            return "pt-BR"
        default:
            return translated.contains(primary) ? primary : nil
        }
    }

    /// Bundle resource name for a catalogue in the current language, or nil
    /// for the base language (callers then load the unsuffixed file).
    static func resourceName(_ stem: String, lang: String = current) -> String? {
        lang == base ? nil : "\(stem).\(lang)"
    }
}
