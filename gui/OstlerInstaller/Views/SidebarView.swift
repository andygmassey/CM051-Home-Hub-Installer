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
                    .font(.custom(Font.OstlerFontName.displaySemi, size: 18, relativeTo: .title))
                    .tracking(2.4)
                    .foregroundStyle(Color.ostlerInk)
                Text(ViewCopy.shared.string(for: "sidebar.subtitle"))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkMuted)
            }
            .padding(.horizontal, .ostlerSpace3)
            .padding(.top, .ostlerSpace4)
            .padding(.bottom, .ostlerSpace3)

            // ScrollView claims all available vertical space so the
            // bottom-anchored footer never crowds out the step list.
            // ScrollViewReader keeps the active step (or, on failure,
            // the failed step) visible by auto-scrolling to it; the
            // sidebar can hold 21 steps which doesn't fit in the
            // viewport without scrolling.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(catalog.ordered) { meta in
                            SidebarRow(meta: meta)
                                .padding(.horizontal, .ostlerSpace2)
                                .id(meta.id)
                        }
                    }
                    .padding(.vertical, .ostlerSpace1)
                }
                .onChange(of: coordinator.currentStepId) { _, newId in
                    if let id = newId {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
                .onChange(of: coordinator.finished) { _, finished in
                    // On failure, pin the failed (last-active) step
                    // in view so the customer sees the xmark on the
                    // right step, not whatever happened to be at the
                    // top of the visible viewport.
                    if finished == .fail, let id = coordinator.currentStepId {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // CX-40 (DMG #27, 2026-05-24): 1px top divider above the
            // footer panel so the Steps/Done summary doesn't visually
            // merge into the scroll list above. Matches the right-pane
            // dividing line, gives the footer its own visual frame.
            Divider()

            VStack(alignment: .leading, spacing: .ostlerSpace1) {
                if let finished = coordinator.finished {
                    // F5 polish 2026-05-22: drop the duplicate Failed/Done
                    // label in the sidebar footer when the install
                    // finishes. The top-of-window banner already carries
                    // the failure heading + actions, and the sidebar row
                    // shows the xmark on the actual step that died.
                    // Render an empty marker so the layout doesn't jump.
                    if finished == .ok {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.ostlerForest)
                            .font(.ostlerCaption)
                    } else {
                        EmptyView()
                    }
                } else if coordinator.currentStepIdx > 0 {
                    // Studio retest #8 (2026-05-22) showed "Step 0 of 11"
                    // throughout the questions phase -- mathematically
                    // wrong (rows above show ~21 steps, not 11) and
                    // semantically wrong (we're in questions, not
                    // install). Hide the counter+bar until the install
                    // phase actually starts ticking steps. The
                    // active-row highlight in the rows above already
                    // tells the customer where they are.
                    Text(ViewCopy.shared.string(
                        for: "sidebar.step_counter",
                        fills: [
                            "current": "\(coordinator.currentStepIdx)",
                            "total": "\(coordinator.totalSteps)",
                        ]
                    ))
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
                .frame(width: 16, height: 16)
            Text(meta.title)
                .font(.custom(isActive ? Font.OstlerFontName.bodySemi : Font.OstlerFontName.bodyRegular,
                              size: 12, relativeTo: .body))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
        // CX-39 (DMG #27, 2026-05-24): once the install has finished
        // (either ok or fail), no step is "active" any more. Pre-fix,
        // when `Install finished: ok` arrived BEFORE the final step's
        // gui_step_end (race between async log ingestion + the install-
        // complete marker), the sidebar's last row kept spinning while
        // the "Done" footer rendered the green check -- making the
        // customer think the install was stuck. Gating isActive on
        // `finished == nil` collapses the row to its completed glyph
        // immediately when the terminal state arrives.
        coordinator.finished == nil && coordinator.currentStepId == meta.id
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
            // When the install has failed, the active step never
            // received a completedSteps entry, so it would otherwise
            // keep spinning forever. Show the failure glyph instead.
            if coordinator.finished == .fail {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.ostlerOxblood)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.ostlerOxblood)
            }
        } else {
            Image(systemName: "circle").foregroundStyle(Color.ostlerHairlineSoft)
        }
    }
}
