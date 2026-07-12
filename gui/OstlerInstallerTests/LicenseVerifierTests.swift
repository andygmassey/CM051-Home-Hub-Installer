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

    // MARK: - Cross-implementation byte-identity
    //
    // The previous tests sign and verify with the same Swift
    // `canonicalJSON`, so any divergence from the Worker
    // (TypeScript) / license-generator (Python) implementations
    // is invisible -- both sides agree on the wrong bytes, the
    // round-trip passes, customer-minted licences fail in the
    // field. This test pins the canonical bytes Swift MUST
    // produce, against a reference string that matches
    //   json.dumps(body, sort_keys=True, separators=(",", ":"),
    //              ensure_ascii=False)
    // i.e. what both reference implementations produce. If Swift
    // diverges, this test fails before a customer ever sees a
    // signature-check failure.
    //
    // Regression history: the version=1 / max_hardware_fingerprints=
    // bridging bug shipped in v0.2.1 (every minted licence failed)
    // because Foundation bridges NSNumber to Bool when the value is
    // 0 or 1, so `value as? Bool` matched first and the canonical
    // emitted `"version":true`. CFBooleanGetTypeID() identity check
    // is the fix, this test pins it.

    func testCanonicalJSONMatchesReferenceBytes() {
        let body: [String: Any] = [
            "version": 1,
            "license_id": "8c7e3f9a-1234-4abc-9def-0123456789ab",
            "issued_to_email": "alice@example.com",
            "purchased_at": "2026-05-15T04:34:12Z",
            "update_window_expires_at": "2027-05-15T04:34:12Z",
            "max_hardware_fingerprints": 3,
            "stripe_payment_id": "pi_TEST_canonical_reference",
            "signature_algorithm": "Ed25519",
        ]

        // Byte-for-byte what Python's
        //   json.dumps(body, sort_keys=True, separators=(",", ":"),
        //              ensure_ascii=False).encode("utf-8")
        // produces. The TypeScript Worker matches this (verified in
        // CM050/tests/license.test.ts round-trip).
        let expected = #"{"issued_to_email":"alice@example.com","license_id":"8c7e3f9a-1234-4abc-9def-0123456789ab","max_hardware_fingerprints":3,"purchased_at":"2026-05-15T04:34:12Z","signature_algorithm":"Ed25519","stripe_payment_id":"pi_TEST_canonical_reference","update_window_expires_at":"2027-05-15T04:34:12Z","version":1}"#

        guard let actual = LicenseVerifier.canonicalJSON(body) else {
            XCTFail("canonicalJSON returned nil for valid body")
            return
        }
        guard let actualStr = String(data: actual, encoding: .utf8) else {
            XCTFail("canonical output was not valid UTF-8")
            return
        }
        XCTAssertEqual(actualStr, expected, "canonical bytes diverged from Python/Worker reference")
    }

    func testCanonicalJSONFromDeserializedJSONHandlesIntOne() throws {
        // The actual regression-protector. The two adjacent literal-Int
        // tests use Swift's native `Int(1)`, which doesn't bridge to Bool
        // via `as? Bool` -- so they would pass with the bridging bug in
        // place too. The bug only fires on values that come out of
        // JSONSerialization (NSNumber-typed), where `NSNumber(int: 1)
        // as? Bool` returns `Optional(true)`. This test exercises that
        // path.
        let raw = #"{"version":1,"max_hardware_fingerprints":0}"#.data(using: .utf8)!
        let body = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let canonical = LicenseVerifier.canonicalJSON(body)!
        XCTAssertEqual(
            String(data: canonical, encoding: .utf8),
            #"{"max_hardware_fingerprints":0,"version":1}"#,
            "canonical bytes diverged from reference; NSNumber/Bool bridging bug may have regressed"
        )
    }

    // MARK: - Public-key override gating (SECURITY)
    //
    // OSTLER_LICENSE_PUBKEY_OVERRIDE lets QA/staging swap the trusted
    // signing key. It MUST be honoured only in DEBUG/dev builds and
    // ignored entirely in release builds, otherwise anyone can point a
    // shipped verifier at their own keypair and self-sign a licence.
    // `selectPublicKeyHex` is deterministic in `allowOverride`, so we
    // exercise both build postures regardless of the test build config.

    /// A syntactically valid but non-production 64-hex override.
    private let fakeOverrideHex =
        String(repeating: "ab", count: 32)

    func testReleaseBuildIgnoresPubkeyOverride() {
        let env = ["OSTLER_LICENSE_PUBKEY_OVERRIDE": fakeOverrideHex]
        let hex = LicenseVerifier.selectPublicKeyHex(
            environment: env,
            allowOverride: false
        )
        // Release posture: the embedded production key is returned and
        // the attacker-controlled override is ignored.
        XCTAssertEqual(hex, LicenseVerifier.embeddedProductionPublicKeyHex)
        XCTAssertNotEqual(hex, fakeOverrideHex)
    }

    func testDebugBuildHonoursPubkeyOverride() {
        let env = ["OSTLER_LICENSE_PUBKEY_OVERRIDE": fakeOverrideHex]
        let hex = LicenseVerifier.selectPublicKeyHex(
            environment: env,
            allowOverride: true
        )
        // Dev posture: the override wins.
        XCTAssertEqual(hex, fakeOverrideHex)
    }

    func testOverrideRequiresExactly64Hex() {
        // A malformed override (wrong length) is ignored even in dev.
        let env = ["OSTLER_LICENSE_PUBKEY_OVERRIDE": "deadbeef"]
        let hex = LicenseVerifier.selectPublicKeyHex(
            environment: env,
            allowOverride: true
        )
        XCTAssertEqual(hex, LicenseVerifier.embeddedProductionPublicKeyHex)
    }

    func testNoOverrideEnvUsesEmbeddedKey() {
        let hex = LicenseVerifier.selectPublicKeyHex(
            environment: [:],
            allowOverride: true
        )
        XCTAssertEqual(hex, LicenseVerifier.embeddedProductionPublicKeyHex)
    }

    func testOverrideAllowedReflectsBuildConfiguration() {
        // Documents the compiled posture: tests build under DEBUG, so
        // the override is permitted here; a release build compiles this
        // to false. If this ever flips under a release test build the
        // gate has regressed.
        #if DEBUG
        XCTAssertTrue(LicenseVerifier.overrideAllowed)
        #else
        XCTAssertFalse(LicenseVerifier.overrideAllowed)
        #endif
    }

    func testCanonicalJSONPreservesIntegerOneAndZero() {
        // The Bool/NSNumber bridging gotcha specifically affects
        // 0 and 1, since those are the only Int values that round-
        // trip cleanly to Bool. Pin both directions.
        let withOne: [String: Any] = ["version": 1, "max_hardware_fingerprints": 0]
        let withZero: [String: Any] = ["version": 0, "max_hardware_fingerprints": 1]

        XCTAssertEqual(
            String(data: LicenseVerifier.canonicalJSON(withOne)!, encoding: .utf8),
            #"{"max_hardware_fingerprints":0,"version":1}"#
        )
        XCTAssertEqual(
            String(data: LicenseVerifier.canonicalJSON(withZero)!, encoding: .utf8),
            #"{"max_hardware_fingerprints":1,"version":0}"#
        )
    }

}
