// RecoveryApp.swift
//
// Recover Ostler.app: a small, standalone SwiftUI app for a customer who is
// locked out of their own data. Andy's words on why this exists: "the whole
// premise of Ostler is that it's for normies to use. So why the fuck are we
// resorting to command line for a user to do this?" This app is the doorway;
// the redeemer it calls (ostler-unlock) already works and is unchanged.
//
// Same pattern as the standalone uninstaller app: placed in /Applications at
// install time so it survives the customer deleting the DMG, and it must work
// even when the Ostler services are down, because that is the situation it
// exists for -- it shells out to the installed Python redeemer directly, not
// to any running service.

import SwiftUI

@main
struct RecoveryApp: App {
    @StateObject private var coordinator = RecoveryCoordinator()

    var body: some Scene {
        Window("Recover Ostler", id: "main") {
            RecoveryRootView()
                .environmentObject(coordinator)
                .frame(
                    minWidth: 520, idealWidth: 520, maxWidth: 560,
                    minHeight: 380, idealHeight: 420, maxHeight: 520
                )
        }
        .windowResizability(.contentSize)

        // Empty Settings scene so cmd-, does not crash. There are no
        // settings: the spec is ultra simple on purpose.
        Settings { EmptyView() }
    }
}
