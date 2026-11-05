// LateStepPolicy.swift
//
// F&F tester report 2026-11-05, item 6 (CRITICAL). At the last step (Tailscale
// sign-in / iPhone pairing) the app did not recognise the phone. The only exit
// was Cancel, which killed install.sh and quit the app; the next launch began
// again at the START: three hours of completed install work lost.
//
// Root cause (two parts):
//  1. FooterView's Cancel unconditionally did coordinator.cancel() +
//     NSApp.terminate(nil), at every step including the last one.
//  2. install.sh's tailscale_signin wait loop has a skip sentinel
//     (`${OSTLER_DIR}/tailscale/.signin_skip`, #644 defect 3, "a Skip affordance
//     in the GUI writes it"), but NO GUI code ever wrote it. The affordance was
//     never built, so nothing could end the 180 s wait except killing the run.
//
// Policy: at a pairing step, Cancel and the new "Finish and pair later" button
// both write the sentinel. install.sh then continues to the end, prints "set up
// later from Settings", and the install completes WITHOUT pairing. The phone link is
// made afterwards from the success screen QR / Doctor. Only Foundation is used,
// so it is unit-testable.

import Foundation

enum LateStepPolicy {
    /// Steps at which the install is complete except for pairing. Cancel here
    /// must never discard the finished work.
    static let pairingStepIds: Set<String> = ["tailscale_signin"]

    enum CancelAction: Equatable {
        /// Early step: nothing worth keeping, stop the installer as before.
        case terminate
        /// Pairing step: finish the install without pairing, keep the app open.
        case finishWithoutPairing
    }

    static func cancelAction(stepId: String?) -> CancelAction {
        guard let id = stepId, pairingStepIds.contains(id) else { return .terminate }
        return .finishWithoutPairing
    }

    static func isPairingStep(_ stepId: String?) -> Bool {
        cancelAction(stepId: stepId) == .finishWithoutPairing
    }

    /// Must equal install.sh `TS_SKIP_SENTINEL="${TS_STATE_DIR}/.signin_skip"`
    /// with TS_STATE_DIR="${OSTLER_DIR}/tailscale" and OSTLER_DIR=~/.ostler.
    static func skipSentinelURL(home: URL) -> URL {
        home.appendingPathComponent(".ostler/tailscale/.signin_skip")
    }

    @discardableResult
    static func writeSkipSentinel(home: URL) -> Bool {
        let url = skipSentinelURL(home: home)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            return true
        } catch {
            return false
        }
    }
}
