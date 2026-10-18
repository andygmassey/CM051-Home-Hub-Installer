import XCTest
@testable import OstlerInstaller

/// "Open Your Wiki" did nothing on every walk from v1.0.100 to v1.0.105: it
/// opened the Ostler.app bundle, which only raises an already-running Hub on
/// whatever page it last showed. The button must use the Hub's deep link.
final class OpenWikiDeepLinkTests: XCTestCase {
    func testTheWikiButtonTargetsTheHubDeepLink() {
        XCTAssertEqual(InstallCompleteView.wikiDeepLink, "ostler://wiki")
        XCTAssertEqual(URL(string: InstallCompleteView.wikiDeepLink)?.scheme, "ostler")
    }

    func testOpenWikiTriesTheDeepLinkBeforeTheBundle() throws {
        let here = URL(fileURLWithPath: #filePath)
        let view = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OstlerInstaller/Views/InstallCompleteView.swift")
        let src = try String(contentsOf: view, encoding: .utf8)
        guard let start = src.range(of: "private func openWiki()") else {
            return XCTFail("openWiki() not found; this test must be updated with it")
        }
        let body = String(src[start.lowerBound...].prefix(600))
        let link = body.range(of: "wikiDeepLink")
        let bundle = body.range(of: "file:///Applications/Ostler.app")
        XCTAssertNotNil(link, "openWiki must open the deep link")
        if let l = link, let b = bundle {
            XCTAssertLessThan(l.lowerBound, b.lowerBound, "the bundle is only a fallback")
        }
    }
}
