// ContentView.swift
//
// Three-pane root layout per plan §5:
//   sidebar (200pt, fixed)  |  main content (flex)  |  log drawer (collapsible bottom)
//
// Window is a fixed 880x620 – the App.swift frame() pins it.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @State private var showLogDrawer: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 200)
                    .background(.thinMaterial)

                Divider()

                VStack(spacing: 0) {
                    HintPanelView()
                    Spacer()
                    if showLogDrawer {
                        Divider()
                        LogDrawerView()
                            .frame(height: 200)
                    }
                    Divider()
                    FooterView(showLogDrawer: $showLogDrawer)
                        .frame(height: 60)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // FDA / sudo overlay sheets attach here
        }
        .frame(width: 880, height: 620)
        .sheet(item: $coordinator.pendingPrompt) { prompt in
            PromptSheet(prompt: prompt)
                .environmentObject(coordinator)
        }
        .sheet(item: $coordinator.needsFDA) { fda in
            FullDiskAccessSheet(probe: fda.probe, reason: fda.reason)
                .environmentObject(coordinator)
        }
    }
}

private struct FooterView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @Binding var showLogDrawer: Bool

    var body: some View {
        HStack {
            Button("Cancel") {
                coordinator.cancel()
                NSApp.terminate(nil)
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Toggle(isOn: $showLogDrawer) {
                Label("Log", systemImage: "terminal")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: [.command, .shift])

            if coordinator.finished == .ok {
                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: ("~/Documents/Ostler" as NSString).expandingTildeInPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Done") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else if coordinator.finished == .fail {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
            } else {
                // No primary action mid-install – install.sh drives.
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
    }
}
