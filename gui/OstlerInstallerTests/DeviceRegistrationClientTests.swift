// DeviceRegistrationClientTests.swift
//
// Exercises the five result branches of DeviceRegistrationClient against
// a stub DeviceRegistrationTransport. No live network calls -- we want
// these tests to run in CI without going through a Worker or a real
// licence id.
//
// We deliberately do not load real customer payloads. All fixtures use
// synthetic uuids + synthetic fingerprints (sha256:dead...beef style).

import XCTest
@testable import OstlerInstaller

final class DeviceRegistrationClientTests: XCTestCase {

    private let endpoint = URL(string: "https://test.example/register-device")!
    private let licenseId = "8c7e3f9a-1234-4abc-9def-0123456789ab"
    private let fingerprint = "sha256:" + String(repeating: "a", count: 64)

    // MARK: - Stub transport

    /// Single-shot transport: returns the configured response once,
    /// or throws when configured to fail. The actor wraps mutable
    /// state because DeviceRegistrationClient calls `send` from its
    /// own actor context and the protocol is Sendable.
    actor StubTransport: DeviceRegistrationTransport {
        var script: (Data, HTTPURLResponse)?
        var error: Error?
        private(set) var lastRequest: URLRequest?

        init(response: (Data, HTTPURLResponse)) {
            self.script = response
        }
        init(error: Error) {
            self.error = error
        }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            self.lastRequest = request
            if let error { throw error }
            guard let script else {
                throw URLError(.unknown)
            }
            return script
        }
    }

    private func makeResponse(status: Int, body: String) -> (Data, HTTPURLResponse) {
        let resp = HTTPURLResponse(
            url: endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), resp)
    }

    // MARK: - 200 OK

    func testOKResponseDecodesCount() async {
        let body = #"{"ok":true,"max_hardware_fingerprints":3,"registered_count":2}"#
        let transport = StubTransport(response: makeResponse(status: 200, body: body))
        let client = DeviceRegistrationClient(endpoint: endpoint, transport: transport)

        let result = await client.register(
            licenseId: licenseId,
            fingerprint: fingerprint
        )
        XCTAssertEqual(result, .ok(maxFingerprints: 3, registeredCount: 2))
    }

    func testOKResponseTolerantOfUnparseableBody() async {
        let transport = StubTransport(response: makeResponse(status: 200, body: "not json"))
        let client = DeviceRegistrationClient(endpoint: endpoint, transport: transport)

        let result = await client.register(
            licenseId: licenseId,
            fingerprint: fingerprint
        )
        // -1 sentinel means "Worker said ok, we just couldn't decode the
        // numbers; proceed". Verified the case statement explicitly so
        // a regression to .networkFailure here would fail the test.
        XCTAssertEqual(result, .ok(maxFingerprints: -1, registeredCount: -1))
    }

    // MARK: - 409 limit reached

    func testLimitReachedDecodesCount() async {
        let body = #"""
        {
            "ok": false,
            "error": "device limit reached",
            "max_hardware_fingerprints": 3,
            "registered_count": 3
        }
        """#
        let transport = StubTransport(response: makeResponse(status: 409, body: body))
        let client = DeviceRegistrationClient(endpoint: endpoint, transport: transport)

        let result = await client.register(
            licenseId: licenseId,
            fingerprint: fingerprint
        )
        XCTAssertEqual(result, .limitReached(maxFingerprints: 3, registeredCount: 3))
    }

    // MARK: - 404 licence not found

    func testLicenceNotFoundMaps() async {
        let body = #"{"ok":false,"error":"license not found"}"#
        let transport = StubTransport(response: makeResponse(status: 404, body: body))
        let client = DeviceRegistrationClient(endpoint: endpoint, transport: transport)

        let result = await client.register(
            licenseId: licenseId,
            fingerprint: fingerprint
        )
        XCTAssertEqual(result, .licenceNotFound)
    }

    // MARK: - 410 revoked / refunded

    func testRevokedMaps() async {
        let body = #"{"ok":false,"error":"license is no longer valid; contact support"}"#
        let transport = StubTransport(response: makeResponse(status: 410, body: body))
        let client = DeviceRegistrationClient(endpoint: endpoint, transport: transport)

        let result = await client.register(
            licenseId: licenseId,
            fingerprint: fingerprint
        )
        XCTAssertEqual(result, .revoked)
    }

    // MARK: - Network failure

    func testNetworkErrorMapsToFailure() async {
        let transport = StubTransport(error: URLError(.notConnectedToInternet))
        let client = DeviceRegistrationClient(endpoint: endpoint, transport: transport)

        let result = await client.register(
            licenseId: licenseId,
            fingerprint: fingerprint
        )
        switch result {
        case .networkFailure:
            // ok
            break
        default:
            XCTFail("expected .networkFailure, got \(result)")
        }
    }

    func testServerErrorMapsToNetworkFailure() async {
        let transport = StubTransport(response: makeResponse(status: 503, body: ""))
        let client = DeviceRegistrationClient(endpoint: endpoint, transport: transport)

        let result = await client.register(
            licenseId: licenseId,
            fingerprint: fingerprint
        )
        switch result {
        case .networkFailure:
            break
        default:
            XCTFail("expected .networkFailure for 5xx, got \(result)")
        }
    }

    // MARK: - Request shape

    func testPayloadIsJSONWithLicenseIdAndFingerprint() async throws {
        let transport = StubTransport(
            response: makeResponse(
                status: 200,
                body: #"{"ok":true,"max_hardware_fingerprints":3,"registered_count":1}"#
            )
        )
        let client = DeviceRegistrationClient(endpoint: endpoint, transport: transport)

        _ = await client.register(licenseId: licenseId, fingerprint: fingerprint)

        let request = await transport.lastRequest
        XCTAssertNotNil(request, "transport.send was not called")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"),
                       "application/json")

        guard let body = request?.httpBody else {
            return XCTFail("no body posted")
        }
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(parsed["license_id"], licenseId)
        XCTAssertEqual(parsed["fingerprint"], fingerprint)
    }
}
