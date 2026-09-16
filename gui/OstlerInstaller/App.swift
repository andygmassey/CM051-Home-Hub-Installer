// App.swift
//
// Entry point for OstlerInstaller.app. Owns the top-level Window
// and the InstallerCoordinator state object that drives the
// installer Process. Window is fixed at 880x620 per the locked
// design (plan §5).

import AppKit
import SwiftUI

/// Releases the `caffeinate -dimsu` power assertion when the APP goes
/// away, which is a different event from the install subprocess ending.
///
/// `CaffeinateManager.stop()` had exactly one call site --
/// `InstallerCoordinator.handleTermination()` -- and its own header
/// claimed it ran "on every install end path (success, failure, cancel,
/// user quit)". Three of those four go through the subprocess handler.
/// USER QUIT DOES NOT. There were zero app-termination hooks in the
/// target: grep for applicationWillTerminate / NSApplicationDelegate /
/// willTerminateNotification across gui/ returned nothing, while the
/// same grep shape for `onAppear` resolved to real production sites.
///
/// `caffeinate` is spawned with `Process` and macOS does not kill a
/// child when its parent dies. Quitting mid-install (cmd-Q, the footer
/// Quit, or the Dock) therefore left an orphan reparented to launchd
/// with its IOPMAssertion still held, and the customer's Mac would not
/// sleep again until they rebooted -- with nothing on screen to explain
/// why, and no obvious way to find the process.
///
/// `applicationWillTerminate` covers the ordinary quit paths.
/// `stop()` is idempotent, so overlapping with the subprocess handler
/// is harmless.
final class InstallerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            CaffeinateManager.shared.stop()
        }
    }
}

@main
struct OstlerInstallerApp: App {
    @StateObject private var coordinator = InstallerCoordinator()
    @NSApplicationDelegateAdaptor(InstallerAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Ostler Installer", id: "main") {
            ContentView()
                .environmentObject(coordinator)
                .frame(
                    minWidth: 880, idealWidth: 880, maxWidth: 880,
                    minHeight: 620, idealHeight: 620, maxHeight: 620
                )
                .onAppear {
                    // First-launch self-relocator. If we're running
                    // from inside a mounted DMG or anywhere else
                    // outside /Applications, prompt the user to move
                    // the .app to /Applications and relaunch. Runs
                    // BEFORE the licence-verify gate so the modal is
                    // the very first thing the customer sees -- the
                    // licence-gate / first-run wizard happens in the
                    // /Applications copy, not the about-to-be-deleted
                    // DMG copy. (DMG brief explicitly requires this
                    // ordering; see CM051 PR #71.)
                    SelfRelocator.checkAndRelocate()

                    // CX-14 Section E1 (2026-05-23) + CX-17 (2026-05-23).
                    // Mid-install auth pre-warm. Surfaces the intro
                    // screen now; the customer reads the four
                    // permissions about to be requested + taps
                    // Grant permissions to fire the actual TCC
                    // dialogs SERIALLY with an 800ms gap between
                    // each (CX-17 fix: the original concurrent
                    // burst landed all four popups in the same
                    // second and Andy missed two of them on Studio
                    // retest 2026-05-23).
                    //
                    // The persisted-licence re-verify path used to
                    // fire here too; under CX-17 it moves into
                    // ContentView's onChange(of: permissionsPrewarmFinished)
                    // so it cannot run in parallel with the popups.
                    // Closes E1 + C4 (TCC subprocess attribution).
                    //
                    // CX-87 (2026-06-01): gate on Full Disk Access FIRST.
                    // If FDA isn't granted yet this raises the up-front
                    // FDA screen and stops; the customer grants it,
                    // macOS makes them quit, and on reopen this same
                    // path finds FDA present and proceeds. Only once FDA
                    // is in place do permissions/licence/install run --
                    // so the whole flow happens once, never mid-install.
                    coordinator.gateFullDiskAccessThenStart()
                }
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))

        // Hidden settings menu so cmd-, doesn't crash. Currently
        // empty – Phase 1 has no user-facing preferences.
        Settings {
            EmptyView()
        }
    }
}
