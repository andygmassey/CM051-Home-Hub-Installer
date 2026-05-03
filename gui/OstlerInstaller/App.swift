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
                    coordinator.bootstrap()
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
