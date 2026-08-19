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

    // MARK: - The trust anchor is not swappable at run time
    //
    // Until 2026-08-16 `LicenseVerifier.init?()` opened with:
    //
    //     if let override = ProcessInfo.processInfo.environment[
    //             "OSTLER_LICENSE_PUBKEY_OVERRIDE"],
    //        override.count == 64 { hex = override }
    //
    // in the SHIPPING, notarised binary. No build-configuration
    // gate, and the branch was checked FIRST -- it REPLACED the
    // production key rather than supplementing it. So the paywall
    // fell to: generate a keypair, self-sign a licence body, launch
    // the installer with that env var set to your own public key.
    // Signature verification then passed against the attacker's key
    // by construction, on a $99 product.
    //
    // The branch was deleted rather than wrapped in `#if DEBUG`,
    // because `init(publicKey:)` was already the documented
    // injection seam and is what these tests have always used. The
    // env branch was redundant with a mechanism that already
    // existed, so a DEBUG gate would have preserved a live bypass in
    // one build configuration for no remaining reason.
    //
    // These three tests are the enforcer. They need no build-config
    // trickery: the branch is gone in EVERY configuration, so the
    // proof is expressible in the Debug build the test target runs
    // under.

    /// Hex-encode raw key bytes so a test can hand a public key to
    /// the env var in exactly the form the deleted branch parsed
    /// (64 lowercase hex chars). Test-generated keys only -- no
    /// production key material is ever formatted here.
    private func hexEncode(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// NEGATIVE CONTROL, and the actual attack.
    ///
    /// Mint an attacker keypair, self-sign a licence with it, point
    /// `OSTLER_LICENSE_PUBKEY_OVERRIDE` at the attacker's public key,
    /// then build the PRODUCTION verifier the app actually uses
    /// (`LicenseVerifier()`, as `InstallerCoordinator` does). The
    /// forged licence must be rejected.
    ///
    /// The paired POSITIVE CONTROL is inside this same test, on
    /// purpose: it proves the same bytes DO verify under the key
    /// that signed them. Without it, a `.invalidSignature` here
    /// would be indistinguishable from a test that accidentally
    /// built a malformed licence -- the gate would go green while
    /// measuring nothing.
    func testEnvOverrideCannotSwapTheProductionKey() throws {
        let attackerKey = Curve25519.Signing.PrivateKey()
        let forged = try sign(makeLicenseBody(), with: attackerKey)

        // Positive control: the forged licence is well-formed and
        // verifies under the key that signed it. If this limb fails,
        // the negative limb below proves nothing.
        let attackerVerifier = LicenseVerifier(publicKey: attackerKey.publicKey)
        guard case .valid = attackerVerifier.verify(licenseData: forged) else {
            XCTFail(
                "positive control failed: the self-signed licence did not verify "
                + "under its own key, so the rejection below would be meaningless"
            )
            return
        }

        // The attack. setenv, not a ProcessInfo stub: the deleted
        // branch read the REAL process environment, so the real
        // process environment is what has to be shown inert.
        let attackerHex = hexEncode(attackerKey.publicKey.rawRepresentation)
        XCTAssertEqual(attackerHex.count, 64, "test key did not hex-encode to the 64 chars the deleted branch required")
        setenv("OSTLER_LICENSE_PUBKEY_OVERRIDE", attackerHex, 1)
        defer { unsetenv("OSTLER_LICENSE_PUBKEY_OVERRIDE") }

        guard let productionVerifier = LicenseVerifier() else {
            XCTFail("LicenseVerifier() returned nil -- the embedded production key does not parse")
            return
        }
        XCTAssertEqual(
            productionVerifier.verify(licenseData: forged),
            .invalidSignature,
            "REVENUE HOLE: a self-signed licence was accepted by the production verifier "
            + "while OSTLER_LICENSE_PUBKEY_OVERRIDE pointed at the signer's own public key. "
            + "The runtime key-override branch has been reintroduced into LicenseVerifier.init?()."
        )
    }

    /// The production initializer still works with the env var set.
    ///
    /// A verifier that returned nil under a hostile environment
    /// would also "reject" the forged licence, for the wrong reason,
    /// and would break every honest customer whose environment
    /// happened to carry the variable. Pin that `init?()` succeeds
    /// and is simply indifferent to the variable.
    func testProductionVerifierInitialisesRegardlessOfEnvironment() {
        XCTAssertNotNil(LicenseVerifier(), "clean environment: embedded production key must parse")

        setenv("OSTLER_LICENSE_PUBKEY_OVERRIDE", String(repeating: "a", count: 64), 1)
        defer { unsetenv("OSTLER_LICENSE_PUBKEY_OVERRIDE") }
        XCTAssertNotNil(
            LicenseVerifier(),
            "a set OSTLER_LICENSE_PUBKEY_OVERRIDE must not change init?() behaviour at all, "
            + "including whether it succeeds"
        )

        // Garbage that the deleted branch would have rejected on
        // length and a 64-char value that is not hex both have to be
        // inert now, not merely handled.
        setenv("OSTLER_LICENSE_PUBKEY_OVERRIDE", String(repeating: "z", count: 64), 1)
        XCTAssertNotNil(LicenseVerifier(), "non-hex override value must be ignored, not fatal")
    }

    /// SHAPE REGRESSION GUARD.
    ///
    /// The two tests above prove the behaviour of the code as
    /// compiled. This one refuses the shape itself, so the branch
    /// cannot come back in a form that reads the environment under a
    /// different variable name -- which the behaviour tests, keyed to
    /// one specific name, would not catch.
    ///
    /// Same source-scan pattern as
    /// `AdminAuthorizationGateTests.testAuthorizationHelperDoesNotShellOutToOsascript`.
    func testLicenseVerifierSourceReadsNoProcessEnvironment() throws {
        let verifierURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // OstlerInstallerTests/
            .deletingLastPathComponent()      // gui/
            .appendingPathComponent("OstlerInstaller/Auth/LicenseVerifier.swift")
        let source = try String(contentsOf: verifierURL, encoding: .utf8)

        // MUST-BE-PRESENT controls first. An absence check passes
        // trivially when the read fails or resolves to the wrong
        // file, so prove the scanner is looking at the right bytes
        // BEFORE believing anything it says about absence.
        XCTAssertFalse(source.isEmpty, "read LicenseVerifier.swift as empty -- the absence checks below would be vacuous")
        XCTAssertTrue(
            source.contains("productionPublicKeyHex"),
            "scanned file does not look like LicenseVerifier.swift; absence checks below are not trustworthy"
        )
        XCTAssertTrue(
            source.contains("init(publicKey: Curve25519.Signing.PublicKey)"),
            "the compile-time injection seam must remain -- it is what replaces the deleted env override"
        )

        // Now the refusals.
        XCTAssertFalse(
            source.contains("OSTLER_LICENSE_PUBKEY_OVERRIDE"),
            "the runtime public-key override env var is back in LicenseVerifier.swift. "
            + "It lets anyone launching the shipped installer substitute their own trust anchor. "
            + "Inject via init(publicKey:) instead."
        )
        XCTAssertFalse(
            source.contains("ProcessInfo"),
            "LicenseVerifier must not consult the process environment for ANY reason. "
            + "Whatever the variable is called, a trust anchor the launching process can set is not a trust anchor."
        )
        XCTAssertFalse(
            source.contains("UserDefaults"),
            "LicenseVerifier must not resolve its key from UserDefaults -- a customer can write those with `defaults write`."
        )
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
