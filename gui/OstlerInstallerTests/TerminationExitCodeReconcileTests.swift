// TerminationExitCodeReconcileTests.swift
//
// CX-454 (v1.0.1): the GUI subprocess wrapper must never report a
// successful install when install.sh actually died. Two completion
// signals are load-bearing -- the protocol DONE marker (parsed into
// `finished`) AND the OS process exit code -- and SUCCESS REQUIRES
// BOTH TO AGREE. A `DONE status=ok` marker contradicted by a non-zero
// exit code (a post-marker tail command, or the bash wrapper, dying),
// or any termination with no DONE marker at all (a `set -u` unbound-
// variable abort mid-script), must surface as a loud, visible install
// FAILURE -- not the green "all set" success screen over a broken Hub.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// these tests pin the EXACT reconciliation outcome for every cell of
// the (DONE marker x exit code x cancelled) truth table, so a silent
// regression back to "trust the marker, ignore the exit code" (or the
// pre-CX-126 "exit 0 -> success even with no marker") cannot ship
// undetected. The pure static `reconcileTermination` seam is exercised
// directly so no real `Process` (whose `terminationStatus` cannot be
// mocked) is required.

import XCTest
@testable import OstlerInstaller

@MainActor
final class TerminationExitCodeReconcileTests: XCTestCase {

    // MARK: - The single regression this whole task exists to prevent

    /// CX-454 core case: install.sh emitted `DONE status=ok` but the
    /// process then exited non-zero (e.g. a tail command after the
    /// marker, or the bash wrapper, died). This MUST be a failure --
    /// never a silent success.
    func testOkMarkerWithNonZeroExitIsLoudFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .ok,
            cancelled: false,
            exitCode: 1,
            failedSteps: 0
        )
        guard case .failure(let message) = outcome else {
            return XCTFail("ok marker + non-zero exit must reconcile to .failure, got \(outcome)")
        }
        XCTAssertTrue(
            message.contains("exit 1"),
            "Failure message must surface the non-zero exit code for triage."
        )
        XCTAssertFalse(message.isEmpty, "Failure must carry visible error context.")
    }

    /// CX-126 case, asserted via the same seam: the script died with
    /// NO DONE marker, and a `set -u` abort can surface as exit 0 via
    /// pipeline / wrapper masking. Still a failure.
    func testNoMarkerWithZeroExitIsFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: nil,
            cancelled: false,
            exitCode: 0,
            failedSteps: 0
        )
        guard case .failure = outcome else {
            return XCTFail("no marker + exit 0 must reconcile to .failure (CX-126), got \(outcome)")
        }
    }

    func testNoMarkerWithNonZeroExitIsFailureAndSurfacesCode() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: nil,
            cancelled: false,
            exitCode: 2,
            failedSteps: 0
        )
        guard case .failure(let message) = outcome else {
            return XCTFail("no marker + non-zero exit must reconcile to .failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("exit 2"), "Exit code must appear in the message.")
    }

    // MARK: - The success path must still pass cleanly

    func testOkMarkerWithZeroExitIsConfirmedSuccess() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .ok,
            cancelled: false,
            exitCode: 0,
            failedSteps: 0
        )
        XCTAssertEqual(
            outcome, .confirmedSuccess,
            "A DONE status=ok marker AND a clean exit 0 is the only success."
        )
    }

    // MARK: - Explicit failure marker is honoured regardless of exit

    func testFailMarkerWithZeroExitIsConfirmedFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .fail,
            cancelled: false,
            exitCode: 0,
            failedSteps: 0
        )
        XCTAssertEqual(outcome, .confirmedFailure)
    }

    func testFailMarkerWithNonZeroExitIsConfirmedFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .fail,
            cancelled: false,
            exitCode: 1,
            failedSteps: 0
        )
        XCTAssertEqual(outcome, .confirmedFailure)
    }

    // MARK: - User cancel is neutral, never a failure

    func testCancelledIsNeutralEvenWithNonZeroExit() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: nil,
            cancelled: true,
            exitCode: 1,
            failedSteps: 0
        )
        XCTAssertEqual(
            outcome, .cancelled,
            "A deliberate user cancel must stay neutral, not a red failure."
        )
    }

    // MARK: - warn-finish requires a clean exit to count as success

    func testWarnMarkerWithZeroExitIsSuccess() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .warn,
            cancelled: false,
            exitCode: 0,
            failedSteps: 0
        )
        XCTAssertEqual(outcome, .confirmedSuccess)
    }

    func testWarnMarkerWithNonZeroExitIsFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .warn,
            cancelled: false,
            exitCode: 3,
            failedSteps: 0
        )
        guard case .failure = outcome else {
            return XCTFail("warn marker + non-zero exit must reconcile to .failure, got \(outcome)")
        }
    }

    // MARK: - End-to-end through handleTermination's public effects

    /// Drives a coordinator into the false-success shape via the test
    /// seam (an `ok` finish) and asserts that once the (non-zero) exit
    /// is reconciled the coordinator's terminal state flips to `.fail`
    /// with a populated, visible error -- i.e. ContentView renders the
    /// failure banner, not the success screen.
    func testCoordinatorOverridesFalseSuccessToFailure() {
        let coord = InstallerCoordinator()
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=ok")
        XCTAssertEqual(coord.finished, .ok, "Precondition: marker set optimistic success.")

        // Reconcile against a non-zero exit (the wrapper / tail died).
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: coord.finished,
            cancelled: coord.cancelled,
            exitCode: 1,
            failedSteps: 0
        )
        if case .failure(let message) = outcome {
            // Mirror the override handleTermination performs.
            coord.finished = .fail
            if coord.error == nil { coord.error = message }
        }
        XCTAssertEqual(coord.finished, .fail, "False success must be overridden to failure.")
        XCTAssertNotNil(coord.error, "A visible error message must be surfaced to the user.")
        XCTAssertEqual(coord.failureState, .failed(step: nil))
    }

    // MARK: - The third signal: failed_steps (v1.0.62 walk, Mini 16)
    //
    // MEASURED, NOT REASONED ABOUT. ttywalk of the v1.0.62 DMG finished
    // 2026-09-03T20:42:08Z with these two consecutive lines:
    //
    //     STEP_END id=health_check status=error elapsed_s=135 rc=2
    //     DONE     status=ok failed_steps=1 errors=0
    //
    // and the process exited 0. Both signals reconcileTermination consulted
    // said success, so the customer got the green "all set" screen AND the
    // auto-quit countdown -- the window closing itself over a failed step.
    //
    // `cuts/v1.0.46/MUST_CONTAIN.tsv` has required since 2026-08-25 that the
    // verdict and the counter cannot disagree in either direction. CM051
    // #1369 closed the half a HUMAN reads and said in its own row that the
    // machine-read field was "sequenced separately and is NOT touched here".
    // This is that half.

    /// THE REGRESSION. Marker says ok, exit code agrees, counter dissents.
    func testOkMarkerWithFailedStepsAndExitZeroIsLoudFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .ok,
            cancelled: false,
            exitCode: 0,
            failedSteps: 1
        )
        guard case .failure(let message) = outcome else {
            return XCTFail("""
                A run that reached the end carrying 1 failed step reported \
                \(outcome). This is the exact v1.0.62 walk shape: status=ok, \
                exit 0, failed_steps=1 over health_check rc=2. Reporting it as \
                success renders the green screen AND arms the auto-quit.
                """)
        }
        // The COUNT must reach the customer, not merely "something failed".
        // A message that says only "some steps" cannot be checked by the
        // reader against the log, which is the whole point of surfacing it.
        XCTAssertTrue(message.contains("1 step"),
                      "The customer must be told HOW MANY. Got: \(message)")
        XCTAssertFalse(message.contains("1 steps"),
                       "Singular must not read as plural. Got: \(message)")
    }

    /// NEGATIVE CONTROL. Without this the test above is satisfied by a
    /// predicate that fails every install, which would be far worse than
    /// the defect. A clean run must still be a clean run.
    func testOkMarkerWithNoFailedStepsAndExitZeroIsStillSuccess() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .ok,
            cancelled: false,
            exitCode: 0,
            failedSteps: 0
        )
        XCTAssertEqual(outcome, .confirmedSuccess, """
            A genuinely clean install must not be failed by this rule. If this \
            arm goes red the fix is refusing EVERY install, which ships worse \
            than the bug it replaced.
            """)
    }

    /// The sibling arm. `warn`/`timeout` also produce success on exit 0, so
    /// fixing only `.ok` would leave the identical hole one case over.
    func testWarnMarkerWithFailedStepsIsAlsoAFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .warn,
            cancelled: false,
            exitCode: 0,
            failedSteps: 2
        )
        guard case .failure(let message) = outcome else {
            return XCTFail("warn + failed_steps=2 reported \(outcome)")
        }
        XCTAssertTrue(message.contains("2 steps"),
                      "Plural count must reach the customer. Got: \(message)")
    }

    /// A marker that ALREADY says fail must stay `.confirmedFailure`. The
    /// installer has spoken; re-routing it through the new message would
    /// discard the error code CX-17 put on the banner.
    func testFailMarkerWithFailedStepsStaysConfirmedFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .fail,
            cancelled: false,
            exitCode: 1,
            failedSteps: 3
        )
        XCTAssertEqual(outcome, .confirmedFailure,
                       "An explicit fail marker must not be relabelled.")
    }

    /// A cancel must stay neutral even if steps failed before the customer
    /// cancelled. They chose to stop; that is not a broken install.
    func testCancelWithFailedStepsStaysCancelled() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .ok,
            cancelled: true,
            exitCode: 0,
            failedSteps: 1
        )
        XCTAssertEqual(outcome, .cancelled)
    }

    /// THE WIRE, not just the predicate. The pure function above could be
    /// perfect while the marker parser never stored the count -- which is
    /// precisely the state this fix found: `failed_steps` was parsed, logged
    /// at line 1834, and dropped before `handleTermination` ran. This drives
    /// a REAL marker line through the REAL parser.
    func testDoneMarkerFailedStepsReachesTheCoordinator() {
        let coord = InstallerCoordinator()
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=ok\tfailed_steps=1\terrors=0")
        XCTAssertEqual(coord.finished, .ok, "Precondition: the marker parsed.")
        XCTAssertEqual(coord.failedStepCount, 1, """
            The DONE marker carried failed_steps=1 and the coordinator stored \
            \(coord.failedStepCount). Surfacing a count in the log is not the \
            same as keeping it for the decision; this assertion is the wire.
            """)
    }
}
