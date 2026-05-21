// BiometricProbe.swift
//
// LAUNCH BLOCKER fix (2026-05-22): the installer's Q12 (passkey-ack)
// hard-coded "Touch ID" copy in MSG_PROMPT_PASSKEY_ACK_HELP. Mac
// Studio, Mac Mini, Mac Pro and standard iMac have no Touch ID --
// every customer who buys a desktop Mac without a Magic Keyboard
// with Touch ID would have read a screen telling them macOS was
// about to prompt for a finger-tap that would never come.
//
// This probe runs at GUI start (App.swift onAppear), classifies the
// machine's biometric capability via LocalAuthentication's LAContext,
// and exposes a single `BiometricModality` value. The Q12 branch in
// OnboardingQuestionView reads this and renders a modality-appropriate
// help string from ViewCopy.json (Rule 0.9 catalogue-keyed).
//
// The probe is pure-read and never triggers a Touch ID prompt -- we
// only call `canEvaluatePolicy(_:error:)`, which classifies hardware
// availability synchronously without invoking the biometric sensor.
//
// Apple framework reference:
//   - LocalAuthentication.LAContext.canEvaluatePolicy(_:error:)
//     ("Assesses whether authentication can proceed for a given
//     policy." -- no prompt, no UI side-effect, safe to call on
//     window open.)
//   - LocalAuthentication.LABiometryType
//     (.touchID + .faceID exist on macOS. .opticID is visionOS-only;
//     the enum exposes it everywhere but the probe never returns it
//     on macOS hardware. We carry the case anyway so the catalogue
//     branches enumerate exhaustively.)
//
// The passkey-wrapped DEK from task #130 already supports password +
// Apple Watch fallback on macOS Sequoia+; install.sh's encryption
// flow does not change. Only the customer-facing copy changes.

import Foundation
import LocalAuthentication

/// What kind of biometric (if any) does this Mac own?
///
/// `.touchID` -- a Touch ID sensor is wired up (built-in on MacBook
/// Air/Pro 2018+, or a paired Magic Keyboard with Touch ID on a
/// Mac Mini / Studio / Pro / iMac).
///
/// `.opticID` -- visionOS only. Carried here so callers enumerate
/// exhaustively; never returned on macOS hardware.
///
/// `.none` -- no biometric available. The passkey will be wrapped
/// by the macOS login password (with an optional Apple Watch
/// fallback on Sequoia+ if a Watch is paired and unlocked).
///
/// Face ID is not available on any current Mac, so we collapse it
/// into `.none` for the customer-facing copy branch. The probe still
/// distinguishes it internally via `LABiometryType.faceID` for the
/// rare/future case, but no Mac today exposes it; we choose to
/// surface it as the modality-equivalent `.touchID` copy on the
/// off chance Apple ships a Face ID Mac in v1.x (the copy reads
/// fine for "biometrics on this Mac").
enum BiometricModality: String, Equatable {
    case touchID
    case opticID
    case none
}

/// Result bundle for the probe. Separates the modality (for the copy
/// branch) from the underlying LAContext error (for diagnostics in
/// the log drawer).
struct BiometricProbeResult: Equatable {
    let modality: BiometricModality
    /// Non-nil when LAContext refused biometrics with a specific
    /// reason (e.g. .biometryNotAvailable, .biometryNotEnrolled). The
    /// Q12 branch ignores this; it's surfaced for log-drawer triage
    /// when a customer reports the "wrong" Q12 copy.
    let underlyingErrorDescription: String?
}

/// Abstraction so tests can inject a synthetic LAContext-shaped
/// double without touching real hardware. The protocol is narrow on
/// purpose: only the two LAContext members the probe actually uses.
protocol BiometricContextProbing {
    /// Mirrors `LAContext.canEvaluatePolicy(_:error:)`. Tests return
    /// the boolean + optionally populate the inout error.
    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool

    /// Mirrors `LAContext.biometryType`. Only meaningful AFTER
    /// `canEvaluatePolicy` has been called (Apple documents the field
    /// as undefined before the first evaluate call).
    var biometryType: LABiometryType { get }
}

/// Production adapter: thin wrapper around a real `LAContext`.
struct LAContextAdapter: BiometricContextProbing {
    private let context: LAContext

    init(context: LAContext = LAContext()) {
        self.context = context
    }

    func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        context.canEvaluatePolicy(policy, error: error)
    }

    var biometryType: LABiometryType { context.biometryType }
}

/// Stateless classifier with a lazy per-process cache. The first
/// call to `cachedResult` populates the cache from a real
/// `LAContext`; subsequent calls return the same value without
/// re-probing. Cheap to call from a SwiftUI view body.
///
/// The probe is split into a static helper that accepts any
/// `BiometricContextProbing` so tests can pin all three return
/// shapes without depending on the host hardware.
enum BiometricProbe {

    /// Process-wide cache. The probe is hardware-classification only
    /// (no prompt, no UI side-effect), so a single read on first
    /// access is sufficient -- biometric capability does not change
    /// during an installer run.
    private static let _cachedResult: BiometricProbeResult = {
        probe(using: LAContextAdapter())
    }()

    /// Cached production probe result. First read populates the
    /// cache; subsequent reads are O(1). Safe to call from any
    /// thread (Swift `let` static initialisation is thread-safe).
    static var cachedResult: BiometricProbeResult {
        _cachedResult
    }

    /// Convenience: just the modality, without the diagnostic error
    /// string. The Q12 view branch uses this; the log drawer can
    /// inspect `cachedResult.underlyingErrorDescription` if a
    /// customer reports the "wrong" Q12 copy.
    static var cachedModality: BiometricModality {
        cachedResult.modality
    }

    /// Production entry-point. Calls `probe(using:)` against a real
    /// `LAContext` -- bypasses the cache. Prefer `cachedResult` for
    /// view-body reads.
    static func detect() -> BiometricProbeResult {
        probe(using: LAContextAdapter())
    }

    /// Test seam. Tests instantiate a `FakeBiometricContext` (see
    /// BiometricProbeTests) and assert one of the three modality
    /// branches.
    ///
    /// Classification logic:
    ///   1. Ask `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`.
    ///      If false, modality is `.none` -- macOS will prompt for
    ///      password (or Apple Watch on Sequoia+).
    ///   2. If true, read `biometryType`. Map `.touchID` and
    ///      `.faceID` -> .touchID (no Face ID Mac ships today; the
    ///      copy reads fine for any biometric on this Mac).
    ///      Map `.opticID` -> .opticID (visionOS only, never reached
    ///      on macOS hardware in practice).
    ///   3. If `canEvaluatePolicy` returned true but `biometryType`
    ///      reports `.none`, the LAContext is in an inconsistent
    ///      state -- treat as `.none` so the customer reads the safer
    ///      password copy. (We've never seen this in practice but
    ///      the explicit branch keeps the switch exhaustive.)
    static func probe(using context: BiometricContextProbing) -> BiometricProbeResult {
        var error: NSError?
        let canDoBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        let errorDescription = error?.localizedDescription

        guard canDoBiometrics else {
            return BiometricProbeResult(
                modality: .none,
                underlyingErrorDescription: errorDescription
            )
        }

        switch context.biometryType {
        case .touchID, .faceID:
            return BiometricProbeResult(
                modality: .touchID,
                underlyingErrorDescription: nil
            )
        case .opticID:
            return BiometricProbeResult(
                modality: .opticID,
                underlyingErrorDescription: nil
            )
        case .none:
            // Inconsistent state -- canEvaluatePolicy said yes but
            // biometryType is .none. Surface the safer copy.
            return BiometricProbeResult(
                modality: .none,
                underlyingErrorDescription: errorDescription
            )
        @unknown default:
            // Future Apple addition (e.g. some new sensor). Default
            // to the password/passcode copy so we never lie about
            // Touch ID on hardware we don't recognise yet.
            return BiometricProbeResult(
                modality: .none,
                underlyingErrorDescription: errorDescription
            )
        }
    }
}
