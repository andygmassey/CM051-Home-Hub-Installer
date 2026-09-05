#!/usr/bin/env bash
# Every script that defaults to an OS003 checkout must default to the SAME one.
#
# CM051 #1485. scripts/sync_rollforward_registry.sh and scripts/sync_cut_bom.sh
# defaulted to different checkouts of the same repo, so during the v1.0.67
# assembly the register sync succeeded against a file the BOM sync then
# reported missing, seconds apart:
#
#     CANNOT-RUN  OS003 has no BOM for v1.0.67 -- write it there first
#
# That sentence reads as "nobody wrote the BOM" and meant "I looked somewhere
# else". A CANNOT-RUN that names the wrong cause is worse than a silent one,
# because it sends the reader to fix a file that is already correct.
#
# AND THE TWO PATHS WERE NOT EQUIVALENT. Measured 2026-09-05:
#
#     ~/Developer/OS003-Ostler-Release           0 dataless    HEAD 3d51fef
#     ~/Documents/Projects/OS003 - Ostler ...    1593 dataless (1591 in .git)
#                                                HEAD eca2b18  -- STALE
#
# iCloud had evicted the second one. A git read against an evicted pack does
# not fail loudly, it returns a false answer, and a recursive grep over that
# tree hangs rather than erroring. So the disagreement was not cosmetic: one
# default pointed at a tree whose absences cannot be trusted.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

# A DENOMINATOR FLOOR. If the extractor stops matching -- a rename, a quoting
# change -- it finds zero defaults, they trivially "agree", and this gate goes
# green over a question it never asked. Two scripts carry one today.
MIN_DEFAULTS=2

# Extract the default from `${OS003_DIR:-<default>}`. Echoes one line per site:
#   <file>\t<default>
# SCOPE IS scripts/ AND bin/ ONLY, AND THAT IS THE POINT.
# The property is about executable sync scripts that RESOLVE a checkout at run
# time. tests/ carries fixture text, help strings and this file's own control
# seeds, all of which contain the literal `OS003_DIR:-` without being a runtime
# default. Scanning them made this gate report ITSELF as a disagreement on its
# first run -- six "distinct checkouts", four of which were its own regex and
# fixtures. A gate that cannot tell its own seeds from its subject is measuring
# the wrong thing.
_os003_defaults() {
    local root="$1" d
    for d in scripts bin; do
        [ -d "${root}/${d}" ] || continue
        grep -rn 'OS003_DIR:-' "${root}/${d}" --include='*.sh' 2>/dev/null
    done \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
        | sed -E 's/^([^:]+):[0-9]+:.*OS003_DIR:-([^}"]*)\}.*/\1\t\2/' \
        | grep -vE '\$\{OS003_DIR' \
        | sort -u
}

cd "$REPO" || cant "cannot enter ${REPO}"

echo "── controls: the extractor must SEE a default and must ABSTAIN ──"
CTL="$(mktemp -d)" || cant "mktemp failed"
trap 'rm -rf "$CTL"' EXIT

mkdir -p "$CTL/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'SRC="${OS003_DIR:-$HOME/Developer/OS003-Ostler-Release}"' > "$CTL/scripts/a.sh"
printf '%s\n' '#!/usr/bin/env bash' 'SRC="${OS003_DIR:-$HOME/Documents/Projects/OS003 - Ostler Release}"' > "$CTL/scripts/b.sh"
printf '%s\n' '#!/usr/bin/env bash' '# OS003_DIR:-$HOME/somewhere/else   a comment, not code' > "$CTL/scripts/c.sh"

CTL_N="$(_os003_defaults "$CTL" | grep -c . || true)"
CTL_DISTINCT="$(_os003_defaults "$CTL" | cut -f2 | sort -u | grep -c . || true)"

if [ "${CTL_N:-0}" -eq 2 ]; then
    ok "CONTROL: the extractor finds both seeded defaults and skips the commented one"
else
    bad "CONTROL: expected 2 seeded defaults, found ${CTL_N}. The extractor is broken, so the verdict below is meaningless."
fi
if [ "${CTL_DISTINCT:-0}" -eq 2 ]; then
    ok "CONTROL: a seeded DISAGREEMENT is detectable (2 distinct defaults)"
else
    bad "CONTROL: a seeded disagreement collapsed to ${CTL_DISTINCT} distinct value(s). This gate cannot fail, so its pass means nothing."
fi

# MUST-MISS: two sites that agree must read as one distinct value.
printf '%s\n' '#!/usr/bin/env bash' 'SRC="${OS003_DIR:-$HOME/Developer/OS003-Ostler-Release}"' > "$CTL/scripts/b.sh"
if [ "$(_os003_defaults "$CTL" | cut -f2 | sort -u | grep -c . || true)" -eq 1 ]; then
    ok "MUST-MISS: two agreeing sites are not reported as a disagreement"
else
    bad "MUST-MISS: two identical defaults were counted as different. The gate is loud rather than right."
fi

echo "── subject: this repo ──"
FOUND="$(_os003_defaults .)"
N="$(printf '%s\n' "$FOUND" | grep -c . || true)"
[ "${N:-0}" -ge "$MIN_DEFAULTS" ] || cant "found ${N} OS003 default(s), below the floor of ${MIN_DEFAULTS}. \
The extractor has gone blind or a script was renamed; zero defaults agree trivially and that is not a pass."

printf '%s\n' "$FOUND" | sed 's/^/    /'
DISTINCT="$(printf '%s\n' "$FOUND" | cut -f2 | sort -u)"
N_DISTINCT="$(printf '%s\n' "$DISTINCT" | grep -c . || true)"

if [ "${N_DISTINCT:-0}" -eq 1 ]; then
    ok "all ${N} OS003 default(s) name the same checkout"
else
    bad "the ${N} OS003 default(s) name ${N_DISTINCT} DIFFERENT checkouts:
$(printf '%s\n' "$DISTINCT" | sed 's/^/          /')
        One script will report a file missing that another just read, and the
        CANNOT-RUN it prints will name the wrong cause."
fi

# The chosen default must not be the iCloud tree. That path is subject to
# eviction, and an evicted git read returns a false answer rather than an error.
# `grep -c`, not `| grep -q`: this repo bans the piped short-circuit form and
# its ratchet caught this very line. grep -c must read to EOF, so it cannot
# SIGPIPE the producer.
if [ "$(printf '%s\n' "$DISTINCT" | grep -c 'Documents/Projects')" -gt 0 ]; then
    bad "an OS003 default points into ~/Documents/Projects, which iCloud evicts. \
A read there can return a false absence instead of failing. Use a ~/Developer checkout."
else
    ok "no OS003 default points into the iCloud-evicted ~/Documents/Projects tree"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
