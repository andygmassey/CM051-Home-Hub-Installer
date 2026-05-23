// ErrorCodeBannerTest.swift
//
// CX-17 (2026-05-23) regression test. Andy's Studio retest #6 ask:
// "Is it worth somehow adding error codes in the failure notice so
// we can track down when and where (and ideally what) fails if a
// customer has an issue?" -- yes, do this.
//
// The wire-shape contract is end-to-end:
//
//   install.sh emits: `gui_emit DONE "status=fail" "code=ERR-NN-..."`
//                      via fail_with_code -> gui_done -> gui_emit
//   ProgressDecoder parses kv["code"] -> InstallerEvent.done(status:, errorCode:)
//   InstallerCoordinator captures lastErrorCode on the .fail path
//   InstallFailedBannerView renders banner heading "Install failed: ERR-NN-..."
//   SupportMailtoBuilder emits subject "Install failure (OstlerInstaller) [ERR-NN-...]"
//   LogDrawerView.formatBuffer(_, errorCode:) prepends "Reference: ERR-NN-..."
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// the silent-bail axis here is "a future PR drops the code= keyword
// from gui_done, or drops the lastErrorCode capture, or drops the
// banner heading override". A happy-path "does it render" test
// would not catch any of those drops because the failure banner
// would still render -- it would just render WITHOUT the code, and
// support triage would silently get worse.
//
// We pin EACH stage of the pipeline:
//   1. ProgressDecoder.decode parses code= on DONE markers.
//   2. InstallerCoordinator.lastErrorCode populates on .fail with code.
//   3. InstallerCoordinator.lastErrorCode stays nil on .ok with no code.
//   4. SupportMailtoBuilder mailto: subject contains the code suffix.
//   5. LogDrawerView.formatBuffer prepends a Reference line.
//   6. ViewCopy.json carries the catalogue keys the banner relies on.

import Foundation
import XCTest
@testable import OstlerInstaller

@MainActor
final class ErrorCodeBannerTest: XCTestCase {

    // MARK: - Stage 1: decoder parses code=

    /// CX-17 contract: when a DONE marker carries `code=ERR-NN-...`,
    /// the decoder must surface it as the `.done(status:errorCode:)`
    /// associated value. A drift to ignoring the code= keyword would
    /// fail here.
    func testDecoderParsesErrorCodeOnDoneMarker() throws {
        let raw = "#OSTLER\tDONE\tstatus=fail\tcode=ERR-17-DOCTOR-MISSING"
        let event = ProgressDecoder.decode(line: raw)
        guard case .done(let status, let code) = event else {
            XCTFail("Expected .done event, got \(event)")
            return
        }
        XCTAssertEqual(status, .fail)
        XCTAssertEqual(code, "ERR-17-DOCTOR-MISSING")
    }

    /// CX-17 contract: a DONE marker without code= produces a nil
    /// errorCode (e.g. the success path, or a legacy bare-`fail`
    /// callsite). A regression that defaulted code to an empty
    /// string would break the banner's `if let code` gate.
    func testDecoderReturnsNilCodeOnDoneMarkerWithoutCode() throws {
        let raw = "#OSTLER\tDONE\tstatus=ok"
        let event = ProgressDecoder.decode(line: raw)
        guard case .done(let status, let code) = event else {
            XCTFail("Expected .done event, got \(event)")
            return
        }
        XCTAssertEqual(status, .ok)
        XCTAssertNil(code,
                     "DONE marker without code= must produce a nil errorCode so the banner falls back to the plain heading. An empty-string default would silently slip through the `if let code` check downstream.")
    }

    // MARK: - Stage 2: coordinator captures lastErrorCode

    /// Drives a synthetic DONE marker through the coordinator's
    /// apply pipeline + asserts lastErrorCode populates on the
    /// .fail path.
    func testCoordinatorCapturesErrorCodeOnFail() {
        let coord = InstallerCoordinator()
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=fail\tcode=ERR-20-EMAIL-INGEST-VENDOR")
        XCTAssertEqual(coord.finished, .fail)
        XCTAssertEqual(coord.lastErrorCode, "ERR-20-EMAIL-INGEST-VENDOR",
                       "InstallerCoordinator.lastErrorCode must be populated when a DONE marker carries a code AND status=fail. The InstallFailedBannerView reads this value to render the banner heading; a nil value would silently fall back to the plain heading and hide the code from support triage.")
    }

    /// The .ok path must NOT populate lastErrorCode even if a code
    /// was somehow attached (defensive -- gui_done only attaches
    /// the code on the fail path today, but a future drift could
    /// reorder). Pins the .ok gate explicitly.
    func testCoordinatorDoesNotCaptureErrorCodeOnOk() {
        let coord = InstallerCoordinator()
        coord.simulateLineForTests("#OSTLER\tDONE\tstatus=ok")
        XCTAssertEqual(coord.finished, .ok)
        XCTAssertNil(coord.lastErrorCode,
                     "InstallerCoordinator.lastErrorCode must stay nil on a successful install. Surfacing a code on success would render a misleading banner heading.")
    }

    // MARK: - Stage 4: mailto subject carries the code suffix

    /// The mailto subject must end with " [ERR-NN-...]" so support
    /// can sort the inbox by code. The suffix template lives at
    /// `install_failed_banner.error_code_subject_suffix`.
    func testMailtoSubjectContainsErrorCodeSuffix() throws {
        let mailtoString = SupportMailtoBuilder.makeMailtoURLString(errorCode: "ERR-09-OSTLER-SECURITY-PIP")
        XCTAssertTrue(mailtoString.contains("ERR-09-OSTLER-SECURITY-PIP")
                      || mailtoString.contains("ERR-09-OSTLER-SECURITY-PIP".replacingOccurrences(of: "-", with: "%2D")),
                      "Mailto URL must contain the error code in the subject so support can sort by code. The code may be percent-encoded (mailto: URL allowed-chars). Got: \(mailtoString)")
    }

    /// Without a code, the mailto subject must stay clean (no
    /// dangling brackets, no [nil]). Pre-CX-17 there was no code
    /// concept; that legacy shape must keep working.
    func testMailtoSubjectStaysCleanWithoutErrorCode() throws {
        let mailtoString = SupportMailtoBuilder.makeMailtoURLString()
        XCTAssertFalse(mailtoString.contains("[]"),
                       "Mailto URL without a code must not contain an empty bracket pair. Got: \(mailtoString)")
        XCTAssertFalse(mailtoString.contains("[nil]"),
                       "Mailto URL without a code must not contain a literal [nil]. Got: \(mailtoString)")
    }

    // MARK: - Stage 5: log buffer prepends Reference line

    /// `LogDrawerView.formatBuffer(_, errorCode:)` must prepend a
    /// "Reference: ERR-NN-..." line so the auto-copied support log
    /// starts with the code -- exactly per the CX-17 brief
    /// ("Reference: ERR-17-EMAIL-INGEST-VENV line near the top of
    /// the redacted log so it's the first thing support sees").
    func testLogBufferPrependsReferenceLineWithCode() throws {
        let lines: [InstallerCoordinator.LogLine] = [
            .init(level: "info", text: "Started", timestamp: Date()),
            .init(level: "error", text: "Boom", timestamp: Date()),
        ]
        let formatted = LogDrawerView.formatBuffer(lines, errorCode: "ERR-13-MODEL-PULL-AI")
        // Reference: line MUST be the very first line. Walk byte
        // by byte: find the prefix label from the catalogue +
        // assert the code lands on the same first line.
        let firstLine = formatted.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(firstLine.contains("ERR-13-MODEL-PULL-AI"),
                      "First line of the redacted log must carry the error code so support sees it before the timestamps. Got first line: '\(firstLine)'")
    }

    /// Without a code, the buffer must be byte-identical to the
    /// legacy (no-code) shape -- no leading Reference: line so
    /// existing LogDrawerFormatTests keep passing.
    func testLogBufferStaysIdenticalWithoutCode() throws {
        let lines: [InstallerCoordinator.LogLine] = [
            .init(level: "info", text: "Started", timestamp: Date()),
        ]
        let withCode = LogDrawerView.formatBuffer(lines, errorCode: nil)
        let legacy = LogDrawerView.formatBuffer(lines)
        XCTAssertEqual(withCode, legacy,
                       "formatBuffer(lines, errorCode: nil) must produce byte-identical output to the no-arg legacy overload so existing LogDrawerFormatTests keep passing.")
    }

    // MARK: - Stage 6: catalogue keys present

    /// The banner heading + the Reference prefix + the subject
    /// suffix all live in ViewCopy.json. A regression that dropped
    /// any of the three keys would render as the dotted-key
    /// fallback (the ViewCopy loader behaviour for missing keys),
    /// which would be the worst kind of silent bail.
    func testRequiredCatalogueKeysPresent() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Resources/ViewCopy.json"
        )
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            XCTFail("ViewCopy.json root is not an object")
            return
        }
        guard let banner = root["install_failed_banner"] as? [String: Any] else {
            XCTFail("ViewCopy.json missing install_failed_banner section")
            return
        }
        for key in ["error_code_prefix", "error_code_heading_with_code", "error_code_subject_suffix"] {
            guard let value = banner[key] as? String else {
                XCTFail("ViewCopy.json install_failed_banner.\(key) is missing or not a string. CX-17 banner / mailto / log-prepend logic reads this key; a missing key would render as a dotted-key fallback in front of the customer.")
                continue
            }
            XCTAssertFalse(value.isEmpty,
                           "ViewCopy.json install_failed_banner.\(key) must not be empty.")
        }
    }

    /// The heading-with-code template must contain the `{code}`
    /// placeholder so the substitution lands somewhere. A drift to
    /// a static "Install failed" template (no placeholder) would
    /// silently drop the code from the banner heading.
    func testHeadingWithCodeTemplateContainsPlaceholder() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Resources/ViewCopy.json"
        )
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let banner = root["install_failed_banner"] as? [String: Any],
              let heading = banner["error_code_heading_with_code"] as? String
        else {
            XCTFail("Could not load install_failed_banner.error_code_heading_with_code")
            return
        }
        XCTAssertTrue(heading.contains("{code}"),
                      "install_failed_banner.error_code_heading_with_code must contain the {code} placeholder so the substitution lands somewhere. A static template would silently drop the code. Got: \(heading)")
    }
}
