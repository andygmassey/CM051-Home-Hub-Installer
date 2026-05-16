// DeviceRegistration.swift
//
// Talks to the CM050 appcast Worker's POST /register-device endpoint.
// The contract is documented at
//   CM050/appcast-server/docs/REGISTER_DEVICE.md
// and the source of truth is the handler at
//   CM050/appcast-server/src/register-device.ts
//
// Response shape mapping (verified against the Worker source 2026-05-16):
//   200 OK    -> .ok(maxFingerprints, registeredCount)
//   400 -> .badRequest (we treat as a programmer error; should not occur
//          for valid claims from a verified licence)
//   404 -> .licenceNotFound
//   409 -> .limitReached(maxFingerprints, registeredCount)  <-- NOT 403
//   410 -> .revoked
//   any  -> .networkFailure (server-side error; treated as a soft failure)
//
// The brief's snippet referred to 403 + {max, current}; the Worker actually
// returns 409 + {max_hardware_fingerprints, registered_count}. We conform
// to what the Worker emits, since the Worker is the source of truth.

import Foundation

/// Transport abstraction so tests can inject a mock without dragging in
/// URLProtocol gymnastics.
protocol DeviceRegistrationTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTransport: DeviceRegistrationTransport {
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Outcome of a single registration attempt.
enum DeviceRegistrationResult: Equatable, Sendable {
    case ok(maxFingerprints: Int, registeredCount: Int)
    case limitReached(maxFingerprints: Int, registeredCount: Int)
    case licenceNotFound
    case revoked
    case badRequest(reason: String)
    case networkFailure(message: String)
}

/// Default production endpoint. Override for staging / tests.
let defaultRegisterDeviceEndpoint =
    URL(string: "https://appcast.ostler.ai/register-device")!

actor DeviceRegistrationClient {

    private let endpoint: URL
    private let transport: DeviceRegistrationTransport

    init(
        endpoint: URL = defaultRegisterDeviceEndpoint,
        transport: DeviceRegistrationTransport = URLSessionTransport()
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    /// Posts `(license_id, fingerprint)` to the Worker and decodes the
    /// outcome. Returns `.networkFailure` for transport-level errors and
    /// 5xx responses; the caller is expected to fail-open + defer the
    /// retry to the Hub-side scheduler so an offline customer is not
    /// blocked at install time.
    func register(
        licenseId: String,
        fingerprint: String
    ) async -> DeviceRegistrationResult {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("OstlerInstaller", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let payload: [String: String] = [
            "license_id": licenseId,
            "fingerprint": fingerprint,
        ]
        do {
            req.httpBody = try JSONEncoder().encode(payload)
        } catch {
            return .networkFailure(message: "encode payload failed: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(req)
        } catch {
            return .networkFailure(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .networkFailure(message: "non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            if let ok = try? JSONDecoder().decode(OKBody.self, from: data) {
                return .ok(
                    maxFingerprints: ok.max_hardware_fingerprints,
                    registeredCount: ok.registered_count
                )
            }
            // The Worker returned 200 but the body didn't parse. Treat as
            // success with an indeterminate count so the install can
            // proceed -- the customer is registered server-side either way.
            return .ok(maxFingerprints: -1, registeredCount: -1)
        case 400:
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "bad request"
            return .badRequest(reason: reason)
        case 404:
            return .licenceNotFound
        case 409:
            if let body = try? JSONDecoder().decode(LimitBody.self, from: data) {
                return .limitReached(
                    maxFingerprints: body.max_hardware_fingerprints,
                    registeredCount: body.registered_count
                )
            }
            return .limitReached(maxFingerprints: 0, registeredCount: 0)
        case 410:
            return .revoked
        case 500...:
            return .networkFailure(message: "server error \(http.statusCode)")
        default:
            return .networkFailure(message: "unexpected status \(http.statusCode)")
        }
    }

    // MARK: - Decode helpers
    //
    // snake_case to match the Worker contract verbatim. We accept the
    // odd Swift-style lint hit in exchange for documentation parity.

    private struct OKBody: Decodable {
        // swiftlint:disable identifier_name
        let max_hardware_fingerprints: Int
        let registered_count: Int
        // swiftlint:enable identifier_name
    }

    private struct LimitBody: Decodable {
        // swiftlint:disable identifier_name
        let max_hardware_fingerprints: Int
        let registered_count: Int
        // swiftlint:enable identifier_name
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }
}
