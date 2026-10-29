// ViewCopy.swift
//
// Customer-facing string catalogue for the SwiftUI installer GUI.
// Mirrors the StepCatalog/HintCopy.json shape -- the JSON in
// Resources/ViewCopy.json is the editorial source of truth so copy
// can be tweaked without rebuilding the app, and v1.2 translation
// is a parallel ViewCopy.{lang}.json drop, not a code lift.
//
// Per Rule 0.9 (locked 2026-05-19): all customer-facing strings in
// the GUI Views/ tree route through this catalogue. New literals in
// Views/*.swift are caught by the project-wide i18n lint guard.
//
// Lookup pattern: `ViewCopy.shared.string(for: "license_entry.heading")`
// or with interpolation:
// `ViewCopy.shared.string(for: "device_limit.heading", fills: ["count": "3"])`
//
// Falls back to the dotted key itself if the JSON is missing or the
// key is unknown, so a partially-broken bundle still renders
// something a developer can grep for, rather than crashing.

import Foundation

final class ViewCopy {
    static let shared = ViewCopy()

    /// Nested dictionary mirroring the JSON tree. Keys are dotted
    /// (`license_entry.heading`); the lookup flattens at access time.
    private var root: [String: Any] = [:]

    init() {
        load()
    }

    /// The same tree in the installer's language (InstallerLanguage),
    /// when one ships. Looked up first; any key it lacks falls back to
    /// `root`, so a partial translation shows English, never a dotted key.
    private var localized: [String: Any] = [:]

    private func load() {
        guard let url = Bundle.main.url(forResource: "ViewCopy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NSLog("ViewCopy.json missing or malformed -- view copy will fall back to dotted-key strings")
            return
        }
        self.root = parsed
        if let name = InstallerLanguage.resourceName("ViewCopy") {
            if let lurl = Bundle.main.url(forResource: name, withExtension: "json"),
               let ldata = try? Data(contentsOf: lurl),
               let lparsed = try? JSONSerialization.jsonObject(with: ldata) as? [String: Any] {
                self.localized = lparsed
            } else {
                NSLog("\(name).json missing or malformed -- view copy stays in English")
            }
        }
    }

    /// Test seam: build a catalogue from in-memory trees.
    init(root: [String: Any], localized: [String: Any]) {
        self.root = root
        self.localized = localized
    }

    private static func lookup(_ parts: [String], in tree: [String: Any]) -> String? {
        var node: Any = tree
        for part in parts {
            guard let dict = node as? [String: Any], let next = dict[part] else {
                return nil
            }
            node = next
        }
        return node as? String
    }

    /// Resolve a dotted key (`license_entry.heading`) against the
    /// loaded catalogue. Returns the dotted key itself as a visible
    /// fallback if the key is unknown, so missing strings show up in
    /// QA rather than silently rendering empty.
    func string(for key: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        return ViewCopy.lookup(parts, in: localized)
            ?? ViewCopy.lookup(parts, in: root)
            ?? key
    }

    /// The "English version prevails" line (Owner ruling 2026-10-24: "localisation
    /// with English prevails"), in the installer's language, or nil when that
    /// line is NOT translated. l10n/ostler_l10n.py ships a translation of it,
    /// and of every other legal/consent string, only once a native reviewer
    /// has passed it (l10n/legal_reviews.tsv), and ships no legal translation
    /// at all for a language until this line is reviewed. So nil means every
    /// legal string on screen is English and no note is due.
    static let englishPrevailsKey = "legal.english_prevails"

    func englishPrevailsNote() -> String? {
        let parts = ViewCopy.englishPrevailsKey.split(separator: ".").map(String.init)
        guard let local = ViewCopy.lookup(parts, in: localized), !local.isEmpty,
              let english = ViewCopy.lookup(parts, in: root), local != english
        else { return nil }
        return local
    }

    /// install.sh prompt ids (gui_read's sixth argument) whose screen carries
    /// legal or consent wording: consent_*, *_consent and terms_*. Today:
    /// consent_install, consent_third_party, consent_article_9,
    /// consent_spoken_capture, consent_voice_eu, consent_enrichment,
    /// terms_personal_use, whatsapp_consent, autologin_consent.
    /// tests/test_legal_prevails_note_on_every_legal_prompt.py holds install.sh
    /// to the same rule, so the GUI and the terminal show the line on the same
    /// screens.
    static func isLegalPrompt(_ id: String) -> Bool {
        id.hasPrefix("consent_") || id.hasSuffix("_consent") || id.hasPrefix("terms_")
    }

    /// Resolve + substitute `{placeholder}` slots in the catalogue
    /// value. Placeholders are Python-style named slots; missing
    /// fills are left as `{name}` literals so they stand out in QA.
    func string(for key: String, fills: [String: String]) -> String {
        var s = string(for: key)
        for (name, value) in fills {
            s = s.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return s
    }
}

/// The legal note under the spoken-capture consent screen, chosen by the
/// Mac's REGION, never its language (the owner, 2026-10-24): a Chinese reader
/// living in London gets the UK line.
///
/// The region is the country part of the global `AppleLocale` default
/// (System Settings > General > Language & Region > Region), parsed with the
/// SAME rule as install.sh (`_ostler_legal_country_from_locale`). Both sides
/// are pinned by tests/fixtures/legal_region_contract.tsv. The
/// `OSTLER_APPLE_LOCALE` environment variable is the test seam on both sides.
///
/// Every `legal_region_*` line is a BEST-EFFORT DRAFT, NOT LEGAL ADVICE, and
/// needs local professional sign-off. Any region not listed gets the neutral
/// core and the responsibility sentence only.
enum LegalRegion {
    enum Jurisdiction: String {
        case gb, eu, hk, us, other
    }

    /// EU-27 plus the EEA states (IS, LI, NO), where the GDPR applies.
    static let gdprRegions: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR",
        "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK",
        "SI", "ES", "SE", "IS", "LI", "NO"
    ]

    /// The raw AppleLocale value: the test seam first, then the user's
    /// global default. nil when the Mac has none (region unknown).
    static func currentAppleLocale(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> String? {
        if let seam = environment["OSTLER_APPLE_LOCALE"] { return seam }
        return defaults.string(forKey: "AppleLocale")
    }

    /// ISO-3166 alpha-2 region from an AppleLocale value (`en_GB`,
    /// `zh-Hant_GB`, `en_US@rg=hkzzzz`, `es_419`), uppercased, or nil when it
    /// names no two-letter region. The language part is never consulted.
    static func country(fromAppleLocale raw: String?) -> String? {
        guard let raw = raw else { return nil }
        func twoLetters(_ s: Substring) -> String? {
            guard s.count == 2, s.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
            return s.uppercased()
        }
        if let r = raw.range(of: "rg=") {
            if let rg = twoLetters(raw[r.upperBound...].prefix(2)) { return rg }
        }
        var base = Substring(raw)
        if let at = base.firstIndex(of: "@") { base = base[..<at] }
        if let dot = base.firstIndex(of: ".") { base = base[..<dot] }
        guard let us = base.lastIndex(of: "_") else { return nil }
        return twoLetters(base[base.index(after: us)...])
    }

    static func jurisdiction(forCountry iso: String?) -> Jurisdiction {
        guard let iso = iso else { return .other }
        if iso == "GB" { return .gb }
        if gdprRegions.contains(iso) { return .eu }
        if iso == "HK" { return .hk }
        if iso == "US" { return .us }
        return .other
    }

    /// Region-line suffixes in display order (`gb`, `eu` + `de`, ...).
    static func spokenCaptureRegionKeys(forCountry iso: String?) -> [String] {
        switch jurisdiction(forCountry: iso) {
        case .gb: return ["gb"]
        case .eu:
            if iso == "DE" { return ["eu", "de"] }
            if iso == "FR" { return ["eu", "fr"] }
            return ["eu"]
        case .hk: return ["hk"]
        case .us: return ["us"]
        case .other: return []
        }
    }

    /// The whole legal note for the given AppleLocale value.
    static func spokenCaptureLegalNote(
        appleLocale: String?,
        copy: ViewCopy = .shared
    ) -> String {
        let base = "consent_spoken_capture."
        var parts = [
            copy.string(for: base + "legal_prefix"),
            copy.string(for: base + "legal_core"),
            copy.string(for: base + "legal_local")
        ]
        for key in spokenCaptureRegionKeys(forCountry: country(fromAppleLocale: appleLocale)) {
            parts.append(copy.string(for: base + "legal_region_" + key))
        }
        parts.append(copy.string(for: base + "legal_responsibility"))
        return parts.joined(separator: " ")
    }
}
