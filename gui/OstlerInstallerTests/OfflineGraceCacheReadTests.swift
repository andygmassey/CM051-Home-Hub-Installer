// OfflineGraceCacheReadTests.swift
//
// The offline-grace proof was written on every successful registration
// and read by nobody.
//
// `FingerprintState`'s own header says of ~/.ostler/state/fingerprint.txt:
// "Read on subsequent installer launches so we do not re-POST a
// registration we already know is in the Worker's set." Measured with
// controls in the same grep shape: `writeCachedFingerprint(` and
// `evaluateOfflineGrace(` each resolved to a production call site in
// InstallerCoordinator.swift, while `cachedFingerprint(` resolved ONLY
// to its own declaration and two unit tests. The reader existed and
// nothing in the product called it.
//
// THE CONSUMER COST. A Mac that HAS registered successfully, re-running
// the installer while offline -- a repair re-run, a travelling laptop, a
// brief appcast.ostler.ai outage -- consumed one of three grace slots
// every time. On the fourth, `.offlineGraceExhausted` refused to install
// and told the customer to get the machine online, while the file
// proving that exact Mac was already in the Worker's set sat unread on
// its own disk.
//
// These tests drive `FingerprintState.decideOffline` with injected
// paths, so the whole decision is exercised without a network, a live
// coordinator, or the real ~/.ostler directory.

import Foundation
import XCTest
@testable import OstlerInstaller

final class OfflineGraceCacheReadTests: XCTestCase {

    private var dir: URL!
    private var cacheURL: URL!
    private var ledgerURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ostler-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("fingerprint.txt")
        ledgerURL = dir.appendingPathComponent("offline_grace.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func decide(_ licence: String, _ fingerprint: String) -> FingerprintState.OfflineDecision {
        FingerprintState.decideOffline(
            licenseId: licence,
            computedFingerprint: fingerprint,
            cacheURL: cacheURL,
            ledgerURL: ledgerURL
        )
    }

    // MARK: - The defect: a registered Mac burning its own allowance

    /// THE REGRESSION TEST. A Mac with a cached fingerprint from an
    /// earlier successful registration must never be locked out by the
    /// offline bound, however many times it re-runs.
    func testRegisteredMacIsNeverLockedOutByRepeatedOfflineReruns() throws {
        try FingerprintState.writeCachedFingerprint("sha256:thismac", to: cacheURL)

        // Far more re-runs than the bound would ever allow.
        for attempt in 1...(FingerprintState.maxOfflineProceeds * 4) {
            XCTAssertEqual(
                decide("LIC-A", "sha256:thismac"),
                .alreadyRegistered,
                """
                Offline re-run \(attempt) on a Mac that is ALREADY registered was \
                not recognised. Pre-fix this consumed one of \
                \(FingerprintState.maxOfflineProceeds) grace slots per run and then \
                refused to install at all, while ~/.ostler/state/fingerprint.txt \
                proved the Worker already had this machine.
                """
            )
        }
    }

    /// The cache hit must not advance the ledger. If it did, the lockout
    /// would simply arrive later rather than never.
    func testCacheHitDoesNotConsumeAGraceSlot() throws {
        try FingerprintState.writeCachedFingerprint("sha256:thismac", to: cacheURL)
        for _ in 0..<5 { _ = decide("LIC-A", "sha256:thismac") }

        XCTAssertNil(
            FingerprintState.readOfflineGrace(at: ledgerURL),
            "A Mac the Worker already counted must not write an offline-grace ledger entry at all."
        )
    }

    // MARK: - The bound still binds (v1.0.10 lockdown intact)

    /// THE SECURITY CONTROL. The whole point of the bound is to stop one
    /// licence installing on unlimited Macs behind a blocked
    /// appcast.ostler.ai. A Mac with NO cache is a Mac the Worker has
    /// never accepted, and it must still be bounded exactly as before.
    /// If this test ever passes trivially, the fix above has been widened
    /// into the unbounded fail-open v1.0.10 closed.
    func testUnregisteredMacIsStillBounded() {
        // No cache written: this is a machine the Worker has never seen.
        for n in 1...FingerprintState.maxOfflineProceeds {
            XCTAssertEqual(
                decide("LIC-A", "sha256:freshmac"), .proceed(attempt: n),
                "A Mac with no proof of registration must still consume the bounded grace."
            )
        }
        XCTAssertEqual(
            decide("LIC-A", "sha256:freshmac"),
            .exhausted(attempts: FingerprintState.maxOfflineProceeds),
            """
            The bounded fail-open stopped binding. This is the v1.0.10 lockdown: \
            without it one licence installs on unlimited Macs behind a blocked \
            appcast.ostler.ai.
            """
        )
    }

    /// A cache written by a DIFFERENT machine must not excuse this one.
    /// The cache is proof about a fingerprint, and a fingerprint that
    /// does not match is proof about somebody else.
    func testAnotherMacsCachedFingerprintDoesNotExcuseThisOne() throws {
        try FingerprintState.writeCachedFingerprint("sha256:someothermac", to: cacheURL)
        XCTAssertEqual(
            decide("LIC-A", "sha256:thismac"), .proceed(attempt: 1),
            "A non-matching cached fingerprint must fall through to the bounded grace, not skip it."
        )
    }

    /// An empty or whitespace-only cache file is not proof of anything.
    /// `cachedFingerprint` already trims to nil; pin that the decision
    /// inherits that rather than comparing against an empty string.
    func testEmptyCacheFileIsNotTreatedAsProof() throws {
        try Data("\n".utf8).write(to: cacheURL)
        XCTAssertEqual(
            decide("LIC-A", ""), .proceed(attempt: 1),
            "An empty cache file must not match an empty computed fingerprint and wave the install through."
        )
    }

    /// Positive control for the whole fixture: the reader really can see
    /// a file this test wrote at the injected path. Without this, every
    /// `.proceed` above could be a cache read that silently failed --
    /// "found nothing" and "could not look" print identically.
    func testCacheReaderControlSeesWhatWasWritten() throws {
        XCTAssertNil(
            FingerprintState.cachedFingerprint(at: cacheURL),
            "Control precondition: nothing cached yet."
        )
        try FingerprintState.writeCachedFingerprint("sha256:control", to: cacheURL)
        XCTAssertEqual(
            FingerprintState.cachedFingerprint(at: cacheURL), "sha256:control",
            "The cache reader cannot see a file written at the injected path, so every cache-miss assertion in this file would be vacuous."
        )
    }

    // MARK: - The reader is actually wired into the product

    /// The decision must be reached from `runDeviceRegistration`'s
    /// network-failure arm. A decision function nothing calls is exactly
    /// the defect this file exists to close, one level up.
    func testCoordinatorConsultsTheCacheOnTheNetworkFailurePath() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/InstallerCoordinator.swift"
        )
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            src.contains("FingerprintState.decideOffline("),
            """
            InstallerCoordinator no longer calls FingerprintState.decideOffline. \
            The fingerprint cache is then written and never read again, and an \
            already-registered Mac goes back to burning a grace slot per offline \
            re-run until it is refused entry to its own install.
            """
        )
        XCTAssertTrue(
            src.contains("case .alreadyRegistered:"),
            "The coordinator must handle the .alreadyRegistered decision explicitly."
        )
        // Control: the surrounding machinery is still present, so the
        // assertions above are reading the file we think they are.
        XCTAssertTrue(
            src.contains("case .networkFailure(let message):"),
            "Loaded a file without the network-failure arm; the assertions above proved nothing."
        )
    }
}
