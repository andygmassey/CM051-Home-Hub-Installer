#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_the_front_page_catch_up_survives_a_late_ingest.sh
#
# THE DEFECT THIS REFUSES TO LET BACK IN
# ---------------------------------------------------------------------------
# com.creativemachines.ostler.editor-frontpage is StartInterval 3600 with
# RunAtLoad true, and its own plist comment says RunAtLoad exists "so the
# Dashboard shows a populated (or honestly-settling) Front Page immediately
# rather than after the first hour". It cannot. The install finishes before
# the ingest it reads, so the one guaranteed run happens at the one moment
# there is provably nothing to read.
#
# Measured on macmini16-walk, 2026-09-23, from the box's own logs:
#     12:00:53  projected 0 preference nodes from    0 Qdrant points
#     13:00:58  projected 0 preference nodes from  926 Qdrant points
#     13:05     the real preference points land
#     13:29     the same installed wrapper, run by hand:
#               projected 4797 nodes from 5723 points; 4628 interests
# For that hour ~/.ostler/preferences/interest_profile.json served count 0,
# which is what /api/v1/preferences serves and what the daemon's
# pwg_preferences tool reads, which is why the BLOCKING walk probe
# assistant_answers_grounded scored [tool_found_nothing:pwg_preferences].
#
# WHAT IS ASSERTED, AND WHY IT IS BEHAVIOUR AND NOT GREP
# ---------------------------------------------------------------------------
# A grep over install.sh can only say a string is present. This carves the
# catch-up wrapper out of install.sh's heredoc and RUNS it, tick by tick, in a
# sandboxed HOME with a stub tick, a stub curl and a stub launchctl, then
# looks at what is left on disk.
#
#   A  POPULATED       profile fills -> the agent removes its own plist
#   B  GENUINELY EMPTY upstream answers 200 with 0 points -> terminates, but
#                      only after the confirmation run, never on one reading
#   C  BOUNDED         upstream unreadable for ever -> still terminates, at
#                      the cap, and never before it
#   D  NOT YET         upstream has points, profile empty -> keeps retrying
#                      and keeps re-running the tick
#
# CONTROLS, because a green from a dead harness is worth nothing
# ---------------------------------------------------------------------------
#   K1 the stub tick must record that it was actually executed. If the
#      wrapper never ran, A..D would be asserting nothing.
#   K2 MUTANT: delete the POPULATED branch's self-removal. Axis A must then
#      FAIL. A predicate that passes a wrapper that never stops is not
#      measuring stopping.
#   K3 MUTANT: collapse the upstream reader's CANNOT-READ into 0, i.e. make
#      "could not look" print the same as "found nothing". Axis C must then
#      FAIL. This is the one honesty property the whole discriminator rests
#      on, so it is proved by a mutant rather than asserted.
#
# Synthetic data throughout: the fixture profile carries no subjects at all,
# only counts.
#
# Usage: test_the_front_page_catch_up_survives_a_late_ingest.sh [install.sh]
#   The optional path is how this is pointed at origin/main's install.sh to
#   demonstrate the pre-fix RED.
#
# EXIT CODES
#   0  every axis and every control behaved
#   1  an axis or a control failed
#   2  could not run. NOT a pass.
# ---------------------------------------------------------------------------
set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -n "${NO_COLOR:-}" ]] && { RED=""; GRN=""; YEL=""; OFF=""; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${1:-${REPO_ROOT}/install.sh}"

fails=0
ok()  { printf '  %sPASS%s  %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1" >&2; fails=$((fails + 1)); }
cannot() {
    printf '%sCANNOT-RUN%s %s\n' "$YEL" "$OFF" "$*" >&2
    printf '  NOTHING was checked. This is not a pass.\n' >&2
    exit 2
}

[[ -f "$INSTALL_SCRIPT" ]] || cannot "no install.sh at: $INSTALL_SCRIPT"
PY_BIN="$(command -v python3 2>/dev/null || true)"
[[ -n "$PY_BIN" ]] || cannot "no python3 on PATH; the wrapper's artefact reads cannot be exercised"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LABEL="com.creativemachines.ostler.editor-frontpage-catchup"

# ── Carve the wrapper out of install.sh ────────────────────────────────────
# `^[^#]*` on the opening marker so a COMMENT that merely names the heredoc
# cannot start the capture -- the exact trap that once swallowed thousands of
# lines in test_uninstall_removes_every_launchagent_plist.sh.
awk '
    /^[^#]*<<'\''EFPCUEOF'\''/ { capture = 1; next }
    /^EFPCUEOF$/               { capture = 0 }
    capture                    { print }
' "$INSTALL_SCRIPT" > "${WORK}/wrapper.orig"

wrapper_lines=$(wc -l < "${WORK}/wrapper.orig" | tr -d ' ')
if [[ "${wrapper_lines:-0}" -lt 40 ]]; then
    bad "install.sh carries no Front Page catch-up wrapper (carved ${wrapper_lines:-0} lines from the EFPCUEOF heredoc). The RunAtLoad-only editor-frontpage agent fires while the graph is empty and nothing re-runs for an hour."
    printf '\n%stest_the_front_page_catch_up_survives_a_late_ingest: FAILED%s\n' "$RED" "$OFF" >&2
    exit 1
fi
bash -n "${WORK}/wrapper.orig" || bad "the carved catch-up wrapper does not parse"
ok "carved a ${wrapper_lines}-line catch-up wrapper out of install.sh and it parses"

# ── Sandbox builder ────────────────────────────────────────────────────────
# scenario file drives the stub tick:
#   empty:<raw_rows>      write a profile with count 0 and that many raw rows
#   populate:<n>:<raw>    write a profile with n interests over raw rows
# upstream file drives the stub curl:
#   <n>        answer 200 with points_count n
#   unreadable exit non-zero, the way a 404 or a refused connection does
build_sandbox() {
    local root="$1" wrapper="$2" scenario="$3" upstream="$4"
    rm -rf "$root"
    mkdir -p "$root/.ostler/bin" "$root/.ostler/state" "$root/.ostler/logs" \
             "$root/.ostler/preferences" "$root/Library/LaunchAgents" "$root/stubs"

    printf '%s' "$scenario"  > "$root/.ostler/.scenario"
    printf '%s' "$upstream"  > "$root/.ostler/.upstream"

    # The stub tick. Carries a PYTHON_BIN="..." line because the wrapper reads
    # its interpreter back out of the producer rather than guessing one.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'PYTHON_BIN="%s"\n' "$PY_BIN"
        printf 'echo ran >> "$HOME/.ostler/.tick-runs"\n'
        printf '"$PYTHON_BIN" - "$HOME" <<%s\n' "'STUBPY'"
        cat <<'STUBBODY'
import json, os, sys
home = sys.argv[1]
spec = open(os.path.join(home, ".ostler", ".scenario")).read().strip().split(":")
if spec[0] == "populate":
    n, raw = int(spec[1]), int(spec[2])
else:
    n, raw = 0, int(spec[1]) if len(spec) > 1 else 0
art = {"schema_version": "0.1", "generated_at": "2026-01-01T00:00:00+00:00",
       "count": n, "interests": [{"id": "synthetic-%d" % i} for i in range(n)],
       "stats": {"raw_rows": raw, "interests": n}}
p = os.path.join(home, ".ostler", "preferences", "interest_profile.json")
with open(p, "w", encoding="utf-8") as fh:
    json.dump(art, fh, indent=2)
STUBBODY
        printf 'STUBPY\n'
    } > "$root/.ostler/bin/editor-frontpage-tick.sh"
    chmod +x "$root/.ostler/bin/editor-frontpage-tick.sh"

    # Stub launchctl: records the bootout, never touches the real launchd.
    {
        printf '#!/bin/sh\n'
        printf 'echo "$@" >> "$HOME/.ostler/.launchctl-calls"\n'
        printf 'exit 0\n'
    } > "$root/stubs/launchctl"
    chmod +x "$root/stubs/launchctl"

    # Stub curl: answers for the Qdrant collection read only.
    {
        printf '#!/bin/sh\n'
        printf 'u=$(cat "$HOME/.ostler/.upstream")\n'
        printf 'if [ "$u" = unreadable ]; then exit 22; fi\n'
        printf 'printf %s "{\\"result\\":{\\"status\\":\\"green\\",\\"points_count\\":$u}}"\n' '%s'
    } > "$root/stubs/curl"
    chmod +x "$root/stubs/curl"

    # The plist the agent must remove when it is done with itself.
    printf 'placeholder\n' > "$root/Library/LaunchAgents/${LABEL}.plist"

    install -m 0755 "$wrapper" "$root/.ostler/bin/ostler-editor-frontpage-catchup"
}

run_tick() {
    local root="$1" max="$2" confirms="$3"
    env -i \
        HOME="$root" \
        PATH="$root/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
        EDITOR_CATCHUP_MAX_TRIES="$max" \
        EDITOR_CATCHUP_EMPTY_CONFIRMATIONS="$confirms" \
        /bin/bash "$root/.ostler/bin/ostler-editor-frontpage-catchup" \
        >>"$root/.stdout" 2>>"$root/.stderr"
}

plist_gone() { [[ ! -e "$1/Library/LaunchAgents/${LABEL}.plist" ]]; }
tick_runs()  { /usr/bin/grep -c . "$1/.ostler/.tick-runs" 2>/dev/null || printf '0'; }
# grep the log FILE, never `cat file | grep -q`. Under `set -o pipefail` a
# short-circuiting consumer inverts a MATCH into a non-zero pipeline status:
# grep -q exits on the first hit, the producer dies EPIPE, and pipefail takes
# the producer's status. Measured while writing this test -- axes A and B
# passed and axis C reported "no CANNOT TELL line" against a log whose second
# line was a CANNOT TELL line. Passing was safety by SIZE, not by construction.
# See tests/test_pipefail_shortcircuit_inversion.sh.
#
# `|| true`, not `|| printf 0`: grep -c PRINTS 0 and EXITS 1 on no match, so
# the second form yields the two-line string "0\n0" and every arithmetic test
# on it is a syntax error.
log_has() {
    local n
    n="$(/usr/bin/grep -c -e "$2" "$1/.ostler/logs/editor-frontpage-catchup.log" 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -ge 1 ]
}

# ===========================================================================
# AXIS A -- POPULATED. The profile fills; the agent stops.
# ===========================================================================
A="${WORK}/A"
build_sandbox "$A" "${WORK}/wrapper.orig" "populate:4628:4797" "5723"
run_tick "$A" 36 2
if plist_gone "$A"; then
    ok "A POPULATED: the profile filled and the catch-up agent removed its own plist"
else
    bad "A POPULATED: the profile filled to 4628 interests and the catch-up agent left its plist in place, so it would keep re-emitting for ever"
fi
if log_has "$A" 'POPULATED'; then
    ok "A POPULATED: said so in its log, in those words"
else
    bad "A POPULATED: the log never names the outcome, so a customer log cannot be read to tell why it stopped"
fi

# K1 -- the harness is alive. If the stub tick never executed, every axis
# above and below would be measuring an empty sandbox.
if [[ "$(tick_runs "$A")" -ge 1 ]]; then
    ok "K1 CONTROL: the stub tick recorded $(tick_runs "$A") execution(s), so the wrapper really ran"
else
    bad "K1 CONTROL: the stub tick recorded no executions. The wrapper did not run and nothing above was measured"
fi

# ===========================================================================
# AXIS B -- GENUINELY EMPTY. Upstream answers 200 with 0 points. The agent
# must stop, and must NOT stop on the first reading.
# ===========================================================================
B="${WORK}/B"
build_sandbox "$B" "${WORK}/wrapper.orig" "empty:0" "0"
run_tick "$B" 36 2
if plist_gone "$B"; then
    bad "B GENUINELY EMPTY: terminated on a SINGLE zero reading. A collection created at hydrate and filled ten minutes later would end the catch-up on the one tick that caught it in between"
else
    ok "B GENUINELY EMPTY: one zero reading is not enough to stop; the agent is still scheduled"
fi
run_tick "$B" 36 2
if plist_gone "$B"; then
    ok "B GENUINELY EMPTY: stopped after the confirmation run, so a box whose owner has no preferences does not retry to the cap"
else
    bad "B GENUINELY EMPTY: two consecutive zero readings and the agent is still scheduled; it would retry to the cap on a box with nothing to project"
fi
if log_has "$B" 'GENUINELY EMPTY'; then
    ok "B GENUINELY EMPTY: named the verdict in its log"
else
    bad "B GENUINELY EMPTY: the log never names the verdict"
fi

# ===========================================================================
# AXIS C -- BOUNDED. Upstream unreadable for ever. "could not look" is not a
# zero, so it must NOT take the empty exit; it must still terminate, at the
# cap and not before.
# ===========================================================================
C="${WORK}/C"
build_sandbox "$C" "${WORK}/wrapper.orig" "empty:0" "unreadable"
for i in 1 2 3; do run_tick "$C" 4 2; done
if plist_gone "$C"; then
    bad "C BOUNDED: an unreadable upstream was treated as a zero and the agent removed itself after 3 of 4 tries. 'could not look' must never read as 'found nothing'"
else
    ok "C BOUNDED: an unreadable upstream did not end the catch-up early"
fi
run_tick "$C" 4 2   # try 4: the last allowed
run_tick "$C" 4 2   # try 5: over the cap
if plist_gone "$C"; then
    ok "C BOUNDED: terminated at the cap, so it cannot spin for ever"
else
    bad "C BOUNDED: still scheduled past EDITOR_CATCHUP_MAX_TRIES=4. The retry is unbounded"
fi
if log_has "$C" 'CANNOT TELL'; then
    ok "C BOUNDED: logged CANNOT TELL rather than reporting an unmeasured upstream as empty"
else
    bad "C BOUNDED: an unreadable upstream produced no CANNOT TELL line, so the log cannot distinguish it from a measured zero"
fi

# ===========================================================================
# AXIS D -- NOT POPULATED YET. Upstream has points, the profile is still
# empty: this is the measured defect. It must keep retrying and keep
# re-running the tick, which is the thing that eventually fills the profile.
# ===========================================================================
D="${WORK}/D"
build_sandbox "$D" "${WORK}/wrapper.orig" "empty:0" "926"
run_tick "$D" 36 2
run_tick "$D" 36 2
if plist_gone "$D"; then
    bad "D NOT POPULATED YET: 926 points upstream and an empty profile is exactly the walked failure, and the agent stopped instead of catching up"
else
    ok "D NOT POPULATED YET: 926 points upstream and an empty profile keeps the catch-up scheduled"
fi
if [[ "$(tick_runs "$D")" -eq 2 ]]; then
    ok "D NOT POPULATED YET: re-ran the existing tick on every attempt ($(tick_runs "$D") of 2)"
else
    bad "D NOT POPULATED YET: the tick ran $(tick_runs "$D") time(s) over 2 attempts, so the agent is scheduled but is not actually re-emitting"
fi
# And the moment the data lands, the very next tick must finish the job.
printf 'populate:4628:4797' > "$D/.ostler/.scenario"
run_tick "$D" 36 2
if plist_gone "$D"; then
    ok "D NOT POPULATED YET: the tick after the ingest landed filled the profile and the agent stood itself down"
else
    bad "D NOT POPULATED YET: the ingest landed and the catch-up still did not finish"
fi

# ===========================================================================
# K2 CONTROL (MUTANT) -- remove the POPULATED branch's self-removal. Axis A
# must fail against it. A predicate that cannot reject a wrapper that never
# stops is not measuring stopping.
# ===========================================================================
"$PY_BIN" - "${WORK}/wrapper.orig" "${WORK}/wrapper.k2" <<'K2PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# The POPULATED branch is the only remove_self preceded by a POPULATED log.
i = src.index("POPULATED: the interest profile now serves")
j = src.index("remove_self", i)
out = src[:j] + ":  # MUTANT K2: self-removal deleted" + src[j + len("remove_self"):]
assert out != src
open(sys.argv[2], "w", encoding="utf-8").write(out)
K2PY
if [[ ! -s "${WORK}/wrapper.k2" ]]; then
    bad "K2 CONTROL: could not build the mutant, so axis A is unproven"
else
    K2="${WORK}/K2"
    build_sandbox "$K2" "${WORK}/wrapper.k2" "populate:4628:4797" "5723"
    run_tick "$K2" 36 2
    if plist_gone "$K2"; then
        bad "K2 CONTROL: the mutant with its self-removal deleted still passed axis A. Axis A proves nothing"
    else
        ok "K2 CONTROL: the mutant that never stops on a populated profile is rejected, so axis A has teeth"
    fi
fi

# ===========================================================================
# K3 CONTROL (MUTANT) -- collapse the upstream reader's CANNOT-READ into 0,
# i.e. make "could not look" print exactly what "found nothing" prints. Axis
# C must fail against it. This is the honesty property the discriminator
# rests on, so it is demonstrated rather than asserted.
# ===========================================================================
sed 's/printf .CANNOT-READ./printf 0/g' "${WORK}/wrapper.orig" > "${WORK}/wrapper.k3"
if ! /usr/bin/grep -q "printf 'CANNOT-READ'" "${WORK}/wrapper.orig"; then
    bad "K3 CONTROL: the wrapper has no CANNOT-READ path to collapse, so the three-state upstream read is not implemented"
else
    K3="${WORK}/K3"
    build_sandbox "$K3" "${WORK}/wrapper.k3" "empty:0" "unreadable"
    run_tick "$K3" 4 2
    run_tick "$K3" 4 2
    if plist_gone "$K3"; then
        ok "K3 CONTROL: the mutant that reads 'could not look' as a zero terminates early and is rejected, so axis C has teeth"
    else
        bad "K3 CONTROL: collapsing CANNOT-READ into 0 changed nothing observable. Axis C cannot detect a two-state upstream read"
    fi
fi

# ===========================================================================
# The agent must be in the uninstaller's teardown register, or an uninstalled
# Mac loads it again at the next login.
# ===========================================================================
_in_labels="$(awk '/^OSTLER_LAUNCHAGENT_LABELS=\(/,/^\)/' "$INSTALL_SCRIPT" \
    | /usr/bin/grep -cE "^[[:space:]]*${LABEL}[[:space:]]*$" || true)"
if [[ "${_in_labels:-0}" -ge 1 ]]; then
    ok "teardown: ${LABEL} is in OSTLER_LAUNCHAGENT_LABELS"
else
    bad "teardown: ${LABEL} is not in OSTLER_LAUNCHAGENT_LABELS, so uninstall leaves the plist and the next login loads it again"
fi

# The hourly agent must NOT have been changed by this fix: its RunAtLoad run
# is harmless and the missing catch-up was the whole defect.
if /usr/bin/grep -q 'RunAtLoad' "${REPO_ROOT}/vendor/cm059_editor/launchd/com.creativemachines.ostler.editor-frontpage.plist" 2>/dev/null; then
    if awk '/<key>RunAtLoad<\/key>/{getline; print}' \
        "${REPO_ROOT}/vendor/cm059_editor/launchd/com.creativemachines.ostler.editor-frontpage.plist" \
        | /usr/bin/grep -q '<true/>'; then
        ok "the hourly Front Page agent still has RunAtLoad true; this fix adds a catch-up and changes nothing about it"
    else
        bad "the hourly Front Page agent's RunAtLoad was changed. The early run is harmless; the missing catch-up was the defect"
    fi
fi

printf '\n'
if [[ "$fails" -ne 0 ]]; then
    printf '%stest_the_front_page_catch_up_survives_a_late_ingest: FAILED (%d)%s\n' "$RED" "$fails" "$OFF" >&2
    exit 1
fi
printf '%stest_the_front_page_catch_up_survives_a_late_ingest: the Front Page catch-up stops when populated, stops when there is genuinely nothing to project, retries while the ingest is still landing, is bounded, and both mutants were rejected%s\n' "$GRN" "$OFF"
exit 0
