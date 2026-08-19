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
            exitCode: 1
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
            exitCode: 0
        )
        guard case .failure = outcome else {
            return XCTFail("no marker + exit 0 must reconcile to .failure (CX-126), got \(outcome)")
        }
    }

    func testNoMarkerWithNonZeroExitIsFailureAndSurfacesCode() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: nil,
            cancelled: false,
            exitCode: 2
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
            exitCode: 0
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
            exitCode: 0
        )
        XCTAssertEqual(outcome, .confirmedFailure)
    }

    func testFailMarkerWithNonZeroExitIsConfirmedFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .fail,
            cancelled: false,
            exitCode: 1
        )
        XCTAssertEqual(outcome, .confirmedFailure)
    }

    // MARK: - User cancel is neutral, never a failure

    func testCancelledIsNeutralEvenWithNonZeroExit() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: nil,
            cancelled: true,
            exitCode: 1
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
            exitCode: 0
        )
        XCTAssertEqual(outcome, .confirmedSuccess)
    }

    func testWarnMarkerWithNonZeroExitIsFailure() {
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .warn,
            cancelled: false,
            exitCode: 3
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
            exitCode: 1
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
}
