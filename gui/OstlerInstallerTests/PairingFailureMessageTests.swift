// PairingFailureMessageTests.swift
//
// #2011 regression test. Every pairing failure used to render one
// string, `pair_iphone.fetch_failed`, which tells the customer the
// gateway "might still be starting up" and to click Refresh.
//
// `GatewayClient` throws FIVE distinct typed cases and always did.
// `InstallCompleteView.loadPairCode` caught them with a bare `catch`
// that never bound the error, so all five collapsed into that one
// sentence. The diagnostic was built, typed, and then discarded one
// line from where it was needed.
//
// WHY IT MATTERS ON THIS PARTICULAR SCREEN: this is the last screen
// of the install, and the failing step is the one that connects the
// phone the product is bought for. For a REFUSED request the old
// copy is wrong in the worst direction -- Refresh can never succeed,
// so the customer is told to keep waiting forever.
//
// The load-bearing assertion in this file is NOT that each case has
// its own words. It is that a REFUSED request never renders the
// "still starting up" copy. That is the defect; the rest is detail.

import XCTest
@testable import OstlerInstaller

final class PairingFailureMessageTests: XCTestCase {

    /// The exact copy the old code rendered for every failure.
    private var startingUpCopy: String {
        ViewCopy.shared.string(for: "pair_iphone.fetch_failed")
    }

    // MARK: - The defect

    func testRefusedDoesNotTellTheCustomerToWait() {
        for code in [401, 403] {
            let message = InstallCompleteView.pairFailureMessage(
                for: GatewayClientError.nonSuccessStatus(code: code, body: "denied")
            )
            XCTAssertNotEqual(
                message, startingUpCopy,
                "a refused pairing request (\(code)) must not render the starting-up copy"
            )
            XCTAssertTrue(
                message.contains(String(code)),
                "the refusal message should name the status code, got: \(message)"
            )
        }
    }

    /// The control for the test above. If `fetch_failed` were missing
    /// from the catalogue, `string(for:)` returns the KEY, every
    /// comparison above would differ from it for the wrong reason,
    /// and the test would pass while proving nothing.
    func testStartingUpCopyIsRealCopyAndNotAMissingKey() {
        XCTAssertNotEqual(startingUpCopy, "pair_iphone.fetch_failed")
        XCTAssertTrue(startingUpCopy.contains("Refresh"))
    }

    // MARK: - Transport is the one case where waiting IS the advice

    func testTransportFailureKeepsTheStartingUpCopy() {
        let underlying = URLError(.cannotConnectToHost)
        let message = InstallCompleteView.pairFailureMessage(
            for: GatewayClientError.transport(underlying: underlying)
        )
        XCTAssertEqual(message, startingUpCopy)
    }

    // MARK: - Every case resolves to real copy

    func testEveryCaseRendersResolvedCopy() {
        let cases: [GatewayClientError] = [
            .transport(underlying: URLError(.timedOut)),
            .nonSuccessStatus(code: 500, body: "boom"),
            .emptyBody,
            .invalidUTF8,
            .malformedEnvelope(reason: "wrapper missing qr_payload object"),
        ]
        for error in cases {
            let message = InstallCompleteView.pairFailureMessage(for: error)
            XCTAssertFalse(message.isEmpty)
            // An unresolved key comes back as the key itself, which
            // always starts with this prefix. That is the shape of a
            // catalogue miss, and it must never reach a customer.
            XCTAssertFalse(
                message.hasPrefix("pair_iphone."),
                "unresolved catalogue key rendered for \(error): \(message)"
            )
            // An unsubstituted placeholder is the other silent miss.
            XCTAssertFalse(
                message.contains("{code}") || message.contains("{reason}"),
                "unsubstituted placeholder rendered for \(error): \(message)"
            )
        }
    }

    // MARK: - The body is deliberately NOT surfaced

    func testResponseBodyIsNeverRendered() {
        // `nonSuccessStatus` carries the body as well as the code.
        // The code is a small integer that tells the reader whether
        // retrying can help. The body is daemon-controlled text of
        // unknown content, so it is not rendered into the UI.
        let secret = "SUPERSECRETBODYCONTENT"
        let message = InstallCompleteView.pairFailureMessage(
            for: GatewayClientError.nonSuccessStatus(code: 500, body: secret)
        )
        XCTAssertFalse(message.contains(secret))
    }

    // MARK: - A non-gateway error still says something sane

    func testUnknownErrorFallsBackToTheGenericCopy() {
        struct Other: Error {}
        XCTAssertEqual(InstallCompleteView.pairFailureMessage(for: Other()), startingUpCopy)
    }
}
