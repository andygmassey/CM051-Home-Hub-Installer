// ContentView.swift
//
// The three screens: confirm (with the two destructive opt-ins), running
// (phase progress), and done (an honest summary, including when the data
// stores were NOT removed, which is a privacy fact, not a cosmetic one).

import SwiftUI
import AppKit

struct UninstallerRootView: View {
    @EnvironmentObject var coordinator: UninstallerCoordinator

    var body: some View {
        VStack(spacing: 0) {
            switch coordinator.screen {
            case .confirm: ConfirmView()
            case .running: RunningView()
            case .done:    DoneView()
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private func quit() { NSApplication.shared.terminate(nil) }

/// Customer copy, from the installer's catalogue (Resources/ViewCopy*.json,
/// bundled into this app) in the Mac's language (InstallerLanguage).
private func copy(_ key: String) -> String { ViewCopy.shared.string(for: "uninstaller." + key) }

// MARK: - Confirm

struct ConfirmView: View {
    @EnvironmentObject var coordinator: UninstallerCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(copy("heading"))
                .font(.title).bold()

            Text(copy("intro"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !coordinator.uninstallerPresent {
                Label(copy("not_found"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle(isOn: $coordinator.options.removeColima) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy("remove_colima"))
                    Text(copy("remove_colima_help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $coordinator.options.purgeKnowledgeData) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy("purge_knowledge"))
                    Text(copy("purge_knowledge_help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button(copy("cancel")) { quit() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("uninstall_button")) { coordinator.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.uninstallerPresent)
            }
        }
    }
}

// MARK: - Running

struct RunningView: View {
    @EnvironmentObject var coordinator: UninstallerCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy("running")).font(.title2).bold()

            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(coordinator.currentPhase.isEmpty ? copy("working") : coordinator.currentPhase)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(coordinator.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Done

struct DoneView: View {
    @EnvironmentObject var coordinator: UninstallerCoordinator

    private var headline: String {
        if !coordinator.succeeded { return copy("done_failed") }
        return coordinator.storesRemoved ? copy("done_removed")
                                         : copy("done_stores_kept")
    }

    private var headlineColor: Color {
        if !coordinator.succeeded { return .red }
        return coordinator.storesRemoved ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(headline, systemImage: coordinator.succeeded
                  ? (coordinator.storesRemoved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                  : "xmark.octagon.fill")
                .font(.title2).bold()
                .foregroundStyle(headlineColor)

            if let msg = coordinator.failureMessage {
                Text(msg)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                summaryRow(copy("row_stores"),
                           coordinator.storesRemoved ? copy("stores_removed")
                           : copy("stores_not_removed"))
                summaryRow(copy("row_colima"), colimaSummary)
                summaryRow(copy("row_knowledge"), knowledgeSummary)
            }
            .font(.callout)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(copy("quit")) { quit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":").bold().frame(width: 130, alignment: .leading)
            Text(value).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var colimaSummary: String {
        switch coordinator.colimaResult {
        case "removed":           return copy("colima_removed")
        case "kept":              return copy("colima_kept")
        case "absent":            return copy("colima_absent")
        case "delete_failed":     return copy("colima_delete_failed")
        case "skipped_no_binary": return copy("colima_no_binary")
        case "":                  return copy("colima_default")
        default:                  return coordinator.colimaResult
        }
    }

    private var knowledgeSummary: String {
        switch coordinator.knowledgeStaging {
        case "preserved":       return copy("knowledge_preserved")
        case "purged":          return copy("knowledge_purged")
        case "absent":          return copy("knowledge_absent")
        case "preserve_failed": return copy("knowledge_preserve_failed")
        case "":                return copy("knowledge_default")
        default:                return coordinator.knowledgeStaging
        }
    }
}
