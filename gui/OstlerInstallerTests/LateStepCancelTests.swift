// F&F tester report 2026-11-05, item 6. See LateStepPolicy.swift.
import XCTest
@testable import OstlerInstaller

@MainActor
final class LateStepCancelTests: XCTestCase {
    private func tmpHome() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("late-step-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Cancel at the pairing step must NOT terminate; it writes the skip marker
    /// install.sh polls, so the install finishes without pairing.
    func testCancelAtPairingStepFinishesWithoutPairing() {
        let home = tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let c = InstallerCoordinator()
        c.currentStepId = "tailscale_signin"
        XCTAssertEqual(c.requestCancel(home: home), .finishWithoutPairing)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: LateStepPolicy.skipSentinelURL(home: home).path))
    }

    /// Control: an early step still cancels as before and writes no marker.
    func testCancelAtAnEarlyStepStillTerminates() {
        let home = tmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let c = InstallerCoordinator()
        c.currentStepId = "installing_docker"
        XCTAssertEqual(c.requestCancel(home: home), .terminate)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: LateStepPolicy.skipSentinelURL(home: home).path))
    }

    /// The marker path is the one install.sh polls.
    func testSentinelPathMatchesInstallSh() {
        XCTAssertTrue(LateStepPolicy.skipSentinelURL(home: URL(fileURLWithPath: "/h")).path
            .hasSuffix("/.ostler/tailscale/.signin_skip"))
    }
}
