// ProgressDecoderTests.swift
//
// Pins the marker -> InstallerEvent classification. Key contract per
// #348: a non-marker line returns `.rawLine`, NOT `.log`. The Verbose
// toggle in the Log drawer keys off this distinction to decide whether
// to surface raw subprocess chatter alongside curated #OSTLER LOG
// markers.

import XCTest
@testable import OstlerInstaller

final class ProgressDecoderTests: XCTestCase {

    func testStructuredLogMarkerYieldsLogEvent() {
        let event = ProgressDecoder.decode(
            line: "#OSTLER\tLOG\tlevel=info\tmsg=Hello there"
        )
        guard case .log(let level, let msg) = event else {
            return XCTFail("expected .log, got \(event)")
        }
        XCTAssertEqual(level, "info")
        XCTAssertEqual(msg, "Hello there")
    }

    func testNonMarkerLineYieldsRawLineEvent() {
        // The contract under test: pre-#348 this returned
        // `.log(level: "info", msg: raw)` which the drawer always
        // surfaced, drowning the curated LOG markers. Post-#348 it
        // returns `.rawLine` so the coordinator can gate it behind
        // the Verbose toggle.
        let event = ProgressDecoder.decode(line: "Cloning into 'thing'...")
        guard case .rawLine(let msg) = event else {
            return XCTFail("expected .rawLine, got \(event)")
        }
        XCTAssertEqual(msg, "Cloning into 'thing'...")
    }

    func testRawLineEqualityIsContentBased() {
        XCTAssertEqual(
            ProgressDecoder.decode(line: "abc"),
            InstallerEvent.rawLine(msg: "abc")
        )
        XCTAssertNotEqual(
            ProgressDecoder.decode(line: "abc"),
            InstallerEvent.rawLine(msg: "def")
        )
    }

    func testUnknownMarkerStillYieldsUnknownEvent() {
        // `.unknown` is a different concern from `.rawLine` -- it
        // means "the line LOOKED like a marker but the event name
        // is not in the schema". Stays an `.unknown` event so the
        // drawer can show "Unrecognised marker: ..." instead of
        // silently swallowing.
        let event = ProgressDecoder.decode(line: "#OSTLER\tBOGUS\tx=y")
        guard case .unknown = event else {
            return XCTFail("expected .unknown, got \(event)")
        }
    }

    func testBareOstlerPrefixWithoutTabIsUnknown() {
        // `#OSTLER` alone with no tab + event name is malformed; we
        // route to `.unknown(raw:)` so the drawer surfaces it for
        // diagnosis rather than treating it as raw output.
        let event = ProgressDecoder.decode(line: "#OSTLER")
        guard case .unknown = event else {
            return XCTFail("expected .unknown, got \(event)")
        }
    }

    // MARK: - BW2-2: multi-paragraph value decoding

    func testHelpValueNewlinesSurviveTheWire() {
        // gui_emit percent-encodes newlines ("%0A") and literal percent
        // ("%25") so a multi-paragraph question body survives the
        // tab-separated, newline-anchored marker wire. Pre-BW2-2 the
        // emitter stripped newlines to spaces, flattening every consent /
        // explainer screen into one dense wall of text. This pins the
        // decode half: paragraph breaks, bullets and a literal "%" must
        // all come back intact.
        let wire = "#OSTLER\tPROMPT\tid=consent_spoken\tkind=yesno" +
            "\ttitle=Spoken capture" +
            "\thelp=Turn spoken conversations into text?%0A%0A" +
            "Ostler can transcribe audio you capture.%0A%0A" +
            "• Runs on your Mac%0A• 100%25 private"
        let event = ProgressDecoder.decode(line: wire)
        guard case .prompt(_, _, _, _, let help, _, _) = event else {
            return XCTFail("expected .prompt, got \(event)")
        }
        let body = help ?? ""
        XCTAssertTrue(body.contains("\n\n"), "paragraph break lost")
        XCTAssertTrue(body.contains("• Runs on your Mac"), "bullet lost")
        XCTAssertTrue(body.contains("100% private"),
                      "literal percent did not round-trip")
        XCTAssertFalse(body.contains("%0A"), "sentinel leaked into rendered copy")
        XCTAssertFalse(body.contains("%25"), "sentinel leaked into rendered copy")
    }

    func testValueWithoutSentinelIsUnchanged() {
        // Fast-path guard: values with no "%" must pass through
        // byte-identical (no accidental mangling of ordinary copy).
        let event = ProgressDecoder.decode(
            line: "#OSTLER\tSTEP_BEGIN\tid=docker\ttitle=Installing Docker"
        )
        guard case .stepBegin(_, let title, _, _, _) = event else {
            return XCTFail("expected .stepBegin, got \(event)")
        }
        XCTAssertEqual(title, "Installing Docker")
    }
}
