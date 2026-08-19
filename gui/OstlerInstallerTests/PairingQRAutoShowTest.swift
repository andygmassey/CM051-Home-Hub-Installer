// PairingQRAutoShowTest.swift
//
// BW-FIND-27 (2026-06-23) regression test. The post-install pairing
// QR stopped AUTO-SHOWING on the success screen (it used to appear on
// its own ~2-3 cuts ago). The customer-facing "Refresh code" button
// still worked, so QR generation was fine -- the regression was in
// the auto-show trigger / first-render fetch.
//
// Root cause: the success screen can render the instant install.sh's
// start-services step fires, before the gateway has bound :8000 and
// minted a first pair code. A fresh-installed Hub has
// `pairing_required = true` but NO current code, so a plain GET
// /admin/paircode returns no `qr_payload`; the single-shot auto-fetch
// then fell through to the empty placeholder glyph. The Refresh
// button "worked" only because by the time the customer tapped it the
// gateway was up and a code had rotated into existence.
//
// The fix has two load-bearing properties this test pins:
//   1. AUTO-SHOW: the success view's `.task` calls `autoShowPairCode`,
//      which RETRIES with a backoff (tolerates a not-yet-ready
//      gateway) so the QR appears on its own.
//   2. MINT: the auto-show MINTS a fresh code via POST
//      /admin/paircode/new (GatewayClient.mintPairCodeEnvelope) so a
//      just-installed Hub with no current code still produces a QR --
//      a GET-only auto-show would regress straight back to the empty
//      placeholder.
//
// A live-gateway behaviour test is not feasible from `xcodebuild
// test` (no running Hub on a CI host), so -- per locked memory
// `feedback_silent_bail_regression_test_shape` -- we walk the
// assembled source bytes and assert the required call shapes exist
// and the forbidden single-shot-GET shape does not recur.

import Foundation
import XCTest
@testable import OstlerInstaller

final class PairingQRAutoShowTest: XCTestCase {

    // MARK: - Source loaders

    private func loadCompleteViewSource() throws -> String {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Views/InstallCompleteView.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loadGatewayClientSource() throws -> String {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/GatewayClient.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Auto-show trigger is wired into the success screen

    /// The success screen must fire the auto-show from `.task` on
    /// first appear. If a future edit drops the `.task` block (or
    /// stops it calling the auto-show), the QR silently stops
    /// auto-appearing -- exactly the BW-FIND-27 regression.
    func testSuccessScreenTaskInvokesAutoShow() throws {
        let src = try loadCompleteViewSource()

        XCTAssertTrue(
            src.contains(".task {"),
            "InstallCompleteView must keep a `.task {}` on its body so the pairing QR fetch fires on first appear. Dropping it is the BW-FIND-27 auto-show regression."
        )
        XCTAssertTrue(
            src.contains("await autoShowPairCode()"),
            "InstallCompleteView.body `.task` must call `await autoShowPairCode()` -- the auto-show entry point. (BW-FIND-27 auto-show wiring guard.)"
        )
        XCTAssertTrue(
            src.contains("private func autoShowPairCode() async"),
            "InstallCompleteView must declare `autoShowPairCode()`. (BW-FIND-27.)"
        )
    }

    // MARK: - Auto-show retries (tolerates a not-yet-ready gateway)

    /// The auto-show must RETRY. The success screen can render before
    /// the gateway has bound :8000 after start-services; a single-shot
    /// fetch then shows nothing. Pin the retry loop shape.
    func testAutoShowRetriesUntilGatewayReady() throws {
        let src = try loadCompleteViewSource()

        XCTAssertTrue(
            src.contains("autoShowMaxAttempts"),
            "InstallCompleteView.autoShowPairCode must have a bounded retry budget (autoShowMaxAttempts) so a not-yet-ready gateway is tolerated. (BW-FIND-27 -- a single-shot fetch regressed the auto-show.)"
        )
        XCTAssertTrue(
            src.contains("Task.sleep"),
            "InstallCompleteView.autoShowPairCode must sleep between attempts so the retries are spaced across the gateway boot. (BW-FIND-27 retry guard.)"
        )
        XCTAssertTrue(
            src.contains("for attempt in 1...Self.autoShowMaxAttempts"),
            "InstallCompleteView.autoShowPairCode must loop over its attempt budget. (BW-FIND-27 retry-loop shape guard.)"
        )
    }

    // MARK: - Auto-show MINTS a fresh code

    /// The auto-show must MINT a fresh code, not just GET the current
    /// one. A freshly-installed Hub has no current code, so a GET-only
    /// auto-show falls through to the empty placeholder -- the exact
    /// regression. Pin that the auto-show path mints.
    func testAutoShowMintsFreshCode() throws {
        let src = try loadCompleteViewSource()

        XCTAssertTrue(
            src.contains("loadPairCode(mint: true)"),
            "InstallCompleteView.autoShowPairCode must call loadPairCode(mint: true) so a just-installed Hub with no current pair code still mints one for the QR. A GET-only (mint:false) auto-show regresses to the empty placeholder. (BW-FIND-27.)"
        )
        // The Refresh button keeps the GET (current-code) semantics.
        XCTAssertTrue(
            src.contains("loadPairCode(mint: false)"),
            "InstallCompleteView.fetchPairCode (the Refresh button handler) must keep GET semantics via loadPairCode(mint: false). (BW-FIND-27 -- preserve the working Refresh path.)"
        )
    }

    // MARK: - GatewayClient mint path hits /admin/paircode/new

    /// GatewayClient.mintPairCodeEnvelope must POST
    /// /admin/paircode/new -- the same `fresh` mint path the Doctor's
    /// pair_status.py uses for regenerate. Pin the endpoint + method
    /// so an endpoint rename or a silent fall-back to GET fails loud.
    func testGatewayClientMintPostsPaircodeNew() throws {
        let src = try loadGatewayClientSource()

        XCTAssertTrue(
            src.contains("func mintPairCodeEnvelope() async throws -> String"),
            "GatewayClient must expose mintPairCodeEnvelope() for the success-screen auto-show. (BW-FIND-27.)"
        )
        XCTAssertTrue(
            src.contains("admin/paircode/new"),
            "GatewayClient mint path must hit /admin/paircode/new (mint + rotate). A fresh install has no current code at /admin/paircode. (BW-FIND-27 -- mirrors Doctor pair_status.py fresh=True.)"
        )
        XCTAssertTrue(
            src.contains("fresh ? \"POST\" : \"GET\""),
            "GatewayClient.pairCodeEnvelope must POST when minting and GET otherwise. (BW-FIND-27 method guard.)"
        )
        // The GET (Refresh) path must still exist unchanged.
        XCTAssertTrue(
            src.contains("func fetchPairCodeEnvelope() async throws -> String"),
            "GatewayClient must keep fetchPairCodeEnvelope() (the GET current-code path) for the Refresh button. (BW-FIND-27 -- preserve the working Refresh path.)"
        )
    }
}
