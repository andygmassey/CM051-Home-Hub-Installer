// App.swift
//
// Entry point for OstlerInstaller.app. Owns the top-level Window
// and the InstallerCoordinator state object that drives the
// installer Process. Window is fixed at 880x620 per the locked
// design (plan §5).

import SwiftUI

@main
struct OstlerInstallerApp: App {
    @StateObject private var coordinator = InstallerCoordinator()

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

                    // Re-verify any persisted licence next. If it
                    // verifies, ContentView's `.onChange` calls
                    // `coordinator.bootstrap()` automatically. If it
                    // does not (no file, signature drift, expiry),
                    // the view falls through to LicenseEntryView
                    // and bootstrap stays gated.
                    coordinator.verifyExistingLicenseOnLaunch()
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
