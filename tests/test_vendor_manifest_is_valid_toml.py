#!/usr/bin/env python3
"""vendor/VENDOR_MANIFEST.toml must actually parse as TOML.

WHY THIS EXISTS
---------------
2026-08-11. CM051 #563 added a doctor hold_ack_reason containing an unescaped
double quote -- `("update X requirement")` inside a basic string -- and landed
on main. Every check stayed green, because the vendor tooling reads the
manifest with its own line-based reader (scripts/_vendor_lib.sh::vlib_field),
never a TOML parser. So the file was broken for anything that DOES parse it,
and nothing in the repo could tell.

That is the shape this guard exists for: the format claim in the filename
(`.toml`) was never asserted anywhere. A reader tolerant of the defect is not
evidence the defect is absent.

The self-check below is the control. A test that only parses the real file
would pass just as happily if `tomllib` were silently a no-op.
"""
from __future__ import annotations

import sys
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "vendor" / "VENDOR_MANIFEST.toml"


def test_manifest_parses() -> None:
    with MANIFEST.open("rb") as fh:
        doc = tomllib.load(fh)
    trees = doc.get("tree", [])
    assert trees, "manifest parsed but declares no [[tree]] entries"
    for tree in trees:
        assert tree.get("name"), f"[[tree]] without a name: {tree!r}"


def test_parser_actually_rejects_the_2026_08_11_defect() -> None:
    """Positive control: reproduce #563's exact defect and require a failure.

    Without this, a green result would be indistinguishable from a check that
    never looked.
    """
    broken = (
        '[[tree]]\n'
        'name = "cm041/example"\n'
        '  hold_ack_reason = "they carry the ("update X requirement") wording"\n'
    )
    try:
        tomllib.loads(broken)
    except tomllib.TOMLDecodeError:
        return
    raise AssertionError(
        "the control string parsed cleanly, so this guard cannot detect the "
        "defect it was written for"
    )


def main() -> int:
    failures = []
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_") or not callable(fn):
            continue
        try:
            fn()
            print(f"  [PASS] {name}")
        except Exception as exc:  # noqa: BLE001 -- report, do not raise
            failures.append((name, exc))
            print(f"  [FAIL] {name}: {exc}")
    if failures:
        print(f"\n{len(failures)} failed")
        return 1
    print("\nall passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
