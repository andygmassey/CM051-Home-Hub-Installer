// HardwareFingerprintTests.swift
//
// Smoke + shape tests for HardwareFingerprint.compute(). We do NOT
// assert a specific hex value (that would couple the test to whichever
// Mac runs CI) -- the contract under test is:
//
//   - The function returns a `sha256:` prefix followed by 64 lowercase
//     hex characters.
//   - Two calls in the same process return the same value (the inputs
//     are stable system properties; nondeterminism would indicate we
//     accidentally folded in a moving value like uptime).
//   - The hash is opaque -- it must NOT echo the IOPlatformUUID verbatim.

import IOKit
import XCTest
@testable import OstlerInstaller

final class HardwareFingerprintTests: XCTestCase {

    func testComputeReturnsPrefixedSha256Hex() throws {
        // Skip on CI/runners that may strip IOPlatformExpertDevice
        // access; if the property is unavailable the function returns
        // nil and the test target should not pretend the contract is
        // verified. Locally on a developer Mac this always succeeds.
        guard let fp = HardwareFingerprint.compute() else {
            throw XCTSkip("IOPlatformUUID/serial unavailable on this host")
        }
        XCTAssertTrue(fp.hasPrefix("sha256:"),
                      "fingerprint must carry the sha256: prefix; got \(fp)")
        let hex = String(fp.dropFirst("sha256:".count))
        XCTAssertEqual(hex.count, 64,
                       "fingerprint hex body must be exactly 64 chars")
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hex.unicodeScalars.allSatisfy { allowed.contains($0) },
                      "fingerprint hex body must be lowercase hex; got \(hex)")
    }

    func testComputeIsDeterministicAcrossCalls() throws {
        guard let a = HardwareFingerprint.compute() else {
            throw XCTSkip("IOPlatformUUID/serial unavailable on this host")
        }
        guard let b = HardwareFingerprint.compute() else {
            return XCTFail("second call returned nil while first succeeded")
        }
        XCTAssertEqual(a, b, "fingerprint must be deterministic across calls")
    }

    func testComputeDoesNotEchoPlatformUUIDVerbatim() throws {
        // Re-derive the IOPlatformUUID via the same accessor the code uses
        // (we cannot fish it out of HardwareFingerprint directly without
        // exposing private state) and assert it does NOT appear in the
        // resulting hash output. The hash purpose is exactly to obscure
        // the underlying identifier from anyone reading the cache file.
        guard let fp = HardwareFingerprint.compute() else {
            throw XCTSkip("IOPlatformUUID/serial unavailable on this host")
        }
        let uuid = readIOPlatformUUID()
        guard let uuid, !uuid.isEmpty else {
            throw XCTSkip("Could not read IOPlatformUUID for comparison")
        }
        XCTAssertFalse(fp.contains(uuid),
                       "fingerprint must not echo the IOPlatformUUID verbatim")
    }

    // MARK: - Helper duplicating the IOKit read for assertion purposes

    private func readIOPlatformUUID() -> String? {
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            svc, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return unmanaged.takeRetainedValue() as? String
    }
}
