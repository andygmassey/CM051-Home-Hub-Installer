#!/usr/bin/env python3
"""Generate the OstlerInstaller AppIcon + DialogIcon from a true squircle.

TNM_BRIEF_icon_superellipse_FINAL (2026-06-05). The icon is a true
continuous-corner squircle (superellipse), NOT a rounded rectangle and NOT a
hand-tessellated polygon. The kink where a rounded-rect's straight edge meets
its circular-arc corner is what read as "not a real squircle".

Two outputs, same geometry, different colour by design (#553):
  - AppIcon.appiconset/*.png  -- INSTALLER app icon, INK (#14120E).
  - Resources/DialogIcon.icns -- FDA pre-warn dialog icon, OXBLOOD (#7A1F1F),
    deliberately the Hub product colour as a "this is Ostler" cue on the
    permission dialog.

Run from repo root:  python3 gui/OstlerInstaller/generate_appicon.py
Requires Pillow + macOS iconutil (for the .icns).
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

INK = (0x14, 0x12, 0x0E)
OXBLOOD = (0x7A, 0x1F, 0x1F)
# Geometry locked to the canonical macOS Big Sur+ icon grid (2026-06-06).
# Measured directly against Safari / QuickTime / System Settings .icns: the
# Apple system grid fills 80.5% of the canvas (824/1024, a 9.8% transparent
# margin each side) with a superellipse whose corner curvature begins at
# ~15.2% of the canvas. The previous 0.90 / N=5.0 values made the squircle
# ~12% too large (90.0% body, no system margin) with over-round 25.8% corners,
# which read as a soft/ill-defined tile next to real macOS icons. Edges were
# always pixel-crisp (2px AA band, identical to Apple); the defect was scale +
# corner curvature, not blur. N=7.0 reproduces the Apple corner curvature
# (measured 16.0% vs Apple 15.2%) at the 80.5% grid.
N = 7.0                 # superellipse exponent (matches macOS corner curvature)
SQUIRCLE_FRAC = 0.805   # squircle side / canvas (canonical macOS Big Sur grid)
RING_OUTER_FRAC = 0.54  # ring outer diameter / squircle side
RING_THICK_FRAC = 0.095  # ring stroke / squircle side (bold)
SS = 6                  # supersample

HERE = Path(__file__).resolve().parent
APPICONSET = HERE / "Assets.xcassets" / "AppIcon.appiconset"
DIALOG_ICNS = HERE / "Resources" / "DialogIcon.icns"

# Unique physical PNG sizes the appiconset references (Contents.json maps
# scale variants onto these). 16/32/64/128/256/512/1024.
APPICON_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def superellipse_mask(size: int) -> Image.Image:
    big = size * SS
    a = (big * SQUIRCLE_FRAC) / 2.0
    c = big / 2.0
    m = Image.new("L", (big, big), 0)
    px = m.load()
    for y in range(big):
        dy = abs((y + 0.5) - c) / a
        if dy >= 1.0:
            continue
        xext = (1.0 - dy ** N) ** (1.0 / N) * a
        x0 = int(c - xext)
        x1 = int(c + xext)
        for x in range(max(0, x0), min(big, x1 + 1)):
            px[x, y] = 255
    return m.resize((size, size), Image.LANCZOS)


def render_icon(size: int, body_rgb) -> Image.Image:
    body = Image.composite(
        Image.new("RGBA", (size, size), (*body_rgb, 255)),
        Image.new("RGBA", (size, size), (0, 0, 0, 0)),
        superellipse_mask(size),
    )
    side = SQUIRCLE_FRAC * size
    ro = (RING_OUTER_FRAC * side) / 2.0
    ri = ro - RING_THICK_FRAC * side
    ring = Image.new("L", (size * SS, size * SS), 0)
    d = ImageDraw.Draw(ring)
    cc = (size * SS) / 2.0
    d.ellipse((cc - ro * SS, cc - ro * SS, cc + ro * SS, cc + ro * SS), fill=255)
    d.ellipse((cc - ri * SS, cc - ri * SS, cc + ri * SS, cc + ri * SS), fill=0)
    ring = ring.resize((size, size), Image.LANCZOS)
    return Image.composite(Image.new("RGBA", (size, size), (255, 255, 255, 255)),
                           body, ring)


_ICNS_SIZES = [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
               ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
               ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
               ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
               ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)]


def build_icns(body_rgb, out_path: Path) -> None:
    if shutil.which("iconutil") is None:
        raise RuntimeError("iconutil not on PATH; run on macOS to build .icns")
    master = render_icon(1024, body_rgb)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "icon.iconset"
        iconset.mkdir()
        for filename, size in _ICNS_SIZES:
            master.resize((size, size), Image.LANCZOS).save(iconset / filename, "PNG")
        subprocess.run(["iconutil", "-c", "icns", "-o", str(out_path), str(iconset)],
                       check=True)


def main() -> int:
    print(f"Generating installer AppIcon (Ink) into {APPICONSET}")
    for s in APPICON_SIZES:
        render_icon(s, INK).save(APPICONSET / f"icon_{s}.png", "PNG", optimize=True)
    print(f"Generating DialogIcon (oxblood) at {DIALOG_ICNS}")
    build_icns(OXBLOOD, DIALOG_ICNS)
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
