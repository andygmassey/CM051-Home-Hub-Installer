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
// first one we ship. English stops the walk and means en-GB, except US
// English (en-US, or a bare "en" on a Mac whose region is US): en-US, a
// differences-only variant layered on en-GB,
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
        "en-US", "de", "fr", "es", "it", "nl", "pt-BR", "pt-PT", "ja", "ko", "zh-Hans", "zh-Hant", "zh-HK", "ar",
    ]

    static let current: String = resolve(
        preferred: Locale.preferredLanguages,
        override: ProcessInfo.processInfo.environment["OSTLER_LANG"],
        region: Locale.current.region?.identifier
    )

    static func resolve(preferred: [String], override: String?, region: String? = nil) -> String {
        if let o = override, o == base || translated.contains(o) {
            return o
        }
        for tag in preferred {
            if let lang = map(tag, region: region) {
                return lang
            }
        }
        return base
    }

    /// Map one BCP-47 tag from Locale.preferredLanguages to a shipped
    /// language, or nil if we do not ship it.
    static func map(_ tag: String, region: String? = nil) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased() else { return nil }
        let rest = parts.dropFirst().map { $0.lowercased() }
        switch primary {
        case "en":
            // US English is a variant; every other English stays British.
            if rest.contains("us") { return "en-US" }
            if rest.isEmpty && region?.uppercased() == "US" { return "en-US" }
            return base
        case "zh":
            // Script wins over region; with no script, region decides.
            // Traditional: Taiwan vocabulary is the base (zh-Hant); Hong Kong
            // and Macau get the regional zh-HK. No Traditional reader gets English.
            if rest.contains("hans") { return "zh-Hans" }
            let hkOrMo = rest.contains("hk") || rest.contains("mo")
            if rest.contains("hant") { return hkOrMo ? "zh-HK" : "zh-Hant" }
            if hkOrMo { return "zh-HK" }
            if rest.contains("tw") { return "zh-Hant" }
            return "zh-Hans"
        case "pt":
            // Brazil, or no region (Apple's bare "pt" is Brazilian): pt-BR.
            // Portugal and every other region (Angola, Mozambique...) write
            // European Portuguese: pt-PT.
            if rest.isEmpty || rest.contains("br") { return "pt-BR" }
            return "pt-PT"
        default:
            return translated.contains(primary) ? primary : nil
        }
    }

    /// Right-to-left languages among the shipped ones.
    static let rightToLeft: Set<String> = ["ar"]
    static var isRightToLeft: Bool { rightToLeft.contains(current) }

    /// Bundle resource name for a catalogue in the current language, or nil
    /// for the base language (callers then load the unsuffixed file).
    static func resourceName(_ stem: String, lang: String = current) -> String? {
        lang == base ? nil : "\(stem).\(lang)"
    }
}
