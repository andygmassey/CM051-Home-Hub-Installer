#!/usr/bin/env bash
# A gate that could not ask must not answer "the pin is stale".
#
# ============================================================================
# WHY, MEASURED. CM051 #1629.
# ============================================================================
# verify_cut_manifest.py has 6 handlers catching subprocess.TimeoutExpired.
# Two named CANNOT-RUN, two were fixed by #1626 and #1628, and two returned an
# EMPTY VALUE PLUS AN ERROR STRING:
#
#     _gh_api_json          -> (None, "gh api ... timed out after Ns")
#     _fetch_asset_content  -> (b"",  "asset N download timed out after Ns")
#
# Every one of the SEVEN call sites that consumes them does:
#
#     if err or not isinstance(x, dict):
#         return Result(..., "FAIL", f"...: {err or 'unexpected shape'}", ...)
#
# so a timeout, and `gh` not being installed at all, both rendered as a FAILED
# freshness check. THAT IS A GATE ASSERTING THE PIN IS STALE WHEN THE TRUTH IS
# THAT IT NEVER ASKED. It is the same family as everything else that has bitten
# this project: a check that could not answer, saying something other than
# "I could not answer".
#
# THE FIX IS TO RAISE, NOT TO RE-WORD. CouldNotMeasure is the established
# vocabulary here and both consuming check_ functions already catch it and
# render CANNOT-RUN. Verified by walking EVERY propagation chain to its
# terminating check_ function before changing a shared producer -- five
# intermediate helpers, all of which terminate in
# check_pinned_artefact_freshness or check_verify_build_info_sidecar_present.
#
# A NON-ZERO EXIT AND MALFORMED JSON ARE DELIBERATELY NOT RAISED. gh answered,
# and its answer is a fact about the repo. Only "could not ask" is CANNOT-RUN,
# and this test asserts that boundary in both directions.
#
# 0 pass  1 fail  2 cannot-run
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${1:-${HERE}/scripts/verify_cut_manifest.py}"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1" >&2; }
cant() { printf '  [CANNOT-RUN] %s\n' "$1" >&2; echo "== ${PASS} pass / ${FAIL} fail / 1 cannot-run =="; exit 2; }

[ -f "$SUBJECT" ] || cant "no verifier at ${SUBJECT}"
command -v python3 >/dev/null 2>&1 || cant "python3 unavailable"

# The driver imports the verifier, replaces subprocess.run with one that raises
# the chosen exception, and asks check_pinned_artefact_freshness for a verdict.
# Nothing touches the network and nothing binds a port.
_drive() { # _drive <file> <timeout|notfound|badexit> -> "STATUS|detail"
    python3 - "$1" "$2" "$HERE" <<'PYEOF'
import importlib.util, subprocess, sys, types
path, mode, repo = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("vcm_under_test", path)
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except Exception as e:
    print(f"IMPORT_FAILED|{type(e).__name__}: {e}"); raise SystemExit(0)

real_run = m.subprocess.run
def fake_run(*a, **k):
    if mode == "timeout":
        raise subprocess.TimeoutExpired(cmd=a[0] if a else "gh", timeout=1)
    if mode == "notfound":
        raise FileNotFoundError(2, "No such file or directory: 'gh'")
    if mode == "badexit":
        # gh ANSWERED. Not a cannot-run: a real fact about the repo.
        return types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"HTTP 404: Not Found")
    return real_run(*a, **k)
m.subprocess.run = fake_run
# STUB THE TOKEN LOOKUP. Without this the fake above also intercepts
# `gh auth token`, no credential resolves, and the check returns SKIP ("this
# row was not evaluated") before it ever reaches an API call -- so the arm
# would be measuring my harness rather than the handler under test. Measured:
# two arms returned SKIP for exactly that reason before this line existed.
m._gh_token_for = lambda owner: "stub-token-not-a-real-credential"

# DRIVE THE REAL MANIFEST ENTRY, NOT AN INVENTED ONE. My first version wrote
# its own proof block with pattern "DAEMON_VERSION" -- no capture group -- so
# check_pinned_artefact_freshness returned FAIL at version resolution and never
# reached a gh call at all. Both arms went red and both were measuring my
# fixture, which is a false positive dressed as a finding. Reading the shipped
# entry removes a whole class of fixture drift: if the real proof block changes
# shape, this test follows it.
import yaml, os
_man = os.path.join(repo, "cut-manifests", "permanent.yaml")
_doc = yaml.safe_load(open(_man, encoding="utf-8"))
_rows = _doc.get("entries") or next(v for v in _doc.values() if isinstance(v, list))
entry = next((r for r in _rows if r.get("id") == "permanent-daemon-freshness"), None)
if entry is None:
    print("FIXTURE_MISSING|permanent-daemon-freshness is not in permanent.yaml")
    raise SystemExit(0)
# The hold_ack would let a stale pin pass; strip it so the arms measure the
# TIMEOUT path and not an exemption.
entry = dict(entry); entry["proof"] = dict(entry["proof"]); entry["proof"].pop("hold_ack", None)

try:
    from pathlib import Path
    # DRIVE check_entry, NOT the check function. check_entry is the single
    # dispatch site and it is where the status is decided -- it catches and
    # converts. Calling check_pinned_artefact_freshness directly bypasses it,
    # which is how my first run saw an "uncaught" raise that production would
    # never see. Answer from the decider.
    r = m.check_entry(entry, {"cm051_dir": Path(".")})
    print(f"{r.status}|{str(r.detail)[:160]}")
except m.CouldNotMeasure as e:
    print(f"UNCAUGHT_CouldNotMeasure|{e}")
except Exception as e:
    print(f"RAISED_{type(e).__name__}|{e}")
PYEOF
}

echo "── subject: ${SUBJECT} ──"

for mode in timeout notfound; do
    out="$(_drive "$SUBJECT" "$mode")"
    st="${out%%|*}"
    case "$st" in
        IMPORT_FAILED)          cant "the verifier could not be imported: ${out#*|}" ;;
        FIXTURE_MISSING)        cant "${out#*|} -- refusing to invent a proof block; that is how the first version of this test measured nothing" ;;
        CANNOT-RUN)             ok "a ${mode} yields CANNOT-RUN, not a verdict about the pin" ;;
        UNCAUGHT_*)             bad "a ${mode} raised out of check_entry, the dispatch site. Nothing above it converts to a verdict: ${out#*|}" ;;
        FAIL)                   bad "a ${mode} still reports FAIL -- the gate asserts the pin is stale when it never asked. ${out#*|}" ;;
        PASS)                   bad "a ${mode} reports PASS. A check that could not run must never be a pass. ${out#*|}" ;;
        *)                      bad "a ${mode} produced '${st}', which is neither a verdict nor CANNOT-RUN: ${out#*|}" ;;
    esac
done

# ── THE BOUNDARY, IN THE OTHER DIRECTION. gh ANSWERING BADLY IS AN ANSWER. ──
# Without this arm the "fix" could be `raise on everything`, which would turn
# every genuine 404 into CANNOT-RUN and make the gate incapable of ever failing.
out="$(_drive "$SUBJECT" badexit)"
st="${out%%|*}"
# WHAT THIS CONTROL IS FOR: the fix must NARROW, not disable. If "raise on
# everything" had been the fix, every genuine 404 would become CANNOT-RUN and
# the gate could never fail again.
#
# SKIP is the CORRECT answer here and my first assertion demanded FAIL, which
# was wrong about the subject rather than a finding. `_repo_is_readable` treats
# the 404/403 shape as "cannot see this repo" and returns SKIP with a written
# reason -- deliberate, and the call site says NARROW ON PURPOSE. Both SKIP and
# FAIL are dispositions reached BECAUSE gh answered. Only CANNOT-RUN (the fix
# over-reaching) and PASS (a vacuous green) are wrong.
case "$st" in
    CANNOT-RUN) bad "CONTROL: a non-zero gh exit (gh ANSWERED, 404) became CANNOT-RUN. The fix over-reached: the gate can no longer dispose of a real answer." ;;
    PASS)       bad "CONTROL: a non-zero gh exit reports PASS -- a vacuous green on an answer the gate did receive" ;;
    SKIP|FAIL)  ok "CONTROL: a non-zero gh exit is ${st}, a real disposition -- gh answered, and the fix did not swallow it" ;;
    *)          bad "CONTROL: a non-zero gh exit produced '${st}': ${out#*|}" ;;
esac

# ── NEGATIVE CONTROL: the pre-fix blob must FAIL the two arms above. ────────
echo "── negative control: the pre-fix blob ──"
CTL="$(mktemp).py"; trap 'rm -f "$CTL"' EXIT
if ! git -C "$HERE" show "${OSTLER_PREFIX_REF:-origin/main}:scripts/verify_cut_manifest.py" > "$CTL" 2>/dev/null; then
    cant "could not read the pre-fix verifier blob; a control that scanned nothing is not a pass"
fi
# DISCRIMINATE ON A PHRASE UNIQUE TO THIS CHANGE. My first guard matched
# "exceeded its .* cap and was killed", which is ALSO the wording of TNM's
# already-merged #1626 fix in _grep_binary_strings -- so it fired on every
# tree and declared the control useless. A control predicate has to be keyed
# on the thing that is actually new.
if grep -q 'so no API call was made' "$CTL"; then
    cant "the 'pre-fix' blob ALREADY carries this change, so it cannot discriminate. Re-point OSTLER_PREFIX_REF."
fi
octl="$(_drive "$CTL" timeout)"
case "${octl%%|*}" in
    FAIL)       ok "CONTROL: the pre-fix tree reports FAIL on a timeout -- the defect reproduces" ;;
    CANNOT-RUN) bad "the pre-fix tree already says CANNOT-RUN, so this harness is not measuring the change" ;;
    *)          bad "the pre-fix tree produced '${octl%%|*}': ${octl#*|}" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / 0 cannot-run =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
