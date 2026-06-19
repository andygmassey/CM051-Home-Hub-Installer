import XCTest
@testable import OstlerContactsCore

final class FeatureFlagTests: XCTestCase {

    func testDefaultOffWhenUnset() {
        XCTAssertFalse(FeatureFlag.isEnabled(environment: [:]))
    }

    func testOffForFalsyValues() {
        for v in ["false", "0", "no", "", "  ", "off", "FALSE-ish"] {
            XCTAssertFalse(
                FeatureFlag.isEnabled(
                    environment: [FeatureFlag.envName: v]),
                "expected OFF for \(v.debugDescription)")
        }
    }

    func testOnForTruthyValues() {
        for v in ["true", "TRUE", "1", "yes", " true "] {
            XCTAssertTrue(
                FeatureFlag.isEnabled(
                    environment: [FeatureFlag.envName: v]),
                "expected ON for \(v.debugDescription)")
        }
    }

    func testEnvNameIsTheSpecConstant() {
        XCTAssertEqual(FeatureFlag.envName, "OSTLER_TIDY_CONTACTS_ENABLED")
    }
}
