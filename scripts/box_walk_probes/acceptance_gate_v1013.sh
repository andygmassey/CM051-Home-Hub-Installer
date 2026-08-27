#!/usr/bin/env bash
# scripts/box_walk_probes/acceptance_gate_v1013.sh
# ============================================================================
# RUNTIME ACCEPTANCE PROBE -- the box-walk, automated, wired into the cut gate.
#
# Ports TNM's ostler-acceptance-gate.sh (A1-A8) into a `box_walk_probe` so the
# runtime truths a customer sees are asserted BEFORE a DMG ships -- the gap that
# let v1.0.13.2 ship with R1/R5/#259/#260/#1/#2. Static provenance/structure
# gates verify the BUILD; this verifies the RUNNING PRODUCT.
#
# Invoked by the `box_walk_probe` primitive in scripts/verify_cut_manifest.py
# (reached via Makefile `check-manifest`, a `ship` prerequisite). The primitive
# already SKIPs when OSTLER_BOX_HOST is unset; this script ALSO skip-exits 0 when
# unset so a direct invocation never fails a cut (matches people_seed_and_retrieval).
#
# READ-ONLY. Every box command is a curl / grep / sqlite3-SELECT / launchctl-list
# / ls -- nothing mutates box state. Requires key-based ssh to $OSTLER_BOX_HOST.
#
# GATING (exit non-zero -> primitive FAILs -> cut BLOCKED):
#   A1 hub binary name is brand-neutral        [MAPS: #1]
#   A2 unpaired frontpage serves welcome cards  [MAPS: R1]
#   A3 SPA fallback does not mask missing /api  [MAPS: #2]
#   A4 pairing signals internally consistent    [MAPS: #3]
#   A5 wiki LLM present, 0 model-404s           [MAPS: #259]
#   A6 wiki compiler clean (fresh image)        [MAPS: #5/#260/#252]
#   A8 every ostler LaunchAgent exits clean     [MAPS: exit-class]
# NEEDS-EYES (printed, NEVER hard-fails):
#   A7 Home/Wiki phase coherence                [MAPS: R5] -- requires a rendered SPA
#
# NOTE (judgement call): the brief named A1-A6 as launch-critical and A7 as
# needs-eyes, and was silent on A8. A8 (nonzero LaunchAgent exit) is an objective,
# machine-checkable "customer sees a broken product" condition -- the reference
# gate hard-fails it -- so it is GATING here too. A7 remains the ONLY needs-eyes
# check, exactly as in the reference. Flip A8 to non-gating by moving its result
# call from FAIL to MANUAL if TNM prefers the strict A1-A6-only reading.
#
# Env:
#   OSTLER_BOX_HOST          user@host of the target box (REQUIRED; unset -> SKIP)
#   OSTLER_BOX_DAEMON_URL    daemon base (default http://localhost:8000)
#   OSTLER_BOX_OLLAMA_URL    ollama base (default http://localhost:11434)
#   OSTLER_BOX_EXPECT_PAIRED 1 -> A4 requires pairing COMPLETE (default: unpaired-consistency)
#
# Exit: 0 = SHIPPABLE / SKIP.  1 = BLOCKED (a launch-critical assertion failed).
#       2 = harness/ssh error (box unreachable).
# ============================================================================
set -uo pipefail

# --- skip convention: match check_box_walk_probe (unset host -> never fail) --
if [ -z "${OSTLER_BOX_HOST:-}" ]; then
    echo "acceptance_gate_v1013: SKIP -- OSTLER_BOX_HOST not set (runtime probe requires a reachable box)"
    exit 0
fi

HOST="${OSTLER_BOX_HOST}"
DAEMON="${OSTLER_BOX_DAEMON_URL:-http://localhost:8000}"
OLLAMA="${OSTLER_BOX_OLLAMA_URL:-http://localhost:11434}"
EXPECT_PAIRED="${OSTLER_BOX_EXPECT_PAIRED:-0}"

pass=0; fail=0; manual=0
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
else RED=""; GRN=""; YEL=""; DIM=""; RST=""; fi

# read-only command on the target box
box(){ ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" "$1" 2>/dev/null; }
# robust log-line count on the box. Patterns MUST NOT contain single-quotes.
# Greps log DIRECTORIES (not *.log globs) so zsh nomatch cannot abort the pipe.
# shellcheck disable=SC2088  # tilde is DELIBERATELY unquoted-for-remote: it must
# expand in the target box's login shell inside box "...", NOT on the cut host.
LOGDIRS='~/.ostler/logs ~/Library/Logs/Ostler'
boxcount(){ local n; n=$(box "grep -rhoE '$1' $LOGDIRS 2>/dev/null | wc -l | tr -d ' '"); echo "${n:-0}"; }

result(){ # $1=PASS|FAIL|MANUAL  $2=id  $3=title  $4=evidence
  case "$1" in
    PASS)   printf "  ${GRN}PASS${RST}  %-4s %s\n" "$2" "$3"; pass=$((pass+1));;
    FAIL)   printf "  ${RED}FAIL${RST}  %-4s %s\n" "$2" "$3"; fail=$((fail+1));;
    MANUAL) printf "  ${YEL}EYES${RST}  %-4s %s\n" "$2" "$3"; manual=$((manual+1));;
  esac
  [ -n "${4:-}" ] && printf "        ${DIM}%s${RST}\n" "$4"
}

echo "=============================================================="
echo " OSTLER ACCEPTANCE PROBE (v1.0.13) -- target: $HOST"
echo "=============================================================="
# fail-fast: is the box reachable at all?
if [ "$(box 'echo ok')" != "ok" ]; then
  echo "${RED}HARNESS ERROR:${RST} cannot ssh to $HOST (key-based BatchMode). Aborting probe."
  exit 2
fi

# -- A1 -- hub binary name is brand-neutral (no codename leak) [MAPS: #1] --
bin_name=$(box "ls /Applications/Ostler.app/Contents/MacOS/ 2>/dev/null | head -1")
if [ "$(echo "$bin_name" | grep -ciE 'zeroclaw|gamingrig|andypedia' || true)" -gt 0 ]; then
  result FAIL A1 "Hub binary name is brand-neutral" "found codename in Contents/MacOS: '$bin_name'"
else
  result PASS A1 "Hub binary name is brand-neutral" "binary: '$bin_name'"
fi

# -- A2 -- unpaired Home frontpage serves welcome cards, not 401 [MAPS: R1] --
fp_code=$(box "curl -s -o /dev/null -w '%{http_code}' --max-time 5 $DAEMON/api/v1/frontpage/cards")
fp_body=$(box "curl -s --max-time 5 $DAEMON/api/v1/frontpage/cards")
if [ "$fp_code" = "200" ] && [ "$(echo "$fp_body" | grep -c 'welcome-' || true)" -gt 0 ]; then
  result PASS A2 "Frontpage cards render pre-pair" "200 + welcome cards present"
else
  result FAIL A2 "Frontpage cards render pre-pair" "GET /api/v1/frontpage/cards -> $fp_code (want 200+welcome cards; 401 = auth layer blocks handler)"
fi

# -- A3 -- missing /api routes 404, don't masquerade as 200-SPA-HTML [MAPS: #2] --
a3_bad=""
for p in /api/v1/pause /api/v1/resume /api/v1/governor-status; do
  ct=$(box "curl -s -o /dev/null -w '%{content_type}' --max-time 4 $DAEMON$p")
  code=$(box "curl -s -o /dev/null -w '%{http_code}' --max-time 4 $DAEMON$p")
  if [ "$code" = "200" ] && [ "$(echo "$ct" | grep -ci 'text/html' || true)" -gt 0 ]; then
    a3_bad="$a3_bad $p(200-html)"
  fi
done
if [ -n "$a3_bad" ]; then
  result FAIL A3 "SPA fallback doesn't mask missing /api routes" "these return SPA-HTML instead of JSON/404:$a3_bad"
else
  result PASS A3 "SPA fallback doesn't mask missing /api routes" "all probed /api routes return JSON or 404"
fi

# -- A4 -- pairing signals are internally consistent [MAPS: #3] --
health=$(box "curl -s --max-time 5 $DAEMON/health")
cp=$(echo "$health" | grep -oE '"companion_paired"[: ]*(true|false)' | grep -oE 'true|false')
pd=$(echo "$health" | grep -oE '"paired"[: ]*(true|false)' | grep -oE 'true|false')
tp=$(echo "$health" | grep -oE '"token_paired"[: ]*(true|false)' | grep -oE 'true|false')
dev_ct=$(box "sqlite3 \$(find ~/.ostler -name devices.db 2>/dev/null | head -1) 'select count(*) from devices' 2>/dev/null")
[ -z "$dev_ct" ] && dev_ct="err"
if [ "$EXPECT_PAIRED" = "1" ]; then
  if [ "$cp" = "true" ] && [ "$pd" = "true" ] && [ "${dev_ct:-0}" -ge 1 ] 2>/dev/null; then
    result PASS A4 "Pairing complete + consistent" "companion=$cp paired=$pd token=$tp devices=$dev_ct"
  else
    result FAIL A4 "Pairing complete + consistent" "companion=$cp paired=$pd token=$tp devices=$dev_ct (want all-true + >=1 device)"
  fi
else
  # unpaired box: the 3 flags must AGREE (shipped bug = token_paired:true while others false)
  if [ "$cp" = "$pd" ] && [ "$pd" = "$tp" ]; then
    result PASS A4 "Pairing signals consistent" "companion=$cp paired=$pd token=$tp (agree)"
  else
    result FAIL A4 "Pairing signals consistent" "companion=$cp paired=$pd token=$tp -- signals DISAGREE (lying-UI)"
  fi
fi

# -- A5 -- the LLM the wiki compiler needs is present; no 404 storm [MAPS: #259] --
models=$(box "curl -s --max-time 6 $OLLAMA/api/tags | tr ',' '\n' | grep -oE '\"name\":\"[^\"]+\"'")
llm_404=$(boxcount 'model .* not found')
if [ -n "$models" ] && [ "${llm_404:-0}" -eq 0 ] 2>/dev/null; then
  result PASS A5 "Wiki LLM present, 0 model-404s" "models: $(echo "$models" | tr '\n' ' ')"
else
  result FAIL A5 "Wiki LLM present, 0 model-404s" "$llm_404 ollama-404s in wiki logs (compiler asked for a model that wasn't pulled)"
fi

# -- A6 -- wiki-compiler image is fresh: no SPARQL-400, no parser crash, no dead links [MAPS: #5/#260/#252] --
ox400=$(boxcount '400 Bad Request')
crash=$(boxcount 'unhashable type|object has no attribute')
brk=$(boxcount 'BROKEN LINK')
if [ "${ox400:-0}" -eq 0 ] && [ "${crash:-0}" -eq 0 ] && [ "${brk:-0}" -eq 0 ] 2>/dev/null; then
  result PASS A6 "Wiki compiler clean (fresh image)" "sparql-400=$ox400 crashes=$crash broken-links=$brk"
else
  result FAIL A6 "Wiki compiler clean (fresh image)" "sparql-400=$ox400 (stale image, pre-#219) parser-crashes=$crash broken-links=$brk"
fi

# -- A7 -- Home/Wiki phase coherence -- needs a rendered SPA, can't assert headlessly --
result MANUAL A7 "Home & Wiki agree on phase" "open the app: Home + Wiki must both show firstrun (unpaired) or both settled (paired). [MAPS: R5]"

# -- A8 -- every ostler LaunchAgent exits clean (78=throttle-yield whitelisted) [MAPS: exit-class] --
bad_agents=$(box "launchctl list | grep -iE 'ostler|creativemachines' | awk '\$2!=0 && \$2!=\"-\" && \$2!=78 {print \$3\"(exit=\"\$2\")\"}'")
if [ -z "$bad_agents" ]; then
  result PASS A8 "LaunchAgents exit clean" "all ostler agents exit 0 / benign"
else
  result FAIL A8 "LaunchAgents exit clean" "nonzero exits: $bad_agents"
fi

echo "=============================================================="
printf " RESULT: ${GRN}%d pass${RST} / ${RED}%d fail${RST} / ${YEL}%d needs-eyes${RST}\n" "$pass" "$fail" "$manual"
if [ "$fail" -gt 0 ]; then
  echo " ${RED}BLOCKED${RST} -- $fail launch-critical runtime assertion(s) failed. Not shippable."
  echo " (A7 needs-eyes is the one check that still requires a human walk.)"
  exit 1
fi
echo " ${GRN}PROBE GREEN${RST} -- runtime checks pass. (Confirm A7 by eye before ship.)"
exit 0
