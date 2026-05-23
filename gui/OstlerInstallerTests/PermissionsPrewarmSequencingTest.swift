// PermissionsPrewarmSequencingTest.swift
//
// CX-17 (2026-05-23) regression test. The CX-14 pre-warm fired all
// four permission requests CONCURRENTLY via `async let`. Andy's
// Studio retest log showed all four dialogs AND grants/denies
// landing in the same second; he never saw the Calendar / Photos
// popups and ended up with silent denies he would have allowed.
//
// CX-17 fix: replace the concurrent burst with a SERIAL loop that
// fires each request, awaits the result, and sleeps 800ms before
// the next one. The serial order + the gap give macOS time to
// render each popup and give the customer time to read + decide.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// for the exact silent-bail axis (concurrent burst => missed
// popups), walk the assembled call sequence call-by-call asserting
//   (1) exactly four calls, one per permission,
//   (2) in the canonical Contacts / Calendar / Reminders / Photos order,
//   (3) with at least gapMillis - epsilon elapsed between each call.
// A "does it work" happy-path test would not catch a regression to
// `async let` because the four calls would still complete and
// return Bools; only the timing + ordering asserts pin the fix.

import Foundation
import XCTest
@testable import OstlerInstaller

@MainActor
final class PermissionsPrewarmSequencingTest: XCTestCase {

    // MARK: - Spy

    /// Records the permission + the timestamp of each request so
    /// the test can assert order + gap. Returns canned results.
    final class SpyRequester: PermissionRequester {
        struct Call: Equatable {
            let permission: PrewarmPermission
            let timestamp: TimeInterval
        }

        var calls: [Call] = []
        var stub: [PrewarmPermission: Bool] = [:]

        func request(_ permission: PrewarmPermission) async -> Bool {
            calls.append(Call(permission: permission, timestamp: Date().timeIntervalSinceReferenceDate))
            return stub[permission] ?? true
        }
    }

    // MARK: - Tests

    /// CX-17 contract: exactly four calls, in canonical order. A
    /// concurrent `async let` regression would land all four calls
    /// before any of the assertions could matter; the order
    /// assertion below pins the fix because async-let does not
    /// guarantee schedule order in the call-receiver.
    func testRequestsFireSeriallyInCanonicalOrder() async throws {
        let spy = SpyRequester()
        // Grant everything so the prewarm hits the happy-path log
        // lines too. Stub is keyed per-permission so future tests
        // can mix-and-match deny patterns.
        for p in PrewarmPermission.allCases { spy.stub[p] = true }

        let prewarmer = PermissionsPrewarmer(
            emitLog: { _, _ in },
            requester: spy,
            gapMillis: 50 // shrink gap for test speed; still asserted below
        )
        _ = await prewarmer.prewarm()

        XCTAssertEqual(spy.calls.count, 4,
                       "PermissionsPrewarmer must fire EXACTLY four requests (one per permission). Got \(spy.calls.count). A regression to async-let or TaskGroup that drops or duplicates a request would fail here.")

        let receivedOrder = spy.calls.map(\.permission)
        XCTAssertEqual(
            receivedOrder,
            PermissionsPrewarmer.requestOrder,
            "PermissionsPrewarmer must fire requests in canonical order \(PermissionsPrewarmer.requestOrder.map(\.rawValue)) so the customer sees the dialogs in a predictable sequence. Got \(receivedOrder.map(\.rawValue)). If this fails AND the new order is intentional, edit PermissionsPrewarmer.requestOrder + this assertion lockstep."
        )
    }

    /// CX-17 contract: at least (gapMillis - epsilon) elapsed between
    /// each adjacent call. The CX-14 concurrent-burst regression
    /// would land all four calls within microseconds of each other;
    /// any sub-gap timing fails this test.
    ///
    /// We use a 50ms gap in the test (vs 800ms in production) so
    /// the test runs fast. The CONTRACT we pin is "the gap is
    /// HONOURED", not "the gap is 800ms" -- the production figure
    /// is a separate constant (`defaultGapMillis`) that does not
    /// need a behavioural test (it is just a number).
    func testAtLeastConfiguredGapBetweenAdjacentRequests() async throws {
        let spy = SpyRequester()
        for p in PrewarmPermission.allCases { spy.stub[p] = true }

        let gapMillis: UInt64 = 50
        let prewarmer = PermissionsPrewarmer(
            emitLog: { _, _ in },
            requester: spy,
            gapMillis: gapMillis
        )
        _ = await prewarmer.prewarm()

        XCTAssertGreaterThanOrEqual(spy.calls.count, 2,
                                    "Need at least 2 calls to assert a between-call gap; got \(spy.calls.count)")

        // Allow a 10ms epsilon for scheduling jitter. The figure
        // we are pinning is the LOWER bound (we waited at LEAST
        // 50ms); a concurrent-burst regression lands all calls
        // within ~1ms which would fail loudly.
        let epsilonSeconds: TimeInterval = 0.010
        let expectedGapSeconds: TimeInterval = TimeInterval(gapMillis) / 1000.0
        for idx in 1..<spy.calls.count {
            let dt = spy.calls[idx].timestamp - spy.calls[idx - 1].timestamp
            XCTAssertGreaterThanOrEqual(
                dt,
                expectedGapSeconds - epsilonSeconds,
                "PermissionsPrewarmer must sleep at least \(gapMillis)ms between adjacent requests (idx=\(idx), dt=\(Int(dt * 1000))ms). CX-17 fix for the concurrent-burst regression. If this fails with dt close to zero, a recent change has reintroduced async-let / TaskGroup; revert to the serial loop."
            )
        }
    }

    /// CX-17 contract: the first request fires immediately (no
    /// leading gap). Pre-fix the user had to wait for an empty
    /// gap before the first popup; that read as a hang.
    func testFirstRequestFiresWithoutLeadingGap() async throws {
        let spy = SpyRequester()
        for p in PrewarmPermission.allCases { spy.stub[p] = true }

        let prewarmer = PermissionsPrewarmer(
            emitLog: { _, _ in },
            requester: spy,
            gapMillis: 200
        )
        let started = Date().timeIntervalSinceReferenceDate
        _ = await prewarmer.prewarm()

        guard let first = spy.calls.first else {
            XCTFail("Expected at least one call recorded")
            return
        }
        // 100ms ceiling is generous; first call should land in <10ms
        // on any reasonable machine. We are pinning "no leading
        // 200ms gap was added", not a precise budget.
        let dt = first.timestamp - started
        XCTAssertLessThan(dt, 0.100,
                          "First permission request must fire promptly after prewarm() (got dt=\(Int(dt * 1000))ms). Pre-CX-17 the loop body slept BEFORE the first request which felt like a hang; the fix moved the sleep to AFTER the first request.")
    }

    /// CX-17 contract: prewarm() returns per-permission results so
    /// the coordinator can surface a denial summary BEFORE the
    /// install starts (rather than burying the deny in the
    /// LogDrawer). The shape of the returned array MUST mirror
    /// canonical order + carry the granted Bool.
    func testReturnsPerPermissionResults() async throws {
        let spy = SpyRequester()
        spy.stub[.contacts]  = true
        spy.stub[.calendar]  = false  // deny
        spy.stub[.reminders] = true
        spy.stub[.photos]    = false  // deny

        let prewarmer = PermissionsPrewarmer(
            emitLog: { _, _ in },
            requester: spy,
            gapMillis: 10
        )
        let results = await prewarmer.prewarm()

        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.map(\.permission), PermissionsPrewarmer.requestOrder,
                       "Returned results must be in the same canonical order as the requests so the denial-summary screen can render them predictably.")
        XCTAssertEqual(results[0].granted, true)
        XCTAssertEqual(results[1].granted, false)
        XCTAssertEqual(results[2].granted, true)
        XCTAssertEqual(results[3].granted, false)
    }

    /// CX-17 contract: every permission outcome is emitted via the
    /// LogLineEmitter (one info line per permission). The
    /// catalogue-keyed strings live under permissions_prewarm.* so
    /// the test asserts the EMIT shape, not the English wording.
    func testLogsEveryPermissionOutcome() async throws {
        let spy = SpyRequester()
        for p in PrewarmPermission.allCases { spy.stub[p] = true }

        var lines: [(level: String, msg: String)] = []
        let prewarmer = PermissionsPrewarmer(
            emitLog: { level, msg in lines.append((level, msg)) },
            requester: spy,
            gapMillis: 5
        )
        _ = await prewarmer.prewarm()

        // We expect at minimum: 1 starting line + 4 per-permission
        // lines + 1 finished line = 6 lines. We do not pin the
        // exact wording (catalogue-controlled) but pin the count.
        XCTAssertGreaterThanOrEqual(lines.count, 6,
                                    "PermissionsPrewarmer must emit a log line for the start, each of the four outcomes, and the finish (>= 6 lines). Got \(lines.count). Pre-CX-14 the outcomes were dropped on the floor and only surfaced inside catch{} branches.")
    }
}
