// DeviceLimitReachedViewSnapshotTests.swift
//
// Renders DeviceLimitReachedView to a PNG via SwiftUI's ImageRenderer
// so the PR body can carry a visual of the limit-reached state. Not a
// regression test -- there is no expected-PNG fixture to diff against;
// rebuilding the view will rebuild the snapshot.
//
// The PNG lands under TMPDIR and the path is printed to stdout for the
// developer running the test locally to pick up. CI does not need to
// preserve the artefact -- this is a one-shot capture for PR review.

import AppKit
import SwiftUI
import XCTest
@testable import OstlerInstaller

@MainActor
final class DeviceLimitReachedViewSnapshotTests: XCTestCase {

    func testRenderDeviceLimitReachedToPNG() throws {
        let view = DeviceLimitReachedView(
            licenseId: "8c7e3f9a-1234-4abc-9def-0123456789ab",
            maxFingerprints: 3,
            registeredCount: 3
        )
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
        let outURL = outDir.appendingPathComponent("device-limit-reached.png")
        try png.write(to: outURL)
        print("SNAPSHOT: \(outURL.path)")
    }
}
