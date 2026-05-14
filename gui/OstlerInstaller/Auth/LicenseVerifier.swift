// LicenseVerifier.swift
//
// Ed25519 verification of customer licence files produced by
// CM050/license-generator and CM050/appcast-server. The schema is
// frozen in CM050/docs/LICENSE_FILE_SCHEMA.md (v1). The signing
// implementations live in:
//
//   - CM050/license-generator/ostler_license/core.py  (Python, admin CLI)
//   - CM050/appcast-server/src/license.ts             (TS, Cloudflare Worker)
//
// Both produce byte-identical canonical JSON. This verifier must
// canonicalise the same way to recompute the signed payload and
// run Ed25519 verify against the embedded public key.
//
// Threat model: a customer must not be able to install Ostler
// without a licence file signed by the CM050 signing key. The
// public key embedded below is the verification counterpart.
// Tampering with the verifier defeats the gate (it's all client-
// side, no network call), but ANY rewrite means recompiling and
// re-signing the .app -- which Apple notarisation also gates. The
// licence + notarisation together raise the cost of pirating
// past the casual-user line.

import CryptoKit
import Foundation

// MARK: - Embedded public key
//
// PRODUCTION public key bytes (32 bytes, Ed25519, raw representation)
// matching the LICENSE_SIGNING_PRIVATE_KEY Worker secret in CM050.
// Keypair ceremonied 2026-05-13.
//
// To override at build time for QA / staging:
//     OSTLER_LICENSE_PUBKEY_OVERRIDE=<64-hex-char string>
// is read from the process env at LicenseVerifier init time.
// Test target injects its own keypair-derived public key via
// `LicenseVerifier(publicKey: testKey)`.

private let productionPublicKeyHex =
    "ad31903baa3b2d84ec4bdbfbab860f10e69d5f31649ad5e2a369dbf3377b3dd3"

// MARK: - License schema

/// The frozen v1 licence body, matching
/// CM050/docs/LICENSE_FILE_SCHEMA.md.
struct LicenseClaims: Codable, Equatable {
    let version: Int
    let licenseId: String
    let issuedToEmail: String
    let purchasedAt: String
    let updateWindowExpiresAt: String
    let maxHardwareFingerprints: Int
    let stripePaymentId: String
    let signatureAlgorithm: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case version
        case licenseId = "license_id"
        case issuedToEmail = "issued_to_email"
        case purchasedAt = "purchased_at"
        case updateWindowExpiresAt = "update_window_expires_at"
        case maxHardwareFingerprints = "max_hardware_fingerprints"
        case stripePaymentId = "stripe_payment_id"
        case signatureAlgorithm = "signature_algorithm"
        case signature
    }
}

// MARK: - Verification result

enum LicenseVerificationResult: Equatable {
    /// Signature valid, schema fields well-formed, window not expired.
    case valid(LicenseClaims)
    /// Signature byte-mismatch (tampered, wrong key, or wrong file).
    case invalidSignature
    /// `update_window_expires_at` is in the past. Per the schema,
    /// the Hub still runs, but updates are restricted -- gating
    /// behaviour at install time is reserved for `.expired` so the
    /// view can show a specific "renew to install on a new Mac"
    /// message.
    case expired(expiresAt: String)
    /// JSON parse failed or a required field is missing /
    /// wrong-typed. The associated reason is intended for the
    /// log drawer, not the customer-facing copy.
    case malformed(reason: String)
}

// MARK: - Verifier

/// Verifies a customer licence file against the embedded production
/// public key (or an injected test key in unit-test contexts).
final class LicenseVerifier {

    private let publicKey: Curve25519.Signing.PublicKey

    /// Production initializer. Reads the embedded public key constant
    /// (or the `OSTLER_LICENSE_PUBKEY_OVERRIDE` env var if set).
    /// Returns `nil` if the embedded key is unusable.
    init?() {
        let hex: String
        if let override = ProcessInfo.processInfo.environment["OSTLER_LICENSE_PUBKEY_OVERRIDE"],
           override.count == 64 {
            hex = override
        } else {
            hex = productionPublicKeyHex
        }
        guard let bytes = Self.hexToData(hex), bytes.count == 32 else {
            NSLog("LicenseVerifier: embedded public key hex is malformed (length=\(hex.count))")
            return nil
        }
        // CryptoKit rejects the all-zero key as an init failure on
        // modern releases. We treat that as a "placeholder key not
        // replaced" condition and surface it via init returning nil.
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else {
            NSLog("LicenseVerifier: public key did not parse -- replace the placeholder")
            return nil
        }
        self.publicKey = key
    }

    /// Test-only initializer. Lets the test target inject a key
    /// derived from a generated test keypair, so tests don't depend
    /// on the embedded production key being in place.
    init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    /// Verify a licence document supplied as raw JSON bytes (the
    /// file contents the customer drags in, or pastes).
    func verify(licenseData: Data, now: Date = Date()) -> LicenseVerificationResult {
        // 1. Parse to a generic dictionary first, so we can both
        //    decode the typed claims AND surgically reconstruct
        //    the canonical body without the signature field.
        guard let raw = try? JSONSerialization.jsonObject(with: licenseData, options: []),
              let dict = raw as? [String: Any]
        else {
            return .malformed(reason: "licence is not a JSON object")
        }
        // 2. Decode typed claims for downstream consumers.
        let claims: LicenseClaims
        do {
            claims = try JSONDecoder().decode(LicenseClaims.self, from: licenseData)
        } catch {
            return .malformed(reason: "licence does not match v1 schema: \(error)")
        }
        // 3. Reject unsupported schema or signature algorithm
        //    versions up front. The schema doc says v1 must reject
        //    anything else rather than be permissive.
        guard claims.version == 1 else {
            return .malformed(reason: "unsupported licence version \(claims.version)")
        }
        guard claims.signatureAlgorithm == "Ed25519" else {
            return .malformed(reason: "unsupported signature algorithm: \(claims.signatureAlgorithm)")
        }
        // 4. Strip the `signature` field, canonicalise the rest,
        //    and run Ed25519 verify.
        var bodyDict = dict
        bodyDict.removeValue(forKey: "signature")
        guard let canonical = Self.canonicalJSON(bodyDict) else {
            return .malformed(reason: "could not canonicalise licence body")
        }
        guard let signatureBytes = Data(base64Encoded: claims.signature) else {
            return .malformed(reason: "signature is not valid base64")
        }
        let ok = publicKey.isValidSignature(signatureBytes, for: canonical)
        guard ok else { return .invalidSignature }
        // 5. Expiry check (informational on the schema -- the Hub
        //    still runs, but the installer should not let a fresh
        //    install start on a never-renewed licence). The view
        //    decides whether to refuse outright or let the customer
        //    proceed with a warning.
        if let expiry = Self.parseISO8601UTC(claims.updateWindowExpiresAt),
           expiry < now {
            return .expired(expiresAt: claims.updateWindowExpiresAt)
        }
        return .valid(claims)
    }

    // MARK: - Canonical JSON (RFC 8785 subset matching CM050)
    //
    // Byte-equivalent to Python's
    //   json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    // and the TypeScript implementation in
    //   CM050/appcast-server/src/license.ts::canonicaliseLicenseBody
    //
    // The schema is flat (no nested objects, no arrays, no floats,
    // no negative integers). We assert those invariants and refuse
    // to canonicalise if any are violated -- a defensive failure is
    // safer than producing diverging bytes.

    static func canonicalJSON(_ body: [String: Any]) -> Data? {
        let sortedKeys = body.keys.sorted()
        var parts: [String] = []
        parts.reserveCapacity(sortedKeys.count)
        for key in sortedKeys {
            guard let valueString = canonicalValue(body[key]) else { return nil }
            parts.append("\(jsonEncodeString(key)):\(valueString)")
        }
        return ("{" + parts.joined(separator: ",") + "}").data(using: .utf8)
    }

    private static func canonicalValue(_ value: Any?) -> String? {
        guard let value = value else { return "null" }
        if let s = value as? String { return jsonEncodeString(s) }
        if let b = value as? Bool {
            // NB: in Foundation Bool also satisfies `value as? Int`,
            // so check Bool before Int.
            return b ? "true" : "false"
        }
        if let n = value as? NSNumber {
            // `NSNumber` is the Foundation bridge for both Int and
            // Bool. We've already handled Bool. Anything left must
            // be a non-negative integer per the schema.
            if CFNumberIsFloatType(n) { return nil }
            let intVal = n.int64Value
            if intVal < 0 { return nil }
            return String(intVal)
        }
        // Schema is flat -- nested objects/arrays are a hard reject.
        return nil
    }

    private static func jsonEncodeString(_ s: String) -> String {
        var out = "\""
        // Iterate over UTF-16 code units so per-character behaviour
        // matches the TS reference implementation (which iterates
        // `s.charCodeAt(i)`). All accepted licence fields are ASCII
        // by intake validation, so the loop only hits control-char
        // escapes for malicious input.
        for unit in s.utf16 {
            switch unit {
            case 0x22: out.append("\\\"")        // "
            case 0x5C: out.append("\\\\")        // \
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x00...0x1F:
                out.append("\\u" + String(format: "%04x", unit))
            default:
                if let scalar = Unicode.Scalar(unit) {
                    out.append(Character(scalar))
                }
            }
        }
        out.append("\"")
        return out
    }

    // MARK: - Helpers

    static func hexToData(_ hex: String) -> Data? {
        let normalised = hex.replacingOccurrences(of: " ", with: "")
        guard normalised.count % 2 == 0 else { return nil }
        var data = Data()
        data.reserveCapacity(normalised.count / 2)
        var idx = normalised.startIndex
        while idx < normalised.endIndex {
            let next = normalised.index(idx, offsetBy: 2)
            guard let byte = UInt8(normalised[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    static func parseISO8601UTC(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
