#!/usr/bin/env bash
# A BOX PROBE MUST NOT SELECT A PROCESS IT DOES NOT OWN.
#
# WHY THIS EXISTS. MEASURED on the v1.0.67 walk:
#
#     [identity_layer_is_importable]
#         interpreter (from pid NNNNN): /Users/<another-account>/.ostler/.venv/bin/python3
#         VERDICT: CANNOT-RUN -- CONTROL FAILED: 'import json' did not succeed
#
# pid 17714 belonged to ANOTHER ACCOUNT's ical-server. `pgrep -f` matches every
# account's processes, so the probe took a foreign pid, read that user's
# interpreter path out of the public command line, and measured a thing that was
# never its subject. It reported CANNOT-RUN rather than a false pass, which is
# the probe being honest -- but HONEST ABOUT THE WRONG SUBJECT IS STILL THE
# WRONG SUBJECT.
#
# The second site is worse in kind: running_config_matches_disk pipes the pid
# into `ps -Eww` to read PWG_SERVICE_TOKEN out of the process ENVIRONMENT. An
# unscoped match points that at a process we do not own; the kernel refuses,
# the token comes back empty, and the CANNOT-RUN is blamed on the wrong thing.
#
# Reading from the LIVE process is deliberate and stays -- a probe that picks
# its own interpreter proves something about an interpreter nobody uses. It
# simply has to be OUR live process. `-u "$(id -u)"` is that, and it is the
# same class as #1471 (:11434 answered by another account) and #1495 (the store
# ports): REACHABLE IS NOT OURS, now for the process table.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROBES="${REPO}/scripts/box_walk_probes"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -d "$PROBES" ] || { echo "CANNOT-RUN: no probe suite at ${PROBES}" >&2; exit 2; }

# Code lines only: a comment that mentions pgrep is not an invocation, and
# counting comments is counting prose.
_pgrep_code_lines() {
    /usr/bin/grep -rn 'pgrep' "$1" 2>/dev/null \
        | /usr/bin/awk -F: '{ line=$0; sub(/^[^:]*:[0-9]+:/,"",line);
                              sub(/^[[:space:]]+/,"",line);
                              if (substr(line,1,1) != "#") print }'
}

MATCHES="$(_pgrep_code_lines "$PROBES")"
N="$(printf '%s' "$MATCHES" | /usr/bin/grep -c . || true)"

# ANTI-VACUITY. If the enumeration finds nothing, this gate would pass by
# looking at zero lines -- the shape that makes a green meaningless.
MIN_PGREP=2
if [ "$N" -lt "$MIN_PGREP" ]; then
    echo "CANNOT-RUN: found ${N} pgrep invocation(s) in ${PROBES}, expected at least ${MIN_PGREP}." >&2
    echo "  Either the probes stopped using pgrep (lower the floor deliberately)," >&2
    echo "  or this enumeration is broken. A gate that inspects nothing is green" >&2
    echo "  in exactly the same way as a gate that inspects everything." >&2
    exit 2
fi
printf '  examined %s pgrep invocation(s) (floor %s)\n\n' "$N" "$MIN_PGREP"

UNSCOPED=0
while IFS= read -r m; do
    [ -n "$m" ] || continue
    case "$m" in
        *"pgrep -u "*) ok "scoped: ${m:0:88}" ;;
        *) bad "UNSCOPED pgrep -- matches every account's processes: ${m:0:88}"; UNSCOPED=$((UNSCOPED+1)) ;;
    esac
done <<< "$MATCHES"

# MUTATION: the checker must be able to SAY NO. Without this the arms above
# could be satisfied by a predicate that matches anything.
printf '\n  mutation control:\n'
TMP="$(mktemp -d)" || { echo "CANNOT-RUN: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/probes"
printf '%s\n' '    _pid="$(box_run "pgrep -f ical-server.py | head -1")"' > "${TMP}/probes/injected.sh"
INJ="$(_pgrep_code_lines "$TMP")"
if printf '%s' "$INJ" | /usr/bin/grep -q 'pgrep -f' && ! printf '%s' "$INJ" | /usr/bin/grep -q 'pgrep -u'; then
    ok "an injected unscoped pgrep IS detected (the predicate can say no)"
else
    bad "an injected unscoped pgrep was NOT detected -- this gate proves nothing"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
