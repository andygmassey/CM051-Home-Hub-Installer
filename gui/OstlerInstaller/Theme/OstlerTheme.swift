// OstlerTheme.swift
//
// SwiftUI mapping of the Ostler design tokens published in the marketing
// site at OS001-Public-Website/assets/ostler.css (reskin-v3 branch).
// Values are 1:1 with the CSS :root custom properties so the .app reads
// as the same brand family as the website and the wiki cascade.
//
// Mapping notes:
//   - Outfit (display) and IBM Plex Sans (body) aren't on macOS by default.
//     We approximate display with SF Pro Rounded (geometric, similar terminal
//     feel to Outfit) and leave body to system default. Bundling the actual
//     web fonts is a follow-up if visual parity ever becomes critical.
//   - Card shadow in CSS is a stacked six-layer effect; SwiftUI's `.shadow`
//     is single-pass, so we approximate with one mid-strength shadow.
//   - Spacing scale 4/8/16/24/40/64 is taken directly from the rhythm in
//     the .css (gap: 14, 22, 28, 32, 40, 56 in various places, settled
//     onto power-of-two-ish for SwiftUI).

import SwiftUI

// MARK: - Colour palette

extension Color {
    /// Build a Color from a 24-bit hex literal so the palette below reads
    /// 1:1 with the .css source (e.g., `#8B1F1F` → `Color(hex: 0x8B1F1F)`).
    fileprivate init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    // Backgrounds (off-white "chassis" family + pure white panel)
    static let ostlerChassis      = Color(hex: 0xF8F8F4)
    static let ostlerChassisDeep  = Color(hex: 0xECEBE5)
    static let ostlerPanel        = Color(hex: 0xFFFFFF)

    // Foreground (near-black "ink")
    static let ostlerInk          = Color(hex: 0x14120E)
    static let ostlerInkMuted     = Color(hex: 0x14120E, opacity: 0.65)
    static let ostlerInkSubdued   = Color(hex: 0x14120E, opacity: 0.50)

    // Accents
    static let ostlerOxblood      = Color(hex: 0x8B1F1F)  // --accent
    static let ostlerOxbloodHover = Color(hex: 0x6E1717)  // --accent-hover
    static let ostlerOxbloodWarm  = Color(hex: 0xA82A2A)  // --accent-warm
    static let ostlerInkBlue      = Color(hex: 0x1E2C52)  // --accent-2
    static let ostlerForest       = Color(hex: 0x2C4A2C)  // --accent-3

    // Hairlines / dividers (rgba on ink)
    static let ostlerHairline      = Color(hex: 0x14120E, opacity: 0.50)
    static let ostlerHairlineSoft  = Color(hex: 0x14120E, opacity: 0.18)
    static let ostlerHairlineFaint = Color(hex: 0x14120E, opacity: 0.08)

    // Soft accent fills (selection, focus, hover-on-light)
    static let ostlerOxbloodSoft   = Color(hex: 0x8B1F1F, opacity: 0.12)
    static let ostlerInkBlueSoft   = Color(hex: 0x1E2C52, opacity: 0.10)
}

// `View.tint(_ tint: Color?)` and similar Optional<Color> parameters need
// shadow members so leading-dot syntax keeps working.
extension Optional where Wrapped == Color {
    static var ostlerChassis:       Color? { Color.ostlerChassis }
    static var ostlerChassisDeep:   Color? { Color.ostlerChassisDeep }
    static var ostlerPanel:         Color? { Color.ostlerPanel }
    static var ostlerInk:           Color? { Color.ostlerInk }
    static var ostlerInkMuted:      Color? { Color.ostlerInkMuted }
    static var ostlerInkSubdued:    Color? { Color.ostlerInkSubdued }
    static var ostlerOxblood:       Color? { Color.ostlerOxblood }
    static var ostlerOxbloodHover:  Color? { Color.ostlerOxbloodHover }
    static var ostlerOxbloodWarm:   Color? { Color.ostlerOxbloodWarm }
    static var ostlerInkBlue:       Color? { Color.ostlerInkBlue }
    static var ostlerForest:        Color? { Color.ostlerForest }
}

// MARK: - Spacing scale

extension CGFloat {
    static let ostlerSpace1: CGFloat = 4
    static let ostlerSpace2: CGFloat = 8
    static let ostlerSpace3: CGFloat = 16
    static let ostlerSpace4: CGFloat = 24
    static let ostlerSpace5: CGFloat = 40
    static let ostlerSpace6: CGFloat = 64
}

// SwiftUI's VStack/HStack `spacing:` argument is `CGFloat?`. Dot-syntax on
// an Optional doesn't pick up static members of the Wrapped type, so we
// republish the scale on `Optional<CGFloat>` to keep `.ostlerSpaceN` working
// at every call site.
extension Optional where Wrapped == CGFloat {
    static var ostlerSpace1: CGFloat? { CGFloat.ostlerSpace1 }
    static var ostlerSpace2: CGFloat? { CGFloat.ostlerSpace2 }
    static var ostlerSpace3: CGFloat? { CGFloat.ostlerSpace3 }
    static var ostlerSpace4: CGFloat? { CGFloat.ostlerSpace4 }
    static var ostlerSpace5: CGFloat? { CGFloat.ostlerSpace5 }
    static var ostlerSpace6: CGFloat? { CGFloat.ostlerSpace6 }
}

// MARK: - Type scale
//
// Display family approximates Outfit via SF Pro Rounded. Body is system
// default (SF Pro Text), monospaced is system mono (SF Mono).
//
// `tracking` is in points (SwiftUI), the .css uses em. Values converted
// at the relevant font size.

extension Font {
    static let ostlerDisplay = Font.system(size: 32, weight: .bold,     design: .rounded)
    static let ostlerH1      = Font.system(size: 24, weight: .semibold, design: .rounded)
    static let ostlerH2      = Font.system(size: 18, weight: .semibold, design: .rounded)
    static let ostlerH3      = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let ostlerBody    = Font.system(size: 13, weight: .regular)
    static let ostlerBodyLg  = Font.system(size: 14, weight: .regular)
    static let ostlerCaption = Font.system(size: 11, weight: .medium)
    static let ostlerStrap   = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let ostlerMono    = Font.system(size: 11, design: .monospaced)
    static let ostlerMonoSm  = Font.system(size: 10, design: .monospaced)
}

// `View.font(_:)` takes `Font?`. Same dot-syntax constraint as CGFloat?.
extension Optional where Wrapped == Font {
    static var ostlerDisplay: Font? { Font.ostlerDisplay }
    static var ostlerH1:      Font? { Font.ostlerH1 }
    static var ostlerH2:      Font? { Font.ostlerH2 }
    static var ostlerH3:      Font? { Font.ostlerH3 }
    static var ostlerBody:    Font? { Font.ostlerBody }
    static var ostlerBodyLg:  Font? { Font.ostlerBodyLg }
    static var ostlerCaption: Font? { Font.ostlerCaption }
    static var ostlerStrap:   Font? { Font.ostlerStrap }
    static var ostlerMono:    Font? { Font.ostlerMono }
    static var ostlerMonoSm:  Font? { Font.ostlerMonoSm }
}

// MARK: - Card pattern

struct OstlerCard: ViewModifier {
    var padding: CGFloat = .ostlerSpace3
    var background: Color = .ostlerPanel

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.ostlerHairlineFaint, lineWidth: 1)
            )
            .shadow(color: Color.ostlerInk.opacity(0.06), radius: 18, x: 0, y: 12)
    }
}

extension View {
    func ostlerCard(padding: CGFloat = .ostlerSpace3,
                    background: Color = .ostlerPanel) -> some View {
        modifier(OstlerCard(padding: padding, background: background))
    }
}

// MARK: - Section heading
//
// Display font, weight semibold, tightish tracking, ink colour. Optional
// accent strong word reproduced via the `accent:` argument which forces
// oxblood for the trailing component (matches `<strong>` in section-head).

struct OstlerSectionHead: View {
    let strap: String?
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace1) {
            if let strap, !strap.isEmpty {
                Text(strap.uppercased())
                    .font(.ostlerStrap)
                    .tracking(1.6)
                    .foregroundStyle(Color.ostlerInkMuted)
            }
            Text(title)
                .font(.ostlerH1)
                .tracking(-0.4)
                .foregroundStyle(Color.ostlerInk)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInkMuted)
            }
        }
    }
}

// MARK: - Button styles

/// Primary CTA. Oxblood pill, white text, display weight.
struct OstlerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.ostlerOxbloodHover
                          : Color.ostlerOxblood)
            )
            .opacity(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Ghost / secondary button. Ink-bordered pill, ink text.
struct OstlerGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(configuration.isPressed
                             ? Color.ostlerChassis
                             : Color.ostlerInk)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed
                          ? Color.ostlerInk
                          : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.ostlerInk, lineWidth: 1.2)
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == OstlerPrimaryButtonStyle {
    static var ostlerPrimary: OstlerPrimaryButtonStyle { OstlerPrimaryButtonStyle() }
}

extension ButtonStyle where Self == OstlerGhostButtonStyle {
    static var ostlerGhost: OstlerGhostButtonStyle { OstlerGhostButtonStyle() }
}
