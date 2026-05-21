"""Flip the rebrand-affected source-code constants from
``lifeline``/``v2`` to ``ostler``/``v3``.

This CLI is the *third* step of the rebrand sequence. The first two
are data migrations:

1. ``ostler-migrate-keychain --execute`` – moves Keychain items
   from service ID ``ai.creativemachines.lifeline`` to
   ``ai.creativemachines.ostler``.
2. ``ostler-migrate-aad --execute`` – re-encrypts every recovery
   envelope under the new AAD prefix
   ``creativemachines/recovery-key-v3:`` and bumps the config
   version to 3.

Once both data migrations report green and ``--verify`` passes for
each, this CLI flips the matching string constants in source so the
running code reads the new values.

Why a separate step
-------------------

The data migrations and the constant flips have to happen in this
order. If the constants flipped first, the code would search for
items / decrypt under the new identifiers immediately – and the data
still on disk under the old identifiers would be invisible. The
user is locked out until the data migration finishes.

Splitting the steps keeps the failure boundary clean: a botched data
migration aborts before any code can stop reading from the old
locations.

Safety contract
---------------

* Default mode is ``--dry-run``. Shows the diff that would be applied.
* ``--execute`` rewrites the source files in-place. A pre-flight
  ``--check`` verifies the constants are in their expected pre-flip
  state; if anything else has touched them, the CLI refuses.
* ``--check`` is read-only – useful in CI to assert "rebrand not yet
  flipped" or "rebrand complete".
* Idempotent: running ``--execute`` twice is a no-op the second time.
* Hard-fail: any ambiguity (multiple candidate matches, lines of an
  unexpected shape) aborts with a clear message rather than guessing.
* The CLI does NOT touch the DATA (Keychain items, recovery configs).
  Run the two data migrations first and verify both before flipping.

Usage
-----

::

    python -m ostler_security.flip_constants --check     # read-only
    python -m ostler_security.flip_constants --dry-run   # diff
    python -m ostler_security.flip_constants --execute   # write

What it changes
---------------

* ``ostler_security/keychain.py`` line ~47::

    -KEYCHAIN_SERVICE = "ai.creativemachines.lifeline"
    +KEYCHAIN_SERVICE = "ai.creativemachines.ostler"

* ``ostler_security/passphrase.py`` (three occurrences)::

    -aad = b"lifeline-recovery-key-v2:" + ...
    +aad = b"creativemachines/recovery-key-v3:" + ...

The matching is anchored on the literal prefix, not on line numbers
– line numbers drift, the literal does not.

Exit codes
----------

::

    0   Success (or already-flipped, or dry-run completed cleanly)
    1   At least one expected match was missing or already in the
        target state
    2   Bad arguments
    3   Internal failure
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, TextIO


# Exit codes
EXIT_OK = 0
EXIT_INCOMPLETE = 1
EXIT_BAD_ARGS = 2
EXIT_INTERNAL = 3


# ── Replacement specs ───────────────────────────────────────────────


@dataclass(frozen=True)
class Replacement:
    """One source-code substitution.

    ``old`` and ``new`` are the literal byte strings to swap. The
    file is read/written as text; matches are exact.

    ``min_count`` / ``max_count`` bracket how many hits we expect.
    Out-of-bracket counts abort the flip – it usually means someone
    edited the file and the migration plan needs reviewing.
    """
    file_relative: str
    old: str
    new: str
    description: str
    min_count: int = 1
    max_count: int = 1


REPLACEMENTS: tuple[Replacement, ...] = (
    Replacement(
        file_relative="ostler_security/keychain.py",
        old='KEYCHAIN_SERVICE = "ai.creativemachines.lifeline"',
        new='KEYCHAIN_SERVICE = "ai.creativemachines.ostler"',
        description="Keychain service identifier",
        min_count=1, max_count=1,
    ),
    Replacement(
        file_relative="ostler_security/passphrase.py",
        old='aad = b"lifeline-recovery-key-v2:"',
        new='aad = b"creativemachines/recovery-key-v3:"',
        description="Recovery-key envelope AAD prefix",
        min_count=3, max_count=3,
    ),
)


# Rolled-back state markers. If the file is already on the new value
# (e.g. user already ran --execute), we should detect that and report
# "already flipped" rather than trying again.
ALREADY_FLIPPED_MARKERS: tuple[tuple[str, str], ...] = (
    ("ostler_security/keychain.py",
     'KEYCHAIN_SERVICE = "ai.creativemachines.ostler"'),
    ("ostler_security/passphrase.py",
     'aad = b"creativemachines/recovery-key-v3:"'),
)


# ── Repo root resolution ────────────────────────────────────────────


def _candidate_repo_roots() -> list[Path]:
    """Find plausible repo roots.

    The CLI ships inside ``ostler_security/``. Three install layouts
    matter:

    1. Source checkout: ``HR015 - Gaming PC/ostler_security/...``.
       The repo root is two levels up from this file.
    2. Editable pip install: same as above (the file is in the
       checkout).
    3. Production install: the package is in the venv's
       ``site-packages``. We can't flip source there – running this
       CLI in production is a configuration error.
    """
    here = Path(__file__).resolve().parent  # ostler_security/
    return [
        here.parent,                                 # repo root (HR015)
        here.parent.parent,                          # parent of repo
        Path.cwd(),                                  # whatever the user ran in
    ]


def find_repo_root() -> Path:
    """Return the directory whose layout matches REPLACEMENTS.

    Picks the first candidate where every ``file_relative`` exists.
    Raises ``RuntimeError`` if none match.
    """
    for candidate in _candidate_repo_roots():
        if all(
            (candidate / r.file_relative).exists() for r in REPLACEMENTS
        ):
            return candidate
    raise RuntimeError(
        "Could not locate repo root. Run from inside the HR015 "
        "checkout, or pass --repo-root explicitly."
    )


# ── Match counting ──────────────────────────────────────────────────


@dataclass
class FileStatus:
    """Per-file status of one Replacement spec."""
    file: Path
    description: str
    old_count: int
    new_count: int
    expected_old: int
    expected_new_after_flip: int
    well_formed: bool   # counts within tolerance
    already_flipped: bool


def _classify_replacement(repo_root: Path, repl: Replacement) -> FileStatus:
    file_path = repo_root / repl.file_relative
    text = file_path.read_text()
    old_count = text.count(repl.old)
    new_count = text.count(repl.new)

    # The expected-after-flip count equals the original min_count.
    # If the file has already been flipped, old_count is 0 and
    # new_count is in [min_count, max_count].
    already_flipped = (
        old_count == 0
        and repl.min_count <= new_count <= repl.max_count
    )

    if already_flipped:
        well_formed = True
    else:
        well_formed = repl.min_count <= old_count <= repl.max_count

    return FileStatus(
        file=file_path,
        description=repl.description,
        old_count=old_count,
        new_count=new_count,
        expected_old=repl.min_count,
        expected_new_after_flip=repl.min_count,
        well_formed=well_formed,
        already_flipped=already_flipped,
    )


# ── Atomic write ────────────────────────────────────────────────────


def _atomic_write_text(path: Path, content: str) -> None:
    """Write text to path via tempfile + os.replace, preserving mode."""
    if path.is_symlink():
        raise RuntimeError(
            f"Source file is a symlink: {path}. Refusing to follow."
        )
    original_mode = path.stat().st_mode & 0o777
    fd, tmp_path_str = tempfile.mkstemp(
        dir=str(path.parent), suffix=".tmp",
    )
    tmp_path = Path(tmp_path_str)
    try:
        with os.fdopen(fd, "w") as fp:
            fp.write(content)
        os.chmod(tmp_path, original_mode)
        os.replace(tmp_path, path)
    except Exception:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        raise


# ── Operations ──────────────────────────────────────────────────────


def check(repo_root: Path, out: TextIO) -> int:
    """Read-only inspection. Reports per-replacement status, exits 0
    only if every replacement is in a clean state (either fully
    pre-flip or fully post-flip)."""
    statuses = [
        _classify_replacement(repo_root, r) for r in REPLACEMENTS
    ]
    all_well_formed = all(s.well_formed for s in statuses)
    all_flipped = all(s.already_flipped for s in statuses)
    none_flipped = all(not s.already_flipped for s in statuses)

    print(f"Repo root: {repo_root}", file=out)
    print("-" * 60, file=out)
    for s, r in zip(statuses, REPLACEMENTS):
        state = (
            "ALREADY FLIPPED" if s.already_flipped
            else ("PRE-FLIP" if s.well_formed else "MALFORMED")
        )
        print(
            f"  [{state:>15s}]  {r.file_relative} – {s.description}",
            file=out,
        )
        print(
            f"    old hits: {s.old_count}  new hits: {s.new_count}  "
            f"expected: min={r.min_count} max={r.max_count}",
            file=out,
        )

    print("-" * 60, file=out)
    if all_flipped:
        print("Status: rebrand constants ALREADY FLIPPED.", file=out)
        return EXIT_OK
    if none_flipped and all_well_formed:
        print("Status: rebrand constants in PRE-FLIP state.", file=out)
        return EXIT_OK
    if all_well_formed:
        print(
            "Status: PARTIAL FLIP – some constants flipped, "
            "others not. Inspect manually before re-running.",
            file=out,
        )
        return EXIT_INCOMPLETE
    print(
        "Status: MALFORMED – at least one file's match count is "
        "outside the expected range. Investigate before flipping.",
        file=out,
    )
    return EXIT_INCOMPLETE


def dry_run(repo_root: Path, out: TextIO) -> int:
    rc = check(repo_root, out)
    if rc != EXIT_OK:
        return rc

    # Show the diff that --execute would apply.
    print("", file=out)
    print("Diff that --execute would apply:", file=out)
    print("-" * 60, file=out)

    statuses = [
        _classify_replacement(repo_root, r) for r in REPLACEMENTS
    ]
    if all(s.already_flipped for s in statuses):
        print("  (nothing – constants already flipped)", file=out)
        return EXIT_OK

    for s, r in zip(statuses, REPLACEMENTS):
        if s.already_flipped:
            continue
        print(f"  {r.file_relative} – {s.description}", file=out)
        print(f"    -  {r.old}", file=out)
        print(f"    +  {r.new}", file=out)
        print(f"    ({s.old_count} occurrence(s))", file=out)

    return EXIT_OK


def execute(repo_root: Path, out: TextIO) -> int:
    statuses = [
        _classify_replacement(repo_root, r) for r in REPLACEMENTS
    ]
    if not all(s.well_formed for s in statuses):
        print(
            "Refusing to flip: at least one source file is not in a "
            "well-formed pre-flip state. Re-run with --check to see.",
            file=out,
        )
        return EXIT_INCOMPLETE

    flipped = 0
    skipped = 0
    for s, r in zip(statuses, REPLACEMENTS):
        if s.already_flipped:
            skipped += 1
            print(
                f"  [skip] {r.file_relative}: already flipped",
                file=out,
            )
            continue
        text = s.file.read_text()
        new_text = text.replace(r.old, r.new)
        # Sanity: count must match exactly.
        new_text_count = new_text.count(r.new)
        if new_text_count != s.old_count + s.new_count:
            return EXIT_INTERNAL  # pragma: no cover
        _atomic_write_text(s.file, new_text)
        flipped += 1
        print(
            f"  [ok  ] {r.file_relative}: flipped {s.old_count} "
            f"occurrence(s) – {s.description}",
            file=out,
        )

    print("-" * 60, file=out)
    print(f"  {flipped} flipped, {skipped} already flipped", file=out)
    if flipped:
        print("", file=out)
        print("Next steps:", file=out)
        print(
            "  1. Update tests that hard-code the old constants:\n"
            "       ostler_security/tests/test_keychain.py\n"
            "         (test_service_constant – update expected value)",
            file=out,
        )
        print(
            "  2. Run the test suite end-to-end to confirm no other "
            "callers reference the legacy strings.",
            file=out,
        )
        print(
            "  3. Commit the source change separately from any "
            "code-only refactor.",
            file=out,
        )
    return EXIT_OK


# ── CLI ─────────────────────────────────────────────────────────────


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ostler-flip-constants",
        description=(
            "Flip the rebrand-affected source-code constants once "
            "the data migrations are complete. Default is --dry-run; "
            "pass --execute to write."
        ),
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="Read-only inspection. Reports state.")
    mode.add_argument("--dry-run", action="store_true",
                      help="(default) show the diff. No writes.")
    mode.add_argument("--execute", action="store_true",
                      help="Apply the flip in-place.")
    p.add_argument("--repo-root", type=Path, default=None,
                   help="Override the auto-detected repo root.")
    return p


def main(argv: Optional[list[str]] = None,
         out: Optional[TextIO] = None,
         err: Optional[TextIO] = None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        repo_root = (
            args.repo_root.expanduser()
            if args.repo_root
            else find_repo_root()
        )
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=err)
        return EXIT_INTERNAL

    # If --repo-root was given explicitly, validate it has the layout
    # we expect. Without this, downstream FileNotFoundError percolates
    # out of read_text and the operator gets a confusing traceback.
    missing = [
        r.file_relative for r in REPLACEMENTS
        if not (repo_root / r.file_relative).exists()
    ]
    if missing:
        print(
            f"ERROR: repo root {repo_root} is missing expected files: "
            f"{', '.join(missing)}",
            file=err,
        )
        return EXIT_INTERNAL

    is_dry_run = (
        args.dry_run or not (args.check or args.execute)
    )

    if args.check:
        return check(repo_root, out)
    if is_dry_run:
        return dry_run(repo_root, out)
    if args.execute:
        return execute(repo_root, out)

    return EXIT_BAD_ARGS  # pragma: no cover


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
