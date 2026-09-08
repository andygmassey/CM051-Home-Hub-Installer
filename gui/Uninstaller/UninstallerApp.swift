// UninstallerApp.swift
//
// Uninstaller.app: a minimal, standalone SwiftUI app (Andy's explicit choice —
// a separate app, not a button inside OstlerInstaller.app). It is placed in
// /Applications at install time so it survives the customer deleting the DMG,
// and it runs the installed ~/.ostler/bin/ostler-uninstall with OSTLER_GUI=1.

import SwiftUI

@main
struct UninstallerApp: App {
    @StateObject private var coordinator = UninstallerCoordinator()

    var body: some Scene {
        Window("Uninstall Ostler", id: "main") {
            UninstallerRootView()
                .environmentObject(coordinator)
                .frame(
                    minWidth: 580, idealWidth: 580, maxWidth: 580,
                    minHeight: 480, idealHeight: 480, maxHeight: 620
                )
        }
        .windowResizability(.contentSize)

        // Empty Settings scene so cmd-, does not crash.
        Settings { EmptyView() }
    }
}
