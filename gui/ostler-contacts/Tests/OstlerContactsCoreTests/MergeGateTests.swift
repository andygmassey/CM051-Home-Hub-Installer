import XCTest
@testable import OstlerContactsCore

/// The single refusal point for a merge write (contract rules 3 + 4).
final class MergeGateTests: XCTestCase {

    private func validToken(survivor: String, victims: [String]) -> String {
        ConfirmToken.derive(survivorID: survivor, victimIDs: victims)
    }

    // Rule 4: flag OFF => refuse, regardless of a valid token.
    func testRefusesWhenFlagOff() {
        let token = validToken(survivor: "S", victims: ["V1"])
        let d = MergeGate.evaluate(
            flagEnabled: false, survivorID: "S", victimIDs: ["V1"],
            presentedToken: token)
        XCTAssertEqual(d, .refuseFlagOff)
        XCTAssertFalse(d.isAllowed)
        XCTAssertNotEqual(d.exitCode, 0)
    }

    // Rule 3: flag ON but no token => refuse.
    func testRefusesWhenNoToken() {
        let d = MergeGate.evaluate(
            flagEnabled: true, survivorID: "S", victimIDs: ["V1"],
            presentedToken: nil)
        XCTAssertEqual(d, .refuseBadToken)
    }

    // Rule 3: flag ON, token for a DIFFERENT group => refuse.
    func testRefusesWrongGroupToken() {
        let wrong = validToken(survivor: "S", victims: ["V_OTHER"])
        let d = MergeGate.evaluate(
            flagEnabled: true, survivorID: "S", victimIDs: ["V1"],
            presentedToken: wrong)
        XCTAssertEqual(d, .refuseBadToken)
    }

    func testRefusesNoVictims() {
        let d = MergeGate.evaluate(
            flagEnabled: true, survivorID: "S", victimIDs: [],
            presentedToken: "anything")
        XCTAssertEqual(d, .refuseNoVictims)
    }

    func testRefusesSurvivorInVictims() {
        let d = MergeGate.evaluate(
            flagEnabled: true, survivorID: "S", victimIDs: ["S", "V1"],
            presentedToken: "anything")
        XCTAssertEqual(d, .refuseSurvivorInVictims)
    }

    // Happy path: flag ON + correct token for THIS group => allow.
    func testAllowsWithFlagAndValidToken() {
        let token = validToken(survivor: "S", victims: ["V1", "V2"])
        let d = MergeGate.evaluate(
            flagEnabled: true, survivorID: "S", victimIDs: ["V1", "V2"],
            presentedToken: token)
        XCTAssertEqual(d, .allow)
        XCTAssertTrue(d.isAllowed)
        XCTAssertEqual(d.exitCode, 0)
    }

    // Every refusal must carry a distinct non-zero exit code + a message.
    func testRefusalsHaveDistinctNonZeroExitCodes() {
        let refusals: [MergeGate.Decision] = [
            .refuseFlagOff, .refuseNoVictims, .refuseSurvivorInVictims, .refuseBadToken,
        ]
        let codes = refusals.map { $0.exitCode }
        XCTAssertEqual(Set(codes).count, codes.count, "exit codes must be distinct")
        for r in refusals {
            XCTAssertNotEqual(r.exitCode, 0)
            XCTAssertFalse(r.message.isEmpty)
        }
    }
}
