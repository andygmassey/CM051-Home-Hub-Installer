// LicenseFetcherClassifyTests.swift
//
// Pin the contract: when a customer pastes into the new
// "paste your licence id" field, `classifyLicensePaste` returns
// the right shape so the view can route to fetcher vs verifier
// vs friendly steer.
//
// Synthetic fixtures only -- `cs_test_*`, `cs_live_*`.

import XCTest
@testable import OstlerInstaller

final class LicenseFetcherClassifyTests: XCTestCase {

    // MARK: - Stripe checkout session id

    func testStripeTestSessionIdRecognised() {
        let id = "cs_test_a1b2c3d4e5f6g7h8i9j0"
        if case .stripeSessionId(let extracted) = classifyLicensePaste(id) {
            XCTAssertEqual(extracted, id)
        } else {
            XCTFail("expected .stripeSessionId, got \(classifyLicensePaste(id))")
        }
    }

    func testStripeLiveSessionIdRecognised() {
        let id = "cs_live_zxcvbnm1234567890"
        if case .stripeSessionId(let extracted) = classifyLicensePaste(id) {
            XCTAssertEqual(extracted, id)
        } else {
            XCTFail("expected .stripeSessionId, got \(classifyLicensePaste(id))")
        }
    }

    func testWhitespaceTrimmedFromSessionId() {
        let id = "cs_test_a1b2c3d4e5f6g7h8i9j0"
        if case .stripeSessionId(let extracted) = classifyLicensePaste("  \(id)  \n") {
            XCTAssertEqual(extracted, id)
        } else {
            XCTFail("expected .stripeSessionId after trim")
        }
    }

    // MARK: - Licence URL

    func testCanonicalLicenceURLExtractsSessionId() {
        let url = "https://appcast.ostler.ai/api/license/cs_test_abcdefghij1234567890"
        if case .licenseUrl(let sid) = classifyLicensePaste(url) {
            XCTAssertEqual(sid, "cs_test_abcdefghij1234567890")
        } else {
            XCTFail("expected .licenseUrl, got \(classifyLicensePaste(url))")
        }
    }

    func testStagingHttpLicenceURLAlsoExtracted() {
        let url = "http://localhost:8000/api/license/cs_live_ZYXabc1234567890_extra"
        if case .licenseUrl(let sid) = classifyLicensePaste(url) {
            XCTAssertEqual(sid, "cs_live_ZYXabc1234567890_extra")
        } else {
            XCTFail("expected .licenseUrl, got \(classifyLicensePaste(url))")
        }
    }

    // MARK: - Raw JSON

    func testRawJsonRecognised() {
        let json = "{\"version\":1,\"license_id\":\"abc\"}"
        if case .rawJson(let data) = classifyLicensePaste(json) {
            XCTAssertEqual(data, json.data(using: .utf8))
        } else {
            XCTFail("expected .rawJson")
        }
    }

    func testJsonWithLeadingWhitespaceStillRawJson() {
        let json = "  \n  {\"version\":1}"
        if case .rawJson = classifyLicensePaste(json) {
            // ok
        } else {
            XCTFail("expected .rawJson after trim")
        }
    }

    // MARK: - Short licence id

    func testEightCharHexShortIdRecognised() {
        if case .shortLicenseId(let s) = classifyLicensePaste("a1b2c3d4") {
            XCTAssertEqual(s, "a1b2c3d4")
        } else {
            XCTFail("expected .shortLicenseId")
        }
    }

    func testFullUUIDShortIdRecognised() {
        let uuid = "8c7e3f9a-1234-4abc-9def-0123456789ab"
        if case .shortLicenseId(let s) = classifyLicensePaste(uuid) {
            XCTAssertEqual(s, uuid)
        } else {
            XCTFail("expected .shortLicenseId for full UUID")
        }
    }

    // MARK: - Unrecognised

    func testEmptyIsUnrecognised() {
        XCTAssertEqual(classifyLicensePaste(""), .unrecognised)
        XCTAssertEqual(classifyLicensePaste("   "), .unrecognised)
    }

    func testRandomTextIsUnrecognised() {
        XCTAssertEqual(classifyLicensePaste("how do I install this thing?"), .unrecognised)
    }

    func testNonStripePrefixIsUnrecognised() {
        // `pi_*` is a Stripe Payment Intent id, NOT a checkout session.
        XCTAssertEqual(classifyLicensePaste("pi_test_abcdefghij1234567890"), .unrecognised)
    }

    func testTooShortStripeSessionIdIsUnrecognised() {
        // `cs_` prefix but body < 10 chars: ambiguous. We do not
        // accept it as a session id, and the body is also longer
        // than the short-id ceiling so it lands on unrecognised.
        XCTAssertEqual(classifyLicensePaste("cs_short"), .unrecognised)
    }

    // MARK: - LicenseFetcher init

    func testLicenseFetcherInitDefaultsAreSafe() {
        // Constructor must never fault on default args even when
        // no env override is set. (Doesn't perform any network I/O.)
        let f = LicenseFetcher()
        XCTAssertNotNil(f)
    }
}
