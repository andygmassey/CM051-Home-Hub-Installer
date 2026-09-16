// CaffeinateTerminationTests.swift
//
// Quit mid-install and the customer's Mac never slept again until they
// rebooted it.
//
// `CaffeinateManager`'s header claimed `stop()` ran "on every install
// end path (success, failure, cancel, user quit)". Measured: `stop()`
// had exactly ONE call site, `InstallerCoordinator.handleTermination()`,
// which is the INSTALL SUBPROCESS handler. A user quit does not pass
// through it. And the target had no app-termination hook of any kind --
// a grep for applicationWillTerminate / NSApplicationDelegate /
// willTerminateNotification / applicationShouldTerminate across gui/
// returned zero, exit code 1, while the same grep shape for `onAppear`
// resolved to real production sites (App.swift, OnboardingQuestionView),
// so the search apparatus was working.
//
// macOS does not kill a child when its parent dies. The orphaned
// `caffeinate -dimsu` reparented to launchd holding a live
// IOPMAssertion: display sleep, idle sleep, disk sleep and system sleep
// all suppressed, with nothing on screen to explain it and no obvious
// process for the customer to find.
//
// TWO INDEPENDENT CLOSURES, because they fail in different ways:
//   - `-w <our pid>` binds the child's lifetime to ours in the KERNEL,
//     so it survives a crash or SIGKILL where no Swift handler runs.
//   - `applicationWillTerminate` releases promptly on an ordinary quit
//     rather than at process teardown.
//
// The argv is asserted as a pure value rather than by spawning a real
// caffeinate, so the suite never leaves a power assertion on the host
// that runs it.

import Foundation
import XCTest
@testable import OstlerInstaller

final class CaffeinateTerminationTests: XCTestCase {

    // MARK: - The kernel-side binding

    /// THE REGRESSION TEST. Without `-w <pid>` the assertion outlives
    /// the app on every path no handler can reach.
    func testCaffeinateLifetimeIsBoundToOurProcess() {
        let args = CaffeinateManager.arguments(watchingPid: 4242)

        guard let wIndex = args.firstIndex(of: "-w") else {
            return XCTFail(
                """
                caffeinate is spawned without -w. Nothing then binds its lifetime \
                to ours: on quit, crash or SIGKILL it reparents to launchd still \
                holding the sleep assertion, and the customer's Mac will not sleep \
                again until it is rebooted.
                """
            )
        }
        XCTAssertTrue(
            args.indices.contains(wIndex + 1),
            "-w was passed with no pid after it."
        )
        XCTAssertEqual(
            args[wIndex + 1], "4242",
            "-w must carry the pid it was asked to watch."
        )
    }

    /// The assertion flags must survive the change. Adding -w while
    /// dropping -dimsu would stop the Mac sleeping problem by no longer
    /// preventing sleep at all, which breaks the install instead.
    func testAssertionFlagsAreUnchanged() {
        let args = CaffeinateManager.arguments(watchingPid: 1)
        XCTAssertEqual(
            args.first, "-dimsu",
            """
            The -dimsu assertion flags are gone. They are why this process exists: \
            -d display, -i idle, -m disk, -s system, -u user-active. Without them \
            a long install can be interrupted by the Mac going to sleep.
            """
        )
    }

    /// The pid is read from the running process, not hardcoded. A
    /// constant here would bind the child to somebody else's lifetime.
    func testPidIsTheLiveProcessIdentifier() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Auth/CaffeinateManager.swift"
        )
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            src.contains("arguments(watchingPid: ProcessInfo.processInfo.processIdentifier)"),
            "start() must watch THIS process's pid, taken live from ProcessInfo."
        )
    }

    // MARK: - The app-side hook

    /// THE SECOND MUTATION DETECTOR. Deleting the delegate puts the
    /// ordinary quit path back to relying on a handler that only the
    /// install subprocess triggers.
    func testAppDeclaresATerminationHookThatReleasesTheAssertion() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/App.swift"
        )
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            src.contains("NSApplicationDelegateAdaptor"),
            """
            App.swift no longer installs an application delegate. There is then no \
            app-termination hook at all, and CaffeinateManager.stop() is reachable \
            only from the install-subprocess handler -- which a user quit never \
            reaches.
            """
        )
        XCTAssertTrue(
            src.contains("func applicationWillTerminate"),
            "The delegate must implement applicationWillTerminate; that is the hook a user quit actually fires."
        )
        XCTAssertTrue(
            src.contains("CaffeinateManager.shared.stop()"),
            "applicationWillTerminate must release the power assertion."
        )
    }

    /// stop() is documented idempotent and both closures can fire on the
    /// same quit, so overlapping must be harmless. Asserted directly
    /// because "safe to call twice" is load-bearing here rather than a
    /// nicety.
    @MainActor
    func testStopIsIdempotent() {
        CaffeinateManager.shared.stop()
        CaffeinateManager.shared.stop()
        XCTAssertFalse(
            CaffeinateManager.shared.isRunning,
            "Repeated stop() with nothing running must be a no-op, since the subprocess handler and the app delegate can both fire on one quit."
        )
    }
}
