#!/usr/bin/env bash
#
# tests/test_prereq_check_dwell_ticks.sh
#
# Locks the closeout Section C2 behaviour on the prereq_check phase
# ("Checking your Mac"): Studio retest #3 (2026-05-22) flagged that
# on a fast Mac the row flashes past in <1 second, leaving the
# customer no time to read what the installer is verifying. The fix
# was two-part:
#
#   1. Per-item PCT markers so the GUI can show ticks accumulate
#      (macOS ok, CPU ok, RAM ok, disk ok, ...) rather than one
#      instant 0 -> 100 jump.
#   2. A minimum-dwell pad (PREREQ_MIN_DWELL_S, default 2 s) applied
#      only in GUI mode, overridable to 0 so test/CI runs stay snappy.
#
# Why this test exists:
#   - Sections of install.sh get rearranged often during cut prep.
#     Losing a PCT marker, breaking the ascending ladder, or dropping
#     the dwell pad would silently regress the install first
#     impression with no functional symptom anywhere else.
#
# Verified scenarios (behavioural, extracted dwell-pad block):
#   1. GUI mode + fast run  -> pads with sleep for the remainder
#   2. GUI mode + dwell 0   -> no sleep (test/CI override contract)
#   3. TTY mode (no GUI)    -> no sleep
#   4. GUI mode + slow run  -> no sleep (elapsed already >= dwell)
#
# Plus structural checks on the PCT ladder and per-item ok ticks.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── Structural: dwell plumbing present ───────────────────────────
if ! grep -q 'PREREQ_CHECK_START=\$(date +%s)' "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: PREREQ_CHECK_START wall-clock capture missing" >&2
    exit 1
fi
echo "PASS: PREREQ_CHECK_START wall-clock capture present"

if ! grep -q 'PREREQ_MIN_DWELL_S="\${PREREQ_MIN_DWELL_S:-' "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: PREREQ_MIN_DWELL_S env-overridable default missing" >&2
    exit 1
fi
echo "PASS: PREREQ_MIN_DWELL_S env-overridable default present"

if ! grep -q '^# Minimum-dwell pad for the prereq_check phase' "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: minimum-dwell pad block header missing" >&2
    exit 1
fi
echo "PASS: minimum-dwell pad block present"

# ── Structural: per-item PCT ladder ──────────────────────────────
# Collect the pct values emitted for step=prereq_check, in file
# order. The ladder must have at least five rungs (one per checked
# item is the intent), start low, strictly ascend, and end at 100.
PCTS=$(grep -oE 'gui_emit PCT "step=prereq_check" "pct=[0-9]+"' "$INSTALL_SCRIPT" \
        | sed -E 's/.*pct=([0-9]+)"/\1/' || true)

if [[ -z "$PCTS" ]]; then
    echo "FAIL [ladder]: no PCT markers found for step=prereq_check" >&2
    exit 1
fi

COUNT=$(wc -l <<<"$PCTS" | tr -d ' ')
if (( COUNT < 5 )); then
    echo "FAIL [ladder]: only ${COUNT} PCT markers for prereq_check (need >= 5 for per-item ticks)" >&2
    exit 1
fi
echo "PASS: prereq_check emits ${COUNT} PCT markers (per-item ticks)"

FIRST=$(head -1 <<<"$PCTS")
LAST=$(tail -1 <<<"$PCTS")
if (( FIRST > 10 )); then
    echo "FAIL [ladder]: first PCT marker is ${FIRST} (expected an early <=10 'started' tick)" >&2
    exit 1
fi
if (( LAST != 100 )); then
    echo "FAIL [ladder]: last PCT marker is ${LAST} (expected 100)" >&2
    exit 1
fi
PREV=-1
while read -r P; do
    if (( P <= PREV )); then
        echo "FAIL [ladder]: PCT ladder not strictly ascending (${PREV} -> ${P})" >&2
        exit 1
    fi
    PREV=$P
done <<<"$PCTS"
echo "PASS: PCT ladder strictly ascending, ${FIRST} .. 100"

# ── Structural: each hardware item has a customer-visible tick ───
# The catalogue keys are the contract: if a probe loses its ok line
# the customer sees a silent gap where a tick should accumulate.
for KEY in MSG_OK_MACOS_DETECTED \
           MSG_OK_APPLE_SILICON_DETECTED \
           MSG_OK_GB_RAM_DETECTED \
           MSG_OK_GB_FREE_DISK_SPACE; do
    if ! grep -q "ok \"\$(printf \"\$${KEY}\"" "$INSTALL_SCRIPT" \
       && ! grep -q "ok \"\$${KEY}\"" "$INSTALL_SCRIPT"; then
        echo "FAIL [ticks]: no ok-tick call for catalogue key ${KEY}" >&2
        exit 1
    fi
done
echo "PASS: per-item ok ticks present (macOS, CPU, RAM, disk)"

# ── Extract the dwell-pad block for behavioural checks ───────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PAD="${WORK}/pad.sh"
awk '
    /^# Minimum-dwell pad for the prereq_check phase/ { capture = 1 }
    capture                                           { print }
    capture && /^fi$/                                 { exit }
' "$INSTALL_SCRIPT" > "$PAD"

if [[ ! -s "$PAD" ]]; then
    echo "FAIL [extract]: could not extract dwell-pad block from install.sh" >&2
    exit 1
fi
if ! bash -n "$PAD"; then
    echo "FAIL [extract]: extracted dwell-pad block does not parse standalone" >&2
    exit 1
fi
echo "PASS: dwell-pad block extracted ($(wc -l < "$PAD") lines)"

# ── Driver: run the pad with a recording sleep stub ──────────────
DRIVER="${WORK}/driver.sh"
cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -euo pipefail
# Shadow sleep so the test never actually waits; record the request.
sleep() { echo "SLEPT $1"; }
OSTLER_GUI="$1"
PREREQ_MIN_DWELL_S="$2"
PREREQ_CHECK_START="$3"
source "$4"
DRIVER_EOF
chmod +x "$DRIVER"

NOW=$(date +%s)

# Scenario 1: GUI mode, fast run (elapsed ~0) -> pad fires.
S1=$(bash "$DRIVER" 1 5 "$NOW" "$PAD")
if ! grep -q '^SLEPT [1-5]$' <<<"$S1"; then
    echo "FAIL [s1]: GUI fast run did not pad (output: '${S1}')" >&2
    exit 1
fi
echo "PASS [s1]: GUI fast run pads to the minimum dwell"

# Scenario 2: GUI mode, dwell overridden to 0 -> no pad. This is the
# contract tests and CI rely on to keep runs snappy.
S2=$(bash "$DRIVER" 1 0 "$NOW" "$PAD")
if grep -q 'SLEPT' <<<"$S2"; then
    echo "FAIL [s2]: PREREQ_MIN_DWELL_S=0 still slept (output: '${S2}')" >&2
    exit 1
fi
echo "PASS [s2]: PREREQ_MIN_DWELL_S=0 override skips the pad"

# Scenario 3: TTY mode (no GUI) -> no pad regardless of dwell.
S3=$(bash "$DRIVER" 0 5 "$NOW" "$PAD")
if grep -q 'SLEPT' <<<"$S3"; then
    echo "FAIL [s3]: non-GUI run slept (output: '${S3}')" >&2
    exit 1
fi
echo "PASS [s3]: TTY (non-GUI) run skips the pad"

# Scenario 4: GUI mode but the checks already took longer than the
# minimum dwell -> no extra pad on top.
S4=$(bash "$DRIVER" 1 2 "$(( NOW - 10 ))" "$PAD")
if grep -q 'SLEPT' <<<"$S4"; then
    echo "FAIL [s4]: slow run still padded (output: '${S4}')" >&2
    exit 1
fi
echo "PASS [s4]: slow run adds no extra pad"

echo ""
echo "ALL PREREQ DWELL + TICKS TESTS PASSED"
