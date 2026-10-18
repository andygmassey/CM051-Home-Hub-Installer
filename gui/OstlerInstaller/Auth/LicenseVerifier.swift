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
// THE VERIFICATION KEY IS COMPILED IN. There is no runtime
// mechanism to swap it -- no env var, no defaults key, no file,
// no argument. `init?()` reads this constant and nothing else.
//
// QA, staging and the unit tests inject their own keypair-derived
// public key through `init(publicKey:)` below. That seam is
// compile-time (the caller has to be linked against the type), so
// it cannot be reached by anyone merely LAUNCHING the shipped app.
//
// This is load-bearing, not stylistic. A verifier that resolves
// its trust anchor from anything the launching process controls
// has no trust anchor: an attacker mints their own keypair, signs
// their own licence body, points the verifier at their own public
// key, and the signature check passes by construction. The paywall
// is then decorative. `LicenseVerifierTests` pins the absence of
// that shape by scanning this file.

private let productionPublicKeyHex =
    "ad31903baa3b2d84ec4bdbfbab860f10e69d5f31649ad5e2a369dbf3377b3dd3"

// MARK: - License tier

/// The tier a licence was issued at.
///
/// THE TIER LIVES INSIDE THE SIGNED BODY. `verify` canonicalises the
/// whole document minus `signature`, so `tier` is covered by the
/// Ed25519 signature like every other field. Measured against the
/// shipped shell verifier extracted from install.sh: a licence signed
/// at `hub` and then hand-edited to `pro` returns rc 13, signature did
/// not verify. A customer cannot promote themselves by editing the
/// file, and no separate anti-tamper machinery is needed for it.
///
/// FOUR STATES, AND THEY MUST NOT COLLAPSE INTO ONE. `resolvedTier`
/// answers "what is this customer entitled to"; `tier` (the raw
/// optional on `LicenseClaims`) answers "what did the licence
/// actually say". Support needs both:
///
///   - absent  a licence issued before tiers existed. Treated as
///             `.hub`, because that is what every licence sold so far
///             bought, and refusing it would brick licences already
///             in customers' hands. `claims.tier == nil` distinguishes
///             it from an explicit "hub".
///   - hub/pro/beta  a recognised tier.
///   - unknown  a tier this build does not recognise, e.g. one CM050
///             starts issuing after this installer shipped. Recorded
///             VERBATIM, grants nothing beyond hub, and refuses
///             nothing. An installer that refused an unrecognised
///             tier would turn every future tier into a support
///             incident for every Mac already in the field.
///
/// Nothing is GATED on the tier yet, deliberately (HR015 #928). The
/// point of landing it now is that retrofitting a tier onto licences
/// already sold is the expensive version.
enum LicenseTier: Equatable {
    case hub
    case pro
    case beta
    case unknown(String)

    /// What an absent `tier` field means. See the note above.
    static let legacyDefault = LicenseTier.hub

    init(raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            self = LicenseTier.legacyDefault
            return
        }
        switch raw.lowercased() {
        case "hub": self = .hub
        case "pro": self = .pro
        case "beta": self = .beta
        default: self = .unknown(raw)
        }
    }

    /// The tier as a stable lowercase token, for logs and for the
    /// entitlement state the Hub keeps. An unrecognised tier is
    /// reported verbatim rather than mapped to a known one.
    var name: String {
        switch self {
        case .hub: return "hub"
        case .pro: return "pro"
        case .beta: return "beta"
        case .unknown(let raw): return raw
        }
    }

    /// False only for a tier this build does not recognise. A caller
    /// that wants to grant something must check this, because
    /// `.unknown` must never be treated as one of the known tiers.
    var isRecognised: Bool {
        if case .unknown = self { return false }
        return true
    }
}

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
    /// OPTIONAL, and it stays optional. `nil` means the licence
    /// predates tiers, NOT that the customer has no tier -- see
    /// `resolvedTier`. Declared as `String?` so a v1 licence without
    /// the field still decodes; declared as `String` (not `Any`) so a
    /// licence carrying a number or an object there is rejected as
    /// malformed by the decoder rather than silently ignored.
    let tier: String?

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
        case tier
    }

    /// The tier to act on. Absent maps to `.hub`; an unrecognised
    /// value stays `.unknown` and is never quietly upgraded.
    var resolvedTier: LicenseTier { LicenseTier(raw: tier) }
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

    /// Production initializer. Uses the embedded public key constant
    /// and nothing else -- the trust anchor is not overridable at
    /// run time, deliberately. To verify against a different key
    /// (QA, staging, unit tests), use `init(publicKey:)`.
    /// Returns `nil` if the embedded key is unusable.
    init?() {
        let hex = productionPublicKeyHex
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

    /// The only key-injection seam, and it is compile-time. Lets the
    /// test target (and any QA / staging harness linked against this
    /// type) verify against a generated keypair instead of the
    /// embedded production key. Nothing in the shipped app calls this
    /// -- `InstallerCoordinator` constructs `LicenseVerifier()` -- so
    /// a customer running the notarised .app cannot reach it without
    /// recompiling, which notarisation already gates.
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
        // 3b. `tier`, when present, must be a short machine token.
        //
        // AN UNRECOGNISED TIER IS NOT A MALFORMED ONE -- those are
        // different states and this check must not merge them. A tier
        // CM050 starts issuing after this build shipped is accepted and
        // recorded verbatim (see `LicenseTier.unknown`). What is
        // rejected here is a value that is not a machine token at all:
        // empty, hundreds of characters, or carrying whitespace or
        // control characters. That matters beyond tidiness because the
        // shell half of this gate hands the tier to install.sh through
        // a single line of stdout, and a tier carrying a newline would
        // split that line. Constraining the SCHEMA is the fix; parsing
        // defensively on one side of a contract the other side does not
        // hold is not.
        //
        // Safe to tighten NOW and only now: no licence in any customer's
        // hands carries a tier, because nothing has ever issued one.
        //
        // 🔴 AN EXPLICIT null IS "ABSENT", NOT "MALFORMED". The
        // synthesised decoder cannot tell a missing key from a null one
        // -- both arrive here as nil -- so this side gets that behaviour
        // for free and the SHELL side had to be written to match it. The
        // first version of the shell check rejected null, which made a
        // licence carrying `"tier": null` pass here and abort the
        // install; see the note beside the same check in install.sh.
        // Do not "tighten" this by reaching into `dict` for NSNull
        // without changing install.sh in the same commit.
        if let rawTier = claims.tier {
            guard Self.isWellFormedTier(rawTier) else {
                return .malformed(reason: "licence tier is not a machine token")
            }
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
        // 🔴 `NSNull`, NOT Swift `nil`, IS HOW A JSON null ARRIVES HERE,
        // and the guard above has therefore never once fired.
        //
        // `canonicalJSON` is called with a dictionary that came out of
        // `JSONSerialization`, where a JSON null is the object
        // `NSNull()`. `body[key]` is then `.some(NSNull())`, the guard
        // succeeds, and the value fell through every branch below to the
        // final `return nil` -- which `verify` reports as "could not
        // canonicalise licence body", i.e. MALFORMED.
        //
        // So this implementation refused any licence carrying any null
        // field, while the Python twin in install.sh accepted it:
        // `canonical_body` has `if isinstance(value, bool) or value is
        // None: continue` and `json.dumps` writes `null`. Measured on
        // origin/main, same body `{"version":1,"tier":null}`:
        //
        //     Swift   canonicalJSON -> nil  (REFUSED)
        //     Python  canonical     -> {"tier":null,"version":1}
        //
        // The two are documented at the top of this file as byte-
        // identical. They were not. A customer handed such a licence
        // would be told it was fine by one half of the product and
        // watched the install abort on the other.
        //
        // Swift moves to match Python, not the other way round, because
        // Python is what CM050's signer canonicalises with: making this
        // side stricter would reject bytes the issuer can legitimately
        // produce. Nothing is weakened by accepting a null -- every
        // REQUIRED field is a non-optional in `LicenseClaims`, so a null
        // in one of those still fails the typed decode as malformed,
        // before this function is ever reached.
        if value is NSNull { return "null" }
        if let s = value as? String { return jsonEncodeString(s) }
        if let n = value as? NSNumber {
            // Foundation bridges Bool to NSNumber. `as? Bool` will succeed
            // for ANY NSNumber whose underlying value is 0 or 1, which
            // silently turns the integer 1 into `true` -- breaking every
            // licence (where `version: 1`). Identity-check via CFBoolean
            // to distinguish actual booleans from integer 0/1.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
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

    /// 1 to 32 characters of `[A-Za-z0-9_.-]`, and nothing else.
    ///
    /// Written as an explicit scalar walk rather than a regex so it
    /// behaves identically to the shell verifier's character-class
    /// check in install.sh. Two implementations of one schema rule
    /// that are written differently WILL drift, and this one has a
    /// twin by design.
    static func isWellFormedTier(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 32 else { return false }
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", ".", "-":
                continue
            default:
                return false
            }
        }
        return true
    }

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
