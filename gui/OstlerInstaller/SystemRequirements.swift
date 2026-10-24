// SystemRequirements.swift
//
// F006 (2026-10-24): the hardware floor, checked on the GUI's FIRST
// screen.
//
// An F&F tester on an 8 GB Mac hit ERR-02-PREREQ-RAM-LOW from
// install.sh, which is correct, but only AFTER the permission prompts,
// licence acceptance, a device slot being registered, the admin
// password and a Command Line Tools download. The GUI had no check of
// its own, so the first refusal came from the subprocess, at the end
// of everything a customer can be asked to do.
//
// The floors below are install.sh's floors, not new ones:
//   - memory  : install.sh `RAM_GB -lt 16`  -> ERR-02-PREREQ-RAM-LOW
//   - macOS   : install.sh `OSTLER_MACOS_FLOOR_MAJOR=14`
//   - chip    : install.sh `uname -m` == arm64
// install.sh keeps its own checks as the backstop.
// SystemRequirementsFloorParityTests reads install.sh and fails if
// either side moves without the other.

import Foundation

/// What the Mac reports about itself. A plain value so tests can
/// inject an 8 GB Mac without owning one.
struct SystemReadings: Equatable {
    var memoryBytes: UInt64
    var macOSMajor: Int
    var macOSVersion: String
    var isAppleSilicon: Bool

    /// Same arithmetic as install.sh: hw.memsize / 1073741824, integer
    /// division. An 8 GB Mac reports exactly 8.
    var memoryGB: Int { Int(memoryBytes / 1_073_741_824) }

    static func live() -> SystemReadings {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let version = v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
        return SystemReadings(
            memoryBytes: info.physicalMemory,
            macOSMajor: v.majorVersion,
            macOSVersion: version,
            isAppleSilicon: Self.hostIsAppleSilicon()
        )
    }

    /// `hw.optional.arm64` is 1 on Apple Silicon, including when the
    /// process runs under Rosetta, so it answers "what chip is this
    /// Mac" rather than "what slice am I". Absent (sysctl fails) on
    /// Intel, which is the answer we want there too.
    private static func hostIsAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return rc == 0 && value == 1
    }
}

enum SystemRequirements {
    static let minimumMemoryGB = 16
    static let macOSFloorMajor = 14

    /// Which floors this Mac is below. `nil` from `evaluate` means it
    /// meets all of them.
    struct Shortfall: Equatable {
        var readings: SystemReadings
        var memoryTooLow: Bool
        var macOSTooOld: Bool
        var notAppleSilicon: Bool
    }

    static func evaluate(_ r: SystemReadings) -> Shortfall? {
        let s = Shortfall(
            readings: r,
            memoryTooLow: r.memoryGB < minimumMemoryGB,
            macOSTooOld: r.macOSMajor < macOSFloorMajor,
            notAppleSilicon: !r.isAppleSilicon
        )
        return (s.memoryTooLow || s.macOSTooOld || s.notAppleSilicon) ? s : nil
    }
}
