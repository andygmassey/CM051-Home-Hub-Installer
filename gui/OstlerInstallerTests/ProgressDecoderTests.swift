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

    // MARK: - #201: bare STEP marker

    func testBareStepMarkerYieldsStepEventWithNameAsId() {
        // #201 (v1.0.13.1 box-walk, 2026-08-01): install.sh emits
        //   #OSTLER<TAB>STEP<TAB>name=permissions_briefing<TAB>total_permissions=10
        // for the "10 macOS popups coming up" walk-through between the
        // setup_questions PHASE and the first install stepBegin. Pre-#201
        // this fell through to `.unknown` and the sidebar stayed stuck on
        // "A few questions" while install.sh had already moved on. The
        // decoder must:
        //   - route the marker to `.step` (not `.unknown`)
        //   - lift `name=` out as the step id
        //   - keep the remaining k=v pairs in `metadata` so the coordinator
        //     can render them as an optional sidebar subtitle
        //   - NOT leave a residual `name` key in `metadata` (that would
        //     round-trip as a bogus subtitle line "name=...")
        let event = ProgressDecoder.decode(
            line: "#OSTLER\tSTEP\tname=permissions_briefing\ttotal_permissions=10"
        )
        guard case .step(let id, let metadata) = event else {
            return XCTFail("expected .step, got \(event)")
        }
        XCTAssertEqual(id, "permissions_briefing")
        XCTAssertEqual(metadata, ["total_permissions": "10"])
        XCTAssertNil(metadata["name"], "name= key must not leak into metadata dict")
    }

    func testBareStepMarkerWithoutMetadataYieldsEmptyDict() {
        // Minimal shape: just `name=`, no auxiliary pairs. `metadata`
        // is present-but-empty; the coordinator uses `isEmpty` to decide
        // whether to render a subtitle so the empty-dict path must be
        // honest.
        let event = ProgressDecoder.decode(line: "#OSTLER\tSTEP\tname=foo")
        guard case .step(let id, let metadata) = event else {
            return XCTFail("expected .step, got \(event)")
        }
        XCTAssertEqual(id, "foo")
        XCTAssertTrue(metadata.isEmpty)
    }

    func testBareStepMarkerWithoutNameFallsBackToQuestionMark() {
        // Defensive: a malformed STEP marker with no `name=` field must
        // still return `.step`, not `.unknown`, so the coordinator's
        // event-count telemetry treats it as a STEP that arrived in a
        // bad shape (surfaces "?" as the id in the log). Matches the
        // `id=kv["id"] ?? "?"` fallback stepBegin uses.
        let event = ProgressDecoder.decode(line: "#OSTLER\tSTEP\tfoo=bar")
        guard case .step(let id, let metadata) = event else {
            return XCTFail("expected .step, got \(event)")
        }
        XCTAssertEqual(id, "?")
        XCTAssertEqual(metadata, ["foo": "bar"])
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
