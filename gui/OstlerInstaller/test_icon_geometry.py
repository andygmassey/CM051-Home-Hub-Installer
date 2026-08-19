"""Regression guards for the OstlerInstaller app icon + DialogIcon.

TNM_BRIEF_icon_superellipse_FINAL. Andy: "don't let it regress." Guards:

  1. CORNER GEOMETRY -- the 1024 app-icon master's corner matches a true
     superellipse (corner-region IoU >= 0.99); a rounded_rectangle
     negative-control fixture MUST fail the same gate, so a regression back
     to a rounded rectangle trips CI. (A single 45-degree scalar cannot
     separate an n=5 superellipse from a matched iOS rounded-rect -- that is
     why Apple uses superellipses -- so the guard is a corner-region match.)
  2. COLOUR CONSISTENCY -- every appiconset slot is Ink. DialogIcon is the
     documented oxblood exception (checked on macOS where sips is available).
  3. GOLDEN-HASH PIN -- every appiconset PNG and DialogIcon.icns sha256 is
     pinned in ICON_HASHES.txt.

There is deliberately NO cross-app parity with the Hub (oxblood) -- the two
apps are intentionally different colours (#553).

stdlib unittest + Pillow (no pytest). DialogIcon colour check is macOS-only.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from PIL import Image, ImageDraw

import generate_appicon as gi

HERE = Path(__file__).resolve().parent
APPICONSET = HERE / "Assets.xcassets" / "AppIcon.appiconset"
DIALOG_ICNS = HERE / "Resources" / "DialogIcon.icns"
MANIFEST = HERE / "ICON_HASHES.txt"

S = 1024
_M = int((1.0 - gi.SQUIRCLE_FRAC) / 2.0 * S)
_BOX = [_M, _M, S - _M - 1, S - _M - 1]
_CZ = (_M, _M, int(0.39 * S), int(0.39 * S))
CORNER_IOU_PASS = 0.99


def _corner_iou(a, b):
    pa = a.crop(_CZ).load(); pb = b.crop(_CZ).load()
    w = _CZ[2] - _CZ[0]; h = _CZ[3] - _CZ[1]
    inter = uni = 0
    for y in range(h):
        for x in range(w):
            p = pa[x, y] >= 128; q = pb[x, y] >= 128
            if p or q: uni += 1
            if p and q: inter += 1
    return inter / uni if uni else 1.0


def _is_ink(rgb):
    r, g, b = rgb[:3]
    return r < 50 and g < 50 and b < 50


def _is_oxblood(rgb):
    r, g, b = rgb[:3]
    return r > 80 and g < 70 and b < 70


def _body_pts(im):
    w, h = im.size
    return [(int(w * 0.28), int(h * 0.28)), (int(w * 0.72), int(h * 0.28)),
            (int(w * 0.5), int(h * 0.22))]


class CornerGeometryGuard(unittest.TestCase):
    def setUp(self):
        self.master = Image.open(APPICONSET / "icon_1024.png").convert("RGBA")
        self.canonical = gi.superellipse_mask(S)

    def test_appicon_corner_is_superellipse(self):
        iou = _corner_iou(self.master.split()[3], self.canonical)
        self.assertGreaterEqual(
            iou, CORNER_IOU_PASS,
            f"app-icon corner IoU {iou:.4f} < {CORNER_IOU_PASS}: not a true "
            "superellipse (regressed to a rounded rectangle?)")

    def test_rounded_rect_negative_control_fails(self):
        worst = 0.0
        for rad in (140, 180, 220, 260):
            rr = Image.new("L", (S, S), 0)
            ImageDraw.Draw(rr).rounded_rectangle(_BOX, radius=rad, fill=255)
            worst = max(worst, _corner_iou(rr, self.canonical))
        self.assertLess(worst, CORNER_IOU_PASS,
                        f"a rounded rectangle scored {worst:.4f}; gate too loose")


class ColourGuard(unittest.TestCase):
    def test_appiconset_all_ink(self):
        for s in gi.APPICON_SIZES:
            im = Image.open(APPICONSET / f"icon_{s}.png").convert("RGBA")
            for x, y in _body_pts(im):
                px = im.getpixel((x, y))
                if px[3] < 200:
                    continue
                self.assertTrue(_is_ink(px),
                                f"icon_{s}.png body {px[:3]} is not Ink")

    @unittest.skipUnless(shutil.which("sips"), "sips (macOS) unavailable")
    def test_dialogicon_is_oxblood(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "x.png")
            subprocess.run(["sips", "-s", "format", "png", str(DIALOG_ICNS),
                            "--out", out, "--resampleHeightWidth", "512", "512"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            im = Image.open(out).convert("RGBA")
            px = im.getpixel((int(512 * 0.28), int(512 * 0.28)))
            self.assertTrue(_is_oxblood(px),
                            f"DialogIcon body {px[:3]} is not the documented oxblood")


class GoldenHashGuard(unittest.TestCase):
    def test_hashes_pinned(self):
        self.assertTrue(MANIFEST.exists(), "ICON_HASHES.txt missing")
        pinned = {}
        for line in MANIFEST.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            h, name = line.split(None, 1)
            pinned[name.strip()] = h.strip()
        targets = {f"icon_{s}.png": APPICONSET / f"icon_{s}.png"
                   for s in gi.APPICON_SIZES}
        targets["DialogIcon.icns"] = DIALOG_ICNS
        for name, path in targets.items():
            self.assertIn(name, pinned, f"{name} not pinned in ICON_HASHES.txt")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(digest, pinned[name],
                             f"{name} sha256 changed without repinning ICON_HASHES.txt")


if __name__ == "__main__":
    unittest.main()
