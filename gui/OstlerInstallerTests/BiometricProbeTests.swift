// BiometricProbeTests.swift
//
// Pins the three modality branches of BiometricProbe.probe(using:)
// using a synthetic LAContext-shaped double. The probe is called
// from OnboardingQuestionView's Q12 (passkey_ack) branch and decides
// whether the customer reads "Touch ID" or "login password" copy --
// a wrong classification means the LAUNCH BLOCKER copy bug returns.
//
// Synthetic test fixture per Andy's locked rule
// (feedback_synthetic_fixtures_no_real_data_default.md): never any
// real LAContext, never any real hardware. The `FakeBiometricContext`
// returns whatever the test sets up.

import XCTest
import LocalAuthentication
@testable import OstlerInstaller

final class BiometricProbeTests: XCTestCase {

    // MARK: - Synthetic fixture

    /// Stand-in for `LAContext` that satisfies `BiometricContextProbing`
    /// without ever touching the real LocalAuthentication framework.
    /// Tests configure the two surfaces directly.
    private final class FakeBiometricContext: BiometricContextProbing {
        let canEvaluateReturn: Bool
        let canEvaluateError: NSError?
        let biometryType: LABiometryType

        init(
            canEvaluate: Bool,
            error: NSError? = nil,
            biometryType: LABiometryType = .none
        ) {
            self.canEvaluateReturn = canEvaluate
            self.canEvaluateError = error
            self.biometryType = biometryType
        }

        func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
            XCTAssertEqual(
                policy,
                .deviceOwnerAuthenticationWithBiometrics,
                "Probe must ask the biometrics-only policy; the .deviceOwnerAuthentication policy would mis-report Macs that can fall back to password."
            )
            if let e = canEvaluateError {
                error?.pointee = e
            }
            return canEvaluateReturn
        }
    }

    // MARK: - Modality: Touch ID

    func testProbeReportsTouchIDWhenBiometryTypeIsTouchID() {
        let fake = FakeBiometricContext(
            canEvaluate: true,
            biometryType: .touchID
        )

        let result = BiometricProbe.probe(using: fake)

        XCTAssertEqual(result.modality, .touchID,
            "MacBook Air/Pro with built-in Touch ID, or a Mac Studio with a paired Magic Keyboard with Touch ID, must classify as .touchID so the customer reads the Touch ID copy.")
        XCTAssertNil(result.underlyingErrorDescription,
            "A successful biometrics probe should not surface a diagnostic error string.")
    }

    func testProbeMapsFaceIDToTouchIDModality() {
        // Face ID is not on any Mac today, but if Apple ships a Face
        // ID Mac in v1.x the same "biometric on this Mac" copy is
        // honest. Pinning the mapping so a future biometry-type
        // expansion doesn't silently mis-route to .none.
        let fake = FakeBiometricContext(
            canEvaluate: true,
            biometryType: .faceID
        )

        let result = BiometricProbe.probe(using: fake)

        XCTAssertEqual(result.modality, .touchID,
            ".faceID should map to the .touchID copy branch (same modality category).")
    }

    // MARK: - Modality: Optic ID

    func testProbeReportsOpticIDWhenBiometryTypeIsOpticID() {
        // visionOS-only in practice; the macOS build never reaches
        // this branch on real hardware, but the enum exposes the
        // case so we must handle it exhaustively.
        let fake = FakeBiometricContext(
            canEvaluate: true,
            biometryType: .opticID
        )

        let result = BiometricProbe.probe(using: fake)

        XCTAssertEqual(result.modality, .opticID,
            ".opticID hardware must classify as .opticID so the catalogue Optic ID copy is rendered.")
    }

    // MARK: - Modality: none

    func testProbeReportsNoneWhenCanEvaluatePolicyReturnsFalse() {
        // The Mac Studio / Mac Mini / Mac Pro / standard iMac path
        // (no Magic Keyboard with Touch ID paired). This is the
        // path the LAUNCH BLOCKER originally crashed against.
        let syntheticError = NSError(
            domain: LAErrorDomain,
            code: LAError.biometryNotAvailable.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Biometry is not available on this device."]
        )
        let fake = FakeBiometricContext(
            canEvaluate: false,
            error: syntheticError,
            biometryType: .none
        )

        let result = BiometricProbe.probe(using: fake)

        XCTAssertEqual(result.modality, .none,
            "When LAContext refuses the biometrics policy, the modality MUST be .none so the customer reads the password/Apple-Watch copy, not the Touch ID copy.")
        XCTAssertNotNil(result.underlyingErrorDescription,
            "When LAContext returns an error, the probe should preserve the diagnostic string for log-drawer triage.")
        XCTAssertEqual(
            result.underlyingErrorDescription,
            "Biometry is not available on this device.",
            "Diagnostic string should pass through verbatim."
        )
    }

    func testProbeReportsNoneWhenBiometryTypeIsNoneDespiteCanEvaluateTrue() {
        // Pathological state: LAContext said yes to the biometrics
        // policy but biometryType reads .none. We have never seen
        // this in practice, but the safer branch is "no biometric"
        // so the customer reads the password copy.
        let fake = FakeBiometricContext(
            canEvaluate: true,
            biometryType: .none
        )

        let result = BiometricProbe.probe(using: fake)

        XCTAssertEqual(result.modality, .none,
            "Inconsistent LAContext state (canEvaluate=true + biometryType=.none) must route to the safer .none copy branch.")
    }

    // MARK: - Smoke test: production cache path

    func testCachedResultReturnsConsistentValueAcrossReads() {
        // The cache is process-wide and lazy. Two reads must return
        // the same value (no re-probe drift between view re-renders).
        let first = BiometricProbe.cachedResult
        let second = BiometricProbe.cachedResult

        XCTAssertEqual(first.modality, second.modality,
            "Cached modality must be stable across reads -- view re-renders would otherwise see a flapping value.")
    }
}
