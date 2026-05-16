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
        Group {
            if coordinator.licenseVerified {
                gatedContent
            } else {
                LicenseEntryView()
            }
        }
        .frame(width: 880, height: 620)
        .background(Color.ostlerChassis)
        .onChange(of: coordinator.registrationGate) { _, gate in
            // Bootstrap is idempotent + already guards on `.ready`;
            // a second call from `runDeviceRegistration` is harmless.
            if gate == .ready { coordinator.bootstrap() }
        }
        .sheet(item: $coordinator.pendingPrompt) { prompt in
            PromptSheet(prompt: prompt)
                .environmentObject(coordinator)
        }
        .sheet(item: $coordinator.needsFDA) { fda in
            FullDiskAccessSheet(probe: fda.probe, reason: fda.reason)
                .environmentObject(coordinator)
        }
    }

    /// Branches on the second-stage registration gate. The first-stage
    /// (cryptographic) gate is already cleared at this point, so the
    /// `LicenseEntryView` is behind us.
    @ViewBuilder
    private var gatedContent: some View {
        switch coordinator.registrationGate {
        case .limitReached(let max, let count):
            DeviceLimitReachedView(
                licenseId: coordinator.verifiedLicense?.licenseId ?? "",
                maxFingerprints: max,
                registeredCount: count
            )
        case .fatal(let reason):
            DeviceRegistrationErrorView(reason: reason)
        case .idle, .registering:
            // The install layout itself is fine to render -- bootstrap()
            // is gated separately, so the subprocess does not launch
            // until the gate is .ready. The footer ProgressView keeps
            // spinning, which is the natural UX for "we're checking".
            installLayout
        case .ready:
            installLayout
        }
    }

    private var installLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 200)
                    .background(Color.ostlerChassisDeep)

                Rectangle()
                    .fill(Color.ostlerHairlineFaint)
                    .frame(width: 1)

                VStack(spacing: 0) {
                    HintPanelView()
                    Spacer()
                    if showLogDrawer {
                        Rectangle()
                            .fill(Color.ostlerHairlineFaint)
                            .frame(height: 1)
                        LogDrawerView()
                            .frame(height: 200)
                    }
                    Rectangle()
                        .fill(Color.ostlerHairlineFaint)
                        .frame(height: 1)
                    FooterView(showLogDrawer: $showLogDrawer)
                        .frame(height: 60)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.ostlerChassis)
            }
        }
    }
}

/// Shown when the Worker rejected the registration with a terminal
/// (non-cap) reason: licence not found, revoked, or malformed. The
/// install is refused; the user is pointed at hello@ostler.ai.
private struct DeviceRegistrationErrorView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.ostlerOxblood)
                Text("We could not register this Mac")
                    .font(.ostlerH1)
                    .foregroundColor(.ostlerInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(reason)
                .font(.ostlerBody)
                .foregroundColor(.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Quit installer") { NSApp.terminate(nil) }
                    .buttonStyle(.ostlerPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }
}

private struct FooterView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @Binding var showLogDrawer: Bool

    var body: some View {
        HStack(spacing: .ostlerSpace2) {
            Button("Cancel") {
                coordinator.cancel()
                NSApp.terminate(nil)
            }
            .buttonStyle(.ostlerGhost)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Toggle(isOn: $showLogDrawer) {
                Label("Log", systemImage: "terminal")
                    .font(.ostlerCaption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(.ostlerInk)
            .keyboardShortcut("d", modifiers: [.command, .shift])

            if coordinator.finished == .ok {
                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: ("~/Documents/Ostler" as NSString).expandingTildeInPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.ostlerGhost)
                Button("Done") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.ostlerPrimary)
            } else if coordinator.finished == .fail {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.ostlerPrimary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.ostlerOxblood)
            }
        }
        .padding(.horizontal, .ostlerSpace3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }
}
