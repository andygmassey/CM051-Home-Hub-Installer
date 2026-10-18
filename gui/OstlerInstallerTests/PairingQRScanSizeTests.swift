// PairingQRScanSizeTests.swift
//
// The install-complete pairing QR was hard to scan: level Q (version 11,
// 61 modules for a ~164-byte envelope) stretched to 128pt, i.e. 2.03pt per
// module, uneven, about 3cm across, with only the generator's one-module
// margin as a quiet zone.
//
// Every assertion here reads the RENDERED BITMAP or a DECODE of it, not the
// renderer's own description of itself: a struct field saying "M" proves
// nothing about the pixels the customer's camera sees.

import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import OstlerInstaller

@MainActor
final class PairingQRScanSizeTests: XCTestCase {

    /// Synthetic §3.3-shaped envelope, exactly 164 bytes. Reserved values only.
    static let envelope: String = {
        var s = #"{"v":1,"hub":"hub-example.local","port":8000,"code":"EXAMPLE-0000-0000","pk":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","exp":1760000000,"sig":""#
        while s.utf8.count < 162 { s += "A" }
        return s + #""}"#
    }()

    private struct Bitmap {
        let width: Int, height: Int, px: [UInt8]   // row 0 = top
        func dark(_ x: Int, _ y: Int) -> Bool { px[y * width + x] < 128 }
    }

    private func bitmap(_ image: NSImage) throws -> (CGImage, Bitmap) {
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        var px = [UInt8](repeating: 255, count: cg.width * cg.height)
        let ctx = try XCTUnwrap(CGContext(
            data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (cg, Bitmap(width: cg.width, height: cg.height, px: px))
    }

    private func render(backingScale: Int = 2) throws -> InstallCompleteView.QRRender {
        XCTAssertEqual(Self.envelope.utf8.count, 164, "fixture must be the 164-byte envelope")
        return try XCTUnwrap(InstallCompleteView.makeQR(
            payload: Self.envelope,
            minSidePoints: InstallCompleteView.pairingQRMinSidePoints,
            backingScale: backingScale))
    }

    private func decode(_ cg: CGImage) throws -> CIQRCodeFeature {
        let det = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                           options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let hits = det.features(in: CIImage(cgImage: cg)).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(hits.count, 1, "exactly one QR must be found in the rendered image")
        return try XCTUnwrap(hits.first)
    }

    func testPairingQRIsLevelMVersion9() throws {
        let r = try render()
        let (cg, _) = try bitmap(r.image)
        let f = try decode(cg)
        let d = try XCTUnwrap(f.symbolDescriptor, "decoder returned no symbol descriptor")
        XCTAssertEqual(d.errorCorrectionLevel, .levelM, "pairing QR must be error-correction level M")
        XCTAssertEqual(d.symbolVersion, 9, "164 bytes at level M is version 9")
        XCTAssertEqual(r.modules, 53, "version 9 is 53 modules")
    }

    func testModuleScaleIsAnIntegerNumberOfPoints() throws {
        let r = try render()
        let (_, b) = try bitmap(r.image)
        let total = r.modules + 2 * r.quietZoneModules
        let pointsPerModule = Double(r.image.size.width) / Double(total)
        XCTAssertEqual(pointsPerModule, pointsPerModule.rounded(), accuracy: 0,
                       "points per module must be an integer, got \(pointsPerModule)")
        XCTAssertEqual(b.width % total, 0, "bitmap pixels must divide evenly into modules")
        // The top-left finder pattern's dark top edge is exactly 7 modules long.
        let pxPerModule = b.width / total
        let q = r.quietZoneModules * pxPerModule
        var run = 0
        while b.dark(q + run, q) { run += 1 }
        XCTAssertEqual(run, 7 * pxPerModule, "finder edge must be 7 whole modules wide")
    }

    func testRenderedSizeIsAtLeast200Points() throws {
        let r = try render()
        XCTAssertGreaterThanOrEqual(r.image.size.width, 200, "rendered QR is \(r.image.size.width)pt")
        XCTAssertEqual(r.image.size.width, r.image.size.height)
        XCTAssertEqual(CGFloat(r.sidePoints), r.image.size.width)
        // The panel must hold it without scaling it down.
        XCTAssertGreaterThanOrEqual(InstallCompleteView.pairingPanelSide(for: r), r.image.size.width)
    }

    func testQuietZoneIsAtLeastFourModulesOnEverySide() throws {
        let r = try render()
        let (_, b) = try bitmap(r.image)
        let pxPerModule = b.width / (r.modules + 2 * r.quietZoneModules)
        var top = b.height, left = b.width, bottom = -1, right = -1
        for y in 0..<b.height { for x in 0..<b.width where b.dark(x, y) {
            top = min(top, y); left = min(left, x); bottom = max(bottom, y); right = max(right, x)
        } }
        XCTAssertGreaterThan(bottom, top, "no dark pixels at all: the predicate cannot see the symbol")
        let margins = [top, left, b.height - 1 - bottom, b.width - 1 - right]
        for m in margins {
            XCTAssertGreaterThanOrEqual(m / pxPerModule, 4,
                "quiet zone \(Double(m) / Double(pxPerModule)) modules, margins px \(margins)")
        }
    }

    func testBlackOnWhiteRegardlessOfTheme() throws {
        let r = try render()
        let (_, b) = try bitmap(r.image)
        XCTAssertTrue(b.px.allSatisfy { $0 == 0 || $0 == 255 },
                      "every pixel must be pure black or pure white (no resampling, no tint)")
        XCTAssertEqual(b.px[0], 255, "corner (quiet zone) must be white")
    }

    func testDecodesBackToTheSamePayload() throws {
        for scale in [1, 2] {
            let r = try render(backingScale: scale)
            let (cg, _) = try bitmap(r.image)
            XCTAssertEqual(try decode(cg).messageString, Self.envelope, "backing scale \(scale)")
        }
        // Control: a different payload must decode to ITSELF, not to the fixture.
        let other = try XCTUnwrap(InstallCompleteView.makeQR(payload: "https://example.com/control",
                                                            minSidePoints: 120))
        let (cg, _) = try bitmap(other.image)
        XCTAssertEqual(try decode(cg).messageString, "https://example.com/control")
    }

    /// Visual proof for the PR: the install-complete screen with the QR.
    /// Writes a PNG under TMPDIR and prints its path; asserts nothing visual.
    func testRenderInstallCompleteScreenToPNG() throws {
        let r = try render()
        let view = InstallCompleteView(previewPairEnvelope: Self.envelope)
            .environmentObject(InstallerCoordinator())
            .frame(width: 620, height: 1200)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let ns = renderer.nsImage, let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("ImageRenderer returned nil (host cannot render SwiftUI headless)")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ostler-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("install-complete-pairing-qr.png")
        try png.write(to: url)
        print("SNAPSHOT: \(url.path) qr_side_pt=\(r.sidePoints) pt_per_module=\(r.pointsPerModule)")
    }
}
