#!/usr/bin/env python3
"""AU-1 appcast-version guard: refuse to publish an entry Sparkle would skip.

Exit 0  the version being published is strictly newer, or the guard was
        deliberately skipped (no reference app to supersede) -- said out loud.
Exit 1  GUARD FAILED. The entry would be published and reach nobody.
Exit 2  CANNOT RUN. Nothing has been found wrong; this failed to LOOK.

============================================================================
THE SILENT FAILURE THIS PREVENTS
============================================================================

Sparkle decides whether to OFFER an update by comparing the appcast's
`sparkle:version` -- which is the new build's CFBundleVersion -- against the
CFBundleVersion of the app already installed. If the appcast version is LESS
THAN OR EQUAL TO the installed one, Sparkle SILENTLY skips it. No update
dialog, no log line, no error, on the Hub or on the server. "We published and
nobody got it" is the entire failure surface.

The concrete way it bites here: the Hub app's own version line (0.7.x) is
distinct from the daemon's hub-v0.4.x line, and both are visible in this
Makefile. Someone hand-types or pastes `0.4.41` where `0.7.4` belonged. That
publishes cleanly, validates as well-formed XML, serves a 200, and reaches
zero machines. Nothing anywhere goes red. So it has to be caught
MECHANICALLY, at publish time, before anything is signed or uploaded.

============================================================================
WHY THIS COMPARATOR LIVES IN CM051 AND NOT IN THE PUBLISHER
============================================================================

It belongs in CM050's `ostler-release publish --reference-app`, and that is
where it was written. MEASURED 2026-08-17 against CM050 origin/main:

    release-tooling/ostler_release/cli.py  cmd_publish options are
      --signature --version --build --channel --notes-url --min-os --pub-date

    `--reference-app` and `--dry-run` exist ONLY on the unmerged branches
      origin/feat/au1-appcast-version-guard   (CM050 PR #41, OPEN)
      origin/feat/au1-release-publish-dryrun  (its base, no PR)

CM051 PR #463 wired the guard by calling `ostler-release publish --dry-run
--reference-app ...`. Grafted onto today's main that is not a guard, it is a
hard failure on every cut: click rejects the unknown option, the recipe exits
non-zero, and the cut dies at the last step with a usage error. A gate that
cannot run is not a strict gate, it is a broken one.

So the PREDICATE is carried here, where the caller is, and the guard runs
unconditionally. The comparator below is a faithful port of the one on that
CM050 branch (release-tooling/ostler_release/versioning.py), which is itself a
port of Sparkle's SUStandardVersionComparator.m.

WHEN CM050 #41 LANDS: `publish-appcast` already threads `--reference-app` into
the real publish call if -- and only if -- the installed CLI advertises it, so
the server-side check switches itself on with no edit here. At that point this
file is a redundant second opinion at a different layer, which is a defensible
thing to keep. If a future reader decides it is not, DELETE it naming the
survivor, so the next reader lands on the live one rather than on two copies
where only one runs.

============================================================================
COMPARATOR SEMANTICS
============================================================================

Split each string into runs of digits and runs of non-digits, using '.', '-',
'+', '_' and whitespace as separators. Compare component by component:
numerically where both are numeric, else lexically. A numeric component ranks
ABOVE a non-numeric one at the same position, so a release ranks above a
pre-release. When one version is a strict prefix of the other, the first extra
component decides: numeric makes the longer version NEWER (1.0.1 > 1.0),
non-numeric makes it OLDER (1.0b < 1.0).

Dotted numeric versions -- the only shape this product actually ships --
compare as you would expect: 0.7.3 > 0.4.41, 0.7.10 > 0.7.9, 0.7.3 == 0.7.3.

BOTH FIELDS MUST BE STRICTLY GREATER, and that is deliberate rather than
belt-and-braces. `build` (CFBundleVersion) is the field Sparkle acts on, so a
regression there is the silent skip itself. `version`
(CFBundleShortVersionString) is the field the CUSTOMER reads in the update
dialog, so a regression there ships an update that announces itself as older
than what it replaces. Neither is acceptable and neither implies the other.

British English throughout; " -- " not em-dashes.
"""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path


class GuardError(Exception):
    """The publish must not proceed. Exit 1."""


class CannotRun(Exception):
    """The guard failed to look. Exit 2. NOT a finding."""


# ---------------------------------------------------------------------------
# Comparator (port of CM050 feat/au1-appcast-version-guard versioning.py)
# ---------------------------------------------------------------------------
_SEPARATORS = set(".-+_ \t\r\n")


def _split(version: str) -> list[str]:
    """Split a version string into comparable components, Sparkle-style.

    A type change also splits, so "1.0b3" -> ["1", "0", "b", "3"].
    """
    parts: list[str] = []
    current = ""
    current_is_digit: bool | None = None
    for ch in version.strip():
        if ch in _SEPARATORS:
            if current:
                parts.append(current)
                current = ""
                current_is_digit = None
            continue
        is_digit = ch.isdigit()
        if current and is_digit != current_is_digit:
            parts.append(current)
            current = ""
        current += ch
        current_is_digit = is_digit
    if current:
        parts.append(current)
    return parts


def _compare_component(a: str, b: str) -> int:
    a_num, b_num = a.isdigit(), b.isdigit()
    if a_num and b_num:
        ia, ib = int(a), int(b)
        return (ia > ib) - (ia < ib)
    if a_num and not b_num:
        # A numeric component ranks ABOVE a non-numeric one (release > beta).
        return 1
    if b_num and not a_num:
        return -1
    return (a > b) - (a < b)


def compare_versions(a: str, b: str) -> int:
    """Return -1 if a < b, 0 if a == b, +1 if a > b (Sparkle semantics)."""
    parts_a, parts_b = _split(a), _split(b)
    for pa, pb in zip(parts_a, parts_b):
        c = _compare_component(pa, pb)
        if c != 0:
            return c
    if len(parts_a) == len(parts_b):
        return 0
    if len(parts_a) > len(parts_b):
        extra = parts_a[len(parts_b)]
        return 1 if extra.isdigit() else -1
    extra = parts_b[len(parts_a)]
    return -1 if extra.isdigit() else 1


# ---------------------------------------------------------------------------
# Reference-app reading
# ---------------------------------------------------------------------------
def read_reference(app: Path) -> tuple[str, str]:
    """Return (short_version, build) from an .app bundle's Info.plist.

    Raises CannotRun rather than GuardError on every failure here. An
    unreadable plist has NOT found a version to be wrong; it means the guard
    could not look, and the two must never print the same way.
    """
    plist = app / "Contents" / "Info.plist"
    if not plist.is_file():
        raise CannotRun(f"no Info.plist inside the reference app: {plist}")
    try:
        with plist.open("rb") as fh:
            data = plistlib.load(fh)
    except Exception as exc:  # noqa: BLE001 -- any parse failure is cannot-run
        raise CannotRun(f"could not parse {plist}: {exc}") from exc
    short = str(data.get("CFBundleShortVersionString", "") or "")
    build = str(data.get("CFBundleVersion", "") or "")
    if not short or not build:
        raise CannotRun(
            f"{plist} is missing CFBundleShortVersionString and/or "
            f"CFBundleVersion (read: version={short!r} build={build!r})"
        )
    return short, build


def assert_strictly_newer(new: str, ref: str, field: str) -> None:
    c = compare_versions(new, ref)
    if c > 0:
        return
    relation = "EQUAL TO" if c == 0 else "LOWER THAN"
    raise GuardError(
        f"{field}: publishing {new!r}, which is {relation} the installed "
        f"{ref!r}. Sparkle would SILENTLY skip this entry."
    )


def run_guard(version: str, build: str, reference_app: str) -> int:
    """The real check. Returns the process exit code."""
    if not reference_app.strip():
        print(
            "[NOTE] AU-1 version guard SKIPPED -- no reference app given "
            "(guard explicitly disabled). Nothing was compared."
        )
        return 0
    app = Path(reference_app)
    if not app.is_dir():
        print(
            f"[NOTE] AU-1 version guard SKIPPED -- {app} is not present, so "
            "there is no installed Hub to supersede (fresh box / first "
            "release). Nothing was compared."
        )
        return 0

    ref_version, ref_build = read_reference(app)
    print(
        f"[STEP] AU-1 version guard: publishing v{version} (build {build}); "
        f"installed at {app} is v{ref_version} (build {ref_build})."
    )
    # Build first: it is the field Sparkle actually compares, so it is the
    # one that produces the silent skip.
    assert_strictly_newer(build, ref_build, "build (sparkle:version / CFBundleVersion)")
    assert_strictly_newer(
        version, ref_version, "version (sparkle:shortVersionString / CFBundleShortVersionString)"
    )
    print(
        f"[OK] AU-1 version guard passed: v{version} (build {build}) is "
        f"strictly newer than the installed Hub."
    )
    return 0


# ---------------------------------------------------------------------------
# SELF-TEST
#
# A guard that has only ever been observed passing is not known to be able to
# fail, and one that has only ever been observed failing gets bypassed. Both
# directions are exercised, plus the cannot-run branch, because a cannot-run
# reported as a pass is how an unverified cut ships.
# ---------------------------------------------------------------------------
def self_test() -> int:
    import tempfile

    passed = failed = 0

    def ok(msg: str) -> None:
        nonlocal passed
        print(f"  PASS  {msg}")
        passed += 1

    def no(msg: str) -> None:
        nonlocal failed
        print(f"  FAIL  {msg}")
        failed += 1

    def cmp_is(a: str, b: str, want: int, why: str) -> None:
        got = compare_versions(a, b)
        (ok if got == want else no)(f"{why}  ({a!r} vs {b!r}: want {want}, got {got})")

    # The comparator, including the exact shape that motivates the guard.
    cmp_is("0.7.3", "0.4.41", 1, "dotted numeric compares per component, not lexically")
    cmp_is("0.4.41", "0.7.3", -1, "THE MOTIVATING CASE: a daemon version is LOWER than a Hub version")
    cmp_is("0.7.10", "0.7.9", 1, "10 > 9 numerically (a string compare would say otherwise)")
    cmp_is("0.7.3", "0.7.3", 0, "equal versions compare equal, so equal cannot pass a strict test")
    cmp_is("1.0.1", "1.0", 1, "a trailing NUMERIC component makes the longer version newer")
    cmp_is("1.0b", "1.0", -1, "a trailing NON-numeric component makes the longer version older")
    cmp_is("1.0", "1.0b3", 1, "a release ranks above a pre-release at the same position")

    def make_app(root: Path, short: str, build: str) -> Path:
        app = root / "Ostler.app"
        (app / "Contents").mkdir(parents=True, exist_ok=True)
        with (app / "Contents" / "Info.plist").open("wb") as fh:
            plistlib.dump({"CFBundleShortVersionString": short, "CFBundleVersion": build}, fh)
        return app

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        installed = make_app(root / "installed", "0.7.3", "703")

        # (A) THE GREEN CONTROL.
        rc = _rc(lambda: run_guard("0.7.4", "704", str(installed)))
        (ok if rc == 0 else no)(f"(A) a strictly newer release passes, exit 0 (got {rc})")

        # (B) EQUAL. Sparkle skips this, so the guard must not.
        rc = _rc(lambda: run_guard("0.7.3", "703", str(installed)))
        (ok if rc == 1 else no)(f"(B) an EQUAL version is refused, exit 1 (got {rc})")

        # (C) LOWER -- the daemon-version paste.
        rc = _rc(lambda: run_guard("0.4.41", "441", str(installed)))
        (ok if rc == 1 else no)(f"(C) a LOWER version is refused, exit 1 (got {rc})")

        # (D) BUILD REGRESSES WHILE SHORT VERSION CLIMBS. This is the case a
        # short-version-only check waves through, and it is the silent skip:
        # Sparkle reads the build.
        rc = _rc(lambda: run_guard("0.7.4", "702", str(installed)))
        (ok if rc == 1 else no)(f"(D) a climbing version with a REGRESSED build is refused (got {rc})")

        # (E) SHORT VERSION REGRESSES WHILE BUILD CLIMBS. Sparkle would offer
        # it; the customer would be shown an update labelled older than what
        # they have. Refused for a different reason than (D).
        rc = _rc(lambda: run_guard("0.6.9", "704", str(installed)))
        (ok if rc == 1 else no)(f"(E) a climbing build with a REGRESSED version is refused (got {rc})")

        # (F) ABSENT reference app -> documented skip, exit 0.
        rc = _rc(lambda: run_guard("0.7.4", "704", str(root / "nope" / "Ostler.app")))
        (ok if rc == 0 else no)(f"(F) an ABSENT reference app skips the guard, exit 0 (got {rc})")

        # (G) EMPTY reference app -> guard disabled, exit 0.
        rc = _rc(lambda: run_guard("0.7.4", "704", ""))
        (ok if rc == 0 else no)(f"(G) an EMPTY reference app disables the guard, exit 0 (got {rc})")

        # (H) CANNOT RUN is exit 2, NOT exit 1. A bundle with no Info.plist has
        # found nothing wrong with the version. Reporting it as a guard failure
        # sends the operator to bump a version that was never the problem.
        broken = root / "broken" / "Ostler.app"
        broken.mkdir(parents=True)
        rc = _rc(lambda: run_guard("0.7.4", "704", str(broken)))
        (ok if rc == 2 else no)(f"(H) an unreadable reference app is CANNOT-RUN, exit 2 (got {rc})")

    print()
    print(f"=== {passed} passed / {failed} failed ===")
    return 0 if failed == 0 else 1


def _rc(fn) -> int:
    """Run a guard call and reduce it to the exit code the CLI would use."""
    try:
        return fn()
    except GuardError:
        return 1
    except CannotRun:
        return 2


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="appcast_version_guard.py",
        description="Refuse to publish an appcast entry Sparkle would silently skip.",
    )
    ap.add_argument("--version", help="CFBundleShortVersionString being published")
    ap.add_argument("--build", help="CFBundleVersion being published (sparkle:version)")
    ap.add_argument(
        "--reference-app",
        default="",
        help="the installed .app this release supersedes; absent or empty skips the guard",
    )
    ap.add_argument("--self-test", action="store_true", help="run the controls and exit")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    if not args.version or not args.build:
        print(
            "appcast-version-guard: CANNOT RUN -- both --version and --build "
            "are required. Nothing has been compared.",
            file=sys.stderr,
        )
        return 2

    try:
        return run_guard(args.version, args.build, args.reference_app)
    except GuardError as exc:
        print("", file=sys.stderr)
        print(f"ERROR: AU-1 appcast-version guard FAILED -- {exc}", file=sys.stderr)
        print(
            "  Refusing to sign or publish. Bump the version and build above the "
            "installed Hub,",
            file=sys.stderr,
        )
        print(
            "  or point HUB_REFERENCE_APP at the app this release actually "
            "supersedes.",
            file=sys.stderr,
        )
        return 1
    except CannotRun as exc:
        print("", file=sys.stderr)
        print(f"ERROR: the AU-1 version guard COULD NOT RUN -- {exc}", file=sys.stderr)
        print(
            "  It has NOT found a version to be wrong; it failed to look. A "
            "publish whose",
            file=sys.stderr,
        )
        print(
            "  version was never checked is not a checked publish. DO NOT "
            "PUBLISH.",
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    sys.exit(main())
