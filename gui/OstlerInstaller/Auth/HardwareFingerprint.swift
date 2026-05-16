// HardwareFingerprint.swift
//
// Derives an opaque, stable identifier for this Mac. Combined with
// the customer's licence_id at the Worker side via POST /register-device,
// this lets us enforce the three-device limit on a licence and stop the
// "pay once, share licence.json with anyone" attack the Ed25519 verifier
// alone cannot.
//
// Components:
//   IOPlatformUUID  -- survives macOS reinstall on the same physical Mac.
//   IOPlatformSerialNumber -- the Apple-assigned serial; stable for the
//                              life of the machine.
//   hw.model        -- a coarse model identifier (e.g. "Mac16,12").
//                      Included so two Macs that somehow share a serial
//                      (returned hardware, manufacturer mishap) still
//                      derive distinct fingerprints in practice.
//
// We deliberately do NOT include MAC addresses: those change on network
// reconfiguration (Tailscale joins/leaves, USB-C dongle swaps, en0/en1
// promotions) and would cause spurious slot consumption.
//
// The fingerprint is exposed as `sha256:<64-hex>` to match the
// CM050 Worker contract documented in
// `appcast-server/docs/REGISTER_DEVICE.md`. The Worker stores the value
// verbatim and never tries to decode it -- the prefix is for the Hub /
// installer's own forward-compat (so we can swap hash algorithms by
// flipping the prefix and the Worker rejects neither).

import CryptoKit
import Darwin
import Foundation
import IOKit

enum HardwareFingerprint {

    /// Returns `sha256:<64-hex>` for this Mac, or `nil` on a profoundly
    /// broken IOKit (no IOPlatformUUID or no serial). A `nil` return is
    /// a fail-closed condition -- the caller must refuse to install
    /// rather than skip enforcement.
    static func compute() -> String? {
        guard let uuid = ioPlatformProperty("IOPlatformUUID"),
              let serial = ioPlatformProperty("IOPlatformSerialNumber") else {
            return nil
        }
        let model = sysctlString("hw.model") ?? "unknown"
        let combined = "\(uuid)|\(serial)|\(model)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    // MARK: - IOKit

    private static func ioPlatformProperty(_ key: String) -> String? {
        // kIOMainPortDefault (macOS 12+) -- previously kIOMasterPortDefault.
        // Target is macOS 14, so the modern name is fine and avoids the
        // deprecation warning the older symbol now emits.
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            svc, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return unmanaged.takeRetainedValue() as? String
    }

    // MARK: - sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buf)
    }
}
