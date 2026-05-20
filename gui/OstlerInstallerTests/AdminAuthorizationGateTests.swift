// AdminAuthorizationGateTests.swift
//
// Pins the pre-launch admin-grant contract added in
// fix/cm051-sudo-install-blocker-2026-05-19. install.sh line 2574
// runs a bare `sudo -v` under OSTLER_GUI=1 with stdin redirected
// to a pipe; on a fresh Mac with no warm sudo timestamp that exits
// non-zero and trips `fail`. The Coordinator must seed the
// timestamp via the macOS-native admin dialog (AuthorizationHelper)
// BEFORE launching install.sh.
//
// Two contract assertions:
//
//   1. Happy path -- the admin-authorisation provider returns true
//      (user clicked Allow + entered password). The Coordinator
//      proceeds to the launch step.
//
//   2. Cancel path -- the provider returns false (user clicked
//      Cancel, or osascript returned non-zero). The Coordinator
//      must NOT proceed to the launch step. `needsAdminRetry`
//      flips true and `error` carries the retry message so the
//      AdminAccessRequiredView surfaces.
//
// Both cases use the DEBUG-only `setAdminAuthorizationProvider(_:)`
// + `setLaunchInstallerOverride(_:)` seams on the Coordinator,
// mirroring the existing test-injection idiom (see
// `setRegistrationClient` / `simulateLineForTests`). No real
// osascript call + no real Process.launch is performed.

import XCTest
@testable import OstlerInstaller

@MainActor
final class AdminAuthorizationGateTests: XCTestCase {

    /// Build a coordinator with the licence + registration gates
    /// already in the "ready to bootstrap" state. We bypass the
    /// production licence-verification path; nothing else in the
    /// test cares whether the claims are real, only that the
    /// guards in `bootstrapAsync()` let us through to the admin
    /// authorisation step.
    private func makeReadyCoordinator() -> InstallerCoordinator {
        let coord = InstallerCoordinator()
        coord.licenseVerified = true
        coord.registrationGate = .ready
        return coord
    }

    /// Drives `bootstrap()` -- which spawns a Task -- and waits for
    /// the inner async work to land its state mutations. Polls the
    /// main run loop for up to `timeout` seconds, returning early
    /// once `condition` flips true. Mirrors the "pump RunLoop"
    /// idiom that XCTest uses for `expectation(forKeyPath:)` but
    /// stays explicit so the test is readable.
    private func waitFor(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    // MARK: - Phase 1: park at acknowledgement gate

    func testBootstrapParksAtAcknowledgementGate() async {
        // F3 (Studio retest #2 2026-05-20): bootstrap() must park
        // at `needsAdminAcknowledgement = true` rather than firing
        // the dialog immediately. The provider must NOT be invoked
        // until the customer presses the Continue button.
        let coord = makeReadyCoordinator()

        var providerCalled = false
        var launchCalled = false

        coord.setAdminAuthorizationProvider { _ in
            providerCalled = true
            return true
        }
        coord.setLaunchInstallerOverride { launchCalled = true }

        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }

        XCTAssertTrue(coord.needsAdminAcknowledgement,
                      "bootstrap must park at the acknowledgement gate")
        XCTAssertFalse(providerCalled,
                       "admin provider MUST NOT fire until the customer acknowledges")
        XCTAssertFalse(launchCalled,
                       "launch step MUST NOT fire until the customer acknowledges")
        XCTAssertFalse(coord.needsAdminRetry)
    }

    // MARK: - Happy path: ack -> grant -> launch

    func testAcknowledgementProceedsToLaunch() async {
        let coord = makeReadyCoordinator()

        var providerCalled = false
        var launchCalled = false
        let promptReason = ViewCopy.shared.string(
            for: "admin_access_required.prompt_reason"
        )
        var capturedReason: String? = nil

        coord.setAdminAuthorizationProvider { reason in
            providerCalled = true
            capturedReason = reason
            return true
        }
        coord.setLaunchInstallerOverride {
            launchCalled = true
        }

        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }
        coord.userAcknowledgedAdminRequest()
        await waitFor { launchCalled }

        XCTAssertTrue(providerCalled,
                      "admin authorisation provider must be invoked before launch")
        XCTAssertEqual(capturedReason, promptReason,
                       "provider must receive the catalogue prompt-reason string verbatim")
        XCTAssertTrue(launchCalled,
                      "launch step must run once admin grant succeeds")
        XCTAssertFalse(coord.needsAdminRetry,
                       "needsAdminRetry must stay false on happy path")
        XCTAssertFalse(coord.needsAdminAcknowledgement,
                       "acknowledgement gate must clear after the customer proceeds")
        XCTAssertNil(coord.error,
                     "error surface must stay clear on happy path")
    }

    // MARK: - Cancel path

    func testAdminCancelHoldsAtRetryGate() async {
        let coord = makeReadyCoordinator()

        var providerCalled = false
        var launchCalled = false

        coord.setAdminAuthorizationProvider { _ in
            providerCalled = true
            return false   // user clicked Cancel in the macOS dialog
        }
        coord.setLaunchInstallerOverride {
            launchCalled = true
        }

        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }
        coord.userAcknowledgedAdminRequest()
        await waitFor { coord.needsAdminRetry }

        XCTAssertTrue(providerCalled,
                      "admin authorisation provider must be invoked once the customer acknowledges")
        XCTAssertFalse(launchCalled,
                       "launch step must NOT run when admin grant is declined")
        XCTAssertTrue(coord.needsAdminRetry,
                      "needsAdminRetry must latch true so AdminAccessRequiredView renders")
        XCTAssertEqual(coord.error,
                       ViewCopy.shared.string(for: "admin_access_required.retry_message"),
                       "error surface must carry the retry message from the catalogue")
    }

    // MARK: - Retry after cancel

    func testRetryAfterCancelReinvokesProviderAndLaunches() async {
        let coord = makeReadyCoordinator()

        var providerCalls = 0
        var launchCalled = false

        coord.setAdminAuthorizationProvider { _ in
            providerCalls += 1
            // First call: user-cancel. Second call (post-Retry): user
            // grants. The Coordinator's retry path must re-invoke the
            // provider; the helper's internal 240s cache exists but
            // is not exercised here because we replace the provider
            // entirely with this closure.
            return providerCalls >= 2
        }
        coord.setLaunchInstallerOverride {
            launchCalled = true
        }

        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }
        coord.userAcknowledgedAdminRequest()
        await waitFor { coord.needsAdminRetry }
        XCTAssertEqual(providerCalls, 1)
        XCTAssertFalse(launchCalled)

        coord.retryAdminAuthorization()
        await waitFor { launchCalled }

        XCTAssertEqual(providerCalls, 2,
                       "retry must re-invoke the admin authorisation provider")
        XCTAssertTrue(launchCalled,
                      "second grant must let the launch step run")
        XCTAssertFalse(coord.needsAdminRetry,
                       "needsAdminRetry must clear after a successful retry")
        XCTAssertNil(coord.error,
                     "error surface must clear after a successful retry")
    }

    // MARK: - Duplicate-fire guard (F2)

    func testDoubleBootstrapDoesNotDoubleFireProvider() async {
        // F2: pre-fix the Studio retest #2 log showed two
        // "Requesting administrator access via macOS native dialog"
        // entries in the same second. Drive bootstrap() twice
        // rapidly and assert the provider only fires once across
        // the ack + launch flow.
        let coord = makeReadyCoordinator()

        var providerCalls = 0
        var launchCalls = 0
        coord.setAdminAuthorizationProvider { _ in
            providerCalls += 1
            // Sleep briefly so a second concurrent caller has time
            // to land its guard check before we resolve.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return true
        }
        coord.setLaunchInstallerOverride { launchCalls += 1 }

        coord.bootstrap()
        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }
        // Now fire the ack twice in flight -- the second call must
        // short-circuit on `requestingAdmin`.
        coord.userAcknowledgedAdminRequest()
        coord.userAcknowledgedAdminRequest()
        await waitFor { launchCalls >= 1 }
        // Give any pending Task a beat to land its mutations
        // before asserting we don't see a duplicate.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(providerCalls, 1,
                       "admin provider must fire exactly once even under double-call")
        XCTAssertEqual(launchCalls, 1,
                       "launch step must fire exactly once even under double-call")
    }
}
