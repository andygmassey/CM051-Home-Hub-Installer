// LicenseFetcher.swift
//
// Pulls a licence body from the CM050 Worker given a Stripe checkout
// session id (`cs_*`). Single endpoint:
//
//   GET https://appcast.ostler.ai/api/license/<sessionId>
//
// The Worker returns one of:
//
//   200  { ok: true, signed_json: "<licence JSON>", ... }
//   404  { ok: false, error: "license not yet ready", retry: true }
//   410  { ok: false, error: "license is no longer available..." }
//   400  { ok: false, error: "invalid session_id" }
//
// (See CM050/appcast-server/src/license-fetch.ts for the canonical
// envelope.)
//
// This file is concerned only with mapping that envelope into a
// `LicenseFetchOutcome` for the GUI's view layer to render. The
// verified-bytes hand-off to `LicenseVerifier` happens in the view
// after a `.fetched(...)` outcome is returned.
//
// Why not a licence-id-keyed endpoint?  The Worker doesn't expose
// one at v1.0 launch (only `/api/license/cs_*`). A pasted "licence
// id" gets a friendly steer toward the JSON file in the welcome
// email instead.

import Foundation

// MARK: - Classification

/// What the customer pasted, after trimming + light parsing.
enum LicensePasteShape: Equatable {
    /// `cs_test_...` or `cs_live_...` -- pass to the Worker.
    case stripeSessionId(String)
    /// Full licence URL e.g. `https://appcast.ostler.ai/api/license/cs_...`
    /// -- extract the `cs_*` path segment + treat as `.stripeSessionId`.
    case licenseUrl(sessionId: String)
    /// 8-36 hex/dash chars -- short Licence ID. No Worker endpoint
    /// at v1.0; view should steer the customer to the JSON file.
    case shortLicenseId(String)
    /// Looks like raw licence JSON (starts with `{`). View should
    /// hand directly to the existing verifier path.
    case rawJson(Data)
    /// None of the above.
    case unrecognised
}

/// Classify the customer's paste into one of the shapes the view
/// can act on. Pure synchronous, exposed at module scope so the
/// test target can exercise it directly.
func classifyLicensePaste(_ raw: String) -> LicensePasteShape {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .unrecognised }

    // 1. Raw JSON: starts with `{` (and is plausibly UTF-8). The
    //    verifier will sort out malformed shapes from here, but we
    //    need to keep this branch early so a JSON paste with a
    //    `cs_*` inside it doesn't get mis-classified.
    if trimmed.hasPrefix("{") {
        if let data = trimmed.data(using: .utf8) {
            return .rawJson(data)
        }
        return .unrecognised
    }

    // 2. Licence URL: extract `cs_*` from the path. Don't bother
    //    with strict URL parsing; the customer can copy from a
    //    welcome email, a browser bar, or a screenshot OCR -- any
    //    of which can mangle the URL slightly. Regex on the path
    //    component is the durable extraction.
    if let sid = extractStripeSessionIdFromURL(trimmed) {
        return .licenseUrl(sessionId: sid)
    }

    // 3. Stripe checkout session id: `cs_...` with the live + test
    //    variants both accepted. Length floor matches the Worker's
    //    SESSION_ID_RE.
    if let sid = matchesStripeSessionId(trimmed) {
        return .stripeSessionId(sid)
    }

    // 4. Short Licence ID: 8-36 hex/dash chars. We're permissive
    //    here so a full UUID (32 hex + 4 dashes = 36) also lands
    //    here -- the welcome email shows just the first 8 chars
    //    but a customer might paste the whole UUID.
    if matchesShortLicenseId(trimmed) {
        return .shortLicenseId(trimmed)
    }

    return .unrecognised
}

// `cs_test_...` / `cs_live_...` / `cs_...` -- 10..200 chars body
// (matches the Worker's SESSION_ID_RE).
private func matchesStripeSessionId(_ s: String) -> String? {
    guard s.hasPrefix("cs_") else { return nil }
    let body = String(s.dropFirst(3))
    guard body.count >= 10, body.count <= 200 else { return nil }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    if body.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
        return s
    }
    return nil
}

private func extractStripeSessionIdFromURL(_ s: String) -> String? {
    // Look for the canonical Worker path. Accept http or https,
    // optional trailing query string.
    let pattern = #"https?://[^\s]+/api/license/(cs_[A-Za-z0-9_]{10,200})"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let ns = s as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let m = regex.firstMatch(in: s, options: [], range: range), m.numberOfRanges >= 2 else { return nil }
    return ns.substring(with: m.range(at: 1))
}

private func matchesShortLicenseId(_ s: String) -> Bool {
    guard s.count >= 8, s.count <= 36 else { return false }
    let hexish = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    return s.unicodeScalars.allSatisfy { hexish.contains($0) }
}

// MARK: - Worker fetch

enum LicenseFetchOutcome: Equatable {
    /// `signed_json` field, ready to hand to LicenseVerifier.verify.
    case fetched(Data)
    /// 404 retry=true. Wait a moment and try again, or use the email.
    case notReady
    /// 410 -- revoked or no longer available.
    case revoked
    /// 400/200-without-signed_json/other malformed envelope. The
    /// `message` carries enough detail to land in the error banner.
    case envelopeMissing
    /// Non-2xx / 4xx with no friendlier mapping. `status` is the
    /// HTTP code so the view can interpolate it into the user-facing
    /// copy.
    case httpError(status: Int)
    /// Transport-level failure (no internet, DNS, TLS handshake,
    /// connection reset, timeout). `reason` is `URLError`'s
    /// localizedDescription.
    case transportError(reason: String)
}

/// Thin async wrapper around URLSession. Test target injects a stub
/// session via the `session:` initializer to avoid hitting the
/// network. The base URL is hard-coded to the production Worker;
/// the `OSTLER_LICENSE_FETCH_BASE_OVERRIDE` env var lets staging
/// builds re-point it.
final class LicenseFetcher {

    private let baseURL: URL
    private let session: URLSession

    init(session: URLSession = .shared) {
        let raw: String
        if let override = ProcessInfo.processInfo.environment["OSTLER_LICENSE_FETCH_BASE_OVERRIDE"],
           !override.isEmpty {
            raw = override
        } else {
            raw = "https://appcast.ostler.ai"
        }
        // Force a trailing-slash-free base so we can build with `/`.
        let normalised = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        self.baseURL = URL(string: normalised) ?? URL(string: "https://appcast.ostler.ai")!
        self.session = session
    }

    /// Fetch the signed licence body for the given Stripe checkout
    /// session id. Maps Worker envelope statuses into
    /// `LicenseFetchOutcome`.
    func fetch(sessionId: String) async -> LicenseFetchOutcome {
        guard let url = URL(string: "\(baseURL.absoluteString)/api/license/\(sessionId)") else {
            return .envelopeMissing
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OstlerInstaller/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .envelopeMissing
            }
            switch http.statusCode {
            case 200:
                return parseSuccess(data)
            case 404:
                return .notReady
            case 410:
                return .revoked
            default:
                return .httpError(status: http.statusCode)
            }
        } catch let urlError as URLError {
            return .transportError(reason: urlError.localizedDescription)
        } catch {
            return .transportError(reason: error.localizedDescription)
        }
    }

    /// Pull the `signed_json` field out of the Worker envelope and
    /// hand back as raw bytes for `LicenseVerifier.verify`.
    private func parseSuccess(_ body: Data) -> LicenseFetchOutcome {
        guard let raw = try? JSONSerialization.jsonObject(with: body, options: []),
              let dict = raw as? [String: Any]
        else {
            return .envelopeMissing
        }
        guard let signed = dict["signed_json"] as? String, !signed.isEmpty else {
            // The Worker returns null for rows minted before
            // migration 0004. We can't recover from here; steer
            // the customer at the JSON attachment instead.
            return .envelopeMissing
        }
        guard let signedData = signed.data(using: .utf8) else {
            return .envelopeMissing
        }
        return .fetched(signedData)
    }
}
