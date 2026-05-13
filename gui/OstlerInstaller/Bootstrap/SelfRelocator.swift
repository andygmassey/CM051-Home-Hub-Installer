// SelfRelocator.swift
//
// First-launch self-relocator. When OstlerInstaller.app is launched
// from anywhere other than /Applications -- typically from inside a
// mounted DMG (Andy's failure mode on Mac Studio, pre-2026-05-13) or
// from ~/Downloads -- this module prompts the user to move the .app
// into /Applications, copies it there, and relaunches.
//
// Wired as the first line of App.swift's onAppear, *before* the
// licence-verify gate. The relocation modal is the very first thing
// the customer sees after double-clicking.
//
// Design constraints:
//
// - Pure-AppKit prompts (NSAlert). No SwiftUI dependency so the
//   modal can fire before any Scene is constructed if needed.
// - Closure-based dependency injection via SelfRelocator.Actions so
//   the test target can drive every branch without touching the real
//   filesystem or NSWorkspace.
// - Honours a one-shot "don't move" UserDefaults flag so the customer
//   who declines the prompt isn't nagged on subsequent launches from
//   the same out-of-Applications path.
// - Hands off the previous bundle URL to the relaunched /Applications
//   copy via OSTLER_RELOCATED_FROM env var so the new process can
//   trash the old copy (unless the source was on a read-only DMG).
//
// See HR015/launch/TNM_BRIEF_DMG_INSTALLER_UX_2026-05-13.md for the
// full behaviour spec.

import AppKit
import Foundation

public final class SelfRelocator {

    // MARK: - Constants

    /// UserDefaults key. ``true`` means the customer has previously
    /// clicked "Don't Move" and should not be prompted again from
    /// this out-of-Applications path.
    public static let dontMoveDefaultsKey = "ai.ostler.installer.SelfRelocator.dontMove"

    /// Environment variable used to tell the relaunched
    /// /Applications copy where the original bundle lived, so it
    /// can trash it.
    public static let relocatedFromEnvKey = "OSTLER_RELOCATED_FROM"

    /// Canonical install location.
    public static let targetURL = URL(fileURLWithPath: "/Applications/OstlerInstaller.app")

    // MARK: - Public API

    /// Run the relocation check with production-default dependencies.
    /// Called from App.swift's ``onAppear``.
    ///
    /// Short-circuits when the process is running inside XCTest -- the
    /// test runner loads OstlerInstaller.app as TEST_HOST and the
    /// app's ``onAppear`` fires before tests get to run. Without this
    /// guard the production NSAlert below would hang the test bundle
    /// connection because there's no UI to drive a modal.
    public static func checkAndRelocate() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        SelfRelocator().run()
    }

    // MARK: - Choice enums

    public enum RelocationChoice {
        case moveToApplications
        case dontMove
    }

    public enum ReplaceChoice {
        case replace
        case cancel
    }

    // MARK: - Action sink

    /// All side-effecting operations are injected as closures so the
    /// test target can drive every branch deterministically without
    /// touching the real disk, NSWorkspace, or NSAlert.
    public struct Actions {
        public var fileExists: (URL) -> Bool
        public var copyItem: (URL, URL) throws -> Void
        public var remove: (URL) throws -> Void
        public var recycle: (URL) -> Void
        public var showRelocationPrompt: (URL) -> RelocationChoice
        public var showReplaceExistingPrompt: () -> ReplaceChoice
        public var showError: (String, String) -> Void
        public var relaunch: (URL, String) -> Void
        public var terminate: () -> Void

        public init(
            fileExists: @escaping (URL) -> Bool,
            copyItem: @escaping (URL, URL) throws -> Void,
            remove: @escaping (URL) throws -> Void,
            recycle: @escaping (URL) -> Void,
            showRelocationPrompt: @escaping (URL) -> RelocationChoice,
            showReplaceExistingPrompt: @escaping () -> ReplaceChoice,
            showError: @escaping (String, String) -> Void,
            relaunch: @escaping (URL, String) -> Void,
            terminate: @escaping () -> Void
        ) {
            self.fileExists = fileExists
            self.copyItem = copyItem
            self.remove = remove
            self.recycle = recycle
            self.showRelocationPrompt = showRelocationPrompt
            self.showReplaceExistingPrompt = showReplaceExistingPrompt
            self.showError = showError
            self.relaunch = relaunch
            self.terminate = terminate
        }

        /// Real-system implementations. Built lazily on access so we
        /// don't construct NSAlerts during unit tests.
        public static var production: Actions {
            Actions(
                fileExists: { url in
                    FileManager.default.fileExists(atPath: url.path)
                },
                copyItem: { src, dst in
                    try FileManager.default.copyItem(at: src, to: dst)
                },
                remove: { url in
                    try FileManager.default.removeItem(at: url)
                },
                recycle: { url in
                    NSWorkspace.shared.recycle(
                        [url],
                        completionHandler: nil,
                    )
                },
                showRelocationPrompt: { _ in
                    let alert = NSAlert()
                    alert.messageText = "Move Ostler Installer to your Applications folder?"
                    alert.informativeText = """
                        Ostler Installer should live in your Applications folder. \
                        Would you like to move it now?
                        """
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Move to Applications")
                    alert.addButton(withTitle: "Don't Move")
                    return alert.runModal() == .alertFirstButtonReturn
                        ? .moveToApplications : .dontMove
                },
                showReplaceExistingPrompt: {
                    let alert = NSAlert()
                    alert.messageText = "An older Ostler Installer is already installed."
                    alert.informativeText = """
                        Replace it with this copy? The older copy will be moved \
                        to the Trash.
                        """
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Replace")
                    alert.addButton(withTitle: "Cancel")
                    return alert.runModal() == .alertFirstButtonReturn
                        ? .replace : .cancel
                },
                showError: { title, message in
                    let alert = NSAlert()
                    alert.messageText = title
                    alert.informativeText = message
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    _ = alert.runModal()
                },
                relaunch: { newBundleURL, oldBundlePath in
                    // Use the modern NSWorkspace API so we can pass
                    // the OSTLER_RELOCATED_FROM env var. The completion
                    // handler is nil because the current process is
                    // about to terminate -- we don't care about the
                    // launch's outcome from our side.
                    let config = NSWorkspace.OpenConfiguration()
                    config.environment = [
                        SelfRelocator.relocatedFromEnvKey: oldBundlePath,
                    ]
                    NSWorkspace.shared.openApplication(
                        at: newBundleURL,
                        configuration: config,
                        completionHandler: nil,
                    )
                },
                terminate: {
                    NSApp?.terminate(nil)
                }
            )
        }
    }

    // MARK: - Dependencies

    private let bundleURL: URL
    private let environmentVariables: [String: String]
    private let userDefaults: UserDefaults
    private let actions: Actions

    public init(
        bundleURL: URL = Bundle.main.bundleURL,
        environmentVariables: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        actions: Actions = .production
    ) {
        self.bundleURL = bundleURL
        self.environmentVariables = environmentVariables
        self.userDefaults = userDefaults
        self.actions = actions
    }

    // MARK: - Run

    public func run() {
        // 1. Post-relaunch cleanup: if we were spawned by an earlier
        //    "Move to Applications" decision, trash the old copy. We
        //    do this *before* the relocation check so the cleanup
        //    runs even on launches where we're already in
        //    /Applications (which is the typical post-relaunch case).
        cleanupPreviousLocation()

        // 2. Relocation check.
        performRelocationCheck()
    }

    // MARK: - Step 1: post-relaunch cleanup

    func cleanupPreviousLocation() {
        guard let priorPath = environmentVariables[Self.relocatedFromEnvKey],
              !priorPath.isEmpty
        else { return }

        let priorURL = URL(fileURLWithPath: priorPath)

        if Self.isInDMG(priorURL) {
            // The DMG mount is read-only; we can't trash from there.
            // The customer ejects the volume manually. (The optional
            // eject-DMG nudge from the brief is filed as a v0.2.1
            // polish.)
            return
        }

        // Best-effort recycle. We don't surface failures because the
        // customer can always trash the old copy by hand if Finder
        // refuses for any reason.
        actions.recycle(priorURL)
    }

    // MARK: - Step 2: relocation check

    func performRelocationCheck() {
        if Self.isInApplications(bundleURL) {
            return
        }

        if userDefaults.bool(forKey: Self.dontMoveDefaultsKey) {
            return
        }

        let choice = actions.showRelocationPrompt(bundleURL)
        switch choice {
        case .moveToApplications:
            // Reset the don't-move flag so a customer who once
            // declined and now changed their mind doesn't leave a
            // stale opt-out behind. (Defensive; the only way we get
            // here with the flag still set is if someone deleted the
            // /Applications copy and re-launched from elsewhere.)
            userDefaults.set(false, forKey: Self.dontMoveDefaultsKey)
            attemptMove()
        case .dontMove:
            userDefaults.set(true, forKey: Self.dontMoveDefaultsKey)
        }
    }

    private func attemptMove() {
        // Edge case: an older copy is already at the target. Offer
        // to replace; default is "Replace" per the launch-scope
        // brief's open question #3 resolution.
        if actions.fileExists(Self.targetURL) {
            switch actions.showReplaceExistingPrompt() {
            case .replace:
                do {
                    try actions.remove(Self.targetURL)
                } catch {
                    actions.showError(
                        "Could not replace existing Ostler Installer",
                        error.localizedDescription
                    )
                    return
                }
            case .cancel:
                return
            }
        }

        do {
            try actions.copyItem(bundleURL, Self.targetURL)
        } catch {
            actions.showError(
                "Could not move Ostler Installer",
                error.localizedDescription
            )
            return
        }

        // Relaunch from the new location. The relaunched process
        // sees OSTLER_RELOCATED_FROM in its environment and trashes
        // the source bundle on startup.
        actions.relaunch(Self.targetURL, bundleURL.path)
        actions.terminate()
    }

    // MARK: - Path classification (testable; also called by tests)

    /// True if ``url`` points at OstlerInstaller.app inside
    /// /Applications. Accepts both the bundle root and any path
    /// inside it (e.g. Contents/MacOS) -- the App's own
    /// ``Bundle.main.bundleURL`` is always the .app root, but the
    /// helper is generous about inputs so tests can pass synthetic
    /// paths without worrying about exact rooting.
    public static func isInApplications(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == "/Applications/OstlerInstaller.app"
            || path.hasPrefix("/Applications/OstlerInstaller.app/")
    }

    /// True if ``url`` is on a mounted DMG volume (path under
    /// /Volumes/). DMG mounts are read-only, so trashing the source
    /// bundle after relocation is impossible -- the post-relaunch
    /// cleanup short-circuits when this is true.
    public static func isInDMG(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix("/Volumes/")
    }
}
