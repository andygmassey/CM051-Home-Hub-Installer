// ChoiceResolver.swift
//
// F&F tester report 2026-11-05, item 3: "How will your assistant reach
// you?" showed NO options. The screen was in review mode (screenshot:
// "Return to current question"), where the picker was
// `.constant(priorAnswer ?? choices.first)`: a prior answer that is empty or
// not one of the choices selects nothing, and a disabled menu picker with no
// selection draws as a blank box with nothing to open. A PROMPT line that
// decodes to no choices would do the same.
//
// A choice prompt must never render empty. Pure functions, no UI types, so the
// behaviour is unit-testable and compiles on its own.

import Foundation

enum ChoiceResolver {
    /// The closed value sets install.sh passes for choice prompts that render as
    /// a Picker. Used only when the PROMPT arrives with no choices. Mirrors
    /// install.sh: channel_choice "1,2,3,4,5" (install.sh gui_read
    /// "channel_choice"), tailscale_confirm "setup,skip".
    static let fallbackChoices: [String: [String]] = [
        "channel_choice": ["1", "2", "3", "4", "5"],
        "tailscale_confirm": ["setup", "skip"],
        "tailscale_connect": ["setup", "skip"],
        "fda_preset": ["recommended", "everything", "customise"],
    ]

    /// The default install.sh offers for a fallback list, used when the prompt
    /// carries no default of its own.
    static let fallbackDefault: [String: String] = [
        "channel_choice": "3",
        "tailscale_confirm": "setup",
        "tailscale_connect": "setup",
        "fda_preset": "recommended",
    ]

    /// Choices to render: the prompt's own when it has any, else the known list
    /// for that prompt id, else the default alone. Never empty when a default
    /// or a known id exists.
    static func choices(promptId: String, choices: [String], defaultValue: String?) -> [String] {
        if !choices.isEmpty { return choices }
        if let known = fallbackChoices[promptId] { return known }
        if let d = defaultValue, !d.isEmpty { return [d] }
        return []
    }

    /// A value that is always one of `options` (empty only when `options` is).
    /// `current` wins if valid, then the prompt's default, then the known
    /// default, then the first option.
    static func selection(promptId: String, current: String?, options: [String], defaultValue: String?) -> String {
        if let c = current, options.contains(c) { return c }
        if let d = defaultValue, options.contains(d) { return d }
        if let k = fallbackDefault[promptId], options.contains(k) { return k }
        return options.first ?? ""
    }
}
