// FullDiskAccessGateView.swift
//
// CX-87 (2026-06-01): front-loaded Full Disk Access gate. The first screen
// whenever the installer does not yet have Full Disk Access. macOS requires
// quit-and-reopen after a grant, so the gate runs before any question and the
// whole setup runs once on the post-grant launch.
//
// 2026-11-11, macOS 27.3: apps can no longer add themselves to the Full Disk
// Access list (READING_TRIAGE_2026-11-11.md). So this screen hands the
// customer the app instead of asking them to find it:
//   - the System Settings pane opens, and this window is docked to the left so
//     both are visible;
//   - the app tile is a real drag source (FDAHandoff.dragProvider), dropped
//     straight onto the list;
//   - a short loop shows the drag and the toggle; with Reduce Motion it shows
//     the same three steps as a still;
//   - a fallback line and Show in Finder cover the manual "+" route;
//   - the gate polls a protected read every 2 seconds and advances the moment
//     access is granted. No Continue click is needed.

import SwiftUI
import AppKit

struct FullDiskAccessGateView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0: tile not yet dragged. 1: tile landed in the list. 2: toggle on.
    @State private var animStep = 0
    @State private var granted = false

    private let appURL = FDAHandoff.appBundleURL()
    private let appName = FDAHandoff.displayName()
    private let appIcon = NSWorkspace.shared.icon(forFile: FDAHandoff.appBundleURL().path)

    var body: some View {
        VStack(spacing: CGFloat.ostlerSpace3) {
            heading
            illustration
            dragTile
            fallbackLine
            Spacer(minLength: 0)
            statusRow
            privacyLine
            controls
        }
        .padding(.horizontal, CGFloat.ostlerSpace5)
        .padding(.vertical, CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.ostlerChassis)
        .onAppear {
            AuthorizationHelper.shared.openFullDiskAccessPane()
            FDAWindowPlacement.dockInstallerLeft()
        }
        .task { await watchForGrant() }
        .task(id: reduceMotion) {
            if !reduceMotion { await loopIllustration() }
        }
    }

    // MARK: - Heading

    private var heading: some View {
        Text(ViewCopy.shared.string(for: "fda_gate.heading"))
            .font(.ostlerDisplay)
            .foregroundStyle(Color.ostlerInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Illustration (animated, or a still under Reduce Motion)

    @ViewBuilder
    private var illustration: some View {
        if reduceMotion {
            HStack(spacing: CGFloat.ostlerSpace2) {
                stillStep(1, symbol: "square.and.arrow.down", key: "fda_gate.anim_drag")
                stillStep(2, symbol: "switch.2", key: "fda_gate.anim_switch_on")
                stillStep(3, symbol: "checkmark.circle.fill", key: "fda_gate.anim_done")
            }
            .frame(height: 140)
        } else {
            mockList
                .frame(width: 320, height: 140)
        }
    }

    private func stillStep(_ number: Int, symbol: String, key: String) -> some View {
        VStack(spacing: CGFloat.ostlerSpace1) {
            Text("\(number)")
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerPanel)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.ostlerOxblood))
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Color.ostlerOxblood)
            Text(ViewCopy.shared.string(for: key))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CGFloat.ostlerSpace2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ostlerPanel)
        )
    }

    /// A small mock of the System Settings list. A copy of the app icon
    /// travels up into the row, and the toggle turns on.
    private var mockList: some View {
        let landed = animStep >= 1
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ostlerPanel)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.ostlerHairlineSoft, lineWidth: 1)

            HStack(spacing: CGFloat.ostlerSpace2) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .opacity(landed ? 1 : 0)
                Text(appName)
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInk)
                Spacer(minLength: 0)
                mockToggle(on: animStep >= 2)
            }
            .padding(CGFloat.ostlerSpace3)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, CGFloat.ostlerSpace2)

            // The travelling copy of the tile: starts below the list, lands on the row.
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 40, height: 40)
                .offset(x: landed ? 14 : 130, y: landed ? 14 : 100)
                .opacity(animStep >= 2 ? 0 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private func mockToggle(on: Bool) -> some View {
        Capsule()
            .fill(on ? Color.ostlerForest : Color.ostlerChassisDeep)
            .frame(width: 40, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Color.ostlerPanel)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
    }

    // MARK: - The draggable app tile

    private var dragTile: some View {
        VStack(spacing: CGFloat.ostlerSpace1) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 64, height: 64)
            Text(appName)
                .font(.ostlerH2)
                .foregroundStyle(Color.ostlerInk)
            Text(ViewCopy.shared.string(for: "fda_gate.drag_hint"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkMuted)
        }
        .padding(.horizontal, CGFloat.ostlerSpace5)
        .padding(.vertical, CGFloat.ostlerSpace3)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.ostlerOxbloodSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.ostlerOxblood.opacity(0.5), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDrag { FDAHandoff.dragProvider(for: appURL) }
        .accessibilityElement(children: .combine)
    }

    private var fallbackLine: some View {
        HStack(spacing: CGFloat.ostlerSpace2) {
            Text(ViewCopy.shared.string(
                for: "fda_gate.fallback_line",
                fills: ["app": appName, "path": displayFolder]
            ))
            .font(.ostlerCaption)
            .foregroundStyle(Color.ostlerInkMuted)
            .fixedSize(horizontal: false, vertical: true)
            Button(ViewCopy.shared.string(for: "fda_gate.reveal_button")) {
                NSWorkspace.shared.activateFileViewerSelecting([appURL])
            }
            .buttonStyle(.ostlerGhost)
        }
        .frame(maxWidth: .infinity)
    }

    /// The folder holding the app, with the home folder shown as ~.
    private var displayFolder: String {
        (appURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Status, privacy, controls

    private var statusRow: some View {
        HStack(spacing: CGFloat.ostlerSpace2) {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.ostlerForest)
                Text(ViewCopy.shared.string(for: "fda_gate.granted"))
            } else {
                ProgressView()
                    .controlSize(.small)
                Text(ViewCopy.shared.string(for: "fda_gate.waiting"))
            }
        }
        .font(.ostlerBody)
        .foregroundStyle(Color.ostlerInk)
        .frame(maxWidth: .infinity)
    }

    private var privacyLine: some View {
        HStack(spacing: CGFloat.ostlerSpace2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.ostlerForest)
            Text(ViewCopy.shared.string(for: "fda_gate.privacy_line"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: CGFloat.ostlerSpace2) {
            if coordinator.showFDAContinueAnyway {
                Text(ViewCopy.shared.string(for: "fda_gate.unconfirmed_note"))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: CGFloat.ostlerSpace3) {
                    Button(ViewCopy.shared.string(for: "fda_gate.quit_reopen_button")) {
                        coordinator.quitAndReopenFromApplications()
                    }
                    .buttonStyle(.ostlerGhost)
                    Spacer()
                    Button(ViewCopy.shared.string(for: "fda_gate.continue_anyway_button")) {
                        coordinator.continueWithoutConfirmedFullDiskAccess()
                    }
                    .buttonStyle(.ostlerGhost)
                }
            }
            HStack(spacing: CGFloat.ostlerSpace3) {
                Button(ViewCopy.shared.string(for: "fda_gate.recheck_button")) {
                    coordinator.recheckFullDiskAccessAndProceed()
                }
                .buttonStyle(.ostlerGhost)

                Spacer()

                // Also the reopen button: if the customer closed the Settings pane, this brings it back.
                Button(ViewCopy.shared.string(for: "fda_gate.open_settings_button")) {
                    AuthorizationHelper.shared.openFullDiskAccessPane()
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Behaviour

    /// Polls a protected read every 2 seconds. On the first successful read,
    /// shows the check mark briefly and hands on to the normal flow.
    private func watchForGrant() async {
        var watch = FDAGrantWatch()
        while !Task.isCancelled {
            if watch.tick(coordinator.fullDiskAccessReport()) {
                granted = true
                try? await Task.sleep(nanoseconds: 700_000_000)
                coordinator.recheckFullDiskAccessAndProceed()
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Drag, toggle, hold, repeat. Each cycle starts from the still frame.
    private func loopIllustration() async {
        while !Task.isCancelled {
            withAnimation(nil) { animStep = 0 }
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeInOut(duration: 0.9)) { animStep = 1 }
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            withAnimation(.easeInOut(duration: 0.3)) { animStep = 2 }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

/// Docks the installer window to the left of the screen, so the System
/// Settings pane opened beside it stays visible. macOS places the Settings
/// window itself; this only controls where the installer sits.
@MainActor
enum FDAWindowPlacement {
    static func dockInstallerLeft() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }),
              let area = (window.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        var frame = window.frame
        frame.origin.x = area.minX + 12
        frame.origin.y = max(area.minY, min(frame.origin.y, area.maxY - frame.height))
        window.setFrame(frame, display: true, animate: true)
    }
}
