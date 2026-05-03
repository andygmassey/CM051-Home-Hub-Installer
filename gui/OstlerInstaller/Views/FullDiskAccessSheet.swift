// FullDiskAccessSheet.swift
//
// Native sheet shown when install.sh emits NEEDS_FDA. Plan §7.

import SwiftUI

struct FullDiskAccessSheet: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    let probe: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace3) {
            HStack(alignment: .top, spacing: .ostlerSpace3) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.ostlerOxblood)
                VStack(alignment: .leading, spacing: .ostlerSpace1) {
                    Text("Full Disk Access required")
                        .font(.ostlerH2)
                        .tracking(-0.2)
                        .foregroundStyle(Color.ostlerInk)
                    Text(reason.isEmpty
                         ? "Ostler reads Safari, iMessage, Notes, Mail, Calendar, Photos and Reminders from local macOS databases."
                         : reason)
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Open System Settings, find Full Disk Access in the Privacy & Security section, and tick OstlerInstaller. Then come back here and tap Continue.")
                .font(.ostlerBody)
                .foregroundStyle(Color.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)

            if !probe.isEmpty {
                HStack(spacing: .ostlerSpace2) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(Color.ostlerInkSubdued)
                    Text(probe)
                        .font(.ostlerMono)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .textSelection(.enabled)
                }
                .padding(CGFloat.ostlerSpace2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.ostlerChassisDeep)
                )
            }

            HStack(spacing: .ostlerSpace2) {
                Button("Open System Settings") {
                    AuthorizationHelper.shared.openFullDiskAccessPane()
                }
                .buttonStyle(.ostlerGhost)
                Spacer()
                Button("I've granted it, continue") {
                    coordinator.needsFDA = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.ostlerPrimary)
            }
        }
        .padding(CGFloat.ostlerSpace4)
        .frame(width: 500)
        .background(Color.ostlerChassis)
    }
}
