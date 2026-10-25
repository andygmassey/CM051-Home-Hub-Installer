#!/usr/bin/env python3
"""Every .app we put in front of a customer has an icon that resolves (118 U4).

WHY. On the v1.0.117 install, /Applications/Ostler held three apps with the
generic blank icon: Ostler Uninstaller, Recover Ostler and Ostler
RemoteCapture. Each built, signed, notarised, stapled and ran. Nothing looked
at what Finder shows, so nothing could fail.

WHAT "RESOLVES" MEANS, read the way Finder reads it:
  - CFBundleIconFile names a file in Contents/Resources (".icns" appended when
    the value has no extension) that exists, is non-empty and starts with the
    "icns" magic; OR
  - CFBundleIconName names an "Icon Image" asset inside
    Contents/Resources/Assets.car (read with assetutil).
Neither key, or a key that points at nothing, is a FAIL for that bundle.

WHAT IS EXAMINED. Every *.app directory under the subject, nested ones
included (the Uninstaller and Recover apps ride inside
OstlerInstaller.app/Contents/Resources). One class is set aside, by name, and
printed: a .app inside a *.framework (Sparkle's Updater.app). That is a vendor
helper that never lands in /Applications and is not ours to restyle.

SUBJECT. A .dmg (attached read-only, detached after), a .tar.gz / .tgz
(extracted to a temp dir) or a directory.

KNOWN RED. --known-red FILE lists "<bundle name>\t<CFBundleShortVersionString>"
rows that are allowed to fail, each with a reason. The run passes only when the
failing set EQUALS the declared rows that apply: a new failure is red, and a
declared row that now passes is ALSO red (delete the row). A row names a
version, so re-pinning to a new build re-arms the check for that app.

EXIT. 0 PASS, 1 FAIL, 2 CANNOT-RUN (nothing examined, the DMG would not
attach, assetutil missing when it is needed). CANNOT-RUN is never a pass.

    python3 scripts/verify_payload_app_icons.py <dmg|tarball|dir> [--known-red FILE]
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

PASS, FAIL, CANNOT = 0, 1, 2


def assetutil_cmd() -> list[str] | None:
    override = os.environ.get("OSTLER_ASSETUTIL")
    if override:
        return [override]
    found = shutil.which("assetutil")
    if found:
        return [found]
    if shutil.which("xcrun"):
        return ["xcrun", "assetutil"]
    return None


def find_apps(root: Path) -> tuple[list[Path], list[Path]]:
    apps, skipped = [], []
    for dirpath, dirnames, _ in os.walk(root):
        for d in list(dirnames):
            if d.endswith(".app"):
                p = Path(dirpath) / d
                if any(part.endswith(".framework") for part in p.relative_to(root).parts):
                    skipped.append(p)
                else:
                    apps.append(p)
    return sorted(apps), sorted(skipped)


def icon_status(app: Path) -> tuple[str, str]:
    """Return (verdict, detail). verdict in PASS / FAIL / CANNOT."""
    info = app / "Contents" / "Info.plist"
    try:
        with info.open("rb") as fh:
            plist = plistlib.load(fh)
    except Exception as exc:  # unreadable plist is a defect in the bundle
        return "FAIL", f"Info.plist unreadable: {exc}"
    res = app / "Contents" / "Resources"
    icon_file = plist.get("CFBundleIconFile")
    icon_name = plist.get("CFBundleIconName")
    reasons = []
    if icon_file:
        name = icon_file if Path(icon_file).suffix else icon_file + ".icns"
        f = res / name
        if f.is_file() and f.stat().st_size > 8:
            with f.open("rb") as fh:
                magic = fh.read(4)
            if magic == b"icns":
                return "PASS", f"CFBundleIconFile -> Resources/{name} ({f.stat().st_size} bytes)"
            reasons.append(f"Resources/{name} is not an icns file")
        else:
            reasons.append(f"CFBundleIconFile={icon_file} but Resources/{name} is missing or empty")
    if icon_name:
        car = res / "Assets.car"
        if not car.is_file():
            reasons.append(f"CFBundleIconName={icon_name} but there is no Resources/Assets.car")
        else:
            cmd = assetutil_cmd()
            if cmd is None:
                return "CANNOT", "assetutil not available to read Assets.car"
            proc = subprocess.run(cmd + ["--info", str(car)], capture_output=True, text=True)
            if proc.returncode != 0:
                return "CANNOT", f"assetutil exit {proc.returncode}: {proc.stderr.strip()[:200]}"
            try:
                entries = json.loads(proc.stdout)
            except ValueError as exc:
                return "CANNOT", f"assetutil output not JSON: {exc}"
            hits = [e for e in entries if isinstance(e, dict)
                    and e.get("Name") == icon_name and e.get("AssetType") == "Icon Image"]
            if hits:
                return "PASS", f"CFBundleIconName -> Assets.car '{icon_name}' ({len(hits)} icon images)"
            reasons.append(f"CFBundleIconName={icon_name} has no Icon Image in Assets.car")
    if not icon_file and not icon_name:
        reasons.append("no CFBundleIconFile and no CFBundleIconName (Finder shows the blank icon)")
    return "FAIL", "; ".join(reasons)


def load_known_red(path: Path | None) -> dict[tuple[str, str], str]:
    rows: dict[tuple[str, str], str] = {}
    if path is None:
        return rows
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 3 or not cols[2].strip():
            raise SystemExit(f"CANNOT-RUN: known-red row needs name<TAB>version<TAB>reason: {line!r}")
        rows[(cols[0], cols[1])] = cols[2]
    return rows


def bundle_version(app: Path) -> str:
    try:
        with (app / "Contents" / "Info.plist").open("rb") as fh:
            return str(plistlib.load(fh).get("CFBundleShortVersionString", "?"))
    except Exception:
        return "?"


def check_tree(root: Path, known: dict[tuple[str, str], str], label: str) -> int:
    apps, skipped = find_apps(root)
    for s in skipped:
        print(f"SET ASIDE  {s.relative_to(root)}  (inside a .framework: vendor helper, never placed in /Applications)")
    if not apps:
        print(f"CANNOT-RUN: no .app bundles found under {label}; nothing was examined")
        return CANNOT
    failing, cannot = set(), False
    for app in apps:
        verdict, detail = icon_status(app)
        key = (app.stem, bundle_version(app))
        tag = verdict
        if verdict == "FAIL":
            failing.add(key)
            if key in known:
                tag = "KNOWN-RED"
        if verdict == "CANNOT":
            cannot = True
            tag = "CANNOT-RUN"
        print(f"{tag:<10} {app.relative_to(root)}  v{key[1]}  {detail}")
        if tag == "KNOWN-RED":
            print(f"           declared: {known[key]}")
    rc = PASS
    new = sorted(failing - set(known))
    if new:
        print(f"FAIL: {len(new)} app(s) with no resolvable icon: " + ", ".join(n for n, _ in new))
        rc = FAIL
    # A declared row whose app was examined and now passes must be deleted.
    examined = {(a.stem, bundle_version(a)) for a in apps}
    stale = sorted(k for k in known if k in examined and k not in failing)
    if stale:
        print("FAIL: known-red rows that now pass, delete them: " + ", ".join(f"{n} {v}" for n, v in stale))
        rc = FAIL
    if rc == PASS and cannot:
        print("CANNOT-RUN: at least one bundle could not be read; this is not a pass")
        return CANNOT
    print(f"examined {len(apps)} app(s), set aside {len(skipped)}, failing {len(failing)}, "
          f"declared known-red {len(failing & set(known))}: {'PASS' if rc == PASS else 'FAIL'}")
    return rc


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("subject")
    ap.add_argument("--known-red", type=Path)
    args = ap.parse_args(argv)
    subject = Path(args.subject)
    if not subject.exists():
        print(f"CANNOT-RUN: {subject} does not exist")
        return CANNOT
    known = load_known_red(args.known_red)
    with tempfile.TemporaryDirectory(prefix="icons.") as tmp:
        if subject.is_dir():
            return check_tree(subject, known, str(subject))
        name = subject.name
        if name.endswith(".dmg"):
            mnt = Path(tmp) / "mnt"
            mnt.mkdir()
            att = subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noverify",
                                  "-mountpoint", str(mnt), str(subject)], capture_output=True, text=True)
            if att.returncode != 0:
                print(f"CANNOT-RUN: hdiutil attach exit {att.returncode}: {att.stderr.strip()}")
                return CANNOT
            try:
                return check_tree(mnt, known, name)
            finally:
                subprocess.run(["hdiutil", "detach", "-force", str(mnt)], capture_output=True)
        if name.endswith((".tar.gz", ".tgz")):
            out = Path(tmp) / "x"
            out.mkdir()
            try:
                with tarfile.open(subject) as tf:
                    tf.extractall(out, filter="data") if hasattr(tarfile, "data_filter") else tf.extractall(out)
            except Exception as exc:
                print(f"CANNOT-RUN: could not extract {name}: {exc}")
                return CANNOT
            return check_tree(out, known, name)
        print(f"CANNOT-RUN: {name} is not a .dmg, a .tar.gz or a directory")
        return CANNOT


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
