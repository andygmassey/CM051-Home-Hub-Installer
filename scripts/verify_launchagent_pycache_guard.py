#!/usr/bin/env python3
"""Refuse a cut in which a LaunchAgent can run a Python without a bytecode redirect.

WHY THIS EXISTS
---------------
v1.0.45 shipped, installed cleanly, and bricked Andy's Mac. Gatekeeper refused
the app because 69 `.pyc` files had appeared inside the notarised bundle.

The cause was not a missing fix. `PYTHONPYCACHEPREFIX` was in the shipped
Mach-O twice (universal binary, two arches) and it works. It was set on the ONE
`Process()` the GUI installer spawns, and launchd is not in that process tree.
The CM059 front-page LaunchAgent ran the app's own interpreter at RunAtLoad and
then hourly, with `EnvironmentVariables` carrying `PATH` and nothing else. Its
plist comment even says "LaunchAgents do not inherit the user's shell PATH";
they do not inherit `PYTHONPYCACHEPREFIX` either.

Measured on a writable ditto of the shipped v1.0.45 app, one ordinary import
(`json, ssl, sqlite3, urllib.request, email.parser`):

    guard set    ->  0 .pyc in the bundle, codesign --deep --strict rc=0
    guard unset  -> 69 .pyc, rc=1 "a sealed resource is missing or invalid"

Four agents had touched this area. Nothing caught it. The only reason it was
found is that a customer's Mac stopped working, and that customer was Andy.

WHAT THIS ASSERTS
-----------------
Every LaunchAgent this repo installs that can reach a Python interpreter must
have `PYTHONPYCACHEPREFIX` reachable at the moment it runs: either in the
plist's own `EnvironmentVariables`, or exported by the script the plist
launches. Nothing else is accepted, because nothing else survives launchd's
empty environment.

This is deliberately a WIDER net than "the interpreter is inside the .app". The
relocation fix means most of these are no longer bundle-anchored, but a rule
phrased around WHERE the interpreter lives needs re-deriving every time the
layout changes, while "a launchd job that runs python sets the redirect" does
not. Cheap to satisfy, one line, and it holds for the next agent who adds one.

PORTABILITY
-----------
`plutil` and `PlistBuddy` are macOS-only and the `preflight` job that runs this
is `ubuntu-latest`. A macOS-only reader in that job has blocked a cut here
before (v1.0.40, PlistBuddy). `plistlib` is stdlib, reads XML and binary, and
runs on both. Fix the reader, never the runner.

EXITS
-----
    0  every python-capable LaunchAgent is guarded
    1  at least one is not
    2  CANNOT-RUN. Nothing was measured, which is not a pass.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
import tempfile
from pathlib import Path

GUARD = "PYTHONPYCACHEPREFIX"
ALT_GUARD = "PYTHONDONTWRITEBYTECODE"

# A ProgramArguments entry, or a line in the launched script, that reaches a
# Python. Deliberately loose: a false POSITIVE here costs one comment line on a
# new agent, a false negative costs a bricked Mac.
PY_RE = re.compile(r"python3(\.\d+)?\b|/\.venv/bin/python|_PYTHON\b|PYTHON_BIN\b|PYTHON3_BIN\b")

# ${VAR} and bare PLACEHOLDER tokens are substituted at install time. Replace
# them so plistlib sees well-formed values rather than refusing to parse.
VAR_RE = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}")
PLACEHOLDER_RE = re.compile(r"\b(OSTLER_BIN|OSTLER_HOME|OSTLER_LOGS|OSTLER_ASSISTANT_BINARY|HUB_POWER_BIN)\b")


class CannotRun(Exception):
    """Raised when the check could not be performed. Never a pass."""


# XML comments carry no plist data, and stripping them is not merely tidiness:
# at least one inline plist in install.sh (com.ostler.ollama, ~10265) contains a
# comment with a DOUBLE HYPHEN in it, which XML forbids inside a comment. Apple's
# parser is lenient and launchd loads it happily; every strict reader, plistlib
# included, refuses the whole document. Stripping comments also means a guard
# mentioned only in a comment cannot satisfy this check, which is the correct
# reading anyway.
COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
NUMERIC_SUB_RE = re.compile(r"<(integer|real)>/tmp/substituted</(?:integer|real)>")


def _substitute(xml: str) -> str:
    xml = COMMENT_RE.sub("", xml)
    xml = VAR_RE.sub("/tmp/substituted", xml)
    xml = PLACEHOLDER_RE.sub("/tmp/substituted", xml)
    # Some plists interpolate a shell variable into a NUMERIC field
    # (com.ostler.fda-rerun's StartInterval, for one). A path substituted there
    # parses as XML and then dies in plistlib's int(). Type-correct the numeric
    # fields rather than loosening the parse, so a genuinely malformed plist
    # still gets caught.
    xml = NUMERIC_SUB_RE.sub(lambda m: f"<{m.group(1)}>0</{m.group(1)}>", xml)
    return xml


def _parse(xml: str, origin: str) -> dict:
    try:
        return plistlib.loads(_substitute(xml).encode("utf-8"))
    except Exception as exc:  # noqa: BLE001 -- any parse failure is CANNOT-RUN
        raise CannotRun(f"{origin}: plist did not parse ({exc})") from exc


def template_plists(root: Path) -> list[tuple[str, str]]:
    """Every checked-in plist under a launchd/ directory."""
    out = []
    for p in sorted(root.rglob("launchd/*.plist")):
        out.append((str(p.relative_to(root)), p.read_text(encoding="utf-8", errors="replace")))
    return out


def inline_plists(install_sh: Path) -> list[tuple[str, str]]:
    """Every plist written inline by install.sh, sliced out of its heredocs."""
    text = install_sh.read_text(encoding="utf-8", errors="replace")
    out = []
    for m in re.finditer(r"<\?xml[^\0]*?</plist>", text):
        body = m.group(0)
        label = re.search(r"<key>Label</key>\s*<string>([^<]*)</string>", body)
        name = label.group(1) if label else "<unlabelled>"
        line = text.count("\n", 0, m.start()) + 1
        out.append((f"install.sh:{line} ({name})", body))
    return out


def launched_scripts(root: Path, program_args: list[str]) -> list[Path]:
    """Resolve the shell scripts a plist launches, by basename, inside the repo."""
    found = []
    for arg in program_args:
        base = Path(arg).name
        if not base.endswith(".sh"):
            continue
        found.extend(sorted(root.rglob(base)))
    return found


def runs_python(root: Path, plist: dict, program_args: list[str], raw_xml: str = "") -> tuple[bool, str]:
    # THE RAW XML FIRST, and this is not belt-and-braces.
    #
    # com.ostler.ical-server's ProgramArguments is `${OSTLER_PYTHON}`. By the
    # time plistlib sees it, _substitute has rewritten it to a placeholder path
    # with no "python" in it, so matching only the PARSED values scored it as
    # not-a-python-agent. The gate reported 3 where a hand count said 4, and the
    # only reason that was caught is that the hand count existed first.
    #
    # The substitution exists to make the document parse. It must not be
    # allowed to destroy the evidence the check is looking for.
    raw_args = re.search(r"<key>ProgramArguments</key>\s*<array>(.*?)</array>", raw_xml, re.S)
    if raw_args and PY_RE.search(raw_args.group(1)):
        hit = PY_RE.search(raw_args.group(1)).group(0)
        return True, f"ProgramArguments (pre-substitution) carries {hit!r}"
    for arg in program_args:
        if PY_RE.search(arg):
            return True, f"ProgramArguments carries {arg!r}"
    for script in launched_scripts(root, program_args):
        body = script.read_text(encoding="utf-8", errors="replace")
        for line in body.splitlines():
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if PY_RE.search(stripped):
                return True, f"{script.name} invokes a python"
    return False, ""


def is_guarded(root: Path, plist: dict, program_args: list[str]) -> tuple[bool, str]:
    env = plist.get("EnvironmentVariables") or {}
    if GUARD in env or ALT_GUARD in env:
        return True, "plist EnvironmentVariables"
    for script in launched_scripts(root, program_args):
        body = script.read_text(encoding="utf-8", errors="replace")
        for line in body.splitlines():
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if (GUARD in stripped or ALT_GUARD in stripped) and stripped.startswith("export "):
                return True, f"{script.name} exports it"
    return False, ""


def audit(root: Path) -> int:
    install_sh = root / "install.sh"
    if not install_sh.is_file():
        raise CannotRun(f"no install.sh at {install_sh}; wrong root, nothing measured")

    entries = template_plists(root) + inline_plists(install_sh)
    if not entries:
        raise CannotRun("found ZERO plists. A denominator of zero is not a pass.")

    examined = 0
    not_a_launchagent = 0
    python_capable = 0
    unguarded: list[tuple[str, str]] = []
    guarded: list[str] = []

    for origin, xml in entries:
        plist = _parse(xml, origin)
        # install.sh also writes Info.plist documents for app wrappers
        # (CFBundleExecutable and friends, ~12663 and ~12815). They are not
        # LaunchAgents, they have no ProgramArguments, and counting them in the
        # denominator inflated it from 29 to 31 -- a number that would have had
        # a reader hunting for two agents that do not exist. Excluded, and the
        # exclusion is PRINTED rather than silent.
        if "Label" not in plist and "ProgramArguments" not in plist:
            not_a_launchagent += 1
            continue
        examined += 1
        args = [str(a) for a in (plist.get("ProgramArguments") or [])]
        # Raw arg strings too, so a `.sh` named only via ${VAR} still resolves.
        raw_args_m = re.search(r"<key>ProgramArguments</key>\s*<array>(.*?)</array>", xml, re.S)
        if raw_args_m:
            args = args + re.findall(r"<string>([^<]*)</string>", raw_args_m.group(1))
        reaches, why = runs_python(root, plist, args, xml)
        if not reaches:
            continue
        python_capable += 1
        ok, how = is_guarded(root, plist, args)
        if ok:
            guarded.append(f"{plist.get('Label', origin)}  [{how}]")
        else:
            unguarded.append((str(plist.get("Label", origin)), why))

    print("launchagent-pycache-guard: DENOMINATOR")
    print(f"  LaunchAgent plists examined  {examined}")
    print(f"    not a LaunchAgent, skipped {not_a_launchagent}  (Info.plist app wrappers)")
    print(f"    of which reach a python    {python_capable}")
    print(f"    guarded                    {len(guarded)}")
    print(f"    UNGUARDED                  {len(unguarded)}")
    for line in guarded:
        print(f"      ok    {line}")
    for label, why in unguarded:
        print(f"      FAIL  {label}  ({why})")

    if python_capable == 0:
        raise CannotRun(
            "no plist reaches a python. Measured 2026-08-26 there are four, so "
            "a zero here means the predicate broke, not that the risk went away."
        )

    if unguarded:
        print()
        print("A LaunchAgent that runs a python must set PYTHONPYCACHEPREFIX, in its")
        print("own EnvironmentVariables or in the script it launches. launchd hands a")
        print("job an empty environment, so it cannot inherit one. v1.0.45 bricked")
        print("exactly this way: 69 .pyc inside the notarised app, codesign rc=1.")
        return 1
    return 0


# ---------------------------------------------------------------------------
# SELF TEST. A gate never seen red is not a gate.
# ---------------------------------------------------------------------------

_GOOD_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.guarded</string>
  <key>ProgramArguments</key><array>
    <string>/tmp/x/.venv/bin/python3</string><string>/tmp/x/run.py</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PYTHONPYCACHEPREFIX</key><string>/tmp/cache</string>
  </dict>
</dict></plist>
"""

_BAD_PLIST = _GOOD_PLIST.replace(
    """  <key>EnvironmentVariables</key><dict>
    <key>PYTHONPYCACHEPREFIX</key><string>/tmp/cache</string>
  </dict>
""",
    "",
).replace("com.example.guarded", "com.example.unguarded")

_NO_PYTHON_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.rustonly</string>
  <key>ProgramArguments</key><array>
    <string>/tmp/x/bin/ostler-assistant</string><string>daemon</string>
  </array>
</dict></plist>
"""


def _scaffold(tmp: Path, plists: dict[str, str], script: str | None = None) -> Path:
    root = tmp / "repo"
    (root / "thing" / "launchd").mkdir(parents=True)
    (root / "install.sh").write_text("#!/usr/bin/env bash\necho hi\n", encoding="utf-8")
    for name, body in plists.items():
        (root / "thing" / "launchd" / name).write_text(body, encoding="utf-8")
    if script is not None:
        (root / "thing" / "bin").mkdir(parents=True)
        (root / "thing" / "bin" / "tick.sh").write_text(script, encoding="utf-8")
    return root


def self_test() -> int:
    failures = []

    def check(name: str, got, want) -> None:
        status = "ok  " if got == want else "FAIL"
        print(f"  {status} {name}: got {got!r}, want {want!r}")
        if got != want:
            failures.append(name)

    print("launchagent-pycache-guard: SELF TEST")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        r = _scaffold(tmp / "a", {"good.plist": _GOOD_PLIST})
        check("a guarded python agent PASSES", audit(r), 0)

        r = _scaffold(tmp / "b", {"bad.plist": _BAD_PLIST})
        check("an UNGUARDED python agent FAILS", audit(r), 1)

        # A plist that runs the Rust daemon must not be dragged in: an
        # over-broad predicate that failed on every agent would be turned off
        # within a week.
        r = _scaffold(tmp / "c", {"rust.plist": _NO_PYTHON_PLIST, "good.plist": _GOOD_PLIST})
        check("CONTROL a non-python agent is not required to be guarded", audit(r), 0)

        # A denominator of zero must be CANNOT-RUN, never a pass.
        r = _scaffold(tmp / "d", {"rust.plist": _NO_PYTHON_PLIST})
        try:
            audit(r)
            check("CONTROL zero python agents is CANNOT-RUN", "returned", "raised CannotRun")
        except CannotRun:
            check("CONTROL zero python agents is CANNOT-RUN", "raised CannotRun", "raised CannotRun")

        # The guard may live in the launched script instead of the plist.
        bad_with_script = _BAD_PLIST.replace(
            "<string>/tmp/x/.venv/bin/python3</string><string>/tmp/x/run.py</string>",
            "<string>/bin/bash</string><string>/tmp/x/tick.sh</string>",
        )
        guarded_script = (
            '#!/usr/bin/env bash\n'
            'export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-${HOME}/.ostler/cache/pycache}"\n'
            'PYTHON_BIN=/tmp/x/.venv/bin/python3\n"$PYTHON_BIN" -c "import json"\n'
        )
        r = _scaffold(tmp / "e", {"s.plist": bad_with_script}, script=guarded_script)
        check("a guard exported by the launched SCRIPT counts", audit(r), 0)

        # ...and removing just that export must flip it red. Same tree, one line.
        r = _scaffold(
            tmp / "f",
            {"s.plist": bad_with_script},
            script=guarded_script.replace(
                'export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-${HOME}/.ostler/cache/pycache}"\n', ""
            ),
        )
        check("MUTATION removing that export flips it RED", audit(r), 1)

        # A COMMENT mentioning the guard must not satisfy it. This is the shape
        # that would quietly disarm the gate: the file that documents the rule
        # would appear to obey it.
        r = _scaffold(
            tmp / "g",
            {"s.plist": bad_with_script},
            script=guarded_script.replace(
                'export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-${HOME}/.ostler/cache/pycache}"',
                "# we should really set PYTHONPYCACHEPREFIX here one day",
            ),
        )
        check("a COMMENT mentioning the guard does NOT satisfy it", audit(r), 1)

    print()
    if failures:
        print(f"SELF TEST FAILED: {', '.join(failures)}")
        return 1
    print("SELF TEST PASSED: the predicate goes red for the right reasons and green for the right reasons.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=".", help="repo root (default: cwd)")
    ap.add_argument("--self-test", action="store_true", help="prove the predicate fires, then exit")
    args = ap.parse_args()
    try:
        if args.self_test:
            return self_test()
        return audit(Path(args.root).resolve())
    except CannotRun as exc:
        print(f"launchagent-pycache-guard: CANNOT-RUN -- {exc}", file=sys.stderr)
        print("Nothing was measured. That is not a pass.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
