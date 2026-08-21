// StepStatusGlyph.swift
//
// The single place a completed step's `StepStatus` becomes a sidebar
// glyph, tint and label.
//
// ── THE DEFECT THIS REPLACES (measured 2026-08-21, v1.0.38) ─────────
//
// #839 gave the wire THREE closing states and said so in its own
// docs (lib/progress_emitter.sh, "THREE STATES, NEVER TWO"):
//
//     ok       the step's children all exited 0
//     timeout  a child was killed by its wall-clock cap (rc 124/137).
//              "We gave up waiting", NOT "it failed".
//     error    a child exited non-zero for any other reason.
//
// `InstallerCoordinator.failureState` honours that split -- a run that
// ends `.timeout` returns `.success`, because giving up waiting on a
// best-effort hydrate is not a failed install. The SIDEBAR did not:
// its status switch read `case .warn, .timeout, .error:` and drew ONE
// oxblood `exclamationmark.triangle.fill` for all three. Three states
// on the wire, two glyphs in the view, and the state that means
// "still going" borrowed the alarm glyph from the state that means
// "this did not work".
//
// What the customer saw on a clean fresh-Mac install: 40 steps, 38
// green ticks, and two red alert triangles on `hydrate_browsing` and
// `hydrate_people` -- the ONLY two non-ok steps in the whole run:
//
//     STEP_END id=hydrate_browsing status=timeout elapsed_s=90 rc=124
//     STEP_END id=hydrate_people   status=timeout elapsed_s=90 rc=124
//
// Both had in fact moved their data before the 90-second cap fired.
// Measured on the box after that install:
//
//     safari_history  8,761 points   vs 8,969 visits extracted
//                                    (208 = the sensitive-URL blocklist;
//                                     8,761 + 208 = 8,969 exactly)
//     people          7,194 points   vs 7,037 Person/BusinessContact
//                                    nodes in Oxigraph
//
// The cap killed the child before it printed its closing JSON summary,
// so install.sh's `sent=` parse fell back to 0 and the sentinel under
// ~/.ostler/state/hydrate/ recorded `payload=sent=0`. That zero is the
// ABSENCE OF THE SUMMARY LINE, not a measurement of work not done.
//
// ── WHAT THIS DOES AND DOES NOT CHANGE ─────────────────────────────
//
// `.timeout` gets its OWN informational glyph. It is deliberately NOT
// promoted to the green tick: the step really did hit its cap and the
// record must keep saying so -- that was the whole point of #839 and
// re-hiding it here would rebuild the defect from the other side. It
// is demoted out of the ALARM bucket, which it never belonged in.
//
// `.warn` and `.error` keep the amber triangle. `.fail` keeps the red
// xmark. Only the state the protocol already documents as "not a
// failure" stops being drawn as one.
//
// Kept out of ProgressProtocol.swift on purpose: that file is the wire
// contract with install.sh and stays free of SwiftUI. This is the view
// layer's READING of the wire, and it is a pure value so the mapping
// can be asserted in a unit test without building a view.

import SwiftUI

/// How loudly a completed step's glyph should speak.
///
/// The bucket is the thing worth testing: which SF Symbol we picked is
/// taste, but "timeout must not share a bucket with error" is the
/// invariant that broke.
enum StepGlyphSeverity: Equatable {
    /// The step did its job.
    case done
    /// The step ended some way other than cleanly, but there is nothing
    /// for the customer to do and the install is not compromised.
    case informational
    /// The step did not do its job. Non-fatal, but worth an eyebrow.
    case alert
    /// The install failed here.
    case fatal
}

/// Pure presentation mapping for a completed step's `StepStatus`.
struct StepStatusGlyph: Equatable {
    let symbolName: String
    let severity: StepGlyphSeverity
    /// Dotted `ViewCopy` key for the accessibility label. A key rather
    /// than a literal so the mapping stays pure (unit-testable without
    /// the app bundle) and so Views/ keeps routing every customer-
    /// facing string through the catalogue, per Rule 0.9.
    let accessibilityCopyKey: String

    var tint: Color {
        switch severity {
        case .done:          return .ostlerForest
        case .informational: return .ostlerInkMuted
        case .alert:         return .ostlerOxbloodWarm
        case .fatal:         return .ostlerOxblood
        }
    }

    /// The one mapping. Exhaustive over `StepStatus` on purpose: adding
    /// a case to the wire enum breaks this build rather than silently
    /// inheriting whatever `default:` happened to say.
    static func forStatus(_ status: StepStatus) -> StepStatusGlyph {
        switch status {
        case .ok:
            return StepStatusGlyph(
                symbolName: "checkmark.circle.fill",
                severity: .done,
                accessibilityCopyKey: "sidebar.status_ok"
            )
        case .timeout:
            // "Took longer than its cap and carried on", not "broke".
            // A clock, not a warning triangle, and a muted ink tint so
            // it reads as a note rather than an alarm -- while staying
            // plainly distinct from the green tick of a step that
            // closed cleanly inside its budget.
            return StepStatusGlyph(
                symbolName: "clock.arrow.circlepath",
                severity: .informational,
                accessibilityCopyKey: "sidebar.status_background"
            )
        case .warn, .error:
            return StepStatusGlyph(
                symbolName: "exclamationmark.triangle.fill",
                severity: .alert,
                accessibilityCopyKey: "sidebar.status_attention"
            )
        case .fail:
            return StepStatusGlyph(
                symbolName: "xmark.circle.fill",
                severity: .fatal,
                accessibilityCopyKey: "sidebar.status_failed"
            )
        }
    }
}
