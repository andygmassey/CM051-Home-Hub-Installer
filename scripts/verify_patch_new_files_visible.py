#!/usr/bin/env python3
"""Every committed divergence patch's new-file hunks must be visible to their consumer.

WHY THIS GATE EXISTS

`vlib_patch_new_files` (scripts/_vendor_lib.sh) decides which files a divergence
patch CREATES. That verdict is the only thing stopping `sync_vendor.sh` deleting
them on the next re-vendor. It matches, literally:

    /^--- \\/dev\\/null$/ { pending = 1 }
    /^\\+\\+\\+ b\\//     { if (pending) print }

On 2026-09-02 `vendor/divergences/doctor.patch` carried `+++ bb/` instead of
`+++ b/`. Measured: 8 new-file hunks written, 0 extracted. sync_vendor.sh
believed the patch created nothing, so all eight files were unprotected,
including `agent/extension_token.py` and `agent/pause_control.py`.

It survived because the patch still APPLIED. git strips at -p1, so `bb/` and
`b/` are identical to `git apply`. Every apply-side check stayed green. Only
the DETECTION was dead, and nothing measured detection.

THE GAP THIS CLOSES (found by A2, and it is the real lesson)

After that fix the invariant was enforced in three places, none of which looks
at a committed artefact:
  (a) the generator's self-check fires only when someone RUNS the generator;
  (b) tests/test_gen_patch_new_files.sh proves it on a synthetic FIXTURE;
  (c) tests/test_doctor_governor_routes_vendored.sh checks ONE named file, in
      ONE tree.
The bug shipped exactly there: the committed patch was written by an older
generator and then sat in the tree, re-checked by nothing. A patch that is
stale, hand-edited, or made by an older tool must be caught regardless of how
it entered the tree, so this gate reads what is COMMITTED.

THE ANY-PREFIX COUNTER IS THE POINT

A patch with zero new-file hunks is legitimately 0/0. A patch with new-file
hunks the consumer cannot see is a silent time bomb. Those two look identical
if you only count what the consumer returns, so this also counts `+++` lines
under ANY prefix. devnull > 0 with visible == 0 and anyprefix > 0 is exactly
the doctor.patch shape.

Exit codes, three states and not two:
    0  every committed patch agrees with its consumer
    1  RED: at least one patch has hunks its consumer cannot see, named
    2  CANNOT-RUN: manifest unreadable, or the parse produced a suspicious
       zero. This is NOT a pass.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    print("verify-patch-new-files: CANNOT-RUN -- python3.11+ needed for tomllib",
          file=sys.stderr)
    sys.exit(2)

REPO = Path(__file__).resolve().parent.parent
MANIFEST = REPO / "vendor" / "VENDOR_MANIFEST.toml"

RE_DEVNULL = re.compile(r"^--- /dev/null$", re.M)
# The consumer's own predicate, character for character.
RE_VISIBLE = re.compile(r"^\+\+\+ b/", re.M)
# Any prefix at all, so "0 visible" can be told apart from "0 present".
RE_ANY_PLUS = re.compile(r"^\+\+\+ (?!/dev/null)", re.M)


def _cannot_run(reason: str) -> int:
    print(f"verify-patch-new-files: CANNOT-RUN -- {reason}", file=sys.stderr)
    print("verify-patch-new-files: this is NOT a pass.", file=sys.stderr)
    return 2


def _visible_count(text: str) -> int:
    """Replicate vlib_patch_new_files exactly: a +++ b/ line PRECEDED by /dev/null."""
    pending = False
    n = 0
    for line in text.splitlines():
        if line == "--- /dev/null":
            pending = True
            continue
        if line.startswith("+++ b/"):
            if pending:
                n += 1
            pending = False
            continue
        pending = False
    return n


def _self_test() -> int:
    """Prove the predicate fires, on synthetic patches, before trusting a verdict.

    Same shape as verify_launchagent_pycache_guard.py --self-test. A checker
    that cannot demonstrate it goes RED is not evidence of anything, and this
    gate exists precisely because an earlier check reported clean over a defect.
    """
    GOOD = (
        "diff --git a/agent/x.py b/agent/x.py\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        "+++ b/agent/x.py\n"
        "@@ -0,0 +1 @@\n"
        "+x = 1\n"
    )
    # The historical doctor.patch shape: hunk present, prefix non-standard.
    BAD_PREFIX = GOOD.replace("+++ b/agent/x.py", "+++ bb/agent/x.py")
    # A patch that legitimately creates nothing. Must NOT be flagged.
    NO_NEW_FILES = (
        "diff --git a/agent/y.py b/agent/y.py\n"
        "--- a/agent/y.py\n"
        "+++ b/agent/y.py\n"
        "@@ -1 +1 @@\n"
        "-x = 1\n"
        "+x = 2\n"
    )
    # A CONTENT line that looks like a header. Must not be counted.
    DECOY = GOOD + "+++ b/not/a/real/header.py\n"

    cases = [
        ("new file, standard prefix", GOOD, 1, 1, True),
        ("new file, bb/ prefix (the real defect)", BAD_PREFIX, 1, 0, False),
        ("modification only, creates nothing", NO_NEW_FILES, 0, 0, True),
        ("content line mimicking a header", DECOY, 1, 1, True),
    ]

    failures = 0
    for label, text, want_devnull, want_visible, want_agree in cases:
        devnull = len(RE_DEVNULL.findall(text))
        visible = _visible_count(text)
        agree = devnull == visible
        ok = (devnull == want_devnull and visible == want_visible
              and agree == want_agree)
        print(f"  {'ok  ' if ok else 'FAIL'}  {label}: "
              f"devnull={devnull} visible={visible} agree={agree}")
        if not ok:
            failures += 1

    if failures:
        print(f"verify-patch-new-files: SELF TEST FAILED on {failures} case(s). "
              "The predicate does not behave as documented, so no verdict it "
              "produces can be trusted.", file=sys.stderr)
        return 1
    print("verify-patch-new-files: self test clean "
          f"({len(cases)} cases, including one that MUST be flagged).")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return _self_test()

    staged = "--staged" in sys.argv
    ref_prefix = ":" if staged else "HEAD:"
    source = "the index (staged)" if staged else "HEAD"

    if not MANIFEST.is_file():
        return _cannot_run(f"{MANIFEST} is not a readable file")

    # tomllib, NOT a line-grep. VENDOR_MANIFEST.toml mixes indented and
    # unindented rows, so any ^-anchored reader silently sees a subset and
    # returns empty values that read as "field absent".
    try:
        data = tomllib.loads(MANIFEST.read_text())
    except Exception as exc:  # noqa: BLE001
        return _cannot_run(f"{MANIFEST.name} does not parse as TOML: {exc}")

    trees = data.get("tree") or data.get("trees") or {}
    if isinstance(trees, dict):
        rows = list(trees.items())
    else:
        rows = [(str(i), t) for i, t in enumerate(trees)]

    if not rows:
        return _cannot_run(
            "the manifest parsed but yielded ZERO tree rows. Either the schema "
            "changed or this gate is reading the wrong table; a zero here would "
            "otherwise print as a clean pass over nothing."
        )

    declared = 0
    checked = 0
    findings = []
    unreadable = []

    for name, row in rows:
        if not isinstance(row, dict):
            continue
        rel = (row.get("divergence_patch") or "").strip()
        if not rel:
            continue
        declared += 1
        path = REPO / rel
        # Read what is COMMITTED, not what is on disk. Only the commit ships.
        #
        # --staged reads the INDEX (`git show :path`) instead. That is not a
        # convenience: in a pre-commit hook HEAD is the PREVIOUS commit, so a
        # patch being FIXED by this very commit would still read as broken (a
        # false RED) and a patch being ADDED would not be checked at all. The
        # hook must judge what is about to be committed.
        proc = subprocess.run(
            ["git", "-C", str(REPO), "show", f"{ref_prefix}{rel}"],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            if path.is_file():
                unreadable.append(f"{name}: {rel} is on disk but NOT in {source}")
            else:
                unreadable.append(f"{name}: {rel} is neither in {source} nor on disk")
            continue
        text = proc.stdout
        checked += 1

        devnull = len(RE_DEVNULL.findall(text))
        visible = _visible_count(text)
        anyprefix = len(RE_ANY_PLUS.findall(text))

        if devnull != visible:
            findings.append(
                (name, rel, devnull, visible, anyprefix)
            )

    if declared == 0:
        return _cannot_run(
            f"{len(rows)} tree row(s) parsed but NOT ONE declares a "
            "divergence_patch. Either every tree is byte-identical to its pin "
            "(possible but unlikely) or the field name has drifted."
        )
    if checked == 0:
        return _cannot_run(
            f"{declared} patch(es) declared, 0 readable from {source}. "
            + "; ".join(unreadable[:5])
        )

    # Flush before any stderr writes below, or CI interleaves the denominator
    # AFTER the findings it is supposed to contextualise.
    print(
        f"verify-patch-new-files: {len(rows)} tree row(s), {declared} declaring a "
        f"patch, {checked} read from {source}.",
        flush=True,
    )

    if unreadable:
        print(
            f"verify-patch-new-files: RED -- {len(unreadable)} declared patch(es) "
            f"could not be read from {source}. A patch on disk but not in the commit "
            "does not ship:",
            file=sys.stderr,
        )
        for u in unreadable:
            print(f"    {u}", file=sys.stderr)
        return 1

    if findings:
        print(
            f"verify-patch-new-files: RED -- {len(findings)} patch(es) create "
            "files their own consumer cannot see. The next sync_vendor.sh "
            "DELETES those files, silently:",
            file=sys.stderr,
        )
        for name, rel, devnull, visible, anyprefix in findings:
            print(
                f"    {name}  ({rel})\n"
                f"        new-file hunks written      : {devnull}\n"
                f"        visible to vlib_patch_new_files: {visible}\n"
                f"        +++ lines under ANY prefix  : {anyprefix}",
                file=sys.stderr,
            )
            if visible == 0 and anyprefix > 0:
                print(
                    "        ^ this is the doctor.patch shape: the hunks exist "
                    "but carry a non-standard path prefix.",
                    file=sys.stderr,
                )
        print(
            "\nRegenerate with scripts/regenerate_divergence_patch.sh, which now "
            "refuses to write a patch with this defect.",
            file=sys.stderr,
        )
        return 1

    print("verify-patch-new-files: clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
