// ConsentContinueGateTests.swift
//
// F&F tester report (v1.0.125): the consent_third_party screen seeds
// its Yes switch OFF (default "n", a GDPR active opt-in). Pressing
// Continue, or Return, with the switch still off sent "n", and
// install.sh treats "n" on that prompt as a decline: it prints
// "Installation canceled" and ends the install. The customer thought
// they had pressed Continue.
//
// The fix: on every yes/no prompt where "n" ends the install, the
// Continue button is disabled until the switch is ON, with a one-line
// hint under the switch. To stop, the customer uses Quit. The
// terminal (non-GUI) path in install.sh is unchanged.
//
// Three claims, each able to fail on its own:
//   1. RENDERED: the real OnboardingQuestionView draws the Continue
//      pill at full oxblood only when the switch is ON. A disabled
//      pill draws at reduced opacity (OstlerButtonLook), so the pixel
//      scan cannot find it. This is the claim that is red on main.
//   2. PURE: yesnoContinueEnabled(promptId:isOn:) for the gated ids,
//      and for an ungated id (the gate must not spread).
//   3. CONTRACT: the gated set matches install.sh. Every yesno
//      gui_read whose decline reaches gui_cancelled is in the set, and
//      every id in the set is a real yesno gui_read in install.sh.

import XCTest
import SwiftUI
import AppKit
@testable import OstlerInstaller

@MainActor
final class ConsentContinueGateTests: XCTestCase {

    // Same geometry and colour as OnboardingButtonFooterProofTests.
    private let viewportWidth: CGFloat = 620
    private let viewportHeight: CGFloat = 760
    private let renderScale: CGFloat = 2.0
    private let oxblood = (r: 0x7A, g: 0x1F, b: 0x1F)
    private let colourTolerance = 12

    private func view(id: String, defaultValue: String) -> some View {
        let coord = InstallerCoordinator()
        coord.simulateLineForTests(
            "#OSTLER\tPROMPT\tid=\(id)\tkind=yesno\ttitle=Share contacts?\tdefault=\(defaultValue)"
            + "\thelp=Short synthetic body."
        )
        return OnboardingQuestionView().environmentObject(coord)
    }

    /// True when a run of full-oxblood pixels sits in the bottom half
    /// of the render, i.e. an ENABLED Continue pill is drawn.
    private func enabledContinuePillIsDrawn<V: View>(_ v: V) throws -> Bool {
        let renderer = ImageRenderer(
            content: v.frame(width: viewportWidth, height: viewportHeight)
        )
        renderer.scale = renderScale
        guard let cg = renderer.cgImage else {
            throw XCTSkip("ImageRenderer produced no image (headless environment).")
        }
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create RGBA context for pixel scan.")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
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
                    if run >= minimumRun { return true }
                } else {
                    run = 0
                }
            }
        }
        return false
    }

    // MARK: - 1. Rendered

    func testConsentThirdPartyContinueIsDisabledWithTheSwitchOff() throws {
        // install.sh seeds this prompt "n", so the switch renders OFF.
        let drawn = try enabledContinuePillIsDrawn(view(id: "consent_third_party", defaultValue: "n"))
        XCTAssertFalse(drawn,
            "consent_third_party: Continue is enabled with the switch OFF, so Continue/Return "
            + "sends \"n\" and install.sh cancels the install.")
    }

    func testConsentThirdPartyContinueIsEnabledWithTheSwitchOn() throws {
        // Positive control for the scan above: same screen, switch ON.
        let drawn = try enabledContinuePillIsDrawn(view(id: "consent_third_party", defaultValue: "y"))
        XCTAssertTrue(drawn, "consent_third_party: Continue is not enabled with the switch ON.")
    }

    func testUngatedYesNoPromptKeepsContinueEnabledWithTheSwitchOff() throws {
        // whatsapp_consent also seeds "n", but "n" there just skips
        // WhatsApp. Its Continue must stay live with the switch off.
        let drawn = try enabledContinuePillIsDrawn(view(id: "whatsapp_consent", defaultValue: "n"))
        XCTAssertTrue(drawn, "whatsapp_consent: Continue was disabled; the gate spread beyond the cancel prompts.")
    }

    // MARK: - 2. Pure

    func testGatedPromptsNeedTheSwitchOn() {
        for id in ["consent_third_party", "consent_article_9", "perms_ok", "filevault_skip"] {
            XCTAssertFalse(yesnoContinueEnabled(promptId: id, isOn: false), "\(id): Continue enabled with the switch off")
            XCTAssertTrue(yesnoContinueEnabled(promptId: id, isOn: true), "\(id): Continue disabled with the switch on")
        }
    }

    func testUngatedPromptsAreNeverBlocked() {
        for id in ["whatsapp_consent", "consent_spoken_capture", "consent_enrichment", "save_keychain", "reuse_settings"] {
            XCTAssertTrue(yesnoContinueEnabled(promptId: id, isOn: false), "\(id): the gate spread to a prompt whose \"n\" does not end the install")
        }
    }

    func testHintStringIsCatalogued() {
        let key = "onboarding_question.yesno_switch_on_to_continue"
        let text = ViewCopy.shared.string(for: key)
        XCTAssertNotEqual(text, key, "hint key missing from ViewCopy.json; the customer would see a dotted key")
        XCTAssertFalse(text.contains("\u{2014}"), "no em dashes in customer copy")
    }

    // MARK: - 3. Contract with install.sh

    private func installSh() throws -> [String] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OstlerInstallerTests
            .deletingLastPathComponent()   // gui
            .deletingLastPathComponent()   // repo root
        let text = try String(contentsOf: repo.appendingPathComponent("install.sh"), encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    /// (prompt id, line index) for every live `gui_read ... yesno` call.
    private func yesnoReads(_ lines: [String]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        let idPattern = try! NSRegularExpression(pattern: #""([a-z0-9_]+)"\)"\s*$"#)
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.contains("gui_read"), t.contains(" yesno ") else { continue }
            let r = NSRange(line.startIndex..., in: line)
            if let m = idPattern.firstMatch(in: line, range: r), let g = Range(m.range(at: 1), in: line) {
                out.append((String(line[g]), i))
            }
        }
        return out
    }

    func testEveryYesNoPromptWhoseDeclineCancelsIsGated() throws {
        let lines = try installSh()
        let reads = yesnoReads(lines)
        XCTAssertGreaterThan(reads.count, 10, "denominator: the yesno scan found too few gui_read calls; the scan is broken")
        var cancellers: Set<String> = []
        for (id, i) in reads {
            // The decline branch runs up to the next gui_read.
            var j = i + 1
            while j < min(i + 80, lines.count) {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if !t.hasPrefix("#") && t.contains("gui_read") { break }
                if t.hasPrefix("gui_cancelled") { cancellers.insert(id); break }
                j += 1
            }
        }
        // Positive control: the prompt this fix is named after must be found.
        XCTAssertTrue(cancellers.contains("consent_third_party"), "scan did not find consent_third_party's gui_cancelled")
        let missing = cancellers.subtracting(yesnoPromptsWhereNoEndsInstall)
        XCTAssertTrue(missing.isEmpty,
            "yes/no prompts whose \"n\" reaches gui_cancelled but whose GUI Continue still sends \"n\": \(missing.sorted())")
    }

    func testEveryGatedIdIsALiveYesNoPromptInInstallSh() throws {
        let ids = Set(yesnoReads(try installSh()).map { $0.0 })
        let stale = yesnoPromptsWhereNoEndsInstall.subtracting(ids)
        XCTAssertTrue(stale.isEmpty, "gated ids no longer a yesno gui_read in install.sh: \(stale.sorted())")
    }

    // MARK: - Log line

    func testYesNoLogLineCarriesTheValueAndNothingElseDoes() {
        func p(_ id: String, _ kind: PromptKind) -> InstallerCoordinator.PendingPrompt {
            InstallerCoordinator.PendingPrompt(id: id, kind: kind, title: "t", defaultValue: nil,
                                               help: nil, choices: [], error: nil)
        }
        XCTAssertEqual(InstallerCoordinator.sentAnswerLogLine(prompt: p("consent_third_party", .yesno), answer: "n"),
                       "Sent answer for consent_third_party (yesno): n")
        XCTAssertEqual(InstallerCoordinator.sentAnswerLogLine(prompt: p("consent_third_party", .yesno), answer: "y"),
                       "Sent answer for consent_third_party (yesno): y")
        XCTAssertEqual(InstallerCoordinator.sentAnswerLogLine(prompt: p("consent_third_party", .yesno), answer: "x@example.com"),
                       "Sent answer for consent_third_party (yesno): other")
        XCTAssertEqual(InstallerCoordinator.sentAnswerLogLine(prompt: p("user_name", .text), answer: "Sample"),
                       "Sent answer for user_name (text)")
    }
}
