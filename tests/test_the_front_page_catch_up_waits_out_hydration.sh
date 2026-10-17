#!/usr/bin/env bash
# Walk #27 (#28 B): during hydration the Front Page catch-up agent
# (com.creativemachines.ostler.editor-frontpage-catchup, the EFPCUEOF wrapper
# in install.sh) read the preferences collection as 0 points twice, at
# 20:22Z and 20:27Z, called it GENUINELY EMPTY and removed itself; the 40,315
# points landed before the install finished (21:01Z), and the profile stayed
# empty until the next hourly tick at 21:25Z. An empty read while the install
# is still running means "not yet", never "nothing to do".
#
# Scenarios (stub tick, stub curl, stub launchctl; same harness as
# test_the_front_page_catch_up_survives_a_late_ingest.sh):
#   1. install-in-progress marker present, upstream 0 on every read: the agent
#      never removes itself, and the empty confirmations never accumulate
#   2. the same agent after the marker clears and the data lands: POPULATED,
#      removes itself (the job is done)
#   3. CONTROL, no marker (install finished), upstream 0 twice: GENUINELY
#      EMPTY still removes itself
#   4. a stale marker (older than 6 h, an aborted install) does not hold the
#      agent for ever
# Runs under bash 3.2.
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
log_has() { /usr/bin/grep -q -e "$2" "$1/.ostler/logs/editor-frontpage-catchup.log" 2>/dev/null; }

W="${WORK}/wrapper.orig"

# 1. hydrating, empty reads
R="${WORK}/s1"; build_sandbox "$R" "$W" "empty:0" 0
printf 'pid=1\n' > "$R/.ostler/state/install-in-progress"
for i in 1 2 3 4 5; do run_tick "$R" 36 2; done
if plist_gone "$R"; then bad "1: the agent removed itself on empty reads while the install was still running"
else ok "1: five empty reads during hydration, the agent is still installed"; fi
log_has "$R" "GENUINELY EMPTY" && bad "1: an empty read during hydration was logged GENUINELY EMPTY" || ok "1: no GENUINELY EMPTY verdict while hydrating"
log_has "$R" "HYDRATING" && ok "1: the log says it is waiting for hydration" || bad "1: the log does not say it is waiting for hydration"

# 2. hydration ends, data lands
rm -f "$R/.ostler/state/install-in-progress"
printf 'populate:12:12' > "$R/.ostler/.scenario"; printf '40315' > "$R/.ostler/.upstream"
run_tick "$R" 36 2
plist_gone "$R" && log_has "$R" "POPULATED" && ok "2: once the data lands the agent populates the profile and removes itself" || bad "2: the agent did not populate and stop after hydration"

# 3. control: no marker, genuinely empty
R="${WORK}/s3"; build_sandbox "$R" "$W" "empty:0" 0
run_tick "$R" 36 2; run_tick "$R" 36 2
plist_gone "$R" && log_has "$R" "GENUINELY EMPTY" && ok "3: CONTROL, a finished install with an empty store still removes itself" || bad "3: CONTROL, a genuinely empty finished install no longer removes itself"

# 4. stale marker
R="${WORK}/s4"; build_sandbox "$R" "$W" "empty:0" 0
printf 'pid=1\n' > "$R/.ostler/state/install-in-progress"
touch -t 202001010000 "$R/.ostler/state/install-in-progress"
run_tick "$R" 36 2; run_tick "$R" 36 2
plist_gone "$R" && ok "4: a stale (aborted-install) marker does not hold the agent for ever" || bad "4: a stale marker kept the agent alive"

if [ "$fails" -eq 0 ]; then printf '\n%stest_the_front_page_catch_up_waits_out_hydration: PASSED%s\n' "$GRN" "$OFF"; exit 0; fi
printf '\n%stest_the_front_page_catch_up_waits_out_hydration: FAILED (%d)%s\n' "$RED" "$fails" "$OFF" >&2
exit 1
