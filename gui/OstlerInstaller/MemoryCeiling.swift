// MemoryCeiling.swift
//
// A ceiling guard on the installer's OWN memory footprint.
//
// WHY: nothing in this estate watches a process for unbounded growth. On the
// v1.0.42 upgrade walk the installer reached 4.27 GB and the first thing that
// noticed was macOS raising "your system has run out of application memory" --
// which suspends every app on the box, including the ones that were healthy.
// By then the customer has lost the window, the log drawer and the pairing QR.
//
// The bound in OutputLineBuffer removes the growth path we MEASURED. This
// guard exists for the one we have not: an installer that is quietly eating
// the machine must say so, in its own log, before the OS says it for us.
//
// DELIBERATELY NOT A KILL SWITCH. Terminating a mid-flight install to save
// memory trades a slow install for a broken one, and the re-run path is the
// repair route (#637 is the standing example of what "your only escape is
// delete and reinstall" costs). It escalates through log levels and, at the
// hard ceiling, tells the customer in the GUI what is happening and what to
// do. Bounding the damage after SUCCESS is the auto-quit's job, not this.
//
// The verdict function is pure and takes the footprint as an argument, so it
// can be driven to RED in a test without allocating gigabytes. The sampler
// that feeds it is the only part that touches the kernel.

import Foundation

enum MemoryCeiling {

    /// First warning. An installer past this is already an outlier: the
    /// steady state through a full install is tens of MB.
    static let warnBytes: UInt64 = 512 * 1024 * 1024        // 512 MB

    /// Hard ceiling. Below the ~4.27 GB that triggered the OS, and below the
    /// point where an 8 GB Mac starts swapping the rest of the session out.
    static let criticalBytes: UInt64 = 1_536 * 1024 * 1024  // 1.5 GB

    enum Verdict: Equatable {
        case ok
        case warn(UInt64)
        case critical(UInt64)
    }

    /// Pure classification. `footprint` is phys_footprint in bytes -- the same
    /// number Activity Monitor shows in its Memory column, which is the number
    /// Andy read off the box.
    static func verdict(footprint: UInt64,
                        warnBytes: UInt64 = MemoryCeiling.warnBytes,
                        criticalBytes: UInt64 = MemoryCeiling.criticalBytes) -> Verdict {
        if footprint >= criticalBytes { return .critical(footprint) }
        if footprint >= warnBytes { return .warn(footprint) }
        return .ok
    }

    /// Current phys_footprint of this process, or nil if the kernel refused.
    /// nil is NOT zero: a caller must not read a failed query as a healthy
    /// one. `verdict(footprint:)` is never called with a fabricated value.
    static func currentFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Human-readable MB, for log lines. One decimal place, matching the
    /// precision Activity Monitor reports.
    static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576.0)
    }
}
