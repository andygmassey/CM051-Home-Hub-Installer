import XCTest
@testable import OstlerContactsCore

/// Confirm-token = the one-shot, group-bound authorisation (contract rule 3).
/// These prove a token minted for one group cannot authorise another.
final class ConfirmTokenTests: XCTestCase {

    func testStableForSameGroup() {
        let a = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1", "V2"])
        let b = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1", "V2"])
        XCTAssertEqual(a, b)
    }

    func testOrderIndependentForVictims() {
        let a = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1", "V2"])
        let b = ConfirmToken.derive(survivorID: "S", victimIDs: ["V2", "V1"])
        XCTAssertEqual(a, b, "victim ordering must not change the token")
    }

    func testDuplicateVictimsCollapse() {
        let a = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1"])
        let b = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1", "V1", "V1"])
        XCTAssertEqual(a, b, "a caller must not be able to pad the victim set")
    }

    func testDifferentSurvivorDifferentToken() {
        let a = ConfirmToken.derive(survivorID: "S1", victimIDs: ["V1"])
        let b = ConfirmToken.derive(survivorID: "S2", victimIDs: ["V1"])
        XCTAssertNotEqual(a, b, "re-picking the survivor is a different merge")
    }

    func testDifferentVictimsDifferentToken() {
        let a = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1"])
        let b = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1", "V2"])
        XCTAssertNotEqual(a, b)
    }

    func testVerifyMatchesDerivedToken() {
        let token = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1", "V2"])
        XCTAssertTrue(ConfirmToken.verify(
            presented: token, survivorID: "S", victimIDs: ["V1", "V2"]))
    }

    func testVerifyRejectsReplayAgainstAnotherGroup() {
        // Token minted for group A must not authorise group B.
        let tokenForA = ConfirmToken.derive(survivorID: "S", victimIDs: ["V1"])
        XCTAssertFalse(ConfirmToken.verify(
            presented: tokenForA, survivorID: "S", victimIDs: ["V2"]),
            "a token for one group must not verify against another")
    }

    func testVerifyRejectsGarbage() {
        XCTAssertFalse(ConfirmToken.verify(
            presented: "not-a-real-token", survivorID: "S", victimIDs: ["V1"]))
        XCTAssertFalse(ConfirmToken.verify(
            presented: "", survivorID: "S", victimIDs: ["V1"]))
    }
}
