// OfflineGraceBoundTests.swift
//
// FIX 4 (v1.0.10 security lockdown -- device-cap fails open).
//
// Pre-v1.0.10 a `.networkFailure` reaching the registration Worker
// set the gate straight to `.ready` -- an UNBOUNDED fail-open. These
// tests lock the bounded-grace policy: a licence may fail open a
// small, time-boxed number of times per Mac, then must be refused.
//
// Uses a unique per-test temp file so the real
// ~/.ostler/state/offline_grace.json is never touched.

import Foundation
import XCTest
@testable import OstlerInstaller

final class OfflineGraceBoundTests: XCTestCase {

    private var tempDir: URL!
    private var ledger: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("OfflineGraceBoundTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        ledger = tempDir.appendingPathComponent("offline_grace.json")
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    /// The first `maxOfflineProceeds` calls proceed; the next is
    /// exhausted. Bound is inclusive of the cap.
    func testProceedsUpToCapThenExhausts() {
        let lic = "LIC-CAP"
        let cap = FingerprintState.maxOfflineProceeds
        for expected in 1...cap {
            let d = FingerprintState.evaluateOfflineGrace(licenseId: lic, now: Date(), at: ledger)
            XCTAssertEqual(d, .proceed(attempt: expected), "attempt \(expected) should proceed")
        }
        // One past the cap must be refused.
        let over = FingerprintState.evaluateOfflineGrace(licenseId: lic, now: Date(), at: ledger)
        XCTAssertEqual(over, .exhausted(attempts: cap))
        // And it stays exhausted on subsequent calls (does not reset).
        let again = FingerprintState.evaluateOfflineGrace(licenseId: lic, now: Date(), at: ledger)
        XCTAssertEqual(again, .exhausted(attempts: cap))
    }

    /// A call outside the grace window rolls the window forward with a
    /// fresh count rather than staying exhausted forever.
    func testWindowElapsedResetsCount() {
        let lic = "LIC-WINDOW"
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Burn through the cap at t0.
        for _ in 1...FingerprintState.maxOfflineProceeds {
            _ = FingerprintState.evaluateOfflineGrace(licenseId: lic, now: t0, at: ledger)
        }
        XCTAssertEqual(
            FingerprintState.evaluateOfflineGrace(licenseId: lic, now: t0, at: ledger),
            .exhausted(attempts: FingerprintState.maxOfflineProceeds)
        )
        // Well past the window: should proceed again from attempt 1.
        let later = t0.addingTimeInterval(FingerprintState.offlineGraceWindow + 60)
        XCTAssertEqual(
            FingerprintState.evaluateOfflineGrace(licenseId: lic, now: later, at: ledger),
            .proceed(attempt: 1)
        )
    }

    /// Swapping to a DIFFERENT licence on the same Mac resets the
    /// bounded grace (the new licence gets its own allowance).
    func testDifferentLicenceResetsGrace() {
        let now = Date()
        for _ in 1...FingerprintState.maxOfflineProceeds {
            _ = FingerprintState.evaluateOfflineGrace(licenseId: "LIC-A", now: now, at: ledger)
        }
        XCTAssertEqual(
            FingerprintState.evaluateOfflineGrace(licenseId: "LIC-A", now: now, at: ledger),
            .exhausted(attempts: FingerprintState.maxOfflineProceeds)
        )
        // Different licence -> fresh allowance.
        XCTAssertEqual(
            FingerprintState.evaluateOfflineGrace(licenseId: "LIC-B", now: now, at: ledger),
            .proceed(attempt: 1)
        )
    }

    /// A resolved registration clears the ledger.
    func testClearResetsLedger() {
        let lic = "LIC-CLEAR"
        _ = FingerprintState.evaluateOfflineGrace(licenseId: lic, at: ledger)
        XCTAssertNotNil(FingerprintState.readOfflineGrace(at: ledger))
        FingerprintState.clearOfflineGrace(at: ledger)
        XCTAssertNil(FingerprintState.readOfflineGrace(at: ledger))
        // After clear, grace starts fresh.
        XCTAssertEqual(
            FingerprintState.evaluateOfflineGrace(licenseId: lic, at: ledger),
            .proceed(attempt: 1)
        )
    }

    /// The ledger persists as 0600 JSON that round-trips.
    func testLedgerRoundTripAndPermissions() throws {
        let g = FingerprintState.OfflineGrace(
            licenseId: "LIC-RT",
            firstOfflineAt: "2026-07-21T00:00:00Z",
            count: 2
        )
        try FingerprintState.writeOfflineGrace(g, at: ledger)
        XCTAssertEqual(FingerprintState.readOfflineGrace(at: ledger), g)
        let attrs = try FileManager.default.attributesOfItem(atPath: ledger.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
