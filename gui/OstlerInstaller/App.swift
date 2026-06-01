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
