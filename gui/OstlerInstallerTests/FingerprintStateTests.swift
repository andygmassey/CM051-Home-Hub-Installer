// FingerprintStateTests.swift
//
// Covers the on-disk state-machine for fingerprint caching and the
// deferred-registration queue. Each test runs against a per-test temp
// directory so we never touch the real `~/.ostler/state/` paths.

import XCTest
@testable import OstlerInstaller

final class FingerprintStateTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ostler-fpstate-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Cache

    func testCachedFingerprintReturnsNilWhenAbsent() {
        let url = tempDir.appendingPathComponent("fingerprint.txt")
        XCTAssertNil(FingerprintState.cachedFingerprint(at: url))
    }

    func testWriteThenReadRoundTripsFingerprint() throws {
        let url = tempDir.appendingPathComponent("fingerprint.txt")
        let value = "sha256:" + String(repeating: "f", count: 64)
        try FingerprintState.writeCachedFingerprint(value, to: url)

        let read = FingerprintState.cachedFingerprint(at: url)
        XCTAssertEqual(read, value)
    }

    func testWriteSetsRestrictivePermissions() throws {
        let url = tempDir.appendingPathComponent("fingerprint.txt")
        try FingerprintState.writeCachedFingerprint("sha256:abc", to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600,
                       "cache file should be owner-read/write only; got \(String(perms, radix: 8))")
    }

    // MARK: - Pending queue

    func testReadPendingReturnsNilWhenAbsent() {
        let url = tempDir.appendingPathComponent("pending_registration.json")
        XCTAssertNil(FingerprintState.readPending(at: url))
    }

    func testWritePendingRoundTrips() throws {
        let url = tempDir.appendingPathComponent("pending_registration.json")
        try FingerprintState.writePending(
            licenseId: "8c7e3f9a-1234-4abc-9def-0123456789ab",
            fingerprint: "sha256:beef",
            at: url
        )

        let read = FingerprintState.readPending(at: url)
        XCTAssertEqual(read?.licenseId, "8c7e3f9a-1234-4abc-9def-0123456789ab")
        XCTAssertEqual(read?.fingerprint, "sha256:beef")
        XCTAssertFalse(read?.queuedAt.isEmpty ?? true,
                       "queuedAt should be populated with an ISO-8601 timestamp")
    }

    func testWritePendingProducesSnakeCaseJSON() throws {
        let url = tempDir.appendingPathComponent("pending_registration.json")
        try FingerprintState.writePending(
            licenseId: "abc",
            fingerprint: "sha256:dead",
            at: url
        )

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"license_id\""),
                      "JSON must use snake_case license_id; got \(raw)")
        XCTAssertTrue(raw.contains("\"queued_at\""),
                      "JSON must use snake_case queued_at; got \(raw)")
    }

    func testClearPendingIsIdempotent() throws {
        let url = tempDir.appendingPathComponent("pending_registration.json")
        // Clearing when absent is a no-op.
        FingerprintState.clearPending(at: url)

        try FingerprintState.writePending(
            licenseId: "abc",
            fingerprint: "sha256:dead",
            at: url
        )
        XCTAssertNotNil(FingerprintState.readPending(at: url))

        FingerprintState.clearPending(at: url)
        XCTAssertNil(FingerprintState.readPending(at: url))
    }

    func testReadPendingReturnsNilOnCorruptFile() throws {
        let url = tempDir.appendingPathComponent("pending_registration.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("garbage not json".utf8).write(to: url)

        XCTAssertNil(FingerprintState.readPending(at: url),
                     "corrupt queue should be treated as no pending, not crash")
    }
}
