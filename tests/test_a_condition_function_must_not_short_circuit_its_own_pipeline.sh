#!/usr/bin/env bash
# A function whose LAST statement is a short-circuiting pipeline, and which is
# used as a CONDITION, inherits the SIGPIPE inversion risk its caller cannot see.
#
# THE HOLE THIS CLOSES, AND WHY THE OTHER GATE CANNOT.
# tests/test_pipefail_shortcircuit_inversion.sh bans `producer | grep -q` in a
# condition. Its CONSTRUCT anchors on `^[[:space:]]*(if|elif|while)`. Move the
# same pipeline into a function body and no line begins with a keyword, so it
# matches nothing:
#
#     _agent_is_running() {
#         launchctl print "gui/$(id -u)/com.ostler.ollama" 2>/dev/null \
#             | grep -q 'state = running'
#     }
#     ...
#     if ... && _agent_is_running; then          <- the pipeline IS the condition
#
# Found 2026-09-05 on CM051 #1471, twenty minutes after #1475 fixed the
# continuation hole in that gate. Measured on that branch: CONSTRUCT matched the
# function body 0 times, the file's count stayed 21, the ratchet passed, and the
# shape was there.
#
# WHY BOTH STEPS. 29 functions in this repo end in a banned pipeline; only 3 are
# used as conditions. The rest are output helpers consumed as $(fn) whose exit
# status nothing reads, and flagging them would bury a real regression in noise.
# The pair of conditions is the predicate; neither half alone is.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="${REPO}/tests/condition_function_pipeline_baseline.txt"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$BASELINE" ] || cant "no baseline at ${BASELINE}; 'no new instances' would be unfounded"
WORK="$(mktemp -d)" || cant "no working directory"
trap 'rm -rf "$WORK"' EXIT

# `[|]` for the literal pipe, NOT `\|`. BSD awk rejects `\|` as an illegal
# primary and errors on EVERY line; with stderr dropped that reads as a clean
# scan finding nothing. `[|]` is valid in both awk and grep -E.
SHORTCIRCUIT='[|] *(grep [^|]*-q|grep [^|]*-m1|head( |$)|read )'

# Join `\`-continuations first, for the same reason #1475 had to: a pipeline
# split across lines is one statement and must be read as one.
_joined() { /usr/bin/sed -e :a -e '/\\$/N; s/\\\n//; ta' "$1" 2>/dev/null; }

# STEP 1: name every function whose last statement is a short-circuiting pipeline.
_fns_ending_in_pipeline() {
    # HEREDOC PAYLOAD IS NOT LIVE SHELL. This gate's own fixtures are inline
    # heredocs containing the banned shape on purpose, and without this the
    # scanner reports the gate itself. Same argument as the sibling gate's
    # tests/fixtures/ exclusion, one level in.
    _joined "$1" | /usr/bin/awk -v pat="$SHORTCIRCUIT" '
        /<<-?"?'"'"'?[A-Za-z_][A-Za-z0-9_]*"?'"'"'?$/ && !/<<[[:space:]]*\$/ {
            if (!inhd) { inhd = 1; d = $0
                         sub(/.*<<-?["'"'"']?/, "", d); sub(/["'"'"'].*/, "", d); next } }
        inhd && $0 ~ ("^[[:space:]]*" d "[[:space:]]*$") { inhd = 0; next }
        inhd { next }
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (line[i] !~ pat) continue
                j = i + 1
                while (j <= NR && line[j] ~ /^[[:space:]]*$/) j++
                if (line[j] !~ /^\}[[:space:]]*$/) continue     # not the last statement
                for (k = i; k >= 1 && k > i - 60; k--) {
                    if (line[k] ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/) {
                        nm = line[k]; sub(/\(\).*/, "", nm); print nm; break
                    }
                }
            }
        }'
}

# STEP 2: is that name used where its EXIT STATUS is branched on?
_used_as_condition() {
    local file="$1" nm="$2" n
    n="$(grep -cE "(^|[[:space:]])(if|while|until|!|&&|\|\|)[[:space:]]+${nm}([[:space:]]|;|\)|$)" "$file" 2>/dev/null || true)"
    [ "${n:-0}" -gt 0 ]
}

population_in() {
    local root="$1" f nm _abs
    while IFS= read -r f; do
        case "$f" in tests/fixtures/*|*/tests/fixtures/*) continue ;; esac
        # READ THROUGH $root, EMIT THE RELATIVE PATH. Without the prefix every
        # grep below runs against a path that does not exist from here, finds
        # nothing, and the scan reports a clean population it never read.
        _abs="${root}/${f}"
        grep -qE 'set -o pipefail|set -[a-z]+o[a-z]* pipefail' "$_abs" 2>/dev/null || continue
        while IFS= read -r nm; do
            [ -n "$nm" ] || continue
            _used_as_condition "$_abs" "$nm" && printf '%s\t%s\n' "$f" "$nm"
        done < <(_fns_ending_in_pipeline "$_abs")
    done < <(cd "$root" && /usr/bin/find . -name '.git' -prune -o \
                 \( -name '*.sh' -o -name '*.yml' \) -type f -print \
                 | sed 's#^\./##' | sort)
}

baseline_rows() { grep -vE '^[[:space:]]*(#|$)' "$1" | sort; }

cd "$REPO" || cant "cannot enter ${REPO}"
POP="$(population_in . | sort -u)"
POP_N="$(printf '%s\n' "$POP" | grep -c . || true)"
BASE_N="$(baseline_rows "$BASELINE" | grep -c . || true)"
printf '  population: %s condition-used function(s); baseline %s\n' "$POP_N" "$BASE_N"

# ── arm 1: the ratchet ───────────────────────────────────────────────────
ADDED="$(comm -13 <(baseline_rows "$BASELINE") <(printf '%s\n' "$POP" | grep -v '^$'))"
REMOVED="$(comm -23 <(baseline_rows "$BASELINE") <(printf '%s\n' "$POP" | grep -v '^$'))"
if [ -z "$ADDED" ]; then
    ok "arm 1: no NEW condition-function short-circuits (${POP_N} found, all baselined)"
else
    bad "arm 1: NEW condition-function short-circuit(s), not in the baseline:
$(printf '%s\n' "$ADDED" | sed 's/^/          /')
        The pipeline's status IS the function's return value and a caller branches on it.
        Remedy, no pipe so nothing can SIGPIPE:
          _out=\"\$(producer 2>/dev/null)\" || return 1
          case \"\$_out\" in *needle*) return 0 ;; esac
          return 1"
fi

# ── arm 2: no rot ────────────────────────────────────────────────────────
if [ -z "$REMOVED" ]; then
    ok "arm 2: every baselined row was found by this scan"
else
    bad "arm 2: the baseline lists rows the scan does NOT find. That is slack a real
        regression hides under. Delist them:
$(printf '%s\n' "$REMOVED" | sed 's/^/          /')"
fi

# ── arm 3: MUTATION. Both halves present must be caught. ─────────────────
CTL="${WORK}/ctl"; mkdir -p "$CTL"
cat > "$CTL/seeded.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
_seeded_probe() {
    printf 'state = running\n' | grep -q 'state = running'
}
if _seeded_probe; then echo yes; fi
FIXTURE
if printf '%s\n' "$(population_in "$CTL")" | grep -qF 'seeded.sh'; then
    ok "arm 3: a function ending in a banned pipeline AND used as a condition IS caught"
else
    bad "arm 3: the seeded positive was NOT caught. Arm 1 cannot fail and its pass means nothing."
fi

# ── arm 4: MUST-MISS. Pipeline present, but the status is never read. ────
cat > "$CTL/output_helper.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
_first_digits() {
    printf '%s' "${1:-0}" | tr -dc '0-9' | head -c10
}
echo "got $(_first_digits "$1")"
FIXTURE
if printf '%s\n' "$(population_in "$CTL")" | grep -qF 'output_helper.sh'; then
    bad "arm 4: an OUTPUT helper consumed as \$(fn) was reported. Step 2 is not
        discriminating, so the population is inflated with 26 harmless rows and a
        real regression hides among them."
else
    ok "arm 4: an output helper whose exit status nothing reads is NOT reported"
fi

# ── arm 5: MUST-MISS. Used as a condition, but no banned pipeline. ───────
cat > "$CTL/clean_condition.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
_clean_probe() {
    local _out
    _out="$(printf 'state = running\n')" || return 1
    case "$_out" in *"state = running"*) return 0 ;; esac
    return 1
}
if _clean_probe; then echo yes; fi
FIXTURE
if printf '%s\n' "$(population_in "$CTL")" | grep -qF 'clean_condition.sh'; then
    bad "arm 5: the REMEDY form was reported as a defect. The gate would reject its own fix."
else
    ok "arm 5: the no-pipe remedy form is NOT reported, so the gate accepts its own fix"
fi

# ── arm 6: MUST-MISS. Banned pipeline, but not the LAST statement. ───────
cat > "$CTL/not_last.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -uo pipefail
_mid_pipeline() {
    printf 'x\n' | grep -q x
    return 0
}
if _mid_pipeline; then echo yes; fi
FIXTURE
if printf '%s\n' "$(population_in "$CTL")" | grep -qF 'not_last.sh'; then
    bad "arm 6: a pipeline that is NOT the last statement was reported. Its status is
        discarded by the explicit return below it, so this inflates the population."
else
    ok "arm 6: a banned pipeline whose status is discarded by a later return is NOT reported"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
