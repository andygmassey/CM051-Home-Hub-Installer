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
#       78 = CANNOT-RUN (box unreachable, or its logs could not be read).
#
# 🔴 THIS SAID 2, AND 2 IS NOT THE PROTOCOL. run_box_walk.sh:44 declares
# EX_CANNOT_RUN=78, and check_box_walk_probe maps 78 -> CANNOT-RUN and EVERY
# OTHER non-zero -> FAIL. So "cannot ssh to the box" was recorded as a FAIL
# against the ARTEFACT, on a row registered in cut-manifests/permanent.yaml,
# which means every cut. That is the exact false accusation
# check_box_walk_probe's own comment describes: it "sends whoever reads the
# report hunting a bug that was never detected, while the actual fault -- a
# signal nobody could read -- goes unsaid."
#
# The 25 probes under probes/ all refuse through lib/probe.sh's
# probe_cannot_run(). This gate sits one directory up and sources nothing, so
# it never inherited the convention.
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

pass=0; fail=0; manual=0; cannot=0
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
else RED=""; GRN=""; YEL=""; DIM=""; RST=""; fi

# read-only command on the target box
box(){ ssh -o ConnectTimeout=8 -o BatchMode=yes "$HOST" "$1" 2>/dev/null; }
# robust log-line count on the box. Patterns MUST NOT contain single-quotes.
# Greps log DIRECTORIES (not *.log globs) so zsh nomatch cannot abort the pipe.
# shellcheck disable=SC2088  # tilde is DELIBERATELY unquoted-for-remote: it must
# expand in the target box's login shell inside box "...", NOT on the cut host.
LOGDIRS='~/.ostler/logs ~/Library/Logs/Ostler'
# 🔴 THREE SITUATIONS USED TO PRODUCE AN IDENTICAL 0: a genuinely clean log, a
# box with NO log directories at all, and an ssh call that returned nothing.
# A5 and A6 then read that 0 and reported "Wiki compiler clean (fresh image),
# sparql-400=0 crashes=0 broken-links=0" -- a PASS asserting the compiler is
# clean on a box where not one log line was ever read. A fresh box is exactly
# the box an acceptance gate runs against.
#
# NOLOGS and UNREACHABLE are returned as text so the caller cannot silently do
# arithmetic on them. Every consumer below tests numeric-ness first.
boxcount(){
  local n
  n=$(box "found=0; for d in $LOGDIRS; do [ -d \"\$d\" ] && found=1; done; \
           if [ \"\$found\" -eq 0 ]; then echo NOLOGS; \
           else grep -rhoE '$1' $LOGDIRS 2>/dev/null | wc -l | tr -d ' '; fi")
  if [ -z "$n" ]; then echo UNREACHABLE; else echo "$n"; fi
}

# A6 grades the WIKI COMPILER, so it must read the wiki compiler's logs and
# nothing else. Measured 2026-09-10 on the v1.0.87 walk: boxcount over all of
# LOGDIRS found ONE "400 Bad Request", and it was in imessage-bundle.err (the
# conversation-ingest pipeline talking to the store), not in any wiki-*.log.
# A6 then reported the wiki image stale. Same shape as the A7 footer: text
# that reads like a diagnosis and measured a different component.
# shellcheck disable=SC2088  # tilde expands on the box, see LOGDIRS.
WIKILOGDIRS='~/.ostler/logs ~/Library/Logs/Ostler'   # the wiki jobs write wiki-*.log and wiki-*.err here (install.sh: LOGS_DIR)
# Enumerates the files with find, never a shell glob, and passes them to grep
# through an unquoted command substitution, never a variable: the box's login
# shell is zsh, which ABORTS the command on an unmatched glob and does NOT
# word-split an unquoted variable (both read as a refusal when this was first
# run against the walk box), but does split an unquoted $(...). Then reads
# grep's own status: 0 and 1 are counts, anything else (an unreadable file, a
# permission error) is a refusal, never a 0. stderr is not merged into the
# counted file: a diagnostic that leaves the status alone must not count as a match.
wikicount(){
  local n
  n=$(box "cnt=\$(find $WIKILOGDIRS -maxdepth 1 -type f \( -name 'wiki-*.log' -o -name 'wiki-*.err' \) 2>/dev/null | wc -l | tr -d ' '); \
           if [ \"\$cnt\" -eq 0 ]; then echo NOLOGS; \
           else t=\$(mktemp); grep -hoE '$1' \$(find $WIKILOGDIRS -maxdepth 1 -type f \( -name 'wiki-*.log' -o -name 'wiki-*.err' \) 2>/dev/null) > \"\$t\" 2>/dev/null; rc=\$?; \
             case \"\$rc\" in 0|1) wc -l < \"\$t\" | tr -d ' ';; *) echo GREPERR;; esac; rm -f \"\$t\"; fi")
  if [ -z "$n" ]; then echo UNREACHABLE; else echo "$n"; fi
}

# The compiler pinned from CM044 v0.1.31 (#268) logs "BROKEN LINK: ..." for
# every internal link it cannot resolve and THEN degrades it to plain text in
# the written page, summarising per compile as "Link audit: N broken links
# found out of M checked; R degraded to plain text" (compile.py:1604 and
# :1632 at 3bc0f3bb). A failed rewrite logs "Link repair failed for ...".
# So on that image a BROKEN LINK line is a source defect made visible, not a
# dead link a customer can click. "No dead links" is found minus degraded,
# summed over every compile in the logs (the catchup log is append-only, so
# the two sums pair per compile), plus zero failed repairs. Prints
# "FOUND DEGRADED FAILED" or a refusal token.
wikiaudit(){
  local n
  n=$(box "cnt=\$(find $WIKILOGDIRS -maxdepth 1 -type f \( -name 'wiki-*.log' -o -name 'wiki-*.err' \) 2>/dev/null | wc -l | tr -d ' '); \
           if [ \"\$cnt\" -eq 0 ]; then echo NOLOGS; \
           else t=\$(mktemp); grep -hoE 'Link audit: [0-9]+ broken links found out of [0-9]+ checked(; [0-9]+ degraded)?|Link repair failed' \$(find $WIKILOGDIRS -maxdepth 1 -type f \( -name 'wiki-*.log' -o -name 'wiki-*.err' \) 2>/dev/null) > \"\$t\" 2>/dev/null; rc=\$?; \
             case \"\$rc\" in 0|1) awk '/^Link audit/{f+=\$3; if (\$12==\"degraded\") d+=\$11} /^Link repair failed/{x++} END{printf \"%d %d %d\\n\", f, d, x}' \"\$t\";; *) echo GREPERR;; esac; rm -f \"\$t\"; fi")
  if [ -z "$n" ]; then echo UNREACHABLE; else echo "$n"; fi
}

# True when a boxcount result is a real number rather than a refusal token.
is_count(){ case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac }

result(){ # $1=PASS|FAIL|MANUAL  $2=id  $3=title  $4=evidence
  case "$1" in
    PASS)   printf "  ${GRN}PASS${RST}  %-4s %s\n" "$2" "$3"; pass=$((pass+1));;
    FAIL)   printf "  ${RED}FAIL${RST}  %-4s %s\n" "$2" "$3"; fail=$((fail+1));;
    MANUAL) printf "  ${YEL}EYES${RST}  %-4s %s\n" "$2" "$3"; manual=$((manual+1));;
    CANNOT) printf "  ${YEL}CANT${RST}  %-4s %s\n" "$2" "$3"; cannot=$((cannot+1));;
  esac
  [ -n "${4:-}" ] && printf "        ${DIM}%s${RST}\n" "$4"
}

echo "=============================================================="
echo " OSTLER ACCEPTANCE PROBE (v1.0.13) -- target: $HOST"
echo "=============================================================="
# fail-fast: is the box reachable at all?
if [ "$(box 'echo ok')" != "ok" ]; then
  # run_box_walk.sh reads the LAST "VERDICT: CANNOT-RUN --" line to record why,
  # and warns "UNRECORDED" for a bare 78, so name the prerequisite here.
  echo "${RED}HARNESS ERROR:${RST} cannot ssh to $HOST (key-based BatchMode). Aborting probe."
  echo "VERDICT: CANNOT-RUN -- cannot ssh to ${HOST} in BatchMode, so NOTHING about the artefact was measured"
  exit 78
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
rp=$(echo "$health" | grep -oE '"require_pairing"[: ]*(true|false)' | grep -oE 'true|false')
dev_ct=$(box "sqlite3 \$(find ~/.ostler -name devices.db 2>/dev/null | head -1) 'select count(*) from devices' 2>/dev/null")
[ -z "$dev_ct" ] && dev_ct="err"
if [ "$EXPECT_PAIRED" = "1" ]; then
  if [ "$cp" = "true" ] && [ "$pd" = "true" ] && [ "${dev_ct:-0}" -ge 1 ] 2>/dev/null; then
    result PASS A4 "Pairing complete + consistent" "companion=$cp paired=$pd token=$tp devices=$dev_ct"
  else
    result FAIL A4 "Pairing complete + consistent" "companion=$cp paired=$pd token=$tp devices=$dev_ct (want all-true + >=1 device)"
  fi
else
  # Unpaired box. What the daemon guarantees (ostler-assistant #208, read from
  # crates/zeroclaw-gateway/src/lib.rs:1946-1972 on 2026-09-10): paired and
  # companion_paired come from the device registry and the passkey file, and
  # are false with no device; token_paired is the bearer-token set being
  # non-empty, which the installer makes TRUE on every install by seeding the
  # admin token (install.sh: the paired_tokens merge). So on a healthy
  # unpaired box the truth is companion=false paired=false token=true and
  # devices=0. The old predicate demanded all three flags AGREE, which no
  # correctly installed box can satisfy; it read FAIL on v1.0.82, v1.0.85 and
  # v1.0.87 behind the A7 footer. The device-state assertion is the two device
  # flags plus the device count. token_paired is reported, not judged.
  if [ "$rp" = "false" ]; then
    # The device registry (and devices.db) exists only when require_pairing is
    # true (ostler-assistant lib.rs:1581-1587); the default is true and the
    # installer never sets it. A false here is a different box, not a broken probe.
    result CANNOT A4 "Pairing signals consistent" \
      "require_pairing=false: this box has pairing disabled, so there is no device registry to grade; companion='$cp' paired='$pd' token='$tp'"
  elif [ -z "$cp" ] || [ -z "$pd" ] || ! is_count "$dev_ct"; then
    result CANNOT A4 "Pairing signals consistent" \
      "companion='$cp' paired='$pd' token='$tp' devices='$dev_ct': a signal could not be read, so NOTHING about pairing was measured"
  elif [ "$cp" = "false" ] && [ "$pd" = "false" ] && [ "$dev_ct" -eq 0 ]; then
    result PASS A4 "Pairing signals consistent" "companion=$cp paired=$pd devices=$dev_ct (unpaired, agree); token=$tp is the installer's admin token, expected"
  else
    result FAIL A4 "Pairing signals consistent" "companion=$cp paired=$pd devices=$dev_ct -- a device flag or the device count claims a pairing that does not exist (lying-UI); token=$tp"
  fi
fi

# -- A5 -- the LLM the wiki compiler needs is present; no 404 storm [MAPS: #259] --
models=$(box "curl -s --max-time 6 $OLLAMA/api/tags | tr ',' '\n' | grep -oE '\"name\":\"[^\"]+\"'")
llm_404=$(boxcount 'model .* not found')
if ! is_count "$llm_404"; then
  result CANNOT A5 "Wiki LLM present, 0 model-404s" \
    "log count came back '$llm_404': NOTHING was read, so '0 model-404s' is not available"
elif [ -n "$models" ] && [ "$llm_404" -eq 0 ]; then
  result PASS A5 "Wiki LLM present, 0 model-404s" "models: $(echo "$models" | tr '\n' ' ')"
else
  result FAIL A5 "Wiki LLM present, 0 model-404s" "$llm_404 ollama-404s in wiki logs (compiler asked for a model that wasn't pulled)"
fi

# -- A6 -- wiki-compiler image is fresh: no SPARQL-400, no parser crash, no dead links [MAPS: #5/#260/#252] --
ox400=$(wikicount '400 Bad Request')
crash=$(wikicount 'unhashable type|object has no attribute')
brk=$(wikicount 'BROKEN LINK')
aud=$(wikiaudit)
found=""; degraded=""; rfail=""
case "$aud" in
  *[!0-9\ ]*|"") : ;;
  *) set -- $aud; if [ $# -eq 3 ]; then found="$1"; degraded="$2"; rfail="$3"; fi ;;
esac
if ! is_count "$ox400" || ! is_count "$crash" || ! is_count "$brk" || [ -z "$rfail" ]; then
  result CANNOT A6 "Wiki compiler clean (fresh image)" \
    "wiki log counts came back sparql-400='$ox400' crashes='$crash' broken-links='$brk' audit='$aud': NOTHING was read from the wiki compiler logs, so 'clean' is not available"
else
  # Dead links come from the per-compile summaries, where found and degraded
  # are paired. The per-link BROKEN LINK lines are NOT retained the same way
  # (measured 2026-09-10: the catchup log held 7 summaries and 1 such line),
  # so they are reported, never subtracted from. A log with BROKEN LINK lines
  # and no summary at all is an older compiler: every one of them counts.
  if [ "$found" -gt 0 ]; then dead=$((found - degraded)); else dead="$brk"; fi
  [ "$dead" -lt 0 ] && dead=0
  if [ "$ox400" -eq 0 ] && [ "$crash" -eq 0 ] && [ "$dead" -eq 0 ] && [ "$rfail" -eq 0 ]; then
    result PASS A6 "Wiki compiler clean (fresh image)" "sparql-400=$ox400 crashes=$crash broken-links=$brk found=$found repaired=$degraded dead=0 repair-failures=$rfail"
  else
  # The evidence is the three counts. This line used to append a fixed
  # "stale image" diagnosis naming a CM044 PR number, unconditionally: a guess
  # from when that PR was the suspect, printed on every FAIL since, and read
  # as a finding on three records.
    result FAIL A6 "Wiki compiler clean (fresh image)" "sparql-400=$ox400 parser-crashes=$crash broken-links=$brk found=$found repaired=$degraded dead=$dead repair-failures=$rfail (read from the wiki compiler logs only)"
  fi
fi

# -- A7 -- Home/Wiki phase coherence -- needs a rendered SPA, can't assert headlessly --
result MANUAL A7 "Home & Wiki agree on phase" "open the app: Home + Wiki must both show firstrun (unpaired) or both settled (paired). [MAPS: R5]"

# -- A8 -- every ostler LaunchAgent exits clean (78=throttle-yield whitelisted) [MAPS: exit-class] --
# 🔴 AN EMPTY RESULT MEANT BOTH "no bad agents" AND "the ssh call returned
# nothing". The clean case and the could-not-look case were the same string,
# and the clean case is the one that PASSED. The remote side now emits a
# terminating OK marker, so an empty or truncated reply is distinguishable from
# a genuinely clean list.
bad_agents=$(box "launchctl list | grep -iE 'ostler|creativemachines' | awk '\$2!=0 && \$2!=\"-\" && \$2!=78 {print \$3\"(exit=\"\$2\")\"}'; echo __A8_OK__")
# 🔴 grep -c, NEVER `| grep -q`. This file runs under `set -uo pipefail`, and
# grep -q exits on the FIRST match, SIGPIPEs the producer, and inverts the
# verdict. tests/test_pipefail_shortcircuit_inversion.sh ratchets against
# exactly this, and it caught the line in my own fix for the defect above:
# I introduced the trap I was writing a refusal for. grep -c reads to EOF.
if [ "$(printf '%s' "$bad_agents" | grep -c '__A8_OK__')" -eq 0 ]; then
  result CANNOT A8 "LaunchAgents exit clean" \
    "the launchctl query returned no terminator, so the agent list was never read: 'all clean' is not available"
else
  bad_agents=$(printf '%s' "$bad_agents" | sed 's/__A8_OK__//' | tr -d '\n' )
  if [ -z "$bad_agents" ]; then
    result PASS A8 "LaunchAgents exit clean" "all ostler agents exit 0 / benign"
  else
    result FAIL A8 "LaunchAgents exit clean" "nonzero exits: $bad_agents"
  fi
fi

echo "=============================================================="
printf " RESULT: ${GRN}%d pass${RST} / ${RED}%d fail${RST} / ${YEL}%d needs-eyes${RST} / ${YEL}%d could-not-run${RST}\n" \
  "$pass" "$fail" "$manual" "$cannot"

# 🔴 FAIL OUTRANKS CANNOT-RUN, AND BOTH OUTRANK GREEN. A real defect that was
# measured must not be downgraded to "could not measure" just because a
# different assertion also failed to read something.
if [ "$fail" -gt 0 ]; then
  echo " ${RED}BLOCKED${RST} -- $fail launch-critical runtime assertion(s) failed. Not shippable."
  echo " (A7 needs-eyes is the one check that still requires a human walk.)"
  exit 1
fi
if [ "$cannot" -gt 0 ]; then
  echo " ${YEL}CANNOT-RUN${RST} -- $cannot assertion(s) could not read what they grade."
  echo " This is NOT a pass and NOT a defect in the artefact. Nothing was measured there."
  echo "VERDICT: CANNOT-RUN -- $cannot assertion(s) could not read the box logs or agent list"
  exit 78
fi
echo " ${GRN}PROBE GREEN${RST} -- runtime checks pass. (Confirm A7 by eye before ship.)"
exit 0
