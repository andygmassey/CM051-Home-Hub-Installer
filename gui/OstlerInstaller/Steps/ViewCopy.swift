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

    private func load() {
        guard let url = Bundle.main.url(forResource: "ViewCopy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NSLog("ViewCopy.json missing or malformed -- view copy will fall back to dotted-key strings")
            return
        }
        self.root = parsed
    }

    /// Resolve a dotted key (`license_entry.heading`) against the
    /// loaded catalogue. Returns the dotted key itself as a visible
    /// fallback if the key is unknown, so missing strings show up in
    /// QA rather than silently rendering empty.
    func string(for key: String) -> String {
        let parts = key.split(separator: ".").map(String.init)
        var node: Any = root
        for part in parts {
            guard let dict = node as? [String: Any], let next = dict[part] else {
                return key
            }
            node = next
        }
        return (node as? String) ?? key
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
