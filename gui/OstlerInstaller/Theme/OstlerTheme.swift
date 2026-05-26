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
    /// 1:1 with the .css source (e.g., `#7A1F1F` → `Color(hex: 0x7A1F1F)`).
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
    static let ostlerOxblood      = Color(hex: 0x7A1F1F)  // --accent
    static let ostlerOxbloodHover = Color(hex: 0x6E1717)  // --accent-hover
    static let ostlerOxbloodWarm  = Color(hex: 0xA82A2A)  // --accent-warm
    static let ostlerInkBlue      = Color(hex: 0x1E2C52)  // --accent-2
    static let ostlerForest       = Color(hex: 0x2C4A2C)  // --accent-3

    // Hairlines / dividers (rgba on ink)
    static let ostlerHairline      = Color(hex: 0x14120E, opacity: 0.50)
    static let ostlerHairlineSoft  = Color(hex: 0x14120E, opacity: 0.18)
    static let ostlerHairlineFaint = Color(hex: 0x14120E, opacity: 0.08)

    // Soft accent fills (selection, focus, hover-on-light)
    static let ostlerOxbloodSoft   = Color(hex: 0x7A1F1F, opacity: 0.12)
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
// Brand fonts:
//   Display - Outfit (registered via Info.plist ATSApplicationFontsPath = "Fonts")
//   Body    - IBM Plex Sans (registered via Info.plist ATSApplicationFontsPath)
//   Mono    - JetBrains Mono (registered via Info.plist ATSApplicationFontsPath)
//
// If a custom face fails to register at launch (font file missing, name
// drift in a future Apple release), SwiftUI's `.custom` falls back to the
// system font for the `relativeTo:` text style, so views never render
// unreadable. The `relativeTo:` argument also lets Dynamic Type scale the
// custom face the same way it scales the system face.
//
// `tracking` is in points (SwiftUI), the .css uses em. Values converted
// at the relevant font size.

extension Font {

    /// PostScript names of the bundled brand fonts.
    /// IBM Plex Sans uses PostScript names that truncate per Apple's 31-char
    /// PS-name limit: Regular drops the -Regular suffix, Medium is `Medm`,
    /// SemiBold is `SmBld`. Don't "fix" these to the long forms -- the
    /// truncated names are the source-of-truth in the TTFs.
    enum OstlerFontName {
        static let displayRegular = "Outfit-Regular"
        static let displayMedium  = "Outfit-Medium"
        static let displaySemi    = "Outfit-SemiBold"
        static let displayBold    = "Outfit-Bold"

        static let bodyRegular    = "IBMPlexSans"
        static let bodyMedium     = "IBMPlexSans-Medm"
        static let bodySemi       = "IBMPlexSans-SmBld"

        static let monoRegular    = "JetBrainsMono-Regular"
        static let monoMedium     = "JetBrainsMono-Medium"
    }

    static let ostlerDisplay = Font.custom(OstlerFontName.displayBold, size: 32, relativeTo: .largeTitle)
    static let ostlerH1      = Font.custom(OstlerFontName.displaySemi, size: 24, relativeTo: .title)
    static let ostlerH2      = Font.custom(OstlerFontName.displaySemi, size: 18, relativeTo: .title2)
    static let ostlerH3      = Font.custom(OstlerFontName.displaySemi, size: 14, relativeTo: .title3)
    static let ostlerBody    = Font.custom(OstlerFontName.bodyRegular, size: 13, relativeTo: .body)
    static let ostlerBodyLg  = Font.custom(OstlerFontName.bodyRegular, size: 14, relativeTo: .body)
    static let ostlerCaption = Font.custom(OstlerFontName.bodyMedium,  size: 11, relativeTo: .caption)
    static let ostlerStrap   = Font.custom(OstlerFontName.displaySemi, size: 10, relativeTo: .caption2)
    static let ostlerMono    = Font.custom(OstlerFontName.monoRegular, size: 11, relativeTo: .footnote)
    static let ostlerMonoSm  = Font.custom(OstlerFontName.monoRegular, size: 10, relativeTo: .footnote)
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
            .font(.custom(Font.OstlerFontName.displaySemi, size: 14, relativeTo: .body))
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
            .font(.custom(Font.OstlerFontName.displayMedium, size: 14, relativeTo: .body))
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
