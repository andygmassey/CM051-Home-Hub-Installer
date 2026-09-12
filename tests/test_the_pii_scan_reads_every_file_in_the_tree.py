#!/usr/bin/env python3
"""The operator-PII scan must READ every file in the shipped tree, not just the
extensions somebody happened to enumerate.

WHY THIS EXISTS. The v1.0.92 cut produced no DMG. no-operator-email and
no-operator-wiki-name both returned CANNOT-RUN because 660 files in the built
OstlerInstaller.app carry a suffix on neither _TEXT_EXTS nor _COMPILED_EXTS
(.icns, .car, .svg, .example and a nested .zip among them). The scan was right
to refuse -- hits=0 across a tree it had not finished reading is a statement
about the files it opened, not about the artefact -- but the consequence was a
gate that could never reach a verdict and a cut that could never be built.

The fix reads them. An unknown suffix is scanned with strings(1) instead of
being recorded as unread, because an unfamiliar extension is evidence about our
enumeration and not about the file.

🔴 THE ONE THING THIS TEST MUST PROTECT. That fix could very easily have been
written as "stop counting unscanned files", which would turn every operator-PII
row green by removing its ability to refuse. So the cases below assert BOTH
directions: the needle is genuinely found in each newly-reachable shape, AND a
file that truly cannot be read still lands in `unscanned` so it can still
poison the row. A clean tree with no needle must produce neither.

Archives get expanded rather than strings-scanned, because deflated bytes carry
no readable literal: scanning a .zip as a binary returns a confident zero about
contents nobody examined, which is the same false zero in a new costume.
"""
import importlib.util
import pathlib
import sys
import tempfile
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location(
    "vcm", REPO / "scripts" / "verify_cut_manifest.py")
vcm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vcm)

# Synthetic and impersonal. It names no person and belongs to no real account,
# so it can live in a tracked file. It must never be a real operator value.
NEEDLE = "ZZSYNTHETICOPERATORNEEDLEZZ"

failures = []


def check(label, got, want):
    if got != want:
        failures.append(f"{label}: expected {want!r}, got {got!r}")
    print(f"  {'ok  ' if got == want else 'FAIL'} {label}: {got!r}")


def scan(root):
    """Return (hit_count, unscanned_names) the way the real checker walks."""
    unscanned = []
    hits = 0
    for path, use_strings in vcm._iter_dmg_tree_scan_files(root, unscanned):
        try:
            n = (vcm._grep_binary_strings(path, NEEDLE) if use_strings
                 else vcm._grep_file(path, NEEDLE))
        except Exception:
            continue
        if n:
            hits += 1
    return hits, sorted(p.name for p in unscanned)


print("CASE 1: the needle is FOUND in each shape the scan used to skip")
d = pathlib.Path(tempfile.mkdtemp())
(d / "icon.icns").write_bytes(b"\x00\x01" + NEEDLE.encode() + b"\x00")
(d / "Assets.car").write_bytes(b"\x00\x00an asset catalogue with nothing in it")
inner = d / "payload.txt"
inner.write_text("a config line carrying " + NEEDLE)
with zipfile.ZipFile(d / "ext.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.write(inner, "payload.txt")
inner.unlink()
hits, unscanned = scan(d)
check("unknown-extension binary and compressed zip both hit", hits, 2)
check("nothing recorded unread", unscanned, [])

print("CASE 2: a file that truly cannot be read STILL poisons the row")
d2 = pathlib.Path(tempfile.mkdtemp())
(d2 / "broken.zip").write_bytes(b"PK\x03\x04THISISNOTAVALIDARCHIVE")
hits2, unscanned2 = scan(d2)
check("corrupt archive is recorded unread", unscanned2, ["broken.zip"])
check("and it contributes no hit", hits2, 0)

print("CASE 3: NEGATIVE CONTROL -- a clean tree must be clean, not merely quiet")
d3 = pathlib.Path(tempfile.mkdtemp())
(d3 / "icon.icns").write_bytes(b"\x00\x01ordinary icon bytes\x00")
(d3 / "note.example").write_text("a sample config with no operator value in it")
with zipfile.ZipFile(d3 / "ext.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("a.txt", "nothing of interest")
hits3, unscanned3 = scan(d3)
check("no false positive", hits3, 0)
check("and nothing recorded unread", unscanned3, [])

if failures:
    print("\nFAILED:")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("\nAll cases passed.")
