# CX-81 B8b -- TNM probe (DialogIcon source-asset findings)

Date: 2026-05-26
Branch: feat/cx81-b8b-dialog-icon-2026-05-26 (off B8's pushed branch)

## Premise being verified

B8 wired the FDA dialog to render with AppIcon.icns (the OstlerInstaller
app icon) instead of the generic `with icon note` system note. Andy ran
that DMG and reported a visible **bounding-box / "feint square outline"**
around the marque in the dialog. Hypothesis: AppIcon was designed with
internal padding so macOS can apply its squircle mask on Dock /
Launchpad. In dialog context that mask is NOT applied, so the icon's
full square canvas (padding + the off-white squircle background) shows.

Confirmed by visual inspection of the existing AppIcon source PNG
(`gui/OstlerInstaller/Assets.xcassets/AppIcon.appiconset/icon_1024.png`):
the asset is a **black globe motif** inside a **cream-coloured squircle
background** with internal padding. The cream squircle is the
bounding-box Andy reported.

## Source-asset search

Searched the canonical brand asset locations for an Ostler "O" mark
matching the brief (oxblood circle + white "O" letter, edge-to-edge):

| Location | Asset | Verdict |
| -------- | ----- | ------- |
| HR015 launch/brand_ref_chat.png | Wiki person card (oxblood pill tags + Gravatar) | Shows brand colour family, not the O avatar |
| CM054 - Ostler Branding/01 - Logo/ostler-marque.svg | Complex marque (eye-of-Sauron style emblem in white-on-black) | Not an "O" letter -- intricate inner detail |
| CM054 - Ostler Branding/03 - App Icon/IllustratorAppIcons-Ostler_1024x1024@1x.png | Black-globe-on-cream squircle | Identical to AppIcon source -- the bug |
| OS001 - Public website/assets/{ostler-marque.svg, icon-512.png} | Black-circle-with-globe motif | Not the O letter |
| CM044 wiki extra.css | Border-radius:50% Gravatar avatars + oxblood `#7A1F1F` accent | Conceptual reference for circular avatar treatment |

**Finding: no existing brand asset matches the brief.** The "Ostler O
brand mark (oxblood circle + white O letter)" Andy describes is a
**conceptual treatment** consistent with the wiki's oxblood pill chips
and the assistant-avatar look-and-feel, not a delivered PNG/SVG in the
brand kit.

## Decision: programmatic generation

Per the brief's fallback path, generated the icon programmatically
using:
- **Outfit-Bold.ttf** -- the Ostler brand display face, vendored at
  `gui/OstlerInstaller/Resources/Fonts/Outfit-Bold.ttf`. Identical to
  the wordmark family, so the dialog icon's letter visually rhymes
  with the marketing wordmark.
- **Canonical oxblood `#7A1F1F`** (NOT `#8B1F1F` -- memory
  `feedback_ostler_brand_light_not_dark` records this as the locked
  brand colour).
- **Pure white `#FFFFFF`** for the letter.

PIL renders a 1024x1024 PNG:
1. Edge-to-edge oxblood circle (0px inset) so dialog rendering has zero
   bounding-box padding to expose.
2. Letter "O" geometrically centred, scaled so the glyph bounding box
   spans 58% of canvas width (~592 px). The 58% ratio matches the
   visual weight Andy described in the wiki avatar treatment.
3. Outfit-Bold's "O" glyph has visibly thicker side strokes than
   top/bottom strokes -- this is the typographic tell that distinguishes
   it from a 0 (zero) or a Q (no descender, no whitespace at descender
   position). Confirmed at 16x16, 32x32, 64x64, 128x128 render sizes.

Source PNG sample (1024):

```
   work/source_1024.png
   # 1024x1024 RGBA, font=735pt, glyph=592x537 px
```

iconset pipeline:

```bash
sips -z {size} ... source_1024.png --out icon_{size}.png   # x10
iconutil -c icns DialogIcon.iconset -o DialogIcon.icns
```

Final asset: `gui/OstlerInstaller/Resources/DialogIcon.icns` (160 321
bytes, valid Mac OS X icon container, all 10 sizes round-trip cleanly
through `iconutil -c iconset`).

## V1.1 follow-up

B8b's icon is programmatically generated. For V1.1+, commission a
proper vector from a designer pass (per
`feedback_brand_changes_need_design_pass`). The acceptance criteria:
- Vector source (SVG) checked into CM054 - Ostler Branding/03 - App Icon/
  with a `ostler-dialog-marque.svg` name.
- Letter "O" hand-drawn rather than typeface-rendered, with optical
  corrections at small sizes (16x16 dialog rendering needs visibly
  bolder stroke than the typeface gives at that point size).
- Multi-resolution iconset including the macOS 64x64 + 1024x1024 sizes
  that some macOS releases use.

The B8b programmatic version is acceptable v1.0 ship quality (visually
clean, unambiguous, brand-consistent), but the designer-driven vector
is the v1.1 upgrade path.

## What I did NOT touch

- B8 branch (`feat/cx81-b8-fda-dialog-icon-wording-2026-05-26`) -- branched
  off it cleanly; B8's wording rewrite is preserved verbatim.
- B8's icon-resolution block in install.sh -- kept AppIcon.icns probes
  as a SECONDARY fallback so any in-flight DMG cut that landed pre-B8b
  doesn't regress to the generic system note icon.
- `with icon note` dev/CI/headless fallback -- retained at the bottom
  of the chain.
- project.yml -- no edit needed. The `resources: - path:
  OstlerInstaller/Resources` block already pulls the entire directory
  (excluding Fonts/) into Contents/Resources/. Confirmed by inspecting
  ~/.ostler-release-artefacts/OstlerInstaller-1.0.0-2026-05-25.dmg
  where `Resources/{HintCopy.json,ViewCopy.json}` land via the same
  glob.
- release.sh / gui/Makefile -- no AppIcon.icns refs in either; the
  bundle layout is wholly driven by xcodebuild + project.yml. DialogIcon
  rides the same machinery.
