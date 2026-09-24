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
    /// THE AXIS THE SUITE DID NOT HAVE, AND THE ONE A CUSTOMER SEES.
    ///
    /// Every assertion above compares finished states to OTHER FINISHED
    /// STATES. None of them asks whether a finished state can be mistaken
    /// for a step that has NOT finished, because "pending" and "running"
    /// are not StepStatus cases -- pending is the ABSENCE of a STEP_END and
    /// is drawn in SidebarView, running is a ProgressView spinner.
    ///
    /// So on 2026-09-24 `unmeasured` shipped as `circle.dashed` while
    /// pending was `circle`, the suite was fully green, and fourteen
    /// COMPLETED steps rendered as though they were still going. Andy found
    /// it by looking at the installer for thirty seconds. A control that
    /// only compares within one compartment cannot see across the boundary
    /// that matters.
    ///
    /// These two literals are the glyphs SidebarView draws for the
    /// unfinished states. If SidebarView changes them, this test must
    /// change with it -- which is the point: the collision becomes a thing
    /// somebody has to look at, rather than a thing nobody owns.
    func testNoStatusGlyphCollidesWithAnUnfinishedStep() {
        let pendingSymbol = "circle"          // SidebarView: not started
        let all: [StepStatus] = [.ok, .timeout, .warn, .error, .fail, .unmeasured]

        for status in all {
            let glyph = StepStatusGlyph.forStatus(status)
            XCTAssertNotEqual(
                glyph.symbolName, pendingSymbol,
                "\(status) is drawn with the NOT-STARTED glyph, so a finished step reads as pending"
            )
        }

        // The specific regression: done-but-unverified must READ as done.
        // A tick carries completion; muted ink and no fill carry "nobody
        // checked". Asserting the family rather than the exact string so a
        // later restyle inside the checkmark family does not fail this,
        // while a return to a bare or dashed circle does.
        let unmeasured = StepStatusGlyph.forStatus(.unmeasured)
        XCTAssertTrue(
            unmeasured.symbolName.hasPrefix("checkmark"),
            "unmeasured must read as COMPLETE, not as an empty circle a customer reads as stuck"
        )
        XCTAssertFalse(
            unmeasured.symbolName.contains("dashed"),
            "a dashed circle is indistinguishable from the pending circle at a glance"
        )

        // #2318's property MOVED on 2026-09-24, it did not go away. The
        // sidebar now draws a finished step as finished either way, on Andy's
        // decision, so the two assertions that used to sit here would
        // contradict it. What they were really protecting is the WIRE, and
        // that is asserted here instead -- deliberately in this test, so the
        // rule travels with the glyph it used to constrain.
        XCTAssertFalse(
            StepStatus.unmeasured.isMeasured,
            "the sidebar stopped showing the measured/unmeasured split; the WIRE must not. "
            + "If this fails, `ok by default` is back and the pixels are the least of it."
        )
        XCTAssertTrue(
            StepStatus.ok.isMeasured,
            "a measured success must still say so on the wire"
        )
    }

    func testEveryStatusMapsToADistinctSeverityBucketWhereIntended() {
        let all: [StepStatus] = [.ok, .timeout, .warn, .error, .fail, .unmeasured]
        let glyphs = all.map { StepStatusGlyph.forStatus($0) }

        // warn and error intentionally share; everything else is unique.
        // #2318: `unmeasured` shares the INFORMATIONAL bucket with
        // `timeout` (neither is an alarm) but must keep its own glyph --
        // "we gave up waiting" and "we never looked" are different facts.
        // 🔴 REWRITTEN 2026-09-24 ON ANDY'S DECISION, watching his own
        // console walk: a FINISHED step reads as finished in the customer's
        // sidebar, measured or not. `unmeasured` therefore shares the glyph
        // AND the severity of `ok`, deliberately, so the counts below drop
        // by one each.
        //
        // The assertions this replaces said "unmeasured must not wear the
        // green tick". That was the right rule for a WIRE and the wrong one
        // for a SIDEBAR: it put an engineering distinction in front of a
        // customer who cannot act on it. They are not deleted to make a red
        // go away -- the property they protected has MOVED, and the test
        // below now asserts it where it actually lives.
        let buckets = Set(glyphs.map { $0.severity })
        XCTAssertEqual(buckets.count, 4,
                       "expected done / informational / alert / fatal -- `timeout` still holds "
                       + "informational on its own now that unmeasured has moved to done")

        let symbols = Set(glyphs.map { $0.symbolName })
        XCTAssertEqual(symbols.count, 4,
                       "expected four distinct glyphs: ok+unmeasured share, warn+error share")

        // THE CUSTOMER-FACING RULE, stated positively.
        XCTAssertEqual(StepStatusGlyph.forStatus(.unmeasured).symbolName,
                       StepStatusGlyph.forStatus(.ok).symbolName,
                       "a finished step must read as finished, whether or not it was verified")

        // AND THE PROPERTY #2318 ACTUALLY PROTECTS, WHICH IS NOT A PIXEL.
        // The distinction lives in the WIRE and must survive this change in
        // full: an operator reading STEP_END, the marker stream or
        // walks/*.tsv must still be able to tell a measured success from a
        // step that measured nothing. If this ever fails, `ok by default`
        // has come back and the sidebar is the least of it.
        XCTAssertTrue(StepStatus.ok.isMeasured,
                      "ok must still report as measured on the wire")
        XCTAssertFalse(StepStatus.unmeasured.isMeasured,
                       "unmeasured must still report as UNMEASURED on the wire -- "
                       + "the sidebar stopped showing the distinction, the log must not")
        XCTAssertNotEqual(StepStatus.ok, StepStatus.unmeasured,
                          "the two states must remain distinct values, not merged")

        XCTAssertNotEqual(StepStatusGlyph.forStatus(.unmeasured).severity,
                          StepStatusGlyph.forStatus(.error).severity,
                          "unmeasured must not be drawn as an alert")

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
        for status in [StepStatus.ok, .timeout, .warn, .error, .fail, .unmeasured] {
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
