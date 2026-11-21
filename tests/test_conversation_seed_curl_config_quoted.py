#!/usr/bin/env python3
"""conversation_seed.sh passes the store credential to curl as ONE quoted word, in
zsh and in sh.

The old line `K="-K $CONF"` then `curl $K ...` relies on word splitting. zsh does
not split an unquoted expansion, so curl got "-K /path" as one argument, exited 26,
and the cleanup deletes failed silently (residue on Mini16, the real-data box).

Tests (both shells, a fake curl that exits 26 on a joined "-K <path>" argument):
  - the new form `curl -K "$CONF" ...` passes under zsh and under sh
  - control: the old `K="-K $CONF"; curl $K` form FAILS under zsh (proves the fake bites)
  - static: conversation_seed.sh has no unquoted `\\$K ` curl argument left
Exit 0 pass, 1 fail.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib", "conversation_seed.sh")

FAKE_CURL = '''#!/bin/sh
case "$1" in
  "-K "*) exit 26 ;;
esac
exit 0
'''


def run(shell, body, workdir):
    with open(os.path.join(workdir, "curl"), "w") as fh:
        fh.write(FAKE_CURL)
    os.chmod(os.path.join(workdir, "curl"), 0o755)
    env = {"PATH": workdir + ":/usr/bin:/bin", "HOME": workdir, "CONF": os.path.join(workdir, "store-curl.conf")}
    open(env["CONF"], "w").close()
    out = subprocess.run([shell, "-c", body], env=env, capture_output=True, text=True)
    return out.returncode


NEW = 'curl -K "$CONF" -sS http://x/'
OLD = 'K="-K $CONF"; curl $K -sS http://x/'


def main():
    bad = forget_cases() + marker_cases()
    with tempfile.TemporaryDirectory() as d:
        for shell in ("zsh", "sh"):
            if run(shell, NEW, d) != 0:
                bad.append("new form must pass under %s" % shell)
        control_rc = run("zsh", OLD, d)
        if control_rc != 26:
            bad.append("CONTROL: the old unquoted form should fail under zsh with rc 26, got %s" % control_rc)
    with open(LIB, encoding="utf-8") as fh:
        src = fh.read()
    live = [l for l in src.splitlines() if not l.lstrip().startswith("#") and "\\$K " in l]
    if live:
        bad.append("unquoted \\$K curl argument left in conversation_seed.sh: %d line(s)" % len(live))
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: the credential is one quoted word under zsh and sh; the old form fails under zsh; no unquoted \\$K left")
    return 0


# ---------------------------------------------------------------------------
# Forget cleanup: a FAKE box exec (OSTLER_CONVO_SEED_LOCAL_SH) returns canned output and saves the
# script body it was given. Host-side logic is judged on the output; the box script body itself
# is checked for shell syntax under sh and zsh (a syntax error here shipped once, unseen).
# A FAILED cleanup prints "ERROR: CLEANUP FAILED" and the forget still exits 0 (the walk-record
# contract: a tidy-up never fails a walk). The ERROR line is what the walk reports.
# ---------------------------------------------------------------------------

FAKE_BOX = """#!/bin/sh
# fake box_exec: saves the script body it was given, prints canned output for FAKE_MODE, exits FAKE_RC
printf '%s' "$2" > "$FAKE_BODY_OUT"
printf '%s\n<<CALL>>\n' "$2" >> "$FAKE_LOG"
case "$2" in
  *"test -f"*"conversation-seed-residue"*) echo "${FAKE_MARKER:-RESIDUE_MARKER_ABSENT}"; exit 0 ;;
  *"conversation_id="*"conversation-seed-residue"*) echo RESIDUE_MARKER_WRITTEN; exit 0 ;;
esac
case "$FAKE_MODE" in
  ok)        printf 'RESIDUE_QDRANT 0\nRESIDUE_GRAPH 0\nCOACH_ROW removed 1\n' ;;
  qdrant2)   printf 'RESIDUE_QDRANT 2\nRESIDUE_GRAPH 0\nCOACH_ROW removed 1\n' ;;
  graph3)    printf 'RESIDUE_QDRANT 0\nRESIDUE_GRAPH 3\nCOACH_ROW removed 1\n' ;;
  coachcan)  printf 'RESIDUE_QDRANT 0\nRESIDUE_GRAPH 0\nCOACH_ROW CANNOT-RUN: encrypted\n' ;;
  coachleft) printf 'RESIDUE_QDRANT 0\nRESIDUE_GRAPH 0\nCOACH_ROW left: the delete did not remove the row (after=1)\n' ;;
  empty)     : ;;
  *)         printf 'RESIDUE_QDRANT 0\nRESIDUE_GRAPH 0\n' ;;
esac
exit "${FAKE_RC:-0}"
"""

DRIVER_HEAD = """set -u
. "$LIB"
CONVERSATION_SEED_STATE=seeded
CONVERSATION_SEED_ID=ostler-walk-conv-test
CONVERSATION_SEED_SHORTID=abcd1234
CONVERSATION_SEED_USER_ID=walk-test
_CS_STORE_CONF_PATH=/nonexistent/store-curl.conf
_CS_CURL=/usr/bin/false
_CS_QDRANT=http://127.0.0.1:6333
_CS_OXIGRAPH=http://127.0.0.1:7878/query
OSTLER_CONVO_SEED_KEEP=0
"""


def forget(mode, rc=0, lib=None, sequence=None):
    """Run the real conversation_seed_forget against the fake box exec.
    Returns (list of exit codes, combined output, saved box script body)."""
    d = tempfile.mkdtemp(prefix="cs-forget-")
    fake = os.path.join(d, "fakebox")
    body_out = os.path.join(d, "body.sh")
    log = os.path.join(d, "calls.log")
    with open(fake, "w") as fh:
        fh.write(FAKE_BOX)
    os.chmod(fake, 0o755)
    if sequence:
        calls = "".join('FAKE_MODE=%s FAKE_RC=%s conversation_seed_forget; echo "RC=$?"\n' % (m, r)
                        for m, r in sequence)
        script = DRIVER_HEAD + calls
    else:
        script = DRIVER_HEAD + 'conversation_seed_forget\necho "RC=$?"\n'
    drv = os.path.join(d, "driver.sh")
    with open(drv, "w") as fh:
        fh.write(script)
    env = {"PATH": "/usr/bin:/bin", "HOME": d, "LIB": lib or LIB, "FAKE_MODE": mode, "FAKE_RC": str(rc),
           "FAKE_BODY_OUT": body_out, "FAKE_LOG": log, "OSTLER_CONVO_SEED_LOCAL_SH": fake}
    out = subprocess.run(["bash", drv], env=env, capture_output=True, text=True)
    rcs = [int(x.split("=")[1]) for x in out.stdout.split() if x.startswith("RC=")]
    body = open(body_out, encoding="utf-8").read() if os.path.exists(body_out) else ""
    FORGET_CALLS[0] = open(log, encoding="utf-8").read() if os.path.exists(log) else ""
    return (rcs or [-1]), out.stdout + out.stderr, body


FORGET_CALLS = [""]


def apply_refusal(marker):
    """Run the real conversation_seed_apply with the fake box answering the marker check. Returns
    (rc, state, number of box calls made)."""
    d = tempfile.mkdtemp(prefix="cs-apply-")
    fake = os.path.join(d, "fakebox")
    with open(fake, "w") as fh:
        fh.write(FAKE_BOX)
    os.chmod(fake, 0o755)
    log = os.path.join(d, "calls.log")
    drv = os.path.join(d, "driver.sh")
    with open(drv, "w") as fh:
        fh.write('set -u\n. "$LIB"\nconversation_seed_apply\necho "RC=$?"\necho "STATE=$CONVERSATION_SEED_STATE"\n')
    env = {"PATH": "/usr/bin:/bin", "HOME": d, "LIB": LIB, "FAKE_MODE": "empty", "FAKE_RC": "0",
           "FAKE_MARKER": marker, "FAKE_BODY_OUT": os.path.join(d, "body.sh"), "FAKE_LOG": log,
           "OSTLER_CONVO_SEED_LOCAL_SH": fake}
    out = subprocess.run(["bash", drv], env=env, capture_output=True, text=True)
    rc = [int(x.split("=")[1]) for x in out.stdout.split() if x.startswith("RC=")]
    st = [x.split("=", 1)[1] for x in out.stdout.split() if x.startswith("STATE=")]
    calls = open(log, encoding="utf-8").read().count("<<CALL>>") if os.path.exists(log) else 0
    return (rc[0] if rc else -1), (st[0] if st else ""), calls


def marker_cases():
    """Option (b): a failed forget leaves a marker, the next seed is refused, a clean forget clears it."""
    bad = []
    _rcs, out, _b = forget("qdrant2")
    if "conversation-seed-residue.json" not in FORGET_CALLS[0] or "RESIDUE_MARKER_WRITTEN" not in FORGET_CALLS[0]:
        bad.append("a failed forget must write the residue marker on the box")
    if "RESIDUE MARKER written" not in out:
        bad.append("a failed forget must say the marker was written")
    _rcs, out, _b = forget("ok")
    if "RESIDUE_MARKER_CLEARED" not in FORGET_CALLS[0] or "rm -f" not in FORGET_CALLS[0]:
        bad.append("a verified clean forget must clear the marker")
    rc, state, calls = apply_refusal("RESIDUE_MARKER_PRESENT")
    if rc != 1 or state != "refused" or calls != 1:
        bad.append("with the marker present the seed must refuse at once (rc %s, state %s, box calls %s)"
                   % (rc, state, calls))
    rc, state, calls = apply_refusal("RESIDUE_MARKER_ABSENT")
    if calls <= 1:
        bad.append("CONTROL: with no marker the seed must go on past the marker check (box calls %s)" % calls)
    return bad


def forget_cases():
    bad = []
    rcs, out, body = forget("ok")
    if rcs != [0] or "ERROR: CLEANUP FAILED" in out:
        bad.append("a clean cleanup must exit 0 with no ERROR, got %s" % rcs)
    # the box script body must be valid shell under sh AND zsh (it runs under zsh over ssh)
    for shell in ("sh", "zsh"):
        r = subprocess.run([shell, "-n", "-c", body], capture_output=True, text=True)
        if r.returncode != 0:
            bad.append("the box script does not parse under %s: %s" % (shell, r.stderr.strip()[:160]))
    cases = [
        ("ok", 255, "item 1: a box exec that exits non-zero is CLEANUP FAILED"),
        ("empty", 0, "item 1: empty box output is CLEANUP FAILED, never done"),
        ("qdrant2", 0, "item 2: Qdrant residue 2 is CLEANUP FAILED even when every delete exited 0"),
        ("graph3", 0, "item 2: graph residue 3 is CLEANUP FAILED even when every delete exited 0"),
        ("coachcan", 0, "item 3: a COACH_ROW CANNOT-RUN is CLEANUP FAILED, loud"),
        ("coachleft", 0, "item 3: a COACH_ROW left after the delete is CLEANUP FAILED"),
    ]
    for mode, rc, label in cases:
        rcs, out, _b = forget(mode, rc=rc)
        if "ERROR: CLEANUP FAILED" not in out:
            bad.append(label + " (no ERROR line printed)")
        if rcs != [0]:
            bad.append("the walk must not fail on a tidy-up: %s exit %s" % (mode, rcs))
    # item 4: the flag resets per forget. A failed forget, then a clean one in one shell: the clean one is clean.
    rcs, out, _b = forget("ok", sequence=[("qdrant2", 0), ("ok", 0)])
    if out.count("CLEANUP STATUS: FAILED") != 1 or out.count("CLEANUP STATUS: verified") != 1:
        bad.append("item 4: the failure must not leak into the next forget (statuses: %d failed, %d verified)"
                   % (out.count("CLEANUP STATUS: FAILED"), out.count("CLEANUP STATUS: verified")))
    # RED control: remove the residue check from a copy; qdrant2 must then print no ERROR.
    with open(LIB, encoding="utf-8") as fh:
        src = fh.read()
    def mutate(old_txt, new_txt):
        if src.count(old_txt) != 1:
            return None
        mdir = tempfile.mkdtemp(prefix="cs-mut-")
        mpath = os.path.join(mdir, "conversation_seed.sh")
        with open(mpath, "w", encoding="utf-8") as fh:
            fh.write(src.replace(old_txt, new_txt, 1))
        return mpath
    m2 = mutate('if [ "${_cs_qres}" != "0" ] || [ "${_cs_gres}" != "0" ]; then', 'if false; then')
    if m2 is None or "ERROR: CLEANUP FAILED" in forget("qdrant2", lib=m2)[1]:
        bad.append("CONTROL item 2: without the residue check, qdrant2 must print no ERROR")
    m1 = mutate('if [ "${_cs_frc}" -ne 0 ] || [ -z "$(printf', 'if false || [ -z "$(printf')
    if m1 is None or "ERROR: CLEANUP FAILED" in forget("ok", rc=255, lib=m1)[1]:
        bad.append("CONTROL item 1: without the exit-status check a failed box exec must print no ERROR")
    m3 = mutate('if printf \'%s\\n\' "${_cs_fout}" | grep -q', 'if false && printf \'%s\\n\' "${_cs_fout}" | grep -q')
    if m3 is None or "ERROR: CLEANUP FAILED" in forget("coachcan", lib=m3)[1]:
        bad.append("CONTROL item 3: without the COACH_ROW check a CANNOT-RUN must print no ERROR")
    m4 = mutate('    _cs_forget_failed=0\n', '')
    if m4 is None:
        bad.append("CONTROL item 4: the reset line was not found to mutate")
    else:
        _r, out4, _b = forget("ok", sequence=[("qdrant2", 0), ("ok", 0)], lib=m4)
        if out4.count("CLEANUP STATUS: FAILED") != 2:
            bad.append("CONTROL item 4: without the reset the clean forget should inherit the failure")
    # syntax RED control: a body with one fi removed must NOT parse (the shipped regression)
    broken = body.replace("\n  fi\nfi\n", "\nfi\n", 1)
    if broken != body:
        r = subprocess.run(["sh", "-n", "-c", broken], capture_output=True, text=True)
        if r.returncode == 0:
            bad.append("CONTROL syntax: a body with a missing fi must fail sh -n")
    return bad


if __name__ == "__main__":
    sys.exit(main())
