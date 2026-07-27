// OnboardingQuestionSupertextGateTests.swift
//
// QA GATE for the box-walk regression fixed on 2026-07-27: the
// "QUESTION X" supertext (the strap-line rendered by
// OnboardingQuestionView.header()) was being CLIPPED off the top edge
// of the window on question screens whose body copy is taller than the
// fixed ~560pt question pane. The pane had no ScrollView, so tall
// content overflowed and SwiftUI pushed the top of the column -- the
// supertext -- above the visible area. consent_spoken_capture (the
// tallest yes/no consent: intro + "What we ask of you" list + long
// legal note) lost its supertext while its shorter sibling
// consent_third_party kept it -- the SAME code path rendering
// inconsistently screen-to-screen. Reported twice on box-walks.
//
// The fix wraps the question column in a ScrollView (GeometryReader
// minHeight keeps short screens pixel-identical) so the header is
// pinned to the top (scroll offset 0) and always visible.
//
// This gate renders the REAL ContentView window (via NSHostingView,
// which does a true AppKit layout + draw pass -- ImageRenderer cannot
// rasterise ScrollView content) for EVERY question kind the customer
// can answer, forces each body to overflow the pane, and asserts the
// oxblood supertext is present in the top band of the question pane.
// It FAILS for any kind that omits / clips the supertext, so a future
// change that drops the ScrollView (or a new kind that renders its own
// header-less path) trips the gate before it can ship.
//
// Data-driven over PromptKind so a newly-added kind is covered the
// moment it is exercised here.

import XCTest
import SwiftUI
import AppKit
@testable import OstlerInstaller

@MainActor
final class OnboardingQuestionSupertextGateTests: XCTestCase {

    /// A paragraph long enough to push any question body past the
    /// ~560pt pane height, so the pre-fix overflow-clip would fire.
    /// (Kinds with a bespoke body -- e.g. consent_spoken_capture --
    /// ignore this help and are already tall on their own.)
    private static let tallHelp: String = Array(repeating:
        "This is deliberately long body copy used by the supertext gate to force the question pane to overflow its fixed height so the regression would reproduce.",
        count: 20
    ).joined(separator: " ")

    /// Every kind the customer answers, with a representative prompt.
    /// `consent_spoken_capture` is the exact screen from the box-walk
    /// report and is included as its own yes/no case.
    private struct KindCase {
        let label: String
        let id: String
        let kind: String
        let title: String
        let choices: String?
        let usesTallHelp: Bool
    }

    private static let cases: [KindCase] = [
        KindCase(label: "text", id: "gate_text", kind: "text",
                 title: "A text question", choices: nil, usesTallHelp: true),
        KindCase(label: "secret", id: "gate_secret", kind: "secret",
                 title: "A secret question", choices: nil, usesTallHelp: true),
        KindCase(label: "yesno-generic", id: "gate_yesno", kind: "yesno",
                 title: "A yes/no question", choices: nil, usesTallHelp: true),
        // The exact box-walk screen (bespoke tall body, ignores help).
        KindCase(label: "yesno-consent_spoken_capture", id: "consent_spoken_capture", kind: "yesno",
                 title: "Turn spoken conversations into text?", choices: nil, usesTallHelp: false),
        KindCase(label: "choice", id: "gate_choice", kind: "choice",
                 title: "A choice question", choices: "one,two,three", usesTallHelp: true),
        KindCase(label: "acknowledge", id: "gate_ack", kind: "acknowledge",
                 title: "An acknowledgement", choices: nil, usesTallHelp: true),
        KindCase(label: "folder", id: "gate_folder", kind: "folder",
                 title: "A folder question", choices: nil, usesTallHelp: true),
        KindCase(label: "text_with_cancel", id: "gate_twc", kind: "text_with_cancel",
                 title: "A typed-consent question", choices: "INSTALL,CANCEL", usesTallHelp: true),
    ]

    func testSupertextVisibleForEveryQuestionKind() {
        for c in Self.cases {
            let rep = renderPane(for: c)
            XCTAssertTrue(
                oxbloodSupertextInTopBand(rep),
                "The \"QUESTION X\" supertext is MISSING from the top of the pane for kind=\(c.kind) (\(c.label)). "
                + "A tall body must not clip the supertext off the top of the window."
            )
        }
    }

    // MARK: - Rendering

    /// Renders the real installer window for one question kind and
    /// returns a bitmap of the drawn pixels. Uses NSHostingView +
    /// cacheDisplay so the ScrollView (and its scroll-offset-0 top
    /// anchoring) actually lays out and draws.
    private func renderPane(for c: KindCase) -> NSBitmapImageRep {
        let coord = InstallerCoordinator()
        coord.permissionsIntroState = .complete
        coord.licenseVerified = true
        // Give the header a real "QUESTION N" index by walking one
        // prior prompt, then emit the case under test.
        emit(coord, id: "channel_choice", kind: "choice", title: "Pick channels")
        coord.applyAnswerForTests(promptId: "channel_choice", answer: "3")
        emit(coord, id: c.id, kind: c.kind, title: c.title,
             help: c.usesTallHelp ? Self.tallHelp : nil, choices: c.choices)

        let host = NSHostingView(rootView: ContentView().environmentObject(coord))
        host.frame = NSRect(x: 0, y: 0, width: 880, height: 620)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func emit(_ coord: InstallerCoordinator, id: String, kind: String,
                      title: String, help: String? = nil, choices: String? = nil) {
        var line = "#OSTLER\tPROMPT\tid=\(id)\tkind=\(kind)\ttitle=\(title)"
        if let help = help { line += "\thelp=\(help)" }
        if let choices = choices { line += "\tchoices=\(choices)" }
        coord.simulateLineForTests(line)
    }

    // MARK: - Pixel probe

    /// True when a pixel matching the Oxblood strap colour (0x7A1F1F)
    /// appears in the top band of the question pane (right of the
    /// 260pt sidebar). The supertext is the only Oxblood element in
    /// that band -- the title is Ink, the body is muted grey, and the
    /// Oxblood Continue button / links sit far below.
    private func oxbloodSupertextInTopBand(_ rep: NSBitmapImageRep) -> Bool {
        // Derive the backing scale from the rep itself -- in a headless
        // test the bitmap may be 1x (880px) rather than 2x (1760px).
        let sx = CGFloat(rep.pixelsWide) / 880.0
        let sy = CGFloat(rep.pixelsHigh) / 620.0
        // Question pane starts after the 260pt sidebar + 1pt divider.
        let minX = Int(261 * sx)
        // Supertext strap sits within the first ~48pt of the pane.
        let maxY = Int(48 * sy)
        let width = rep.pixelsWide
        let height = min(rep.pixelsHigh, maxY)
        var y = 0
        while y < height {
            var x = minX
            while x < width {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    let r = color.redComponent * 255
                    let g = color.greenComponent * 255
                    let b = color.blueComponent * 255
                    // Oxblood 0x7A1F1F ≈ (122, 31, 31): dark, strongly
                    // red-dominant. Tolerant band, anti-aliased edges
                    // included, but excludes ink (near-black, r≈g≈b)
                    // and chassis (near-white).
                    if r > 80 && r < 175 && g < 85 && b < 85 && r > g + 35 && r > b + 35 {
                        return true
                    }
                }
                x += 1
            }
            y += 1
        }
        return false
    }
}
