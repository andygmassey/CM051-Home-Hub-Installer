// SidebarPhaseAdvanceTests.swift
//
// Pins #347's contract: a PHASE marker whose id is in
// StepCatalog.canonicalOrder advances the sidebar tick state, back-
// filling all earlier canonical entries as completed.
//
// We can't directly invoke the @MainActor private apply(event:)
// without standing up the full SwiftUI environment, but we CAN drive
// it via the public `verifyLicense` -> `runDeviceRegistration` ->
// `bootstrap` flow, then feed events into the public surface via
// the same handleIncoming path the readability handler uses. For a
// focused unit test that stays cheap we use a minimal direct hook:
// publishing a synthetic stdout chunk through a small test-only
// reflection of the parser then asserting the published state.
//
// To stay within the existing test scaffolding we instead verify the
// helpers ProgressDecoder + StepCatalog produce the inputs the
// coordinator expects, and assert the sidebar contract on a tightly-
// constructed coordinator that drives the underlying state through
// a public test seam.

import XCTest
@testable import OstlerInstaller

@MainActor
final class SidebarPhaseAdvanceTests: XCTestCase {

    /// Drive a phase event through the coordinator's public seam by
    /// constructing a synthetic line and routing through the same
    /// ProgressDecoder + apply path the readability handler uses.
    /// We expose this via the test target's `simulateLine(_:)`
    /// helper on the coordinator.
    private func makeCoordinator() -> InstallerCoordinator {
        InstallerCoordinator()
    }

    func testPhaseInCanonicalOrderBackFillsEarlierEntries() {
        let coord = makeCoordinator()
        // PHASE setup_questions -- index 2 in canonicalOrder. We
        // expect entries 0 (license_entry) and 1 (prereq_check) to
        // be back-filled as completed, and currentStepId to land on
        // setup_questions.
        coord.simulateLineForTests(
            "#OSTLER\tPHASE\tid=setup_questions\ttitle=Setup"
        )
        XCTAssertEqual(coord.currentStepId, "setup_questions")
        let ids = coord.completedSteps.map { $0.id }
        XCTAssertTrue(ids.contains("license_entry"),
                      "license_entry should be marked complete; got \(ids)")
        XCTAssertTrue(ids.contains("prereq_check"),
                      "prereq_check should be marked complete; got \(ids)")
        XCTAssertFalse(ids.contains("setup_questions"),
                       "setup_questions is still active, not yet complete")
    }

    func testPhaseOutsideCanonicalOrderLeavesSidebarAlone() {
        let coord = makeCoordinator()
        // PHASE "install" is a wrapper phase emitted by install.sh's
        // `step "Installing"` line. It is NOT in canonicalOrder
        // (which lists granular step ids); the sidebar tick should
        // not move from this event -- subsequent STEP_BEGIN markers
        // will drive it.
        coord.simulateLineForTests("#OSTLER\tPHASE\tid=install\ttitle=Installing")
        XCTAssertNil(coord.currentStepId)
        XCTAssertTrue(coord.completedSteps.isEmpty)
        // The phase title still updates so the footer can display it.
        XCTAssertEqual(coord.phase, "Installing")
    }

    func testRepeatedPhaseDoesNotDuplicateCompletedEntries() {
        let coord = makeCoordinator()
        coord.simulateLineForTests("#OSTLER\tPHASE\tid=setup_questions\ttitle=Setup")
        coord.simulateLineForTests("#OSTLER\tPHASE\tid=setup_questions\ttitle=Setup")
        let licenseCount = coord.completedSteps.filter { $0.id == "license_entry" }.count
        let prereqCount = coord.completedSteps.filter { $0.id == "prereq_check" }.count
        XCTAssertEqual(licenseCount, 1)
        XCTAssertEqual(prereqCount, 1)
    }

    func testStepBeginAfterPhaseTakesOverActiveRow() {
        let coord = makeCoordinator()
        // Walk the realistic flow: PHASE setup_questions -> then the
        // first install.sh `progress(..., "homebrew_install")` fires
        // a STEP_BEGIN. The sidebar's active row should move from
        // setup_questions to homebrew_install + setup_questions
        // should be back-filled as complete.
        coord.simulateLineForTests("#OSTLER\tPHASE\tid=setup_questions\ttitle=Setup")
        coord.simulateLineForTests(
            "#OSTLER\tSTEP_BEGIN\tid=homebrew_install\ttitle=Homebrew\tidx=1\ttotal=20"
        )
        XCTAssertEqual(coord.currentStepId, "homebrew_install")
        // setup_questions, prereq_check, license_entry all complete.
        let ids = Set(coord.completedSteps.map { $0.id })
        XCTAssertTrue(ids.contains("setup_questions"))
        XCTAssertTrue(ids.contains("prereq_check"))
        XCTAssertTrue(ids.contains("license_entry"))
    }

    // MARK: - v1.0.11: blank-step-title retain fix

    /// Regression for the "weird new '?' titled page" seen on the late
    /// settling/enrichment screens. A STEP_BEGIN that arrives WITHOUT a
    /// `title=` field must NOT blank the H1 to "?" -- the coordinator
    /// retains the last known step title instead.
    func testTitlelessStepBeginRetainsPreviousTitle() {
        let coord = makeCoordinator()
        coord.simulateLineForTests(
            "#OSTLER\tSTEP_BEGIN\tid=settling_enrich\ttitle=Enriching your graph\tidx=35\ttotal=38"
        )
        XCTAssertEqual(coord.currentStepTitle, "Enriching your graph")

        // A subsequent title-less STEP_BEGIN (e.g. a phase-ish progress
        // marker on the live stream) must retain the heading, never "?".
        coord.simulateLineForTests("#OSTLER\tSTEP_BEGIN\tid=settling_enrich")
        XCTAssertEqual(coord.currentStepTitle, "Enriching your graph")
        XCTAssertNotEqual(coord.currentStepTitle, "?")
    }

    /// An explicitly empty `title=` value is treated the same as absent:
    /// the previous title is retained, not overwritten with a blank/"?".
    func testEmptyTitleStepBeginRetainsPreviousTitle() {
        let coord = makeCoordinator()
        coord.simulateLineForTests(
            "#OSTLER\tSTEP_BEGIN\tid=settling_a\ttitle=Settling in"
        )
        coord.simulateLineForTests("#OSTLER\tSTEP_BEGIN\tid=settling_b\ttitle=")
        XCTAssertEqual(coord.currentStepTitle, "Settling in")
    }

    /// A real titled STEP_BEGIN still takes over the heading.
    func testTitledStepBeginStillUpdatesTitle() {
        let coord = makeCoordinator()
        coord.simulateLineForTests(
            "#OSTLER\tSTEP_BEGIN\tid=one\ttitle=First"
        )
        coord.simulateLineForTests(
            "#OSTLER\tSTEP_BEGIN\tid=two\ttitle=Second"
        )
        XCTAssertEqual(coord.currentStepTitle, "Second")
    }

    /// A title-less PHASE retains the current strap rather than "?".
    func testTitlelessPhaseRetainsStrap() {
        let coord = makeCoordinator()
        coord.simulateLineForTests("#OSTLER\tPHASE\tid=install\ttitle=Installing")
        XCTAssertEqual(coord.phase, "Installing")
        coord.simulateLineForTests("#OSTLER\tPHASE\tid=install")
        XCTAssertEqual(coord.phase, "Installing")
        XCTAssertNotEqual(coord.phase, "?")
    }

    /// The decoder no longer fabricates a "?" glyph for an absent title;
    /// it yields "" so the coordinator can distinguish "no title" from a
    /// genuine one.
    func testDecoderTitlelessStepBeginYieldsEmptyTitle() {
        let event = ProgressDecoder.decode(line: "#OSTLER\tSTEP_BEGIN\tid=x")
        guard case .stepBegin(_, let title, _, _, _) = event else {
            return XCTFail("expected .stepBegin, got \(event)")
        }
        XCTAssertEqual(title, "")
    }
}
