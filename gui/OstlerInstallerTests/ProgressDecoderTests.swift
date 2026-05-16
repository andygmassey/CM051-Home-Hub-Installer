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
}
