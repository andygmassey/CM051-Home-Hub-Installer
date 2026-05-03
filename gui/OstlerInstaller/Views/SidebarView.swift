// SidebarView.swift
//
// Left rail showing each installer step with a status glyph. Mirrors
// the canonical step order from StepCatalog. The currently-running
// step pulses; completed steps show a check or warn glyph.

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    private let catalog = StepCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App identity at the top – sparse, matches Installer.app vibe.
            VStack(alignment: .leading, spacing: 4) {
                Text("Ostler")
                    .font(.title2.weight(.semibold))
                Text("Installer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(catalog.ordered) { meta in
                        SidebarRow(meta: meta)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()

            // Footer: tiny progress + finished state hint.
            VStack(alignment: .leading, spacing: 4) {
                if let finished = coordinator.finished {
                    Label(finished == .ok ? "Done" : "Failed",
                          systemImage: finished == .ok ? "checkmark.circle.fill"
                                                       : "xmark.circle.fill")
                        .foregroundStyle(finished == .ok ? .green : .red)
                        .font(.caption.weight(.medium))
                } else {
                    Text("Step \(coordinator.currentStepIdx) of \(coordinator.totalSteps)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(coordinator.currentStepIdx),
                                 total: Double(max(coordinator.totalSteps, 1)))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    let meta: StepMeta

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 18, height: 18)
            Text(meta.title)
                .font(.system(size: 12))
                .foregroundStyle(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.15) : .clear)
        )
    }

    private var status: StepStatus? {
        coordinator.completedSteps.last(where: { $0.id == meta.id })?.status
    }

    private var isActive: Bool {
        coordinator.currentStepId == meta.id
    }

    private var textColor: Color {
        if isActive { return .primary }
        if status != nil { return .secondary }
        return .secondary.opacity(0.6)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let s = status {
            switch s {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warn:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .fail:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        } else if isActive {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
