// StringsCatalogueEmDashTest.swift
//
// Pins the em-dash rule across all three customer-facing string
// catalogues:
//   - install.sh.strings.en-GB.sh (MSG_* shell vars)
//   - gui/OstlerInstaller/Resources/ViewCopy.json
//   - gui/OstlerInstaller/Resources/HintCopy.json
//
// The locked rule (`feedback_em_dash_rule_scope`): no em-dash
// (U+2014 "—") and no double-hyphen ASCII fallback ("--") inside
// any customer-facing string value. En-dash with spaces (" – ",
// U+2013) is the canonical replacement.
//
// Exemptions (intentional, whitelisted by exact path/key match):
//   - any `_meta` field anywhere in the JSON catalogues (file-level
//     metadata, not customer-rendered)
//   - `_exempt_*` sibling keys (the Rule 0.9 exemption convention
//     where a sibling key explains why a value is allowed to contain
//     a brand noun or pattern)
//   - shell comments in install.sh.strings.en-GB.sh (lines starting
//     with `#` after optional whitespace)
//
// This test is intentionally crude: it walks every string value and
// scans for the two byte patterns. The point is to fail-loud the
// next time a PR introduces an em-dash, not to be elegant.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// each failure asserts the offending key + the offending byte
// position so the fix is point-and-click.

import Foundation
import XCTest
@testable import OstlerInstaller

final class StringsCatalogueEmDashTest: XCTestCase {

    // U+2014 em-dash. Note: NOT U+2013 en-dash (allowed).
    private static let emDash = "\u{2014}"

    /// Returns true if the value uses `--` as a visual em-dash
    /// surrogate (whitespace on at least one side). CLI flag
    /// mentions like `--allow-plaintext` or `--profile` are NOT
    /// flagged: they have an alphanumeric character immediately
    /// adjacent to the second `-`. This mirrors the actual rule
    /// Andy enforces: visual punctuation, not flag references.
    private static func containsEmDashSurrogate(_ s: String) -> Bool {
        // Walk every occurrence of `--`. The visual-surrogate
        // shape is `<whitespace OR start>--<whitespace OR end>`.
        var idx = s.startIndex
        while let range = s.range(of: "--", range: idx..<s.endIndex) {
            let beforeIsBoundary: Bool = {
                if range.lowerBound == s.startIndex { return true }
                let prev = s.index(before: range.lowerBound)
                return s[prev].isWhitespace
            }()
            let afterIsBoundary: Bool = {
                if range.upperBound == s.endIndex { return true }
                return s[range.upperBound].isWhitespace
            }()
            if beforeIsBoundary && afterIsBoundary {
                return true
            }
            idx = range.upperBound
        }
        return false
    }

    // MARK: - ViewCopy.json

    func testViewCopyJsonHasNoEmDashes() throws {
        let url = try Self.repoFile(relative: "gui/OstlerInstaller/Resources/ViewCopy.json")
        try scanJsonCatalogue(url: url, label: "ViewCopy.json")
    }

    // MARK: - HintCopy.json

    func testHintCopyJsonHasNoEmDashes() throws {
        let url = try Self.repoFile(relative: "gui/OstlerInstaller/Resources/HintCopy.json")
        try scanJsonCatalogue(url: url, label: "HintCopy.json")
    }

    // MARK: - install.sh.strings.en-GB.sh

    func testInstallShStringsHaveNoEmDashes() throws {
        let url = try Self.repoFile(relative: "install.sh.strings.en-GB.sh")
        let text = try String(contentsOf: url, encoding: .utf8)
        for (lineNum, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let raw = String(line)
            // Skip shell comments (whole-line); inline trailing `#`
            // comments are rare in this file and the few we have
            // (e.g. `# assistant-name-exempt`) are catalogue metadata
            // not customer copy.
            let stripped = raw.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            // Only check MSG_*= assignment lines.
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = String(raw[..<eq])
            if !key.trimmingCharacters(in: .whitespaces).hasPrefix("MSG_") {
                continue
            }
            // Extract the quoted value. Strings catalogue uses
            // double-quoted single-line values; everything between
            // the first and last `"` on the line is the value.
            let afterEq = raw[raw.index(after: eq)...]
            guard let firstQuote = afterEq.firstIndex(of: "\""),
                  let lastQuote = afterEq.lastIndex(of: "\""),
                  firstQuote < lastQuote
            else { continue }
            let value = String(afterEq[afterEq.index(after: firstQuote)..<lastQuote])
            XCTAssertFalse(
                value.contains(Self.emDash),
                "install.sh.strings.en-GB.sh line \(lineNum + 1) key \(key) contains em-dash (U+2014): \(value)"
            )
            XCTAssertFalse(
                Self.containsEmDashSurrogate(value),
                "install.sh.strings.en-GB.sh line \(lineNum + 1) key \(key) contains '--' used as em-dash surrogate (whitespace-bounded): \(value). CLI flag mentions like '--allow-plaintext' are fine; use en-dash ' – ' (U+2013) for visual punctuation."
            )
        }
    }

    // MARK: - JSON catalogue walker

    /// Walks a JSON catalogue recursively. Skips `_meta` keys (file-
    /// level metadata, not customer-rendered) and any sibling key
    /// starting with `_exempt_`.
    private func scanJsonCatalogue(url: URL, label: String) throws {
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = parsed as? [String: Any] else {
            XCTFail("\(label) root is not a JSON object")
            return
        }
        walk(node: root, path: label, label: label)
    }

    private func walk(node: Any, path: String, label: String) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                if key == "_meta" || key.hasPrefix("_exempt_") || key == "_meta_note" || key == "note" {
                    // Whitelist: file-level / per-section metadata.
                    // `note` is the conventional key for the catalogue
                    // header note (see ViewCopy.json:_meta.note).
                    continue
                }
                walk(node: value, path: "\(path).\(key)", label: label)
            }
            return
        }
        if let arr = node as? [Any] {
            for (idx, value) in arr.enumerated() {
                walk(node: value, path: "\(path)[\(idx)]", label: label)
            }
            return
        }
        guard let str = node as? String else { return }
        XCTAssertFalse(
            str.contains(Self.emDash),
            "\(path) contains em-dash (U+2014): \(str)"
        )
        XCTAssertFalse(
            Self.containsEmDashSurrogate(str),
            "\(path) contains '--' used as em-dash surrogate (whitespace-bounded): \(str). CLI flag mentions like '--allow-plaintext' are fine; use en-dash ' – ' (U+2013) for visual punctuation."
        )
    }

    // MARK: - Repo-root resolution

    /// Resolves a path relative to the repo root by walking up from
    /// this test file's `#file` path (compile-time absolute).
    /// Repo root is the directory containing `install.sh`.
    static func repoFile(relative: String, file: String = #file) throws -> URL {
        var current = URL(fileURLWithPath: file).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = current.appendingPathComponent("install.sh")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return current.appendingPathComponent(relative)
            }
            current = current.deletingLastPathComponent()
        }
        throw NSError(
            domain: "StringsCatalogueTest",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                "Could not locate repo root from \(file). Expected an ancestor directory containing install.sh."]
        )
    }
}
