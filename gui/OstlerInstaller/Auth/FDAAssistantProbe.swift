// FDAAssistantProbe.swift
//
// The drag screen asks for TWO grants, because two different programs read
// protected files:
//   1. Ostler (OstlerAssistant.app): the daemon and its agents, at runtime.
//   2. Ostler Installer: install.sh's own reads during setup (install.sh
//      early probe, Mail reclassify, the install-time chat.db read).
//
// macOS decides a grant per program, so a read made by this process says
// nothing about Ostler. The installer is probed from its own process
// (FullDiskAccessProbe). Ostler is probed AS Ostler: OstlerAssistant.app is
// launched through LaunchServices (`open`), so the app is its own responsible
// process and TCC judges it, not us (install.sh explains why a plain child
// process would be judged as the installer instead). It runs the one-shot
// `run-source imessage --self-test`, which prints "SELF-TEST: OK" or
// "SELF-TEST: DENIED" and exits; the output is captured with open's --stdout.
//
// Anything else (no marker, no output, the binary does not know the flag) is
// "noAnswer": no information, never a grant.

import Foundation

enum FDAAssistantOutcome: Equatable {
    case granted
    case denied
    case noAnswer
}

/// The one-shot's arguments, shared by the capability check and the probe.
enum FDAAssistantSelfTest {
    static let arguments = ["run-source", "imessage", "--self-test"]
    static let marker = "SELF-TEST:"

    /// Reads the one-shot's output. Only an explicit OK is a grant.
    static func parse(_ output: String?) -> FDAAssistantOutcome {
        guard let output, let line = output.split(separator: "\n").first(where: { $0.contains(marker) })
        else { return .noAnswer }
        let verdict = line.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespaces)
        if verdict.hasPrefix("OK") { return .granted }
        if verdict.hasPrefix("DENIED") { return .denied }
        return .noAnswer
    }
}

/// Seam so tests never launch an app or touch a protected file.
protocol FDAAssistantRunning {
    /// True when the bundle's binary answers the self-test with the marker
    /// (an older binary would instead start its persistent daemon).
    func supportsSelfTest(bundle: URL) async -> Bool
    /// Runs the one-shot as the app itself and returns its stdout, or nil.
    func runAsApp(bundle: URL) async -> String?
}

struct FDAAssistantProbe {
    let runner: FDAAssistantRunning
    let bundle: URL
    private(set) var capable: Bool?

    init(runner: FDAAssistantRunning, bundle: URL) {
        self.runner = runner
        self.bundle = bundle
    }

    /// Checks the capability once, then probes as the app. A binary that does
    /// not honour the one-shot is never launched through `open`.
    mutating func probe() async -> FDAAssistantOutcome {
        if capable == nil { capable = await runner.supportsSelfTest(bundle: bundle) }
        guard capable == true else { return .noAnswer }
        return FDAAssistantSelfTest.parse(await runner.runAsApp(bundle: bundle))
    }
}

/// Real runner. Not exercised by the unit tests (it launches an app); the
/// tests drive FDAAssistantProbe through a fake.
struct LaunchServicesAssistantRunner: FDAAssistantRunning {
    static func binary(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/MacOS/ostler-assistant")
    }

    private func run(_ exe: String, _ args: [String], timeout: TimeInterval) async -> (Int32, String)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if p.isRunning { p.terminate(); cont.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    func supportsSelfTest(bundle: URL) async -> Bool {
        // Direct exec, self-exiting, no app launch (as install.sh does).
        guard let r = await run(Self.binary(in: bundle).path, FDAAssistantSelfTest.arguments, timeout: 5)
        else { return false }
        return r.1.contains(FDAAssistantSelfTest.marker)
    }

    func runAsApp(bundle: URL) async -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ostler-fda-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")
        let err = dir.appendingPathComponent("err.txt")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        // -g/-j: background and hidden; -n: a fresh instance. No -W: the
        // one-shot exits by itself, and we wait on its output instead.
        let args = ["-g", "-j", "-n", "--stdout", out.path, "--stderr", err.path, "-a", bundle.path, "--args"]
            + FDAAssistantSelfTest.arguments
        guard await run("/usr/bin/open", args, timeout: 5) != nil else { return nil }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let text = try? String(contentsOf: out, encoding: .utf8), text.contains(FDAAssistantSelfTest.marker) {
                return text
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // No answer: stop only an instance started with our exact arguments.
        _ = await run("/usr/bin/pkill", ["-f", "ostler-assistant " + FDAAssistantSelfTest.arguments.joined(separator: " ")],
                      timeout: 3)
        return nil
    }
}

/// The two grants the screen waits for. Pure, so tests drive it.
/// `assistant == nil` means there is no Ostler bundle to ask for (it is not in
/// this installer), so only the installer's grant is awaited.
struct FDATwoGrantWatch: Equatable {
    private(set) var fired = false
    private(set) var installerGranted = false
    private(set) var assistantGranted = false

    mutating func tick(installer: FDAProbeReport, assistant: FDAAssistantOutcome?) -> Bool {
        // Grants are sticky within a session: once seen, they stay seen.
        if installer.granted { installerGranted = true }
        if assistant == .granted { assistantGranted = true }
        let assistantOK = assistant == nil ? true : assistantGranted
        guard !fired, installerGranted, assistantOK else { return false }
        fired = true
        return true
    }
}

/// Which tile the customer is on. In sequence: Ostler (1), then Ostler
/// Installer (2). The first tile not yet granted is the active one.
enum FDATileID: Equatable { case assistant, installer }

enum FDATileSequence {
    static func order(hasAssistant: Bool) -> [FDATileID] {
        hasAssistant ? [.assistant, .installer] : [.installer]
    }

    static func active(hasAssistant: Bool, assistantGranted: Bool, installerGranted: Bool) -> FDATileID? {
        for id in order(hasAssistant: hasAssistant) {
            if id == .assistant && !assistantGranted { return id }
            if id == .installer && !installerGranted { return id }
        }
        return nil
    }
}
