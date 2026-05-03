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
            // Brand identity at the top: word-mark in the marketing
            // strap voice (uppercase, tracked) over a smaller strap.
            VStack(alignment: .leading, spacing: .ostlerSpace1) {
                Text("OSTLER")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(Color.ostlerInk)
                Text("Installer")
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkMuted)
            }
            .padding(.horizontal, .ostlerSpace3)
            .padding(.top, .ostlerSpace4)
            .padding(.bottom, .ostlerSpace3)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(catalog.ordered) { meta in
                        SidebarRow(meta: meta)
                            .padding(.horizontal, .ostlerSpace2)
                    }
                }
                .padding(.vertical, .ostlerSpace1)
            }

            Spacer()

            VStack(alignment: .leading, spacing: .ostlerSpace1) {
                if let finished = coordinator.finished {
                    Label(finished == .ok ? "Done" : "Failed",
                          systemImage: finished == .ok ? "checkmark.circle.fill"
                                                       : "xmark.circle.fill")
                        .foregroundStyle(finished == .ok ? Color.ostlerForest : Color.ostlerOxblood)
                        .font(.ostlerCaption)
                } else {
                    Text("Step \(coordinator.currentStepIdx) of \(coordinator.totalSteps)")
                        .font(.ostlerStrap)
                        .tracking(1.2)
                        .foregroundStyle(Color.ostlerInkSubdued)
                    ProgressView(value: Double(coordinator.currentStepIdx),
                                 total: Double(max(coordinator.totalSteps, 1)))
                        .progressViewStyle(.linear)
                        .tint(.ostlerOxblood)
                }
            }
            .padding(.horizontal, .ostlerSpace3)
            .padding(.bottom, .ostlerSpace3)
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    let meta: StepMeta

    var body: some View {
        HStack(spacing: .ostlerSpace2) {
            statusIcon
                .frame(width: 18, height: 18)
            Text(meta.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular, design: .rounded))
                .foregroundStyle(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, .ostlerSpace2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.ostlerOxbloodSoft : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.ostlerOxblood)
                    .frame(width: 3, height: 18)
                    .padding(.leading, -2)
            }
        }
    }

    private var status: StepStatus? {
        coordinator.completedSteps.last(where: { $0.id == meta.id })?.status
    }

    private var isActive: Bool {
        coordinator.currentStepId == meta.id
    }

    private var textColor: Color {
        if isActive { return Color.ostlerInk }
        if status != nil { return Color.ostlerInkMuted }
        return Color.ostlerInkSubdued
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let s = status {
            switch s {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.ostlerForest)
            case .warn:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ostlerOxbloodWarm)
            case .fail:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.ostlerOxblood)
            }
        } else if isActive {
            ProgressView()
                .controlSize(.small)
                .tint(.ostlerOxblood)
        } else {
            Image(systemName: "circle").foregroundStyle(Color.ostlerHairlineSoft)
        }
    }
}
