// ContentView.swift
//
// The three screens: confirm (with the two destructive opt-ins), running
// (phase progress), and done (an honest summary — including when the data
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

// MARK: - Confirm

struct ConfirmView: View {
    @EnvironmentObject var coordinator: UninstallerCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Uninstall Ostler")
                .font(.title).bold()

            Text("This removes the Ostler app, its background services, its "
                 + "Docker data stores, and the Ostler folder in your home "
                 + "directory. Your generated content in Documents/Ostler is "
                 + "kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !coordinator.uninstallerPresent {
                Label("The Ostler uninstaller was not found. Ostler may already "
                      + "be uninstalled.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle(isOn: $coordinator.options.removeColima) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also delete the shared Docker VM (about 30 GB)")
                    Text("Only if Ostler was the only thing using Docker on "
                         + "this Mac. This is the shared colima ‘default’ VM and "
                         + "may hold Docker data unrelated to Ostler.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $coordinator.options.purgeKnowledgeData) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also delete my imported knowledge data")
                    Text("Wipes the knowledge-staging cache (imported notes and "
                         + "images). Left in place by default so a reinstall can "
                         + "reuse it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { quit() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Uninstall Ostler") { coordinator.start() }
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
            Text("Uninstalling…").font(.title2).bold()

            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(coordinator.currentPhase.isEmpty ? "Working" : coordinator.currentPhase)
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
        if !coordinator.succeeded { return "Uninstall did not finish" }
        return coordinator.storesRemoved ? "Ostler has been removed"
                                         : "Ostler removed — but your data stores were NOT"
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
                summaryRow("Data stores",
                           coordinator.storesRemoved ? "removed"
                           : "NOT removed — start Docker and run: cd ~/.ostler && docker compose down -v")
                summaryRow("Shared colima VM", colimaSummary)
                summaryRow("Knowledge data", knowledgeSummary)
            }
            .font(.callout)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Quit") { quit() }
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
        case "removed":           return "deleted"
        case "kept":              return "kept (still on disk)"
        case "absent":            return "none present"
        case "delete_failed":     return "delete failed — remove manually with: colima delete default"
        case "skipped_no_binary": return "not deleted (colima not found)"
        case "":                  return "kept"
        default:                  return coordinator.colimaResult
        }
    }

    private var knowledgeSummary: String {
        switch coordinator.knowledgeStaging {
        case "preserved":       return "kept for a reinstall"
        case "purged":          return "deleted"
        case "absent":          return "none present"
        case "preserve_failed": return "removed (could not be set aside)"
        case "":                return "kept"
        default:                return coordinator.knowledgeStaging
        }
    }
}
