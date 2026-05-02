// FullDiskAccessSheet.swift
//
// Native sheet shown when install.sh emits NEEDS_FDA. Plan §7.

import SwiftUI

struct FullDiskAccessSheet: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    let probe: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Full Disk Access required")
                        .font(.headline)
                    Text(reason.isEmpty ? "Ostler reads Safari, iMessage, Notes, Mail, Calendar, Photos and Reminders from local macOS databases." : reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Open System Settings, find Full Disk Access in the Privacy & Security section, and tick OstlerInstaller. Then come back here and tap Continue.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !probe.isEmpty {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text(probe)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Open System Settings") {
                    AuthorizationHelper.shared.openFullDiskAccessPane()
                }
                Spacer()
                Button("I've granted it, continue") {
                    coordinator.needsFDA = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
