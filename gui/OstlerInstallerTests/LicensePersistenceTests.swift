// LicensePersistenceTests.swift
//
// Round-trip tests for `LicensePersistence`. Uses a unique
// per-test temp directory so the real `~/.ostler/license/` is
// never touched by the test target.

import Foundation
import XCTest
@testable import OstlerInstaller

final class LicensePersistenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("LicensePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    func testWriteThenReadRoundTrip() throws {
        let path = tempDir.appendingPathComponent("license.json")
        let payload = Data(#"{"version":1}"#.utf8)
        try LicensePersistence.write(licenseData: payload, to: path)
        let readBack = LicensePersistence.readExisting(at: path)
        XCTAssertEqual(readBack, payload)
    }

    func testReadMissingFileReturnsNil() {
        let path = tempDir.appendingPathComponent("absent.json")
        XCTAssertNil(LicensePersistence.readExisting(at: path))
    }

    func testWriteCreatesIntermediateDirectories() throws {
        let path = tempDir
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("license.json")
        let payload = Data("{}".utf8)
        try LicensePersistence.write(licenseData: payload, to: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testWriteSetsFileMode0600() throws {
        let path = tempDir.appendingPathComponent("license.json")
        try LicensePersistence.write(licenseData: Data("{}".utf8), to: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.uint16Value, 0o600,
                       "Licence file should be readable/writable only by owner")
    }
}
