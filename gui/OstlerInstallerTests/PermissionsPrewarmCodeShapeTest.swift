// PermissionsPrewarmCodeShapeTest.swift
//
// CX-18 (2026-05-23) regression test. The PermissionsPrewarmer
// silent-fail axis is "the four TCC requestAccess calls fire in a
// shape that lets macOS treat them as a concurrent burst, or that
// silently swallows a cached deny without rendering a popup, or
// that misses the AppleEvent Contacts scope that install.sh
// triggers later via osascript". A behaviour test (build the app,
// click Grant, watch the popups) is not feasible from xcodebuild
// test on a CI host with no TCC state; instead we pin the SHAPE
// of the code by walking PermissionsPrewarmer.swift byte-by-byte
// and asserting the required call patterns exist + the forbidden
// patterns do not.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// for the exact silent-bail axis (concurrent burst + silent cache
// + missed AppleEvent), walk the assembled source bytes asserting
// the forbidden shape never recurs. A happy-path test would still
// pass on a regression to async-let / TaskGroup / "drop the
// pre-check" / "drop the AppleEvent probe" because the methods
// would still compile + return Bools.

import Foundation
import XCTest
@testable import OstlerInstaller

final class PermissionsPrewarmCodeShapeTest: XCTestCase {

    // MARK: - Source loader

    /// Locate PermissionsPrewarmer.swift relative to the test
    /// bundle. Uses the same repo-root walker as
    /// PermissionsPrewarmInfoPlistTest via StringsCatalogueEmDashTest.
    private func loadPrewarmerSource() throws -> String {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Auth/PermissionsPrewarmer.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Fix 1 -- await-each-completion sequencing

    /// The CX-17 fix was a serial `for ... in requestOrder` loop
    /// that awaits each request before moving to the next. A
    /// regression to `async let` or `TaskGroup` would race all
    /// four popups in the same second and the customer would miss
    /// two of them (Studio retest 2026-05-23). Pin the SHAPE.
    func testPrewarmUsesSerialForAwaitLoopNotConcurrentBurst() throws {
        let src = try loadPrewarmerSource()

        // Required: the canonical serial loop body.
        XCTAssertTrue(
            src.contains("for (idx, permission) in Self.requestOrder.enumerated()"),
            "PermissionsPrewarmer.prewarm() must walk requestOrder serially via a for-in loop. CX-17 fix for the concurrent-burst regression that landed all four popups in the same second."
        )
        XCTAssertTrue(
            src.contains("await requester.request(permission)"),
            "PermissionsPrewarmer.prewarm() must await each requester.request call before moving to the next. Without the await the loop would fire-and-forget and stack popups."
        )

        // Forbidden: async-let or TaskGroup concurrency forms.
        // These would burst all four requests at once.
        XCTAssertFalse(
            src.contains("async let "),
            "PermissionsPrewarmer must NOT use `async let` for the four permission requests -- that races them all into the same second. Use a serial for-in loop instead. (CX-17 regression guard.)"
        )
        XCTAssertFalse(
            src.contains("withTaskGroup") || src.contains("withThrowingTaskGroup"),
            "PermissionsPrewarmer must NOT use TaskGroup for the four permission requests -- same regression shape as async-let. Use a serial for-in loop. (CX-17 regression guard.)"
        )
    }

    // MARK: - Fix 1b (CX-18) -- TCC authorizationStatus pre-check

    /// CX-18 (2026-05-23). The pre-warm now PRE-CHECKS each
    /// permission's current TCC status before calling
    /// requestAccess. A cached deny / grant short-circuits the
    /// request so the serial loop only PAUSES on permissions that
    /// actually need a customer decision -- the "Reminders fires
    /// but the other three came back silently denied" Studio
    /// retest #13 failure shape never recurs.
    func testSystemRequesterPreChecksAuthorizationStatusForEachPermission() throws {
        let src = try loadPrewarmerSource()

        // Required: each requestAccess wrapper queries the cached
        // status first. The byte-walk pins the API call shape;
        // future framework changes that drop authorizationStatus
        // (Apple deprecation) would fail this test loudly so we
        // can pick a replacement instead of silently regressing.
        XCTAssertTrue(
            src.contains("CNContactStore.authorizationStatus(for: .contacts)"),
            "SystemPermissionRequester.requestContactsAccess must pre-check CNContactStore.authorizationStatus before calling requestAccess. (CX-18 fix for Studio retest #13 silent-deny shape.)"
        )
        XCTAssertTrue(
            src.contains("EKEventStore.authorizationStatus(for: .event)"),
            "SystemPermissionRequester.requestCalendarAccess must pre-check EKEventStore.authorizationStatus(.event) before calling requestFullAccessToEvents. (CX-18 regression guard.)"
        )
        XCTAssertTrue(
            src.contains("EKEventStore.authorizationStatus(for: .reminder)"),
            "SystemPermissionRequester.requestRemindersAccess must pre-check EKEventStore.authorizationStatus(.reminder) before calling requestFullAccessToReminders. (CX-18 regression guard.)"
        )
        XCTAssertTrue(
            src.contains("PHPhotoLibrary.authorizationStatus(for: .readWrite)"),
            "SystemPermissionRequester.requestPhotosAccess must pre-check PHPhotoLibrary.authorizationStatus before calling requestAuthorization. (CX-18 regression guard.)"
        )
    }

    // MARK: - Fix 2 -- AppleEvent Contacts probe

    /// CX-18 (2026-05-23). install.sh's contact-card auto-detect
    /// runs `osascript -e 'tell application "Contacts" to ...'`
    /// which triggers the SEPARATE AppleEvent automation TCC
    /// scope. Without an up-front probe, the customer hits the
    /// blue-icon "wants to control Contacts" prompt mid-install
    /// when they have walked away. Pin the AppleEvent probe shape
    /// in PermissionsPrewarmer + its wiring into prewarm().
    func testAppleEventContactsProbeExistsAndIsWiredIntoPrewarm() throws {
        let src = try loadPrewarmerSource()

        XCTAssertTrue(
            src.contains("enum AppleEventContactsProbe"),
            "PermissionsPrewarmer.swift must declare `AppleEventContactsProbe` (CX-18 fix). install.sh's osascript Contacts call triggers the AppleEvent automation TCC scope on top of CNContact TCC; the probe pre-warms it at the same point in the flow as the other four prompts."
        )
        XCTAssertTrue(
            src.contains("NSAppleScript(source:"),
            "AppleEventContactsProbe must instantiate NSAppleScript so the probe actually triggers the AppleEvent automation prompt. (CX-18 regression guard -- a stub-only enum would silently pass.)"
        )
        XCTAssertTrue(
            src.contains("tell application \\\"Contacts\\\""),
            "AppleEventContactsProbe must execute a `tell application \"Contacts\"` script so the probe matches install.sh's contact-card auto-detect target. (CX-18 contract -- same script target = same TCC prompt.)"
        )

        // The probe must be WIRED into prewarm() (just declaring
        // it but never calling it would still pass the previous
        // asserts but fail the customer-facing intent).
        XCTAssertTrue(
            src.contains("AppleEventContactsProbe.probe()"),
            "PermissionsPrewarmer.prewarm() must call AppleEventContactsProbe.probe() so the AppleEvent prompt fires during the pre-warm sequence, not mid-install. (CX-18 wiring guard.)"
        )
    }

    // MARK: - Fix 1c -- no leading sleep before first request

    /// CX-17 contract preserved into CX-18: the first request
    /// fires immediately, not after a leading gap. Pre-fix the
    /// loop slept BEFORE every iteration which read as a hang
    /// while the customer waited for the first popup.
    func testFirstRequestFiresWithoutLeadingTaskSleep() throws {
        let src = try loadPrewarmerSource()
        // The gap is INSIDE the loop body under an `idx > 0`
        // guard. Walk for the guard. If a future edit moved the
        // sleep above the guard (or dropped the guard), this
        // assert fires.
        XCTAssertTrue(
            src.contains("if idx > 0 {"),
            "PermissionsPrewarmer.prewarm() must gate the Task.sleep gap on `if idx > 0` so the first request fires without a leading delay. A regression to unconditional `Task.sleep` before each request reads as a hang. (CX-17 regression guard.)"
        )
    }
}
