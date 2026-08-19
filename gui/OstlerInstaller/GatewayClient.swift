// GatewayClient.swift
//
// CX-56 (DMG ship, 2026-05-24). Minimal HTTP client used by the
// post-install pairing-QR section on InstallCompleteView. The Hub
// gateway exposes the pair-code endpoints at:
//
//   GET  http://localhost:8000/admin/paircode      (current code)
//   POST http://localhost:8000/admin/paircode/new  (mint + rotate)
//
// (No auth needed on localhost; gateway binds 127.0.0.1 only.)
//
// BW-FIND-27 (2026-06-23): the GET path returns no `qr_payload`
// when no code has been minted yet -- the steady state right after
// a fresh install. The success-screen auto-show therefore MINTS via
// the POST path (mintPairCodeEnvelope) so a code always exists for
// the first render; the customer-facing Refresh button keeps the
// GET semantics (show the current code). This mirrors the Doctor's
// pair_status.py `fresh` flag.
//
// The gateway returns a wrapper JSON of shape:
//   { "message": "...", "pairing_code": "255474",
//     "pairing_required": true, "success": true,
//     "qr_payload": { "v":1, "hub_addr": "...", "pairing_token":
//                     "...", "rp_id": "...", "expires_at": ... } }
//
// CM031's iOS pairing flow expects the §3.3 envelope (the inner
// `qr_payload` object), not the wrapper. We decode the response,
// pull out qr_payload, and re-serialise it for the QR so iOS sees
// the canonical envelope shape.
//
// Failure modes the call-site needs to handle:
//   - Gateway not yet up: install.sh start-services step has fired
//     but the gateway can take a few seconds to bind 8000. Surface
//     as a retry-able "couldn't connect" state in the UI.
//   - Gateway up but pair endpoint disabled: not currently a real
//     code path; treat as a non-retryable error (the UI's Refresh
//     button will retry anyway, which is acceptable).
//   - Customer offline: irrelevant -- the endpoint is loopback only.

import Foundation

/// Strongly-typed failure modes so the UI can render a sensible
/// message instead of stringifying URLError.
enum GatewayClientError: Error {
    case transport(underlying: Error)
    case nonSuccessStatus(code: Int, body: String)
    case emptyBody
    case invalidUTF8
    case malformedEnvelope(reason: String)
}

/// Lightweight gateway client. Stateless: each call builds a fresh
/// URLRequest + URLSession.shared task. URLSession.shared is fine
/// here because we are never authenticated against a public service
/// (this is localhost-only).
struct GatewayClient {
    /// Default gateway base URL. Hardcoded as the install path
    /// always binds to localhost:8000 -- changing the port would be
    /// a coordinated change across install.sh + the gateway service
    /// plist + CM031's pairing flow.
    static let defaultBaseURL: URL = URL(string: "http://localhost:8000")!

    let baseURL: URL
    /// Timeout for the pair-code request. Short enough that a
    /// stalled gateway shows the retry-able state quickly; long
    /// enough that a normal start-of-day gateway boot (1-3s) still
    /// returns clean.
    let requestTimeout: TimeInterval

    init(baseURL: URL = GatewayClient.defaultBaseURL, requestTimeout: TimeInterval = 5.0) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    /// GET /admin/paircode, extract the §3.3 envelope from the
    /// wrapper response, and return it as a JSON string ready for
    /// the QR generator.
    ///
    /// Returns the §3.3 envelope JSON on success. Throws
    /// GatewayClientError for transport / status / body / shape
    /// issues.
    func fetchPairCodeEnvelope() async throws -> String {
        return try await pairCodeEnvelope(fresh: false)
    }

    /// POST /admin/paircode/new to MINT a fresh §3.3 envelope, then
    /// return it as a JSON string ready for the QR generator.
    ///
    /// BW-FIND-27 (2026-06-23): right after a fresh install the
    /// gateway has `pairing_required = true` but NO current code
    /// minted yet, so a plain GET /admin/paircode returns no
    /// `qr_payload` and the success-screen QR auto-show fell through
    /// to the empty placeholder glyph -- the QR stopped
    /// auto-appearing. The customer-facing Refresh button "worked"
    /// only because by the time they tapped it the gateway had
    /// rotated a code into existence. The robust fix is to MINT on
    /// the auto-show (same `fresh=True` path the Doctor's
    /// pair_status.py uses for /api/v1/pair/regenerate) so a code
    /// always exists for the first render.
    func mintPairCodeEnvelope() async throws -> String {
        return try await pairCodeEnvelope(fresh: true)
    }

    /// Shared GET-current / POST-mint implementation. `fresh = true`
    /// POSTs /admin/paircode/new (mints + rotates); `fresh = false`
    /// GETs /admin/paircode (current code only). Both return the
    /// inner §3.3 `qr_payload` envelope re-serialised as a string.
    private func pairCodeEnvelope(fresh: Bool) async throws -> String {
        let path = fresh ? "admin/paircode/new" : "admin/paircode"
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = fresh ? "POST" : "GET"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw GatewayClientError.transport(underlying: error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "(non-utf8 body)"
            throw GatewayClientError.nonSuccessStatus(code: http.statusCode, body: body)
        }

        if data.isEmpty {
            throw GatewayClientError.emptyBody
        }

        // Decode the wrapper, pull out qr_payload, re-serialise as
        // a JSON string. iOS's pairing flow expects the inner §3.3
        // envelope only -- the wrapper exists for admin/CLI use.
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GatewayClientError.malformedEnvelope(reason: "wrapper JSON parse failed: \(error.localizedDescription)")
        }
        guard let dict = json as? [String: Any] else {
            throw GatewayClientError.malformedEnvelope(reason: "wrapper is not a JSON object")
        }
        guard let envelope = dict["qr_payload"] as? [String: Any] else {
            throw GatewayClientError.malformedEnvelope(reason: "wrapper missing qr_payload object")
        }
        let envelopeData: Data
        do {
            envelopeData = try JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]
            )
        } catch {
            throw GatewayClientError.malformedEnvelope(reason: "qr_payload re-serialise failed: \(error.localizedDescription)")
        }
        guard let body = String(data: envelopeData, encoding: .utf8) else {
            throw GatewayClientError.invalidUTF8
        }
        return body
    }
}
