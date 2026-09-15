#!/usr/bin/env python3
"""The cut checklist must exclude CI alarms, and must exclude NOTHING ELSE.

THE LIVELOCK THIS GUARDS, MEASURED ON 2026-09-06.

`red-main-opens-an-issue.yml` opens an issue labelled `main-red` when a gate
fails on main, and that issue closes itself when the gate next SUCCEEDS on
main. `test_the_cut_checklist_is_complete.py` is one of the gates it watches,
and it requires every OPEN issue to be registered in the cut manifest. So:

    the checklist gate goes red   ->  watchdog opens #1713, label main-red
    #1713 open and unregistered   ->  the checklist gate goes red
    the gate never succeeds       ->  #1713 never self-closes

Main could not return to green by any amount of correct work. The only exits
were putting a transient CI alarm into the SHIPPING checklist, or closing it
by hand against the instructions printed in its own body.

WHY THIS TEST EXISTS SEPARATELY FROM THE FIX. An exclusion is a hole in a
gate. This asserts the hole is exactly the shape of the alarm and no larger:
an unlabelled issue is still required, an issue with a DIFFERENT label is
still required, and a repository whose every open issue wears the alarm label
is CANNOT-RUN rather than a clean sheet.

`gh` is stubbed on PATH so the arms are deterministic and no network is
touched. The stub's own correctness is checked by the first arm: if the stub
were broken, the subject would report CANNOT-RUN and every later arm would
be meaningless.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
SUBJECT = REPO / "tests" / "test_the_cut_checklist_is_complete.py"
MANIFEST = REPO / "cut-manifests"

PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  [PASS] {m}")


def bad(m):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {m}")


def registered_issue_numbers():
    """Read the newest manifest's registered ids WITHOUT importing yaml.

    The runner may not have PyYAML, and a skip here would read as a pass.
    """
    manifests = sorted(MANIFEST.glob("v*.yaml"))
    if not manifests:
        print("  [CANNOT-RUN] no cut manifest to read. NOTHING was measured.")
        raise SystemExit(2)

    def key(p):
        return [int(x) for x in re.findall(r"\d+", p.stem)]

    newest = max(manifests, key=key)
    ids = [int(m.group(1)) for m in
           re.finditer(r"^  - issue:\s*(\d+)\s*$", newest.read_text(encoding="utf-8"),
                       re.MULTILINE)]
    if not ids:
        print(f"  [CANNOT-RUN] parsed ZERO issue rows out of {newest.name}. That is a "
              f"broken predicate, not an empty register.")
        raise SystemExit(2)
    return newest.name, ids


def run_with_stub(issues):
    """Run the subject with `gh issue list` answering `issues`.

    `issues` is a list of (number, [labels]).
    """
    payload = json.dumps([{"number": n, "labels": [{"name": x} for x in labs]}
                          for n, labs in issues])
    with tempfile.TemporaryDirectory() as tmp:
        stub = pathlib.Path(tmp) / "gh"
        stub.write_text(
            "#!/bin/sh\n"
            # Answer ONLY the call the subject makes. Anything else exits 3, so
            # a subject that starts asking gh something new fails loudly here
            # rather than silently getting an issue list as the answer.
            'case "$*" in\n'
            "  *'issue list'*) cat <<'JSON'\n" + payload + "\nJSON\n"
            "    ;;\n"
            "  *'auth status'*) exit 0 ;;\n"
            "  *) echo \"stub: unexpected gh call: $*\" >&2; exit 3 ;;\n"
            "esac\n",
            encoding="utf-8")
        stub.chmod(0o755)
        env = dict(os.environ, PATH=f"{tmp}:{os.environ.get('PATH','')}",
                   PYTHONDONTWRITEBYTECODE="1")
        p = subprocess.run([sys.executable, str(SUBJECT)], capture_output=True,
                           text=True, env=env, cwd=str(REPO), timeout=120)
        return p.returncode, p.stdout + p.stderr


def main():
    name, ids = registered_issue_numbers()
    print(f"== a CI alarm is not a register gap ==")
    print(f"  manifest under test : {name}, {len(ids)} registered issue(s)")

    base = [(i, []) for i in ids]

    # ARM 1. The alarm alone. This is the exact live shape on 2026-09-06.
    rc, out = run_with_stub(base + [(1713, ["main-red"])])
    if rc == 0 and "excluded as CI alarms" in out:
        ok("an open `main-red` alarm is excluded and the register PASSES (rc 0)")
    else:
        bad(f"the alarm shape did not pass: rc={rc}. This arm also validates the "
            f"stub, so every arm below is unsafe until it is green.\n{out[-900:]}")
        print(f"\n== {PASS} pass / {FAIL} fail / {PASS+FAIL} total ==")
        return 1

    # ARM 2. CONTROL THAT MUST FAIL. An ordinary unregistered issue.
    unused = max(ids) + 100000
    rc, out = run_with_stub(base + [(unused, [])])
    if rc == 1 and str(unused) in out:
        ok(f"CONTROL THAT MUST FAIL: an unlabelled open issue is still required "
           f"(rc 1, names #{unused})")
    else:
        bad(f"an unlabelled unregistered issue did NOT fail the gate: rc={rc}. "
            f"The exclusion is wider than the alarm.\n{out[-700:]}")

    # ARM 3. CONTROL THAT MUST FAIL. A different label must not be a pass.
    rc, out = run_with_stub(base + [(unused, ["bug", "cut-blocker"])])
    if rc == 1 and str(unused) in out:
        ok("CONTROL THAT MUST FAIL: a DIFFERENTLY-labelled issue is still required, "
           "so the exclusion keys on the alarm label and not on merely having one")
    else:
        bad(f"an issue with unrelated labels was excluded: rc={rc}. The predicate is "
            f"'has labels', not 'is an alarm'.\n{out[-700:]}")

    # ARM 4. Every open issue is an alarm. Not a clean sheet -- a misused label.
    rc, out = run_with_stub([(1713, ["main-red"]), (1714, ["main-red"])])
    if rc == 2 and "CANNOT-RUN" in out:
        ok("a repository whose every open issue wears the alarm label is CANNOT-RUN "
           "(rc 2), not an empty backlog")
    else:
        bad(f"all-alarms did not refuse: rc={rc}, wanted 2.\n{out[-700:]}")

    # ARM 5. CONTROL. The alarm must not paper over a REAL gap sitting beside it.
    rc, out = run_with_stub(base + [(1713, ["main-red"]), (unused, [])])
    if rc == 1 and str(unused) in out and "1713" not in out.split("not in the checklist")[-1][:40]:
        ok("CONTROL: an alarm and a real gap TOGETHER still fail, and the failure "
           "names the real gap rather than the alarm")
    else:
        bad(f"alarm + real gap did not fail correctly: rc={rc}\n{out[-700:]}")

    # ARM 6. THE PREFIX THAT MADE PROPERTY 2 BLIND FOR ITS ENTIRE LIFE.
    # Every real row writes its status as `gate: 'GATE: NONE YET. ...'`. The
    # detector in the gate was startswith("NONE"), which matches none of them.
    # Measured on v1.0.99 the day it was found: 112 rows said NONE YET and the
    # gate counted 0, while printing a PASS saying every issue was gated.
    # PROPERTY 2 is the check that BLOCKS A CUT, so a cut could be tagged with
    # every row unproven. This arm asserts the detector sees the spelling the
    # manifests ACTUALLY USE, and still lets a genuinely gated row through.
    import importlib.util as _ilu
    _f = pathlib.Path(__file__).with_name("test_the_cut_checklist_is_complete.py")
    _spec = _ilu.spec_from_file_location("_cutchk", _f)
    _m = _ilu.module_from_spec(_spec); _spec.loader.exec_module(_m)
    _seen = getattr(_m, "_is_ungated", None)
    if _seen is None:
        bad("the cut checklist gate exposes no _is_ungated predicate to test; "
            "PROPERTY 2 cannot be verified from here")
    else:
        _catch = ["GATE: NONE YET. Triage pending.", "NONE YET",
                  "  gate: none yet, lowercase and padded"]
        _pass  = ["GATED by entry probe-doctor-page-renders-for-a-customer.",
                  "DEFERRED to v1.0.1 by Andy 2026-09-10, reason written in full here."]
        _missed = [g[:44] for g in _catch if not _seen({"gate": g})]
        _false  = [g[:44] for g in _pass  if _seen({"gate": g})]
        if not _missed and not _false:
            ok(f"the ungated detector sees the spelling manifests actually use "
               f"({len(_catch)} caught, including the `GATE: ` prefix that hid 112 "
               f"rows) and does not flag a gated row ({len(_pass)} controls)")
        else:
            bad(f"ungated detector is wrong. MISSED, so they read as gated: "
                f"{_missed}. FALSE POSITIVES, a gated row flagged: {_false}")

    print(f"\n== {PASS} pass / {FAIL} fail / {PASS+FAIL} total ==")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
