// GatewayClient.swift
//
// CX-56 (DMG ship, 2026-05-24). Minimal HTTP client used by the
// post-install pairing-QR section on InstallCompleteView. The Hub
// gateway exposes a §3.3-envelope pair-code endpoint at:
//
//   POST http://localhost:8000/admin/paircode
//
// (No auth needed on localhost; gateway binds 127.0.0.1 only.)
//
// The response is a JSON §3.3 envelope that CM031's iOS pairing flow
// is built to decode. We do NOT parse the envelope here -- we POST,
// trim/validate the body, and hand the raw JSON string to the QR
// generator so the iPhone receives exactly the bytes the gateway
// emitted (any local re-encoding here would break the envelope
// signature CM031 verifies on the iOS side).
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

    /// POST to /admin/paircode and return the response body as a
    /// raw JSON string. The §3.3 envelope is signed + carries its
    /// own expiry; we don't parse it here -- the QR generator hashes
    /// the raw bytes and the iPhone verifies them on the way in.
    ///
    /// Returns the JSON string on success. Throws GatewayClientError
    /// for transport / status / body issues.
    func fetchPairCodeEnvelope() async throws -> String {
        let url = baseURL.appendingPathComponent("admin/paircode")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The endpoint accepts an empty POST body -- no params
        // needed -- but we send `{}` so middleware that asserts
        // a content-type + non-empty body does not 400 us.
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

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

        guard let body = String(data: data, encoding: .utf8) else {
            throw GatewayClientError.invalidUTF8
        }

        // Trim trailing newlines but preserve the JSON structure.
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
