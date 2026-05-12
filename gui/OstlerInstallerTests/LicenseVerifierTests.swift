// LicenseVerifierTests.swift
//
// Round-trip tests for `LicenseVerifier`. We generate a fresh
// Ed25519 keypair per test run (CryptoKit -- no committed test
// keys, no committed test fixtures), mint a synthetic licence
// matching the CM050 v1 schema with canonical JSON bytes, sign
// it, then run the verifier end-to-end.
//
// No real customer licences. No production-key dependency. The
// production-public-key embedding in `LicenseVerifier.swift` is
// covered by an integration smoke test (run by hand against a
// staging Worker) -- see PR body for the manual checklist.

import CryptoKit
import Foundation
import XCTest
@testable import OstlerInstaller

final class LicenseVerifierTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal v1 licence body. `signature` is filled in
    /// afterwards by the caller (sign with the test private key,
    /// base64-encode, set the field).
    private func makeLicenseBody(
        licenseId: String = "8c7e3f9a-1234-4abc-9def-0123456789ab",
        email: String = "alice@example.com",
        purchasedAt: String = "2026-04-23T14:00:00Z",
        windowExpiresAt: String = "2099-04-23T14:00:00Z",
        stripeId: String = "pi_TEST_0123456789",
        maxFingerprints: Int = 3
    ) -> [String: Any] {
        return [
            "version": 1,
            "license_id": licenseId,
            "issued_to_email": email,
            "purchased_at": purchasedAt,
            "update_window_expires_at": windowExpiresAt,
            "max_hardware_fingerprints": maxFingerprints,
            "stripe_payment_id": stripeId,
            "signature_algorithm": "Ed25519",
        ]
    }

    /// Sign the body with the supplied private key, attach the
    /// signature, return the on-disk JSON bytes (pretty-printed
    /// so it matches what `license-generator generate` writes).
    private func sign(
        _ body: [String: Any],
        with privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        guard let canonical = LicenseVerifier.canonicalJSON(body) else {
            throw NSError(domain: "test", code: 1)
        }
        let signature = try privateKey.signature(for: canonical)
        var full = body
        full["signature"] = signature.base64EncodedString()
        return try JSONSerialization.data(
            withJSONObject: full,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func makeVerifier() -> (LicenseVerifier, Curve25519.Signing.PrivateKey) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let verifier = LicenseVerifier(publicKey: publicKey)
        return (verifier, privateKey)
    }

    // MARK: - Happy path

    func testValidLicenseVerifies() throws {
        let (verifier, privateKey) = makeVerifier()
        let body = makeLicenseBody()
        let licenseData = try sign(body, with: privateKey)

        let result = verifier.verify(licenseData: licenseData)
        switch result {
        case .valid(let claims):
            XCTAssertEqual(claims.version, 1)
            XCTAssertEqual(claims.issuedToEmail, "alice@example.com")
            XCTAssertEqual(claims.signatureAlgorithm, "Ed25519")
            XCTAssertEqual(claims.maxHardwareFingerprints, 3)
        default:
            XCTFail("Expected .valid, got \(result)")
        }
    }

    // MARK: - Tamper detection

    func testTamperedEmailFailsVerification() throws {
        let (verifier, privateKey) = makeVerifier()
        let body = makeLicenseBody(email: "alice@example.com")
        var licenseData = try sign(body, with: privateKey)

        // Surgically swap "alice" for "mallory" in the on-disk
        // bytes. The signature is over the canonical body without
        // the signature field; this byte-level edit invalidates
        // the signature without changing the JSON shape.
        let raw = String(data: licenseData, encoding: .utf8)!
        let tampered = raw.replacingOccurrences(of: "alice", with: "mallory")
        licenseData = tampered.data(using: .utf8)!

        XCTAssertEqual(verifier.verify(licenseData: licenseData), .invalidSignature)
    }

    func testTamperedSignatureFailsVerification() throws {
        let (verifier, privateKey) = makeVerifier()
        let body = makeLicenseBody()
        var licenseData = try sign(body, with: privateKey)

        // Flip a single base64 char in the signature.
        let raw = String(data: licenseData, encoding: .utf8)!
        let sigIdx = raw.range(of: "\"signature\"")!
        let valStart = raw.range(of: "\"", range: sigIdx.upperBound..<raw.endIndex)!.upperBound
        let valLast = raw.range(of: "\"", range: valStart..<raw.endIndex)!.lowerBound
        var mutable = raw
        // Replace second char of signature payload (skip the leading quote already gone)
        let target = mutable.index(valStart, offsetBy: 2)
        let nextChar: Character = mutable[target] == "A" ? "B" : "A"
        mutable.replaceSubrange(target...target, with: String(nextChar))
        _ = valLast
        licenseData = mutable.data(using: .utf8)!

        XCTAssertEqual(verifier.verify(licenseData: licenseData), .invalidSignature)
    }

    func testWrongKeyFailsVerification() throws {
        // Mint with key A, verify with key B.
        let signingKey = Curve25519.Signing.PrivateKey()
        let body = makeLicenseBody()
        let licenseData = try sign(body, with: signingKey)

        let otherKey = Curve25519.Signing.PrivateKey()
        let otherVerifier = LicenseVerifier(publicKey: otherKey.publicKey)
        XCTAssertEqual(otherVerifier.verify(licenseData: licenseData), .invalidSignature)
    }

    // MARK: - Expiry

    func testExpiredLicenseReportsExpired() throws {
        let (verifier, privateKey) = makeVerifier()
        // Update window already in the past.
        let body = makeLicenseBody(windowExpiresAt: "2020-04-23T14:00:00Z")
        let licenseData = try sign(body, with: privateKey)

        let result = verifier.verify(licenseData: licenseData)
        switch result {
        case .expired(let expiresAt):
            XCTAssertEqual(expiresAt, "2020-04-23T14:00:00Z")
        default:
            XCTFail("Expected .expired, got \(result)")
        }
    }

    func testValidLicenseAtFutureExpiryStillVerifies() throws {
        let (verifier, privateKey) = makeVerifier()
        let body = makeLicenseBody(windowExpiresAt: "2099-04-23T14:00:00Z")
        let licenseData = try sign(body, with: privateKey)

        // Pin `now` so the test does not silently bit-rot in 70 years.
        let now = LicenseVerifier.parseISO8601UTC("2026-05-13T00:00:00Z")!
        if case .valid = verifier.verify(licenseData: licenseData, now: now) {
            // pass
        } else {
            XCTFail("Expected .valid at fixed `now` before 2099 expiry")
        }
    }

    // MARK: - Schema rejection

    func testWrongVersionRejected() throws {
        let (verifier, privateKey) = makeVerifier()
        var body = makeLicenseBody()
        body["version"] = 2
        let licenseData = try sign(body, with: privateKey)

        if case .malformed = verifier.verify(licenseData: licenseData) {
            // pass -- the version check fires before signature.
        } else {
            XCTFail("Expected .malformed for version != 1")
        }
    }

    func testWrongSignatureAlgorithmRejected() throws {
        let (verifier, privateKey) = makeVerifier()
        var body = makeLicenseBody()
        body["signature_algorithm"] = "RSA-2048"
        let licenseData = try sign(body, with: privateKey)

        if case .malformed = verifier.verify(licenseData: licenseData) {
            // pass
        } else {
            XCTFail("Expected .malformed for non-Ed25519 algorithm")
        }
    }

    func testMissingFieldRejected() throws {
        let (verifier, _) = makeVerifier()
        let raw = #"{"version":1,"signature":"abc"}"#.data(using: .utf8)!
        if case .malformed = verifier.verify(licenseData: raw) {
            // pass
        } else {
            XCTFail("Expected .malformed for incomplete body")
        }
    }

    func testGarbageInputRejected() {
        let (verifier, _) = makeVerifier()
        let garbage = "not even json".data(using: .utf8)!
        if case .malformed = verifier.verify(licenseData: garbage) {
            // pass
        } else {
            XCTFail("Expected .malformed for non-JSON")
        }
    }

    // MARK: - Production-key safety

    func testProductionPlaceholderKeyDoesNotVerify() {
        // The all-zero hex placeholder must NOT yield a working
        // verifier. If a future Andy commits a real key, this test
        // will start failing -- which is the desired signal (it
        // means production is wired and the placeholder branch
        // is no longer in play; delete or replace the test).
        let v = LicenseVerifier()
        XCTAssertNil(v, "Embedded production public key is the placeholder; refuse to issue a verifier so the gate cannot accidentally pass.")
    }
}
