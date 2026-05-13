#!/usr/bin/env python3
"""Generate the OstlerInstaller DMG background image.

Writes a 660x400 PNG to ``gui/assets/dmg-background.png`` with the
brand-cream chassis colour, a centred arrow between the icon
positions, and a "Drag Ostler Installer to Applications" caption.

The image is the *background* layer of the DMG window. ``create-dmg``
positions the .app icon at (165, 200) and the /Applications symlink
at (495, 200) on top of this background, so the arrow + caption sit
in the visible gaps:

    +----------------------------------------------------------------+
    |                                                                |
    |   [icon]          --------->          [Applications]           |
    |                                                                |
    |       Drag Ostler Installer to Applications                    |
    |                                                                |
    +----------------------------------------------------------------+

v1 launch goal is "not broken", not "polished" -- per the brief at
``HR015/launch/TNM_BRIEF_DMG_INSTALLER_UX_2026-05-13.md``. Post-launch,
a designer-polished version with brand illustration can replace
``gui/assets/dmg-background.png`` without touching this script.

Run from anywhere:

    python3 gui/scripts/generate_dmg_background.py

Requires Pillow (``pip install Pillow``).
"""
from __future__ import annotations

from pathlib import Path
from typing import Tuple

from PIL import Image, ImageDraw, ImageFont


# Brand tokens (mirrors OS001 assets/ostler.css --chassis / --ink).
# Kept in this script rather than read from CSS because the script
# has to run in any Python venv without parsing CSS.
BG: Tuple[int, int, int] = (248, 248, 244)   # --chassis
INK: Tuple[int, int, int] = (20, 18, 14)     # --ink
INK_MUTED: Tuple[int, int, int] = (90, 88, 80)

WIDTH = 660
HEIGHT = 400

# Icon centres (must match the --icon X Y args in gui/Makefile's
# create-dmg invocation).
APP_ICON_CENTER = (165, 200)
APPLICATIONS_CENTER = (495, 200)
ICON_SIZE = 128  # matches --icon-size 128 in the Makefile


def _load_font(size: int) -> ImageFont.ImageFont:
    """Resolve a sans font available on the typical Mac build host.

    We try the SF Pro system font first (matches macOS chrome), then
    fall back to Helvetica, then to PIL's bundled default. The
    fallback chain means the script still produces *something* on
    a non-Mac CI host where SF Pro is absent.
    """
    candidates = (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    )
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def _draw_arrow(draw: ImageDraw.ImageDraw) -> None:
    """Draw a horizontal arrow between the two icon positions."""
    # Leave generous padding around each icon so the arrow sits in
    # the gap rather than overlapping the icon glyphs Finder draws
    # on top.
    icon_half = ICON_SIZE // 2
    start_x = APP_ICON_CENTER[0] + icon_half + 18
    end_x = APPLICATIONS_CENTER[0] - icon_half - 18
    y = APP_ICON_CENTER[1]

    line_thickness = 3
    draw.line([(start_x, y), (end_x, y)], fill=INK, width=line_thickness)

    # Arrowhead. Filled triangle.
    head_size = 14
    draw.polygon(
        [
            (end_x, y),
            (end_x - head_size, y - head_size + 1),
            (end_x - head_size, y + head_size - 1),
        ],
        fill=INK,
    )


def _draw_caption(draw: ImageDraw.ImageDraw) -> None:
    """Draw the instructional caption below the icon row."""
    text = "Drag Ostler Installer to Applications"
    font = _load_font(20)
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    # Place below the icons. ICON center is y=200, icon spans down
    # to ~264 with size 128, so y=305 sits clear of the icon glyphs.
    y = APP_ICON_CENTER[1] + (ICON_SIZE // 2) + 36
    draw.text(
        ((WIDTH - text_w) // 2, y),
        text, font=font, fill=INK_MUTED,
    )


def generate(out_path: Path) -> None:
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)
    _draw_arrow(draw)
    _draw_caption(draw)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, "PNG", optimize=True)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "assets" / "dmg-background.png"
    generate(out)
