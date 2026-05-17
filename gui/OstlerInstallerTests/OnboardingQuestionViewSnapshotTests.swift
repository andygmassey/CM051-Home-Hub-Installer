// OnboardingQuestionViewSnapshotTests.swift
//
// Drives OnboardingQuestionView through ImageRenderer for each of
// the four rendering states (text early, text with total known,
// yes/no, back-review). The PNGs land under TMPDIR so the local
// developer can eyeball them, and the test acts as a render-crash
// regression net.
//
// Caveat: ImageRenderer is a headless SwiftUI pipeline with no
// NSWindow attached, so AppKit-backed control styles (TextField
// .roundedBorder, SecureField, Picker .menu, Toggle .switch) fall
// back to a stop-symbol placeholder. The customer-facing render
// in the running .app -- where there is an NSWindow -- is fine.
// We accept that limitation for unit testing; a true visual smoke
// is a manual install on the Studio.

import AppKit
import SwiftUI
import XCTest
@testable import OstlerInstaller

@MainActor
final class OnboardingQuestionViewSnapshotTests: XCTestCase {

    private func render(coordinator: InstallerCoordinator, label: String) throws {
        let view = OnboardingQuestionView()
            .environmentObject(coordinator)
            .frame(width: 880, height: 620)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0

        guard let nsImage = renderer.nsImage else {
            throw XCTSkip("ImageRenderer returned nil (host may not support headless SwiftUI rendering)")
        }
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode PNG from rendered image")
        }

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ostler-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outDir,
            withIntermediateDirectories: true
        )
        let outURL = outDir.appendingPathComponent("onboarding-\(label).png")
        try png.write(to: outURL)
        print("SNAPSHOT: \(outURL.path)")
    }

    /// Mid-flow, Y still unknown (channel_choice not yet answered).
    func testRenderTextPromptEarlyFlow() throws {
        let coord = InstallerCoordinator()
        coord.currentQuestionIndex = 4
        coord.pendingPrompt = InstallerCoordinator.PendingPrompt(
            id: "assistant_name",
            kind: .text,
            title: "Assistant name",
            defaultValue: "Ostler",
            help: "Pick from the suggestions or type your own. This is the name your assistant will respond to.",
            choices: []
        )
        try render(coordinator: coord, label: "text-early")
    }

    /// Mid-flow with Y known: the customer has picked channels and
    /// the iMessage allowlist question is on screen.
    func testRenderTextPromptWithTotalKnown() throws {
        let coord = InstallerCoordinator()
        coord.currentQuestionIndex = 8
        coord.totalQuestionCount = 16
        coord.pendingPrompt = InstallerCoordinator.PendingPrompt(
            id: "imessage_allowed",
            kind: .text,
            title: "Allowed contacts",
            defaultValue: nil,
            help: "Allowlist of phone numbers and Apple ID emails (comma-separated). Ostler only replies to listed contacts; messages from anyone else are ignored. At least one entry required. e.g. +447700900000, you@example.com",
            choices: []
        )
        try render(coordinator: coord, label: "text-with-total")
    }

    /// Yes / no question; verbose tip in the help field.
    func testRenderYesNoPrompt() throws {
        let coord = InstallerCoordinator()
        coord.currentQuestionIndex = 6
        coord.totalQuestionCount = 16
        coord.pendingPrompt = InstallerCoordinator.PendingPrompt(
            id: "email_apple_mail",
            kind: .yesno,
            title: "Read mail via Apple Mail?",
            defaultValue: "Y",
            help: "Reads any account you have added to Apple Mail (iCloud, Gmail, Outlook, etc.) using Full Disk Access. No passwords stored. Recommended for almost everyone.",
            choices: []
        )
        try render(coordinator: coord, label: "yesno")
    }

    /// Back review mode: showing a previous answer read-only with
    /// the review banner.
    func testRenderBackReview() throws {
        let coord = InstallerCoordinator()
        coord.currentQuestionIndex = 8
        coord.totalQuestionCount = 16
        let prior = InstallerCoordinator.PendingPrompt(
            id: "assistant_name",
            kind: .text,
            title: "Assistant name",
            defaultValue: "Ostler",
            help: "Pick from the suggestions or type your own.",
            choices: []
        )
        coord.answerHistory = [
            InstallerCoordinator.AnsweredQuestion(
                index: 4, prompt: prior, answer: "Ostler"
            )
        ]
        coord.backReviewIndex = 0
        try render(coordinator: coord, label: "back-review")
    }
}
