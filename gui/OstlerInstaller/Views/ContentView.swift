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
        // PROMPT events are rendered inline in `installLayout` via
        // `OnboardingQuestionView` (#353). FDA approval is still a
        // sheet for now -- it sits outside the question flow and
        // pre-dates the in-window decision.
        .sheet(item: $coordinator.needsFDA) { fda in
            FullDiskAccessSheet(probe: fda.probe, reason: fda.reason)
                .environmentObject(coordinator)
        }
    }

    /// Full-screen blocker shown when the pre-launch admin-grant
    /// AppleScript dialog was cancelled (or otherwise failed). The
    /// install subprocess has NOT been launched at this point;
    /// Retry re-invokes `AuthorizationHelper` cleanly.
    @ViewBuilder
    private var adminRetryGate: some View {
        AdminAccessRequiredView()
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
            // Pre-launch admin-grant cancelled? Hold here with a
            // Retry surface; the install subprocess is not running.
            if coordinator.needsAdminRetry {
                adminRetryGate
            } else {
                installLayout
            }
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
                    // Onboarding takes over the main content area
                    // whenever there is a live PROMPT or the customer
                    // is reviewing a previous answer via Back. The
                    // sidebar Steps + footer remain visible so the
                    // customer never loses their progress anchor.
                    if coordinator.pendingPrompt != nil ||
                       coordinator.backReviewIndex != nil {
                        OnboardingQuestionView()
                    } else {
                        HintPanelView()
                    }
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

/// Shown when the pre-launch admin-grant AppleScript dialog was
/// cancelled (or osascript returned non-zero). The install
/// subprocess has NOT been launched. Retry re-invokes the helper;
/// Quit terminates the installer cleanly.
private struct AdminAccessRequiredView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.ostlerOxblood)
                Text(ViewCopy.shared.string(for: "admin_access_required.heading"))
                    .font(.ostlerH1)
                    .foregroundColor(.ostlerInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ViewCopy.shared.string(for: "admin_access_required.prompt_reason"))
                .font(.ostlerBody)
                .foregroundColor(.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Spacer()
                Button(ViewCopy.shared.string(for: "admin_access_required.quit_button")) {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.ostlerGhost)

                Button(ViewCopy.shared.string(for: "admin_access_required.retry_button")) {
                    coordinator.retryAdminAuthorization()
                }
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
                Text(ViewCopy.shared.string(for: "device_registration_error.heading"))
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
                Button(ViewCopy.shared.string(for: "device_registration_error.quit_button")) {
                    NSApp.terminate(nil)
                }
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
            Button(ViewCopy.shared.string(for: "footer.cancel_button")) {
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
                Button(ViewCopy.shared.string(for: "footer.reveal_in_finder_button")) {
                    let url = URL(fileURLWithPath: ("~/Documents/Ostler" as NSString).expandingTildeInPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.ostlerGhost)
                Button(ViewCopy.shared.string(for: "footer.done_button")) { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.ostlerPrimary)
            } else if coordinator.finished == .fail {
                Button(ViewCopy.shared.string(for: "footer.quit_button")) { NSApp.terminate(nil) }
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
