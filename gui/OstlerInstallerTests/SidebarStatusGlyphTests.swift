// SidebarStatusGlyphTests.swift
//
// #952: pins the status -> glyph mapping in the sidebar's left rail.
//
// THE DEFECT THESE TESTS PIN. #839 split the wire's closing status
// into three states -- ok / timeout / error -- and documented timeout
// as "we gave up waiting, NOT it failed". `ProgressDecoderTests`
// already pinned the DECODE half (a timeout must not decode as .ok).
// Nothing pinned the RENDER half, so the sidebar collapsed the three
// states back into two:
//
//     case .warn, .timeout, .error:
//         Image(systemName: "exclamationmark.triangle.fill") ...
//
// and a fresh v1.0.38 install drew two red alert triangles over
// `hydrate_browsing` and `hydrate_people` -- both of which had moved
// their data (8,761/8,969 visits, 7,194 people points) before their
// 90-second cap fired. The alarm was the display, not the install.
//
// The assertions below are deliberately about the SEVERITY BUCKET,
// not about which SF Symbol we happened to pick. The symbol is taste
// and may change; "timeout does not share a bucket with error" and
// "timeout is not silently promoted to a green tick" are the two
// invariants that broke, and they are what must stay red if someone
// re-collapses the switch.

import XCTest
import SwiftUI
@testable import OstlerInstaller

final class SidebarStatusGlyphTests: XCTestCase {

    // ── The defect, stated directly ────────────────────────────────

    func testTimeoutIsNotRenderedAsAnAlert() {
        let timeout = StepStatusGlyph.forStatus(.timeout)
        let error = StepStatusGlyph.forStatus(.error)
        let warn = StepStatusGlyph.forStatus(.warn)

        XCTAssertEqual(timeout.severity, .informational,
                       "a step that hit its wall-clock cap is not an alert")
        XCTAssertNotEqual(timeout.severity, error.severity,
                          "timeout collapsed back into the error bucket")
        XCTAssertNotEqual(timeout.severity, warn.severity,
                          "timeout collapsed back into the warn bucket")
        XCTAssertNotEqual(timeout.symbolName, error.symbolName,
                          "timeout is drawing the error glyph again")
    }

    /// The mirror-image failure. Demoting `timeout` out of the alarm
    /// bucket must not quietly promote it to the tick of a step that
    /// closed cleanly: the step really did hit its cap and the surface
    /// must keep saying so. Re-hiding it here would rebuild #839's
    /// defect from the other side.
    func testTimeoutIsNotPromotedToSuccess() {
        let timeout = StepStatusGlyph.forStatus(.timeout)
        let ok = StepStatusGlyph.forStatus(.ok)

        XCTAssertNotEqual(timeout.severity, ok.severity,
                          "a timed-out step is drawing the success glyph")
        XCTAssertNotEqual(timeout.symbolName, ok.symbolName)
        XCTAssertNotEqual(timeout.accessibilityCopyKey, ok.accessibilityCopyKey)
    }

    // ── The states that must NOT have moved ────────────────────────

    func testErrorAndWarnKeepTheAlertGlyph() {
        XCTAssertEqual(StepStatusGlyph.forStatus(.error).severity, .alert)
        XCTAssertEqual(StepStatusGlyph.forStatus(.warn).severity, .alert)
        XCTAssertEqual(StepStatusGlyph.forStatus(.error).symbolName,
                       "exclamationmark.triangle.fill")
    }

    func testFailKeepsTheFatalGlyph() {
        let fail = StepStatusGlyph.forStatus(.fail)
        XCTAssertEqual(fail.severity, .fatal)
        XCTAssertEqual(fail.symbolName, "xmark.circle.fill")
        XCTAssertNotEqual(fail.severity, StepStatusGlyph.forStatus(.error).severity,
                          "a fatal install failure must stay louder than a non-fatal error")
    }

    func testOKKeepsTheSuccessGlyph() {
        let ok = StepStatusGlyph.forStatus(.ok)
        XCTAssertEqual(ok.severity, .done)
        XCTAssertEqual(ok.symbolName, "checkmark.circle.fill")
    }

    // ── Sanity: every state maps, and the tints are distinguishable ──

    /// A control that MUST be non-trivial: if `forStatus` ever starts
    /// returning one shared value, the inequality assertions above
    /// would still be the only thing catching it. This asserts the
    /// mapping actually discriminates across the whole enum.
    func testEveryStatusMapsToADistinctSeverityBucketWhereIntended() {
        let all: [StepStatus] = [.ok, .timeout, .warn, .error, .fail]
        let glyphs = all.map { StepStatusGlyph.forStatus($0) }

        // warn and error intentionally share; everything else is unique.
        let buckets = Set(glyphs.map { $0.severity })
        XCTAssertEqual(buckets.count, 4,
                       "expected done / informational / alert / fatal")

        let symbols = Set(glyphs.map { $0.symbolName })
        XCTAssertEqual(symbols.count, 4,
                       "expected four distinct glyphs across five states")

        for g in glyphs {
            XCTAssertFalse(g.symbolName.isEmpty)
            XCTAssertTrue(g.accessibilityCopyKey.hasPrefix("sidebar.status_"),
                          "accessibility label must route through ViewCopy")
        }
    }

    /// The tint is what the customer actually reads at a glance. The
    /// informational tint must not be the alert tint.
    func testInformationalTintIsNotTheAlertTint() {
        XCTAssertNotEqual(StepStatusGlyph.forStatus(.timeout).tint,
                          StepStatusGlyph.forStatus(.error).tint)
        XCTAssertNotEqual(StepStatusGlyph.forStatus(.timeout).tint,
                          StepStatusGlyph.forStatus(.fail).tint)
    }

    // ── The copy the labels resolve to ─────────────────────────────
    //
    // Resolved off DISK via #file, the way the other catalogue tests
    // do it, not through `ViewCopy.shared`. In the unit-test target
    // `Bundle.main` is the xctest runner, which does not carry the
    // app's Resources -- so a Bundle.main lookup would fall back to
    // the dotted key and these tests would pass or fail for a reason
    // that has nothing to do with the catalogue's actual contents.

    /// Load `sidebar` out of the real ViewCopy.json on disk.
    private func sidebarCopy() throws -> [String: Any] {
        let url = try Self.repoFile(relative: "gui/OstlerInstaller/Resources/ViewCopy.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(root["sidebar"] as? [String: Any],
                             "ViewCopy.json has no `sidebar` block")
    }

    /// The keys the glyph mapping names must actually exist. A missing
    /// one renders the raw dotted key to VoiceOver at runtime.
    func testAccessibilityKeysResolveInTheCatalogue() throws {
        let sidebar = try sidebarCopy()
        for status in [StepStatus.ok, .timeout, .warn, .error, .fail] {
            let key = StepStatusGlyph.forStatus(status).accessibilityCopyKey
            // "sidebar.status_ok" -> "status_ok"
            let leaf = String(key.split(separator: ".").last ?? "")
            let value = sidebar[leaf] as? String
            XCTAssertNotNil(value, "ViewCopy.json sidebar is missing `\(leaf)` (for \(key))")
            XCTAssertFalse((value ?? "").isEmpty, "`\(leaf)` is empty")
        }
    }

    /// The timeout label must not be worded as a failure. This is the
    /// copy half of the same defect: a neutral glyph over "Failed"
    /// would still tell the customer their install broke.
    func testTimeoutCopyDoesNotClaimFailure() throws {
        let sidebar = try sidebarCopy()
        let leaf = String(
            StepStatusGlyph.forStatus(.timeout)
                .accessibilityCopyKey.split(separator: ".").last ?? ""
        )
        let resolved = try XCTUnwrap(sidebar[leaf] as? String).lowercased()

        for forbidden in ["fail", "error", "broke", "problem", "wrong"] {
            XCTAssertFalse(resolved.contains(forbidden),
                           "timeout copy calls it a failure: '\(resolved)'")
        }

        // Control: the FAILED label must contain exactly the kind of
        // word the timeout label must not. Without this, the loop above
        // would pass just as happily against an empty string or a
        // catalogue that failed to load.
        let failed = try XCTUnwrap(sidebar["status_failed"] as? String).lowercased()
        XCTAssertTrue(failed.contains("fail"),
                      "control failed: status_failed does not read as a failure")
    }

    // ── Repo-root resolution (mirrors StringsCatalogueEmDashTest) ────

    /// Walk up from this file's compile-time path until the repo root
    /// (the directory containing `install.sh`) is found.
    static func repoFile(relative: String, file: String = #file) throws -> URL {
        var current = URL(fileURLWithPath: file).deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = current.appendingPathComponent("install.sh")
            if FileManager.default.fileExists(atPath: marker.path) {
                return current.appendingPathComponent(relative)
            }
            current = current.deletingLastPathComponent()
        }
        throw XCTSkip("repo root not found from \(file)")
    }
}
