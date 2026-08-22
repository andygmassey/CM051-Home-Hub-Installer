#!/bin/bash
# #595 layer 2 -- A DYING SCHEDULED AGENT MUST BE LOUD.
#
# THE DEFECT. On .228 (published v1.0.38) com.ostler.fda-rerun -- the only
# recurring ingest for contacts, calendar, iMessage, WhatsApp, browsing and
# notes -- exited 1 on every hourly tick for days. The graph froze. NOTHING
# surfaced it. The product went on saying "still loading in the background".
#
# Layer 1 (#945) stops the runtime going missing. This layer asserts that if a
# scheduled agent dies anyway, for any reason, a human is told.
#
# WHAT THIS ASSERTS, AND WHAT IT DELIBERATELY DOES NOT.
#
# It asserts the VERDICT of the state machine and the SEVERITY of the finding
# -- `agent_state`, `severity`, and whether a finding exists at all. It never
# greps the customer copy. Copy lives in diagnostic_copy.py and gets reworded;
# a test pinned to a sentence goes green-while-blind the day someone improves
# it, and red-while-correct the day someone fixes a typo.
#
# THE THREE STATES THAT MUST NOT CONFLATE (#810). "Never ran" and "ran and
# succeeded" must not print the same. The gate that inherited that conflation
# wrote `${ec:-0}`, turning an unloaded label's empty string into a clean
# exit 0, and went GREEN on a box where the bundle was not installed at all.
#
# EXIT CODES
#   0  every control passed
#   1  at least one control failed
#   2  CANNOT-RUN. Nothing was checked, which is not a pass.
#
# --self-test  reinstate the defect in a copy of the module and require the
#              matching controls to go RED. A control that has never been
#              observed failing is not evidence that it can fail.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_DIR="${REPO}/vendor/doctor/agent"
RULES="${AGENT_DIR}/diagnostic_rules.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
cannot_run() { printf '\nCANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[[ -f "$RULES" ]] || cannot_run "no diagnostic_rules.py at ${RULES}"
command -v python3 >/dev/null 2>&1 || cannot_run "no python3"

# PREFLIGHT: if the module will not import, NOTHING can be measured, and that
# is CANNOT-RUN -- not a wall of failures that read exactly like real defects.
#
# This is not hypothetical. The first CI run of this gate was on a runner
# without httpx (status_collector imports it at module scope, and there is no
# doctor venv on a runner). Every limb printed `FAIL ... state=<> raw=<>`,
# sixteen of them, which is indistinguishable at a glance from the rule being
# genuinely broken. A test whose "could not look" and "looked and it is
# broken" print the same is the very defect this gate exists to attack, so it
# does not get to commit it itself.
_import_err="$(python3 -c "import sys; sys.path.insert(0,'${AGENT_DIR}'); import diagnostic_rules" 2>&1)" \
    || cannot_run "diagnostic_rules could not be imported, so nothing was measured: ${_import_err}"

SELF_TEST=0
[[ "${1:-}" == "--self-test" ]] && SELF_TEST=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# The driver. Imports the REAL rule module and drives one label through the
# state machine with an injected observation, so every branch is reachable
# without needing a real failing launchd job. State dir is redirected per
# call so streaks are deterministic.
# ---------------------------------------------------------------------------
DRIVER="${TMP}/drive.py"
cat > "$DRIVER" <<'DRIVEREOF'
import json, os, sys
sys.path.insert(0, os.environ["AGENT_DIR"])
import diagnostic_rules as d

mode = sys.argv[1]

if mode == "observe":
    # argv: observe <label> <json-observation> [<json-observation> ...]
    # Replays observations in order against one persisted streak.
    label = sys.argv[2]
    out = []
    for raw in sys.argv[3:]:
        out.append(d._scheduled_agent_observe(label, obs=json.loads(raw)))
    print(json.dumps(out))

elif mode == "parse":
    # argv: parse <rc> <path-to-launchctl-output>
    rc = int(sys.argv[2])
    text = open(sys.argv[3]).read() if sys.argv[3] != "-" else ""
    print(json.dumps(d._parse_launchd_job(rc, text)))

elif mode == "rule":
    # Run the whole rule with a stubbed observer, so we exercise the real
    # finding-construction path (copy formatting, severity, dedupe).
    forced = json.loads(sys.argv[2])
    real = d._scheduled_agent_observe
    def fake(label, now=None, obs=None):
        return real(label, now=now, obs=forced.get(label, {"state": "healthy",
                                                          "runs": 5,
                                                          "last_exit": 0}))
    d._scheduled_agent_observe = fake
    print(json.dumps(d.check_scheduled_agents(None)))

elif mode == "registered":
    print(json.dumps([f.__name__ for f in d.ALL_RULES]))

elif mode == "real":
    # No stub at all: ask the actual launchd on this machine.
    print(json.dumps(d._parse_launchd_job(*d._launchctl_print(sys.argv[2]))))
DRIVEREOF

export AGENT_DIR
run() { OSTLER_STATE_DIR="$(mktemp -d "${TMP}/st.XXXXXX")" python3 "$DRIVER" "$@"; }

jqf() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1],{"d":d}))' "$1"; }

echo "== 1. PREMISE / ANTI-VACUITY: the fixture must actually reproduce the defect =="
# If this limb does not go 'failing', every other failing-limb below is vacuous
# -- they would be asserting against a fixture that never reproduced anything.
out="$(run observe com.ostler.fda-rerun '{"state":"failing","runs":10,"last_exit":1}')"
st="$(printf '%s' "$out" | jqf 'd[0]["state"]')"
if [[ "$st" == "failing" ]]; then
    ok "a non-zero last exit code is scored FAILING (fixture reproduces the defect)"
else
    bad "fixture did NOT reproduce the defect: state=<${st}> raw=<${out}>"
fi

echo "== 2. CONTROL that MUST be non-zero: a healthy agent is scored HEALTHY =="
# The control for limb 1. If everything scored 'failing', limb 1 would pass
# while proving nothing. These two must DIFFER.
out2="$(run observe com.ostler.fda-rerun '{"state":"healthy","runs":10,"last_exit":0}')"
st2="$(printf '%s' "$out2" | jqf 'd[0]["state"]')"
if [[ "$st2" == "healthy" && "$st2" != "$st" ]]; then
    ok "exit 0 is scored HEALTHY, and differs from the failing verdict"
else
    bad "healthy/failing did not separate: healthy=<${st2}> failing=<${st}>"
fi

echo "== 3. THE #810 CONFLATION: never-ran must NOT read as ran-and-succeeded =="
# The never-ran side MUST be the overdue one. Comparing a just-installed
# never-ran against healthy compares two empty lists, and two zeros print
# identically -- the comparison would pass while proving nothing. (This limb
# was written the vacuous way first and this test caught it.)
SD0="$(mktemp -d "${TMP}/conflate.XXXXXX")"
mkdir -p "${SD0}/launchd_tick_posture"
cat > "${SD0}/launchd_tick_posture/com.ostler.fda-rerun.json" <<'CONFEOF'
{"label":"com.ostler.fda-rerun","state":"never_ran","runs":0,
 "first_observed_at":"2020-01-01T00:00:00+00:00","failing_since":null,
 "runs_at_failing_start":null,"failed_ticks":0}
CONFEOF
never="$(OSTLER_STATE_DIR="$SD0" python3 "$DRIVER" rule \
         '{"com.ostler.fda-rerun":{"state":"never_ran","runs":0}}')"
healthy="$(run rule '{"com.ostler.fda-rerun":{"state":"healthy","runs":9,"last_exit":0}}')"
# Anti-vacuity for the comparison itself: the never-ran side must be non-empty,
# or the two sides are equal for an uninteresting reason.
[[ "$(printf '%s' "$never" | jqf 'len(d)')" -ge 1 ]] \
    && ok "premise: the never-ran side actually produced a finding to compare" \
    || bad "never-ran side was empty -- limb 3's comparison would be vacuous"
n_states="$(printf '%s' "$never"   | jqf '[f["agent_state"] for f in d]')"
h_states="$(printf '%s' "$healthy" | jqf '[f["agent_state"] for f in d]')"
if [[ "$n_states" == "$h_states" ]]; then
    bad "never-ran and healthy produced IDENTICAL output ${n_states} -- this is #810"
else
    ok "never-ran and healthy produce different findings (${n_states} vs ${h_states})"
fi
# and specifically: healthy must be SILENT, never-ran must not be.
[[ "$h_states" == "[]" ]] && ok "a healthy agent emits NO card (silence is correct only here)" \
                          || bad "healthy emitted a card: ${h_states}"

echo "== 4. NEVER-RAN only fires once genuinely overdue, and then it DOES fire =="
# Two limbs so a rule that never fires cannot pass this section by being shy.
fresh="$(run rule '{"com.ostler.fda-rerun":{"state":"never_ran","runs":0}}')"
[[ "$(printf '%s' "$fresh" | jqf 'len(d)')" == "0" ]] \
    && ok "a just-installed agent with runs=0 does NOT cry wolf" \
    || bad "runs=0 fired immediately after install: ${fresh}"

# Now age the observation past 2x its interval by pre-seeding the state file.
SD="$(mktemp -d "${TMP}/aged.XXXXXX")"
mkdir -p "${SD}/launchd_tick_posture"
cat > "${SD}/launchd_tick_posture/com.ostler.fda-rerun.json" <<'AGEDEOF'
{"label":"com.ostler.fda-rerun","state":"never_ran","runs":0,
 "first_observed_at":"2020-01-01T00:00:00+00:00","failing_since":null,
 "runs_at_failing_start":null,"failed_ticks":0}
AGEDEOF
aged="$(OSTLER_STATE_DIR="$SD" python3 "$DRIVER" rule \
        '{"com.ostler.fda-rerun":{"state":"never_ran","runs":0}}')"
a_states="$(printf '%s' "$aged" | jqf '[f["agent_state"] for f in d]')"
if [[ "$a_states" == "['never_ran']" ]]; then
    ok "an agent that has never run two full windows later DOES raise a card"
else
    bad "overdue never-ran did not raise: ${a_states} raw=${aged}"
fi

echo "== 5. N CONSECUTIVE FAILURES accumulate, and any success RESETS the streak =="
# The whole point: one bad tick is a warning, a streak is critical.
streak="$(run observe com.ostler.fda-rerun \
    '{"state":"failing","runs":1,"last_exit":1}' \
    '{"state":"failing","runs":2,"last_exit":1}' \
    '{"state":"failing","runs":3,"last_exit":1}')"
ticks="$(printf '%s' "$streak" | jqf 'd[-1]["failed_ticks"]')"
[[ "$ticks" == "3" ]] && ok "three failed ticks accumulate to failed_ticks=3" \
                      || bad "expected failed_ticks=3, got <${ticks}>"

reset="$(run observe com.ostler.fda-rerun \
    '{"state":"failing","runs":1,"last_exit":1}' \
    '{"state":"failing","runs":2,"last_exit":1}' \
    '{"state":"healthy","runs":3,"last_exit":0}' \
    '{"state":"failing","runs":4,"last_exit":1}')"
rticks="$(printf '%s' "$reset" | jqf 'd[-1]["failed_ticks"]')"
[[ "$rticks" == "1" ]] && ok "a successful tick resets the streak (back to 1, not 4)" \
                       || bad "streak did not reset after success: <${rticks}>"

echo "== 6. SEVERITY escalates with the streak =="
one="$(run rule '{"com.ostler.fda-rerun":{"state":"failing","runs":1,"last_exit":1}}')"
sev1="$(printf '%s' "$one" | jqf 'd[0]["severity"]')"
[[ "$sev1" == "warning" ]] && ok "a single failed tick is a warning, not a klaxon" \
                           || bad "one failed tick severity=<${sev1}>, expected warning"

SD2="$(mktemp -d "${TMP}/streak.XXXXXX")"
mkdir -p "${SD2}/launchd_tick_posture"
cat > "${SD2}/launchd_tick_posture/com.ostler.fda-rerun.json" <<'STREAKEOF'
{"label":"com.ostler.fda-rerun","state":"failing","runs":40,"last_exit":1,
 "first_observed_at":"2020-01-01T00:00:00+00:00",
 "failing_since":"2020-01-01T00:00:00+00:00",
 "runs_at_failing_start":1,"failed_ticks":40}
STREAKEOF
many="$(OSTLER_STATE_DIR="$SD2" python3 "$DRIVER" rule \
        '{"com.ostler.fda-rerun":{"state":"failing","runs":41,"last_exit":1}}')"
sevN="$(printf '%s' "$many" | jqf 'd[0]["severity"]')"
tickN="$(printf '%s' "$many" | jqf 'd[0]["agent_failed_ticks"]')"
[[ "$sevN" == "critical" ]] && ok "a sustained streak is CRITICAL (${tickN} ticks)" \
                            || bad "sustained streak severity=<${sevN}>, expected critical"

echo "== 7. AN UNLOADED AGENT IS NOT A HEALTHY ONE =="
gone="$(run rule '{"com.ostler.fda-rerun":{"state":"not_loaded","why":"exit 113"}}')"
g_state="$(printf '%s' "$gone" | jqf 'd[0]["agent_state"]')"
g_sev="$(printf '%s' "$gone" | jqf 'd[0]["severity"]')"
if [[ "$g_state" == "not_loaded" && "$g_sev" == "critical" ]]; then
    ok "a job launchd has no record of is a CRITICAL card, not silence"
else
    bad "unloaded agent gave state=<${g_state}> severity=<${g_sev}>"
fi

echo "== 8. CANNOT-RUN is its own state -- 'we could not look' != 'it was fine' =="
unk="$(run rule '{"com.ostler.fda-rerun":{"state":"unknown","why":"launchctl unavailable"}}')"
u_state="$(printf '%s' "$unk" | jqf 'd[0]["agent_state"]')"
[[ "$u_state" == "unknown" ]] && ok "an unreadable answer raises a card rather than passing" \
                              || bad "unknown state was swallowed: <${u_state}>"

echo "== 9. NO LOSSY DEFAULT: a missing exit code must never become 0 =="
# This is the literal `${ec:-0}` defect, asserted at the predicate.
printf 'runs = 12\nstate = not running\n' > "${TMP}/noexit.txt"
noexit="$(run parse 0 "${TMP}/noexit.txt")"
ne="$(printf '%s' "$noexit" | jqf 'd["state"]')"
[[ "$ne" == "unknown" ]] && ok "runs>0 with no exit-code line -> unknown, NOT healthy" \
                         || bad "missing exit code was defaulted to <${ne}>"

echo "== 10. THE PARSER MATCHES REAL LAUNCHD, not just my own fixture =="
# A parser proved only against a fixture I wrote is a parser proved against my
# beliefs. This limb asks the real launchd on this machine, and requires a
# ragged answer: real jobs must land in MORE THAN ONE state. Uniform output
# would mean the predicate is broken, not that the machine is uniform.
if command -v launchctl >/dev/null 2>&1; then
    real_states="$(python3 - <<'REALEOF'
import json, os, subprocess, sys, tempfile
os.environ.setdefault("OSTLER_STATE_DIR", tempfile.mkdtemp())
sys.path.insert(0, os.environ["AGENT_DIR"])
import diagnostic_rules as d
seen = {}
lines = subprocess.run(["launchctl", "list"], capture_output=True,
                       text=True).stdout.splitlines()[1:]
for line in lines[:120]:
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    st = d._parse_launchd_job(*d._launchctl_print(parts[2]))["state"]
    seen[st] = seen.get(st, 0) + 1
print(json.dumps(seen))
REALEOF
)"
    n_kinds="$(printf '%s' "$real_states" | jqf 'len(d)')"
    n_total="$(printf '%s' "$real_states" | jqf 'sum(d.values())')"
    if [[ "${n_total:-0}" -eq 0 ]]; then
        bad "CONTROL FAILED: parsed zero real launchd jobs -- the predicate looked at nothing"
    elif [[ "${n_kinds:-0}" -ge 2 ]]; then
        ok "real launchd jobs land in ${n_kinds} distinct states across ${n_total} jobs: ${real_states}"
    else
        bad "uniform verdict over ${n_total} real jobs (${real_states}) -- broken predicate"
    fi
else
    printf '  skip launchd realism limb (no launchctl on this host)\n'
fi

echo "== 11. THE RULE IS REGISTERED -- an unwired rule is a dark rule =="
reg="$(run registered)"
# Herestring, NOT `printf | grep -q`. Under `set -o pipefail` a short-
# circuiting consumer can SIGPIPE the producer and invert the verdict, so a
# rule that IS registered could report as missing. The repo ratchets against
# this construct and caught these two lines on the first CI run.
if grep -q 'check_scheduled_agents' <<< "$reg"; then
    ok "check_scheduled_agents is in ALL_RULES"
else
    bad "rule exists but is NOT in ALL_RULES -- it would never run"
fi
# Control: the pattern must be able to find a rule that IS there, so a zero
# above cannot be a broken grep.
if grep -q 'check_hydrate_ingest' <<< "$reg"; then
    ok "control: the same predicate finds a pre-existing rule"
else
    bad "control failed -- could not find check_hydrate_ingest either"
fi

echo "== 12. The module still imports and compiles =="
python3 -c "import sys; sys.path.insert(0,'${AGENT_DIR}'); import diagnostic_rules" 2>/dev/null \
    && ok "diagnostic_rules imports cleanly" || bad "diagnostic_rules failed to import"
python3 -m py_compile "${AGENT_DIR}/diagnostic_copy.py" 2>/dev/null \
    && ok "diagnostic_copy compiles" || bad "diagnostic_copy failed to compile"

# ---------------------------------------------------------------------------
# SELF-TEST. Reinstate each half of the defect in a COPY of the module and
# require the matching control to go RED.
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" == "1" ]]; then
    echo
    echo "== SELF-TEST: the controls must go RED when the defect is reinstated =="
    MUT="${TMP}/mutant"
    mkdir -p "$MUT"
    cp "${AGENT_DIR}"/*.py "$MUT"/ 2>/dev/null

    # MUTANT A: the #810 conflation -- treat a missing/zero-run job as healthy,
    # exactly what `${ec:-0}` did.
    python3 - "$MUT/diagnostic_rules.py" <<'MUTAEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('    if runs == 0:\n        return {"state": "never_ran", "runs": 0, "why": exit_raw}',
              '    if runs == 0:\n        return {"state": "healthy", "runs": 0, "last_exit": 0}')
open(p, "w").write(s)
MUTAEOF
    a_out="$(AGENT_DIR="$MUT" OSTLER_STATE_DIR="$(mktemp -d "${TMP}/mA.XXXXXX")" \
             python3 "$DRIVER" parse 0 /dev/null 2>/dev/null || true)"
    printf 'runs = 0\nlast exit code = (never exited)\n' > "${TMP}/zero.txt"
    a_state="$(AGENT_DIR="$MUT" OSTLER_STATE_DIR="$(mktemp -d "${TMP}/mA2.XXXXXX")" \
               python3 "$DRIVER" parse 0 "${TMP}/zero.txt" | jqf 'd["state"]')"
    if [[ "$a_state" == "healthy" ]]; then
        ok "MUTANT A reinstated the #810 conflation (never-ran now reads healthy)"
        # ...and the real module must NOT do that.
        real_state="$(run parse 0 "${TMP}/zero.txt" | jqf 'd["state"]')"
        [[ "$real_state" == "never_ran" ]] \
            && ok "the shipped module resists MUTANT A (never_ran)" \
            || bad "shipped module ALSO conflates: <${real_state}>"
    else
        bad "MUTANT A did not take effect -- self-test proves nothing"
    fi

    # MUTANT B: make the rule silent, the original defect in its purest form.
    cp "${AGENT_DIR}"/*.py "$MUT"/ 2>/dev/null
    python3 - "$MUT/diagnostic_rules.py" <<'MUTBEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('        if state in ("healthy", "in_flight"):\n            continue',
              '        if True:\n            continue')
open(p, "w").write(s)
MUTBEOF
    b_out="$(AGENT_DIR="$MUT" OSTLER_STATE_DIR="$(mktemp -d "${TMP}/mB.XXXXXX")" \
             python3 "$DRIVER" rule '{"com.ostler.fda-rerun":{"state":"failing","runs":9,"last_exit":1}}')"
    b_n="$(printf '%s' "$b_out" | jqf 'len(d)')"
    if [[ "$b_n" == "0" ]]; then
        ok "MUTANT B reinstated the silence (a failing agent emits nothing)"
        r_n="$(run rule '{"com.ostler.fda-rerun":{"state":"failing","runs":9,"last_exit":1}}' | jqf 'len(d)')"
        [[ "${r_n:-0}" -ge 1 ]] \
            && ok "the shipped module resists MUTANT B (${r_n} finding)" \
            || bad "shipped module is ALSO silent on a failing agent"
    else
        bad "MUTANT B did not take effect -- self-test proves nothing"
    fi
fi

echo
echo "PASS=${PASS} FAIL=${FAIL}"
[[ $FAIL -eq 0 ]]
