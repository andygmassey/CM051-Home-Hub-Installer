"""Wording-drift guard for ``legal.consent_strings``.

Compares the SHA-256 of every :class:`ConsentString` constant exported
from :mod:`legal` against the pinned values in
``tests/consent_wording_hashes.json``. Fails loudly with the offending
constant name if anything drifted, has been added, or has been
removed.

Run from CI on every PR. The point is forced awareness: wording
changes ride together with a deliberate bump of the JSON file, so a
typo fix or material legal rewrite cannot silently break the
``ostler-consent-gate`` Rust crate's bundled mirror.

Usage::

    python3 -m legal.check_wording          # CI mode: exit 1 on drift
    python3 -m legal.check_wording --write  # regenerate the JSON

The ``--write`` mode is for the developer who is intentionally
bumping wording. Run, eyeball ``git diff tests/consent_wording_hashes.json``,
commit alongside the wording change.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import legal
from legal.consent_strings import ConsentString


HASHES_FILE = (
    Path(__file__).resolve().parent.parent / "tests" / "consent_wording_hashes.json"
)


def collect_constants() -> dict[str, tuple[str, ConsentString]]:
    """Return ``{tickbox_id: (constant_name, ConsentString)}``.

    Walks the public ``legal`` namespace for any attribute that is a
    :class:`ConsentString`. Constant order does not matter; the JSON
    is sorted by ``tickbox_id``.
    """
    out: dict[str, tuple[str, ConsentString]] = {}
    for name, value in vars(legal).items():
        if isinstance(value, ConsentString):
            out[value.tickbox_id] = (name, value)
    return out


def write_hashes() -> int:
    """Regenerate ``tests/consent_wording_hashes.json`` from current code."""
    constants = collect_constants()
    payload = {tid: c.sha256() for tid, (_name, c) in constants.items()}
    HASHES_FILE.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"Wrote {HASHES_FILE} ({len(payload)} entries)")
    return 0


def check() -> int:
    """Return 0 on agreement, 1 on any drift."""
    constants = collect_constants()
    actual = {tid: c.sha256() for tid, (_n, c) in constants.items()}
    name_for = {tid: name for tid, (name, _c) in constants.items()}

    if not HASHES_FILE.exists():
        print(
            f"ERROR: pinned-hashes file missing: {HASHES_FILE}\n"
            f"  Run: python3 -m legal.check_wording --write",
            file=sys.stderr,
        )
        return 1

    expected = json.loads(HASHES_FILE.read_text(encoding="utf-8"))

    actual_ids = set(actual)
    expected_ids = set(expected)

    missing_in_json = sorted(actual_ids - expected_ids)
    dangling_in_json = sorted(expected_ids - actual_ids)
    drift = sorted(
        (tid, expected[tid], actual[tid])
        for tid in actual_ids & expected_ids
        if expected[tid] != actual[tid]
    )

    if not (missing_in_json or dangling_in_json or drift):
        print(
            f"OK: {len(actual)} ConsentString constants match "
            f"{HASHES_FILE.name}"
        )
        return 0

    print("FAIL: consent-wording drift detected", file=sys.stderr)
    if missing_in_json:
        print(
            "  New ConsentString constants in code, not yet pinned:",
            file=sys.stderr,
        )
        for tid in missing_in_json:
            print(
                f"    - {name_for[tid]} (tickbox_id={tid!r}): {actual[tid]}",
                file=sys.stderr,
            )
    if dangling_in_json:
        print(
            "  Pinned tickbox ids no longer present in code "
            "(constant removed or renamed):",
            file=sys.stderr,
        )
        for tid in dangling_in_json:
            print(f"    - tickbox_id={tid!r}", file=sys.stderr)
    if drift:
        print("  Wording drift (text changed; hash differs):", file=sys.stderr)
        for tid, exp, act in drift:
            print(
                f"    - {name_for.get(tid, '?')} (tickbox_id={tid!r}):",
                file=sys.stderr,
            )
            print(f"        expected: {exp}", file=sys.stderr)
            print(f"        actual:   {act}", file=sys.stderr)
    print(
        "\n  If the wording change is intentional, regenerate the hashes:\n"
        "    python3 -m legal.check_wording --write\n"
        "  AND remember to update the byte-identical mirror in "
        "ostler-assistant\n"
        "  (crates/ostler-consent-gate/src/wording_data/*.txt + "
        "tests/consent_wording_hashes.json).",
        file=sys.stderr,
    )
    return 1


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if "--write" in args:
        return write_hashes()
    return check()


if __name__ == "__main__":
    raise SystemExit(main())
