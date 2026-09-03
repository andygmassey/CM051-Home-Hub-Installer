#!/usr/bin/env python3
"""A CANNOT-RUN branch after a bare call is unreachable code.

── THE DEFECT ───────────────────────────────────────────────────────────────

GitHub runs a `run:` block as `/bin/bash -e {0}` (the runner prints this).
Under -e, a command that exits non-zero terminates the step AT THAT LINE.
So this shape:

    /bin/bash tests/test_thing.sh
    rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "::error::CANNOT-RUN -- nothing was measured, this is not a pass"
    fi
    exit "$rc"

never reaches the echo. The step still fails, but it fails ANONYMOUSLY: a
harness that could not set itself up is reported identically to a product
defect. CANNOT-RUN is a third state, and this shape silently collapses it
into FAIL.

Measured 2026-09-04 under the real shell, with a stub test exiting 2:

    bare call + rc=$?    rc=2, 0 ::error lines   <- unreachable
    `... || rc=$?`       rc=2, 1 ::error line
    control, test exits 0  rc=0, 0 ::error lines  <- silent on a pass

Found live on CM051 #1398: the "A refusal must reach the transcript" step
went RED while the test it ran passed 8 of 8. The step had BOTH this defect
and a dropped `fi`, and the syntax error masked the dead branch underneath.

── WHY A GATE AND NOT FOURTEEN FIXES ────────────────────────────────────────

The shape is idiomatic and reads correctly. It is what anyone writes who has
not measured it. Fourteen fixes leave the fifteenth free to be written next
week, and two of the fourteen sat on the SHIP path (cut.yml's DMG walk step,
walk-record-gate.yml). The gate does not.

── THE PREDICATE ────────────────────────────────────────────────────────────

Report `NAME=$?` when ALL of:
  * the step's effective shell has -e semantics, AND
  * no `set +e` appears earlier in the same run block, AND
  * no `|| NAME=` appears earlier in the same run block, AND
  * the preceding code line is an unprotected command (no ||, &&, no
    if/while/until/! head).

Exit 0 clean, 1 violations, 2 CANNOT-RUN. A cannot-run is NOT a pass.
"""

import pathlib
import re
import sys

USAGE = "usage: verify_cannot_run_branch_is_reachable.py [WORKFLOWS_DIR]"

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_CANNOT_RUN = 2

# Anti-vacuity floors. A scan that parsed almost nothing scores identically to
# a clean one. These are floors, not expectations -- they only have to be low
# enough never to fire on a real tree and high enough to catch a broken glob.
MIN_WORKFLOWS = 20
MIN_RUN_STEPS = 60

RC_ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=\$\?\s*(#.*)?$")

# A line that cannot be the unprotected tail of a fallible command.
PROTECTED_HEAD = re.compile(r"^\s*(if|elif|while|until|case|!|\}|fi|done|esac|then|else)\b")


def effective_shell(doc, job, step):
    """Resolve the shell this step actually runs under.

    Precedence: step > job defaults > workflow defaults > GitHub's default.
    GitHub's default for `run:` on macOS and Linux is `bash -e {0}`.
    """
    for src in (step,
                (job or {}).get("defaults", {}).get("run", {}),
                (doc or {}).get("defaults", {}).get("run", {})):
        if isinstance(src, dict) and src.get("shell"):
            return str(src["shell"])
    return "__default__"


def shell_has_errexit(shell):
    """Does this shell abort the step on the first non-zero command?

    The default and the named `bash`/`sh`/`pwsh` forms all set -e. Only a
    CUSTOM command line (one containing {0}) can opt out, and then only by
    genuinely omitting -e.
    """
    if shell == "__default__":
        return True
    s = shell.strip()
    if "{0}" in s:
        # A custom invocation. It has errexit only if it asks for it.
        return bool(re.search(r"(^|\s)-[a-zA-Z]*e", s))
    # Named shells: bash and sh get -e from GitHub. python/pwsh/cmd do not
    # have this shape at all, so they cannot carry the defect.
    return s.split()[0] in ("bash", "sh")


def find_violations(run, shell):
    """Return [(lineno, varname, prev_line)] for unreachable-rc sites."""
    if not shell_has_errexit(shell):
        return []
    out = []
    lines = run.split("\n")
    for i, line in enumerate(lines):
        m = RC_ASSIGN.match(line)
        if not m:
            continue
        var = m.group(1)
        before = lines[:i]
        joined = "\n".join(before)
        # Already guarded, in either of the two correct spellings.
        if re.search(r"^\s*set\s+\+e", joined, re.M):
            continue
        if re.search(rf"\|\|\s*{re.escape(var)}=", joined):
            continue
        # The command this is capturing. Skip blanks and comments backwards.
        prev = ""
        for cand in reversed(before):
            t = cand.strip()
            if t and not t.startswith("#"):
                prev = t
                break
        if not prev:
            continue
        if PROTECTED_HEAD.match(prev):
            continue
        if "||" in prev or "&&" in prev:
            continue
        out.append((i + 1, var, prev))
    return out


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("-")]
    if len(args) > 1:
        print(USAGE, file=sys.stderr)
        return EXIT_CANNOT_RUN

    wf_dir = pathlib.Path(args[0]) if args else pathlib.Path(".github/workflows")
    strict = "--no-floor" not in argv[1:]

    if not wf_dir.is_dir():
        print(f"COULD NOT RUN: {wf_dir} is not a directory (exit 2)",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    try:
        import yaml
    except ImportError:
        print("COULD NOT RUN: PyYAML is not installed, so no workflow could be "
              "parsed. This is a cannot-run, NOT a pass (exit 2)",
              file=sys.stderr)
        return EXIT_CANNOT_RUN

    files = sorted(wf_dir.glob("*.yml")) + sorted(wf_dir.glob("*.yaml"))
    if not files:
        print(f"COULD NOT RUN: no workflow files under {wf_dir}. An empty scan "
              f"scores identically to a clean one (exit 2)", file=sys.stderr)
        return EXIT_CANNOT_RUN

    violations = []
    n_workflows = 0
    n_run_steps = 0

    for f in files:
        try:
            doc = yaml.safe_load(f.read_text())
        except Exception as e:  # noqa: BLE001 -- any parse failure is cannot-run
            print(f"COULD NOT RUN: {f.name} did not parse: {e} (exit 2)",
                  file=sys.stderr)
            return EXIT_CANNOT_RUN
        if not isinstance(doc, dict):
            continue
        n_workflows += 1
        for job_name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            for step in (job.get("steps") or []):
                if not isinstance(step, dict):
                    continue
                run = step.get("run")
                if not isinstance(run, str):
                    continue
                n_run_steps += 1
                shell = effective_shell(doc, job, step)
                for lineno, var, prev in find_violations(run, shell):
                    violations.append({
                        "file": f.name,
                        "job": job_name,
                        "step": step.get("name", "<unnamed>"),
                        "line": lineno,
                        "var": var,
                        "prev": prev,
                    })

    print(f"workflows parsed : {n_workflows}")
    print(f"run steps scanned: {n_run_steps}")
    print(f"violations       : {len(violations)}")

    if strict and (n_workflows < MIN_WORKFLOWS or n_run_steps < MIN_RUN_STEPS):
        print(f"\nCOULD NOT RUN: scanned {n_workflows} workflows / "
              f"{n_run_steps} run steps, below the floor of {MIN_WORKFLOWS} / "
              f"{MIN_RUN_STEPS}. A near-empty scan prints the same zero as a "
              f"clean one, so it is not a pass (exit 2)", file=sys.stderr)
        return EXIT_CANNOT_RUN

    if violations:
        print()
        for v in violations:
            print(f"  {v['file']} [{v['job']}] {v['step']}")
            print(f"      line {v['line']} of the run block: {v['var']}=$?")
            print(f"      captures: {v['prev'][:90]}")
        print(f"\nFAIL: {len(violations)} site(s) capture $? after a bare call "
              f"under a -e shell. The rc is never captured and any CANNOT-RUN "
              f"branch below is dead code -- a harness failure reports "
              f"identically to a product failure.")
        print("Fix: `cmd || rc=$?` (and initialise `rc=0` first), or `set +e` "
              "before the call.")
        return EXIT_VIOLATION

    print("\nOK: every $? capture is reachable under the step's own shell.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
