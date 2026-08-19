// OnboardingButtonFooterProofTests.swift
//
// #632 regression net. The Back/Continue footer must sit at a
// CONSTANT viewport-bottom y-position regardless of body length.
//
// History: #503's `ViewThatFits` top-flow regressed this. On short
// prompts the buttons flowed to the end of the (variable-length) body
// copy, so the click target jumped from one question to the next
// (Andy, box-walk #3, 2026-08-05). The fix decouples the input (which
// hugs the body, inside a space-claiming ScrollView) from the
// buttonRow (pinned below it), so the footer y no longer tracks
// content height.
//
// WHY THIS TEST MEASURES PIXELS
// -----------------------------
// The first cut of this file only asserted "the render did not
// crash". That assertion passes on the BROKEN layout too -- verified
// by rendering the pre-fix #503 code through this exact harness on
// 2026-08-06: TEST SUCCEEDED, with Continue sitting at y=430 of 760
// and a wall of dead space beneath it. A net that cannot fail on the
// bug it is named after is not a net.
//
// So these tests locate the oxblood Continue pill IN THE RENDERED
// PIXELS and assert its position. Two independent claims:
//
//   1. ABSOLUTE  -- the pill bottom sits in the bottom ~15% of the
//      viewport. Catches "footer floated up under short copy".
//   2. RELATIVE  -- the short-body and tall-body pills land at the
//      SAME y (within `footerAgreementTolerance`). This is the actual
//      #632 complaint: the target MOVED between questions. A layout
//      that pinned the footer only for tall bodies would satisfy (1)
//      on the tall case and still fail here.
//
// Measuring the pill (rather than the toggle or body copy) is
// deliberate: SwiftUI draws it itself, so it rasterises reliably
// under a headless `ImageRenderer`. AppKit control chrome inside the
// scroll region does NOT rasterise here -- do not add assertions
// about the body copy or the input to this file; they will be
// vacuous. On-box visual confirmation stays part of the installer
// walk.
//
// Set OSTLER_PROOF_DIR to also dump each render as a PNG for eyeball
// review; the path is printed with a `#PROOF_PNG` marker. Under
// `xcodebuild test` the variable must be passed as
// TEST_RUNNER_OSTLER_PROOF_DIR -- a plain shell export does NOT reach
// the test host process, which is how the first version of this file
// appeared to emit PNGs while actually emitting none.

import XCTest
import SwiftUI
import AppKit
@testable import OstlerInstaller

@MainActor
final class OnboardingButtonFooterProofTests: XCTestCase {

    // Render geometry, in points. Matches the installer's content area.
    private let viewportWidth: CGFloat = 620
    private let viewportHeight: CGFloat = 760
    private let renderScale: CGFloat = 2.0

    /// The pill's bottom edge must land within this fraction of the
    /// viewport height from the bottom. The pinned footer sits about
    /// 24pt (`.ostlerSpace3` vertical padding) above the edge, i.e.
    /// ~3%; 15% is loose enough to survive padding tweaks and tight
    /// enough that the #503 regression (bottom edge at 60% of the
    /// viewport, on a two-line body) fails it decisively.
    private let bottomBandFraction: CGFloat = 0.15

    /// Short-body and tall-body footers must agree to within this many
    /// points. They are laid out by the same pinned row, so in
    /// practice they are identical; the tolerance only absorbs
    /// antialiasing at the pill's rounded edge.
    private let footerAgreementTolerance: CGFloat = 2.0

    /// Ostler oxblood, `Color(hex: 0x7A1F1F)` in OstlerTheme.
    private let oxblood = (r: 0x7A, g: 0x1F, b: 0x1F)
    /// Per-channel tolerance when matching the pill's fill. Generous
    /// enough for colour-space conversion, far tighter than the gap to
    /// any other colour on the screen (chassis cream, ink near-black).
    private let colourTolerance = 12

    private func emitPrompt(
        _ coord: InstallerCoordinator,
        id: String,
        kind: String = "text",
        title: String = "Prompt",
        help: String? = nil
    ) {
        var line = "#OSTLER\tPROMPT\tid=\(id)\tkind=\(kind)\ttitle=\(title)"
        if let help = help {
            line += "\thelp=\(help)"
        }
        coord.simulateLineForTests(line)
    }

    /// Renders the view and returns the bottom edge of the lowest
    /// oxblood region, in points from the top of the viewport.
    ///
    /// The "QUESTION N" eyebrow is oxblood too, so the scan ignores
    /// everything in the top half -- the Continue pill is always the
    /// lowest oxblood mass on this screen.
    ///
    /// When OSTLER_PROOF_DIR is set, also writes a PNG for review
    /// (opt-in side effect; no writes in the default/CI path).
    private func continueButtonBottom<V: View>(of view: V, named name: String) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: view.frame(width: viewportWidth, height: viewportHeight)
        )
        renderer.scale = renderScale
        guard let cg = renderer.cgImage else {
            throw XCTSkip("ImageRenderer produced no image (headless environment).")
        }

        try dumpProofPNG(cg, named: name)

        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create RGBA context for pixel scan.")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Scan upward from the bottom; first row containing a run of
        // oxblood wins. A run (not a single pixel) so a stray
        // antialiased pixel cannot set the answer.
        let minimumRun = 8
        for y in stride(from: height - 1, through: height / 2, by: -1) {
            var run = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                if abs(Int(pixels[i]) - oxblood.r) <= colourTolerance,
                   abs(Int(pixels[i + 1]) - oxblood.g) <= colourTolerance,
                   abs(Int(pixels[i + 2]) - oxblood.b) <= colourTolerance,
                   pixels[i + 3] > 200 {
                    run += 1
                    if run >= minimumRun {
                        return CGFloat(y) / renderScale
                    }
                } else {
                    run = 0
                }
            }
        }
        XCTFail("No oxblood Continue pill found in the bottom half of the \(name) render.")
        return -1
    }

    private func dumpProofPNG(_ cg: CGImage, named name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["OSTLER_PROOF_DIR"] else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let url = dirURL.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("#PROOF_PNG\t\(name)\t\(url.path)")
    }

    private func shortBodyView() -> some View {
        let coord = InstallerCoordinator()
        emitPrompt(
            coord,
            id: "filevault_skip",
            kind: "yesno",
            title: "Ready to continue?",
            help: "This is a short two-line prompt body."
        )
        return OnboardingQuestionView().environmentObject(coord)
    }

    private func tallBodyView() -> some View {
        let coord = InstallerCoordinator()
        let longHelp = Array(repeating:
            "Ostler runs entirely on this Mac. Nothing leaves the machine unless you " +
            "explicitly ask it to. This paragraph is repeated to force the body region " +
            "to overflow the available height so the scroll fallback engages.",
            count: 8
        ).joined(separator: " ")
        emitPrompt(
            coord,
            id: "imessage_allowed_contacts",
            kind: "text",
            title: "Which contacts can talk to your assistant?",
            help: longHelp
        )
        return OnboardingQuestionView().environmentObject(coord)
    }

    // Claim 1, short body. The #503 regression put the pill's bottom
    // at ~60% of the viewport here; this is the assertion it fails.
    func testShortBodyFooterSitsInBottomBand() throws {
        let bottom = try continueButtonBottom(of: shortBodyView(), named: "short-yesno")
        let threshold = viewportHeight * (1 - bottomBandFraction)
        XCTAssertGreaterThan(
            bottom, threshold,
            "Continue pill bottom is at y=\(bottom) of \(viewportHeight); a pinned "
            + "footer must be below y=\(threshold). The footer has floated up to "
            + "follow short body copy (#632)."
        )
    }

    // Claim 1, tall body. The tall case passed even before the fix --
    // it is here so the pair proves the pin holds at BOTH extremes,
    // not just the one that always worked.
    func testTallBodyFooterSitsInBottomBand() throws {
        let bottom = try continueButtonBottom(of: tallBodyView(), named: "tall-scrolling")
        let threshold = viewportHeight * (1 - bottomBandFraction)
        XCTAssertGreaterThan(
            bottom, threshold,
            "Continue pill bottom is at y=\(bottom) of \(viewportHeight); a pinned "
            + "footer must be below y=\(threshold)."
        )
    }

    // Claim 2 -- the actual #632 complaint. The click target must not
    // move between one question and the next.
    func testFooterDoesNotMoveBetweenShortAndTallQuestions() throws {
        let short = try continueButtonBottom(of: shortBodyView(), named: "agreement-short")
        let tall = try continueButtonBottom(of: tallBodyView(), named: "agreement-tall")
        XCTAssertEqual(
            short, tall, accuracy: footerAgreementTolerance,
            "Continue pill moved \(abs(short - tall))pt between a short-body and a "
            + "tall-body question (short y=\(short), tall y=\(tall)). The footer "
            + "must be pinned, not flowed after the body (#632)."
        )
    }
}
