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
//   - a miniature of that pane shows, on a ~4.4 second loop, the app being
//     dragged into the list and switched on (Reduce Motion: the final state
//     with three numbered captions);
//   - the app tile is a real drag source (FDAHandoff.dragProvider), dropped
//     straight onto the list;
//   - "Can't drag it?" reveals the manual "+" route and Show in Finder;
//   - the gate polls a protected read every 2 seconds and advances the moment
//     access is granted. A manual continue link appears only after 20 seconds.
//
// Which app: the probe reads protected files from THIS process, and install.sh
// runs as its child, inheriting this app's grant. So the installer bundle is
// the one macOS needs listed; it is named with its CFBundleDisplayName.

import SwiftUI
import AppKit

struct FullDiskAccessGateView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var granted = FDADebug.showGranted
    @State private var showManual = FDADebug.showManual
    @State private var showAlreadyOn = (FDADebug.linkDelay == 0)

    private let appURL = FDAHandoff.appBundleURL()
    private let appName = FDAHandoff.displayName()
    private let appIcon = NSWorkspace.shared.icon(forFile: FDAHandoff.appBundleURL().path)

    /// Seconds before the manual continue link appears.
    static let manualContinueDelay: Double = 20

    private var reduceMotion: Bool {
        FDADebug.reduceMotion || systemReduceMotion
    }

    var body: some View {
        VStack(spacing: 0) {
            heading
                .padding(.bottom, CGFloat.ostlerSpace3)
            hero
            instruction
                .padding(.top, CGFloat.ostlerSpace3)
            dragTile
                .padding(.top, CGFloat.ostlerSpace2)
            cantDrag
                .padding(.top, CGFloat.ostlerSpace2)
            Spacer(minLength: CGFloat.ostlerSpace2)
            footer
        }
        .padding(.horizontal, CGFloat.ostlerSpace5)
        .padding(.vertical, CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.ostlerChassis)
        .onAppear {
            if FDADebug.active { return }
            AuthorizationHelper.shared.openFullDiskAccessPane()
            FDAWindowPlacement.dockInstallerLeft()
        }
        .task {
            if FDADebug.snapshotDir != nil {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                FDADebug.writeSnapshots(coordinator: coordinator)
                NSApp.terminate(nil)
                return
            }
            await watchForGrant()
        }
        .task { await revealManualContinue() }
    }

    // MARK: - Heading and instruction

    private var heading: some View {
        Text(ViewCopy.shared.string(for: "fda_gate.heading"))
            .font(.ostlerH1)
            .tracking(-0.4)
            .foregroundStyle(Color.ostlerInk)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }

    private var instruction: some View {
        Text(ViewCopy.shared.string(for: "fda_gate.instruction", fills: ["app": appName]))
            .font(.ostlerBodyLg)
            .foregroundStyle(Color.ostlerInkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520)
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if reduceMotion {
            VStack(spacing: CGFloat.ostlerSpace3) {
                FDAMiniSettings(frame: .final, appName: appName, appIcon: appIcon)
                HStack(alignment: .top, spacing: CGFloat.ostlerSpace3) {
                    stillCaption(1, key: "fda_gate.anim_drag")
                    stillCaption(2, key: "fda_gate.anim_switch_on")
                    stillCaption(3, key: "fda_gate.anim_done")
                }
                .frame(width: FDAMiniSettings.size.width * FDAMiniSettings.displayScale)
            }
        } else {
            if let t = FDADebug.frozenProgress {
                FDAMiniSettings(frame: FDAHeroTimeline.frame(at: t), appName: appName, appIcon: appIcon)
            } else {
                animatedHero
            }
        }
    }

    private var animatedHero: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let t = seconds.truncatingRemainder(dividingBy: FDAHeroTimeline.period) / FDAHeroTimeline.period
            FDAMiniSettings(frame: FDAHeroTimeline.frame(at: t), appName: appName, appIcon: appIcon)
        }
    }

    private func stillCaption(_ number: Int, key: String) -> some View {
        HStack(alignment: .top, spacing: CGFloat.ostlerSpace2) {
            Text("\(number)")
                .font(.ostlerCaption)
                .foregroundStyle(Color.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.ostlerOxblood))
            Text(ViewCopy.shared.string(for: key))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - The draggable app tile

    private var dragTile: some View {
        HStack(spacing: CGFloat.ostlerSpace2) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 44, height: 44)
            Text(appName)
                .font(.ostlerH3)
                .foregroundStyle(Color.ostlerInk)
        }
        .padding(.leading, CGFloat.ostlerSpace2)
        .padding(.trailing, CGFloat.ostlerSpace4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.ostlerPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.ostlerHairlineSoft, lineWidth: 1)
        )
        .shadow(color: Color.ostlerInk.opacity(0.08), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrag { FDAHandoff.dragProvider(for: appURL) }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Can't drag it?

    private var cantDrag: some View {
        VStack(spacing: CGFloat.ostlerSpace2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showManual.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(ViewCopy.shared.string(for: "fda_gate.cant_drag"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showManual ? 90 : 0))
                }
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkMuted)
            }
            .buttonStyle(.plain)

            if showManual {
                HStack(spacing: CGFloat.ostlerSpace2) {
                    Text(ViewCopy.shared.string(for: "fda_gate.manual_steps", fills: ["app": appName]))
                        .font(.ostlerCaption)
                        .foregroundStyle(Color.ostlerInk)
                    Button(ViewCopy.shared.string(for: "fda_gate.reveal_button")) {
                        NSWorkspace.shared.activateFileViewerSelecting([appURL])
                    }
                    .buttonStyle(.plain)
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerOxblood)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(Color.ostlerOxblood.opacity(0.6), lineWidth: 1))
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer: status, primary action, privacy

    private var footer: some View {
        VStack(spacing: CGFloat.ostlerSpace2) {
            statusRow
            if coordinator.showFDAContinueAnyway { unconfirmedControls }
            Button(ViewCopy.shared.string(for: "fda_gate.open_settings_button")) {
                AuthorizationHelper.shared.openFullDiskAccessPane()
            }
            .buttonStyle(.ostlerPrimary)
            .keyboardShortcut(.defaultAction)

            // Reserves its line so the layout does not jump when it appears.
            Button(ViewCopy.shared.string(for: "fda_gate.already_on_link")) {
                coordinator.recheckFullDiskAccessAndProceed()
            }
            .buttonStyle(.plain)
            .font(.ostlerCaption)
            .foregroundStyle(Color.ostlerInkMuted)
            .underline()
            .opacity(showAlreadyOn && !granted ? 1 : 0)
            .allowsHitTesting(showAlreadyOn && !granted)
            .accessibilityHidden(!(showAlreadyOn && !granted))

            privacyLine
        }
    }

    private var statusRow: some View {
        HStack(spacing: CGFloat.ostlerSpace2) {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FDAMiniSettings.macGreen)
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
        .animation(.easeInOut(duration: 0.2), value: granted)
    }

    private var privacyLine: some View {
        HStack(spacing: CGFloat.ostlerSpace2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ostlerForest)
            Text(ViewCopy.shared.string(for: "fda_gate.privacy_line"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkMuted)
        }
        .frame(maxWidth: .infinity)
    }

    /// Shown only after manual rechecks failed twice: the honest escape hatch.
    private var unconfirmedControls: some View {
        VStack(spacing: CGFloat.ostlerSpace2) {
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
    }

    // MARK: - Behaviour

    /// Polls a protected read every 2 seconds. On the first successful read,
    /// shows the check mark briefly and hands on to the normal flow.
    private func watchForGrant() async {
        if FDADebug.active { return }
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

    /// The manual continue is a last resort; it appears only after a wait.
    private func revealManualContinue() async {
        let delay = FDADebug.linkDelay ?? Self.manualContinueDelay
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        if !Task.isCancelled { withAnimation(.easeIn(duration: 0.3)) { showAlreadyOn = true } }
    }
}

// MARK: - Hero animation timeline (pure, so a test can drive it)

/// Everything the miniature needs to draw one instant of the loop.
struct FDAHeroFrame: Equatable {
    /// Cursor tip, in hero coordinates; opacity 0 hides it.
    var cursor: CGPoint
    var cursorOpacity: Double
    /// Centre and scale of the travelling app icon; opacity 0 hides it.
    var tile: CGPoint
    var tileScale: Double
    var tileOpacity: Double
    /// 0 = row absent, 1 = row fully in the list.
    var row: Double
    /// 0 = toggle off, 1 = toggle on.
    var toggle: Double
    /// Cursor "click" squeeze, 0...1.
    var press: Double

    /// The resting end state: row in, toggle on, nothing travelling.
    static let final = FDAHeroFrame(cursor: .zero, cursorOpacity: 0, tile: .zero, tileScale: 1,
                                    tileOpacity: 0, row: 1, toggle: 1, press: 0)
}

enum FDAHeroTimeline {
    /// One loop, seconds.
    static let period: Double = 4.4

    private static func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
    /// 0...1 progress of t through [a, b], eased.
    private static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double {
        ease((t - a) / (b - a))
    }
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    // Hero coordinates (see FDAMiniSettings.size).
    static let tileSource = CGPoint(x: 220, y: 192)
    static let dropPoint = CGPoint(x: 290, y: 80)
    static let rowIcon = CGPoint(x: 146, y: 56)
    static let toggleSpot = CGPoint(x: 397, y: 54)
    static let cursorStart = CGPoint(x: 330, y: 205)

    static func frame(at t: Double) -> FDAHeroFrame {
        // 0.00-0.10 cursor arrives, 0.10-0.17 grab, 0.17-0.50 drag,
        // 0.50-0.64 drop and row slides in, 0.64-0.76 cursor to toggle,
        // 0.76-0.84 toggle on, 0.84-0.95 hold, 0.95-1.00 reset.
        let arrive = seg(t, 0.0, 0.10)
        let drag = seg(t, 0.17, 0.50)
        let toToggle = seg(t, 0.64, 0.76)
        let reset = 1 - seg(t, 0.95, 1.0)

        var cursor = lerp(cursorStart, CGPoint(x: tileSource.x + 6, y: tileSource.y + 8), arrive)
        if t >= 0.17 { cursor = lerp(CGPoint(x: tileSource.x + 6, y: tileSource.y + 8), CGPoint(x: dropPoint.x + 6, y: dropPoint.y + 8), drag) }
        if t >= 0.64 { cursor = lerp(CGPoint(x: dropPoint.x + 6, y: dropPoint.y + 8), toggleSpot, toToggle) }

        let grab = seg(t, 0.10, 0.17)
        let drop = seg(t, 0.52, 0.585)
        var tile = tileSource
        if t >= 0.17 { tile = lerp(tileSource, dropPoint, drag) }
        if t >= 0.52 { tile = lerp(dropPoint, rowIcon, drop) }
        // 40pt tile shrinks to the row's 20pt icon, then the row's own icon takes over.
        let tileScale = 1 + 0.10 * grab - 0.10 * grab * drop - 0.50 * drop
        let tileOpacity = min(seg(t, 0.0, 0.06), 1 - seg(t, 0.585, 0.615))

        let row = seg(t, 0.46, 0.60) * reset
        let toggle = seg(t, 0.76, 0.84) * reset
        let press = t >= 0.76 && t < 0.84 ? sin((t - 0.76) / 0.08 * .pi) : 0
        let cursorOpacity = min(seg(t, 0.0, 0.05), 1 - seg(t, 0.86, 0.94))

        return FDAHeroFrame(cursor: cursor, cursorOpacity: cursorOpacity, tile: tile,
                            tileScale: tileScale, tileOpacity: tileOpacity,
                            row: row, toggle: toggle, press: press)
    }
}

// MARK: - Miniature of System Settings > Privacy & Security > Full Disk Access

struct FDAMiniSettings: View {
    let frame: FDAHeroFrame
    let appName: String
    let appIcon: NSImage

    /// Hero canvas: the miniature window plus room for the tile beneath it.
    static let size = CGSize(width: 440, height: 216)
    /// The miniature is designed at `size` and shown a little larger.
    static let displayScale: CGFloat = 1.2
    private static let windowHeight: CGFloat = 176
    private static let sidebarWidth: CGFloat = 112
    private static let rowHeight: CGFloat = 32
    private static let listX: CGFloat = 126
    private static let listY: CGFloat = 40
    private static let listWidth: CGFloat = 298

    /// macOS system green (toggle on, success).
    static let macGreen = Color(red: 0.204, green: 0.78, blue: 0.349)
    private static let selectionBlue = Color(red: 0.0, green: 0.478, blue: 1.0)
    private static let skeleton = Color.black.opacity(0.10)

    var body: some View {
        ZStack(alignment: .topLeading) {
            window
                .frame(width: Self.size.width, height: Self.windowHeight)

            // Travelling copy of the app icon.
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 40, height: 40)
                .scaleEffect(frame.tileScale)
                .shadow(color: .black.opacity(0.25 * frame.tileOpacity), radius: 6, x: 0, y: 3)
                .opacity(frame.tileOpacity)
                .position(frame.tile)

            // The real macOS arrow, hot-spot at its top-left.
            let cursorImage = NSCursor.arrow.image
            Image(nsImage: cursorImage)
                .scaleEffect(1 - 0.08 * frame.press)
                .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
                .opacity(frame.cursorOpacity)
                .position(x: frame.cursor.x + cursorImage.size.width / 2,
                          y: frame.cursor.y + cursorImage.size.height / 2)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .scaleEffect(Self.displayScale, anchor: .topLeading)
        .frame(width: Self.size.width * Self.displayScale, height: Self.size.height * Self.displayScale,
               alignment: .topLeading)
        .accessibilityHidden(true)
    }

    // The window chrome, sidebar and content pane.
    private var window: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.955))
            // Sidebar
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.915))
                .frame(width: Self.sidebarWidth)
                .mask(alignment: .leading) { Rectangle().frame(width: Self.sidebarWidth) }
            sidebar
            // Content title
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(Self.skeleton)
                    .frame(width: 96, height: 9)
            }
            .offset(x: Self.listX, y: 17)
            list
                .offset(x: Self.listX, y: Self.listY)
            trafficLights
                .offset(x: 10, y: 9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 6)
    }

    private var trafficLights: some View {
        HStack(spacing: 5) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34),
                     Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                Circle().fill(c).frame(width: 8, height: 8)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<6, id: \.self) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == 3 ? Color.white : Color.black.opacity(0.22))
                        .frame(width: 11, height: 11)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == 3 ? Color.white.opacity(0.9) : Self.skeleton)
                        .frame(width: CGFloat([52, 44, 58, 66, 40, 50][i]), height: 6)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(i == 3 ? Self.selectionBlue : .clear))
            }
        }
        .padding(.horizontal, 8)
        .offset(y: 32)
        .frame(width: Self.sidebarWidth, alignment: .topLeading)
    }

    // The inset grouped list: the Ostler row slides in above two greyed rows.
    private var list: some View {
        VStack(spacing: 0) {
            ostlerRow
                .frame(height: Self.rowHeight * frame.row, alignment: .top)
                .clipped()
                .opacity(max(0, (frame.row - 0.55) / 0.45))
            greyRow(widths: (70, 34), tint: 0.30)
            greyRow(widths: (58, 40), tint: 0.24)
            footerBar
        }
        .frame(width: Self.listWidth)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var ostlerRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(appName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 0)
                toggle(progress: frame.toggle)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            Divider().opacity(0.6)
        }
        .frame(height: Self.rowHeight + 1, alignment: .top)
    }

    private func greyRow(widths: (CGFloat, CGFloat), tint: Double) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(tint))
                    .frame(width: 20, height: 20)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.13))
                    .frame(width: widths.0, height: 7)
                Spacer(minLength: 0)
                toggle(progress: 0).opacity(0.55)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            Divider().opacity(0.6)
        }
    }

    private var footerBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
            Image(systemName: "minus").font(.system(size: 9, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.black.opacity(0.45))
        .padding(.horizontal, 10)
        .frame(height: 22)
    }

    /// macOS-style switch: grey track to green, white knob.
    private func toggle(progress p: Double) -> some View {
        let off = Color(white: 0.84)
        return ZStack(alignment: .leading) {
            Capsule().fill(off)
            Capsule().fill(Self.macGreen).opacity(p)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
                .frame(width: 14, height: 14)
                .offset(x: 2 + 14 * p)
        }
        .frame(width: 30, height: 18)
    }
}

/// Development-only hooks. In Release every value is inert (false / nil), so
/// they let a screenshot jump to this screen and freeze the loop only in a
/// Debug build.
///   OSTLER_DEBUG_FDA_GATE=1       open on this screen, no Settings, no probe
///   OSTLER_DEBUG_FDA_T=0.35       freeze the hero at that point of the loop
///   OSTLER_DEBUG_FDA_REDUCE=1     render the Reduce Motion layout
///   OSTLER_DEBUG_FDA_GRANTED=1    show the "Access granted" state
///   OSTLER_DEBUG_FDA_LINK_AFTER=0 seconds before the manual link appears
///   OSTLER_DEBUG_FDA_MANUAL=1     open the "Can't drag it?" disclosure
///   OSTLER_DEBUG_FDA_SNAPSHOT_DIR=/dir  render the screen to PNGs and quit
@MainActor
enum FDADebug {
    #if DEBUG
    static var overrides: [String: String] = [:]
    private static func value(_ k: String) -> String? {
        overrides[k] ?? ProcessInfo.processInfo.environment[k]
    }
    static var active: Bool { value("OSTLER_DEBUG_FDA_GATE") == "1" }
    static var reduceMotion: Bool { active && value("OSTLER_DEBUG_FDA_REDUCE") == "1" }
    static var showGranted: Bool { active && value("OSTLER_DEBUG_FDA_GRANTED") == "1" }
    static var showManual: Bool { active && value("OSTLER_DEBUG_FDA_MANUAL") == "1" }
    static var frozenProgress: Double? { active ? value("OSTLER_DEBUG_FDA_T").flatMap(Double.init) : nil }
    static var linkDelay: Double? { active ? value("OSTLER_DEBUG_FDA_LINK_AFTER").flatMap(Double.init) : nil }
    static var snapshotDir: String? { active ? ProcessInfo.processInfo.environment["OSTLER_DEBUG_FDA_SNAPSHOT_DIR"] : nil }

    /// Renders the screen at the installer's window size, once per state, to
    /// PNGs. SwiftUI's own renderer, so it needs no Screen Recording grant.
    static func writeSnapshots(coordinator: InstallerCoordinator) {
        guard let dir = snapshotDir else { return }
        let states: [(String, [String: String])] = [
            ("t30", ["OSTLER_DEBUG_FDA_T": "0.30"]),
            ("t50", ["OSTLER_DEBUG_FDA_T": "0.51"]),
            ("t85", ["OSTLER_DEBUG_FDA_T": "0.88"]),
            ("granted", ["OSTLER_DEBUG_FDA_T": "0.88", "OSTLER_DEBUG_FDA_GRANTED": "1"]),
            ("manual", ["OSTLER_DEBUG_FDA_T": "0.88", "OSTLER_DEBUG_FDA_MANUAL": "1", "OSTLER_DEBUG_FDA_LINK_AFTER": "0"]),
            ("reduce", ["OSTLER_DEBUG_FDA_REDUCE": "1"]),
        ]
        for (name, env) in states {
            overrides = env
            let view = FullDiskAccessGateView()
                .environmentObject(coordinator)
                .frame(width: 880, height: 620)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("fda_v2_\(name).png"))
            }
        }
        overrides = [:]
    }
    #else
    static var active: Bool { false }
    static var reduceMotion: Bool { false }
    static var showGranted: Bool { false }
    static var showManual: Bool { false }
    static var frozenProgress: Double? { nil }
    static var linkDelay: Double? { nil }
    static var snapshotDir: String? { nil }
    static func writeSnapshots(coordinator: InstallerCoordinator) {}
    #endif
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
