#!/usr/bin/env python3
"""Generate the Ostler installer DMG background image.

Writes an 820x400 PNG to ``gui/assets/dmg-background.png`` with the
brand-cream chassis colour, a single arrow from the OstlerInstaller
icon to the /Applications drop-link, a "Drag Ostler Installer to
Applications" caption, and an informational label under the
Ostler.app icon explaining that it is installed automatically by
the installer (so the customer is not confused about why a second
app sits in the DMG window).

The image is the *background* layer of the DMG window. ``create-dmg``
positions three icons on top of this background:

  - Ostler.app at         (140, 200)
  - OstlerInstaller.app at (340, 200)
  - /Applications at      (660, 200)

The arrow + caption sit in the visible gaps between OstlerInstaller
and /Applications. Ostler.app gets a "(installed automatically)"
label below it; there is no arrow drawn from Ostler.app because
the customer does not need to drag it -- install.sh stages it
into /Applications during the install run (see install.sh section
3.14g).

    +-------------------------------------------------------------------+
    |                                                                   |
    |   [Ostler.app]      [OstlerInstaller]  ----->   [Applications]    |
    |                                                                   |
    |   installed         Drag Ostler Installer to Applications         |
    |   automatically                                                   |
    +-------------------------------------------------------------------+

For the single-app DMG fallback (no Ostler.app bundled), pass
``--single-app`` to fall back to the 660x400 layout used pre-v1.0.

Run from anywhere:

    python3 gui/scripts/generate_dmg_background.py

Requires Pillow (``pip install Pillow``).
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Tuple

from PIL import Image, ImageDraw, ImageFont


# Brand tokens (mirrors OS001 assets/ostler.css --chassis / --ink).
BG: Tuple[int, int, int] = (248, 248, 244)   # --chassis
INK: Tuple[int, int, int] = (20, 18, 14)     # --ink
INK_MUTED: Tuple[int, int, int] = (90, 88, 80)
INK_QUIET: Tuple[int, int, int] = (140, 138, 130)

ICON_SIZE = 128  # matches --icon-size 128 in the Makefile


def _load_font(size: int) -> ImageFont.ImageFont:
    """Resolve a sans font available on the typical Mac build host."""
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


def _draw_arrow(
    draw: ImageDraw.ImageDraw,
    start_center: Tuple[int, int],
    end_center: Tuple[int, int],
) -> None:
    """Draw a horizontal arrow between two icon centres."""
    icon_half = ICON_SIZE // 2
    start_x = start_center[0] + icon_half + 18
    end_x = end_center[0] - icon_half - 18
    y = start_center[1]

    draw.line([(start_x, y), (end_x, y)], fill=INK, width=3)

    # Arrowhead filled triangle.
    head = 14
    draw.polygon(
        [(end_x, y), (end_x - head, y - head + 1), (end_x - head, y + head - 1)],
        fill=INK,
    )


def _draw_centred_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    x_centre: int,
    y_top: int,
    *,
    font: ImageFont.ImageFont,
    fill: Tuple[int, int, int],
) -> None:
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    draw.text((x_centre - text_w // 2, y_top), text, font=font, fill=fill)


def generate_two_app(out_path: Path) -> None:
    width, height = 820, 400
    ostler = (140, 200)
    installer = (340, 200)
    applications = (660, 200)

    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)

    # Single arrow: OstlerInstaller -> Applications.
    _draw_arrow(draw, installer, applications)

    # Caption row under the icons.
    caption_font = _load_font(20)
    info_font = _load_font(14)

    caption_y = installer[1] + (ICON_SIZE // 2) + 36

    # Primary caption sits centred between OstlerInstaller and
    # Applications icons, matching the arrow above it.
    caption_centre = (installer[0] + applications[0]) // 2
    _draw_centred_text(
        draw,
        "Drag Ostler Installer to Applications",
        caption_centre,
        caption_y,
        font=caption_font,
        fill=INK_MUTED,
    )

    # Informational label under Ostler.app, two short lines so it
    # fits in the icon-column width without crowding the icon glyph.
    _draw_centred_text(
        draw,
        "Installed automatically",
        ostler[0],
        caption_y,
        font=info_font,
        fill=INK_QUIET,
    )
    _draw_centred_text(
        draw,
        "by the installer",
        ostler[0],
        caption_y + 20,
        font=info_font,
        fill=INK_QUIET,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, "PNG", optimize=True)
    print(f"wrote {out_path} ({width}x{height}, two-app layout)")


def generate_single_app(out_path: Path) -> None:
    width, height = 660, 400
    installer = (165, 200)
    applications = (495, 200)

    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)
    _draw_arrow(draw, installer, applications)

    caption_font = _load_font(20)
    caption_y = installer[1] + (ICON_SIZE // 2) + 36
    _draw_centred_text(
        draw,
        "Drag Ostler Installer to Applications",
        width // 2,
        caption_y,
        font=caption_font,
        fill=INK_MUTED,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, "PNG", optimize=True)
    print(f"wrote {out_path} ({width}x{height}, single-app layout)")


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "assets" / "dmg-background.png"
    if "--single-app" in sys.argv:
        generate_single_app(out)
    else:
        generate_two_app(out)
