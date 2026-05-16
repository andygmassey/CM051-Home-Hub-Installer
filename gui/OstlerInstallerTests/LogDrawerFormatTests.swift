// LogDrawerFormatTests.swift
//
// Pins the byte layout of the "Copy log" button output. Customers paste
// these lines into support emails; the format must stay grep-friendly
// across releases. The view itself is exercised by manual smoke -- this
// test covers the pure-function buffer formatter.

import XCTest
@testable import OstlerInstaller

final class LogDrawerFormatTests: XCTestCase {

    private func makeLine(level: String, text: String, hms: String) -> InstallerCoordinator.LogLine {
        // Synthesise a Date with hour:minute:second pinned by parsing
        // an ISO-8601 string. Day / month / year are arbitrary because
        // the formatter only reads HH:mm:ss.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let date = iso.date(from: "2026-05-17T\(hms)Z")!
        return InstallerCoordinator.LogLine(level: level, text: text, timestamp: date)
    }

    func testEmptyBufferProducesEmptyString() {
        XCTAssertEqual(LogDrawerView.formatBuffer([]), "")
    }

    func testSingleLineCarriesTimestampLevelAndText() {
        // GMT-aware formatter: format the input timestamp in the local
        // zone the runtime will display in, so the test isn't brittle
        // to the CI runner's TZ. We assert the SHAPE (3 segments split
        // by 2 spaces) rather than the literal hour.
        let line = makeLine(level: "info", text: "→ Hello", hms: "12:34:56")
        let out = LogDrawerView.formatBuffer([line])
        let parts = out.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 4,
                       "format should be HH:mm:ss<SP><SP>[LEVEL]<SP>text; got: \(out)")
        XCTAssertTrue(out.contains("[INFO ]"),
                      "level should be 5-wide upper-case in brackets; got: \(out)")
        XCTAssertTrue(out.hasSuffix("→ Hello"),
                      "trailing text must be the line.text verbatim; got: \(out)")
    }

    func testWarnAndErrorLevelsRender5Wide() {
        let warn = makeLine(level: "warn", text: "wat", hms: "00:00:00")
        let error = makeLine(level: "error", text: "boom", hms: "00:00:00")
        XCTAssertTrue(LogDrawerView.formatBuffer([warn]).contains("[WARN ]"))
        XCTAssertTrue(LogDrawerView.formatBuffer([error]).contains("[ERROR]"))
    }

    func testMultipleLinesJoinedByLF() {
        let a = makeLine(level: "info", text: "first", hms: "01:00:00")
        let b = makeLine(level: "warn", text: "second", hms: "01:00:01")
        let out = LogDrawerView.formatBuffer([a, b])
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("first"))
        XCTAssertTrue(lines[1].hasSuffix("second"))
    }
}
