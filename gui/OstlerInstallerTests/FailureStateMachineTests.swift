// FailureStateMachineTests.swift
//
// CX-14 Section D shared root cause regression tests (2026-05-23).
//
// The CX-14 brief identified that D1-D6 share a single underlying
// failure-state shape (was: implicit derivation from `finished ==
// .fail` scattered across SidebarView / ContentView / HintPanelView,
// now: explicit `failureState` derivation on InstallerCoordinator).
// These tests pin the contract so a refactor cannot silently drop
// the failed-step identity that the sidebar xmark relies on, nor the
// no-output watchdog visible-overlay signal that distinguishes
// wedged-installs from slow-but-running installs.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// each test walks the assembled state byte-by-byte (here, asserting
// the exact `.failed(step:)` enum case + the exact ViewCopy key the
// watchdog surfaces) so a silent regression to "Failed" without the
// step id, or to a hard-coded "Still going" without the catalogue
// lift, cannot ship undetected.

import XCTest
@testable import OstlerInstaller

@MainActor
final class FailureStateMachineTests: XCTestCase {

    private func makeCoordinator() -> InstallerCoordinator {
        InstallerCoordinator()
    }

    // MARK: - failureState derivation (D1, D2)

    func testFailureStateRunningWhenNotFinished() {
        let coord = makeCoordinator()
        XCTAssertEqual(coord.failureState, .running)
    }

    func testFailureStateSuccessWhenFinishedOk() {
        let coord = makeCoordinator()
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=ok")
        XCTAssertEqual(coord.failureState, .success)
    }

    func testFailureStateFailedCarriesStepIdentity() {
        let coord = makeCoordinator()
        // STEP_BEGIN sets currentStepId, then DONE fail surfaces
        // the failed-step identity to the sidebar.
        coord.simulateLineForTests(
            "#OSTLER\tSTEP_BEGIN\tid=homebrew_install\ttitle=Installing Homebrew"
        )
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=fail")
        XCTAssertEqual(coord.failureState, .failed(step: "homebrew_install"))
    }

    func testFailureStateFailedWithoutPriorStepBeginCarriesNilStep() {
        let coord = makeCoordinator()
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=fail")
        // No STEP_BEGIN ever arrived; currentStepId is nil so the
        // failed-state still resolves but with a nil step. Sidebar
        // falls back to its "all canonical entries idle" rendering.
        XCTAssertEqual(coord.failureState, .failed(step: nil))
    }

    // MARK: - A SECOND DONE MARKER (#642, 2026-09-04)
    //
    // THE INPUT THIS PINS. `set -E` propagates install.sh's ERR trap into a
    // command substitution's subshell. The subshell emits a TERMINAL DONE and
    // dies; `OSTLER_DONE_EMITTED=1` dies with it because a subshell cannot
    // write to its parent, so the parent never learns and emits its own DONE.
    // MEASURED on /bin/bash 3.2.57, one process, printing $$ and $BASH_SUBSHELL
    // at every emit:
    //
    //     pid=55691  subshell=1   DONE status=fail  failed_steps=1
    //     pid=55691  subshell=0   DONE status=ok    failed_steps=0
    //
    // So the GUI can receive two DONE markers in one run, and the second can
    // DISAGREE with the first.
    //
    // WHY THIS NEEDED PINNING RATHER THAN JUST ASSERTING. `failureState` is a
    // computed property over `finished`, and the DONE handler assigns
    // `finished = status` UNCONDITIONALLY. So the revert below is a by-product
    // of two implementation choices, not a rule anybody wrote down or tested.
    // Every test above stops at the first DONE. These two say out loud what
    // the second one does, so a future latch is a deliberate, visible change
    // rather than a silent behaviour flip.
    //
    // NOT AN ENDORSEMENT. Which behaviour is CORRECT is a product decision:
    // last-writer-wins shows success over a failed install, and latch-first
    // shows failure over a successful one. install.sh is being fixed so the
    // second marker cannot be a phantom (CM051 #1459). These tests pin what
    // the GUI does TODAY, whichever way that decision lands.

    /// fail then ok: the phantom is overwritten and the customer is shown SUCCESS.
    func testASecondDoneOverwritesTheFirstFailThenOkShowsSuccess() {
        let coord = makeCoordinator()
        coord.simulateLineForTests(
            "#OSTLER\tSTEP_BEGIN\tid=hydrate_graph\ttitle=Building the graph"
        )
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=fail\tfailed_steps=1")
        // The subshell's terminal marker lands first and is believed.
        XCTAssertEqual(coord.failureState, .failed(step: "hydrate_graph"))

        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=ok\tfailed_steps=0")
        // The parent's marker arrives second and wins. LAST WRITER WINS.
        XCTAssertEqual(coord.failureState, .success)
    }

    /// ok then fail: the same rule in the other direction, so the test above
    /// is a statement about ORDER and not about `.ok` being special.
    func testASecondDoneOverwritesTheFirstOkThenFailShowsFailure() {
        let coord = makeCoordinator()
        coord.simulateLineForTests(
            "#OSTLER\tSTEP_BEGIN\tid=hydrate_graph\ttitle=Building the graph"
        )
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=ok\tfailed_steps=0")
        XCTAssertEqual(coord.failureState, .success)

        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=fail\tfailed_steps=1")
        XCTAssertEqual(coord.failureState, .failed(step: "hydrate_graph"))
    }

    /// The TALLY is overwritten too, not just the verdict. This is the field
    /// CM051 #1460 grades, and a second DONE resetting it to 0 is how a run
    /// can end carrying `failed_steps=0` while its log records a failed step.
    func testASecondDoneAlsoOverwritesTheFailedStepTally() {
        let coord = makeCoordinator()
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=fail\tfailed_steps=1")
        XCTAssertEqual(coord.failedStepCount, 1)

        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=ok\tfailed_steps=0")
        XCTAssertEqual(coord.failedStepCount, 0,
                       "the second marker's tally replaces the first; the GUI keeps no memory of the earlier count")
    }

    func testSimulateFailureForTestsRoundTrip() {
        let coord = makeCoordinator()
        coord.simulateFailureForTests(
            step: "ai_models",
            errorMessage: "ollama pull qwen3.5:9b -> exit 1"
        )
        XCTAssertEqual(coord.failureState, .failed(step: "ai_models"))
        XCTAssertEqual(coord.error, "ollama pull qwen3.5:9b -> exit 1")
        XCTAssertEqual(coord.finished, .fail)
    }

    // MARK: - watchdog visible state (D5)

    func testWatchdogSilentFlipsAfterFifteenSeconds() {
        let coord = makeCoordinator()
        XCTAssertFalse(coord.watchdogSilent)

        // Anchor the watchdog clock (production code does this in
        // launchInstaller; we do it directly via the test seam).
        coord.simulateWatchdogSilenceForTests(elapsedSeconds: 0)
        XCTAssertFalse(coord.watchdogSilent, "Fresh output: overlay must stay hidden.")

        coord.simulateWatchdogSilenceForTests(elapsedSeconds: 14)
        XCTAssertFalse(coord.watchdogSilent, "Sub-threshold: overlay must stay hidden.")

        coord.simulateWatchdogSilenceForTests(elapsedSeconds: 15)
        XCTAssertTrue(coord.watchdogSilent, "15s silence: overlay must surface.")

        coord.simulateWatchdogSilenceForTests(elapsedSeconds: 45)
        XCTAssertTrue(coord.watchdogSilent, "Still silent at 45s: overlay must remain.")
    }

    func testWatchdogSilentClearsOnFreshSubprocessOutput() {
        let coord = makeCoordinator()
        coord.simulateWatchdogSilenceForTests(elapsedSeconds: 20)
        XCTAssertTrue(coord.watchdogSilent)

        // Fresh stdout/stderr arriving simulates the subprocess
        // moving again -- e.g. mkdocs printing the next build line.
        // The coordinator's handleIncoming clears watchdogSilent
        // synchronously; simulating via a known marker exercises
        // the same code path.
        coord.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=mkdocs done")
        // The synthetic test seam routes through `apply` directly,
        // which does NOT clear watchdogSilent (only handleIncoming
        // does). Re-arming via the watchdog with elapsed=0 emulates
        // a tick after fresh output landed.
        coord.simulateWatchdogSilenceForTests(elapsedSeconds: 0)
        XCTAssertFalse(coord.watchdogSilent, "Fresh output clears the overlay.")
    }

    func testWatchdogSilentSuppressedDuringPrompt() {
        let coord = makeCoordinator()
        // A PROMPT marker installs a pendingPrompt. While the
        // customer is staring at the question, the subprocess is
        // *deliberately* silent (it's blocked reading from the
        // FIFO). The watchdog must not flag that as a wedge.
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=user_name\tkind=text\ttitle=Your name"
        )
        XCTAssertNotNil(coord.pendingPrompt)

        coord.simulateWatchdogSilenceForTests(elapsedSeconds: 30)
        XCTAssertFalse(
            coord.watchdogSilent,
            "Customer-blocked silence (pendingPrompt != nil) must not surface the overlay."
        )
    }

    func testWatchdogSilentSuppressedAfterFinish() {
        let coord = makeCoordinator()
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=ok")
        coord.simulateWatchdogSilenceForTests(elapsedSeconds: 30)
        XCTAssertFalse(
            coord.watchdogSilent,
            "Post-finish silence must not surface the overlay."
        )
    }

    // MARK: - watchdog overlay catalogue string (D5)

    func testWatchdogOverlayCopyComesFromCatalogue() {
        // Per Rule 0.9, the customer-facing copy MUST live in
        // ViewCopy.json. This test pins the catalogue key + asserts
        // the rendered string is not the literal key itself (which
        // ViewCopy returns on a lookup miss). Drift either side
        // surfaces immediately.
        let label = ViewCopy.shared.string(for: "hint_panel.watchdog_still_going")
        XCTAssertNotEqual(label, "hint_panel.watchdog_still_going",
                          "Catalogue must contain hint_panel.watchdog_still_going")
        XCTAssertFalse(label.isEmpty)
    }
}
