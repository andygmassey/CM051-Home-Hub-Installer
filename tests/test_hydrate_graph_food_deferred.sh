#!/usr/bin/env bash
# hydrate_graph: the food-evidence ingest is deferred, and a failure is named
# by the source that failed (v1.0.121)
# =========================================================================
#
# v1.0.120 cold walk, 16 GB Mac: the WhatsApp leg's graph write runs EVERY
# pwg_ingest source. The food-evidence source (added by #3130) hit its 900 s
# preference-ingest cap, pwg_ingest exited 1, the rc was filed against
# WhatsApp, hydrate_graph closed rc=1, and the customer read "WhatsApp chats
# were read but not written to your people graph".
#
# Behavioural, through the real pieces: extracts the REAL Step 2 block and the
# REAL label helper from install.sh, sources the REAL en-GB strings, and runs
# them under /bin/bash (3.2 on macOS) with an armed ERR trap. The python it
# calls is the REAL vendored pwg_ingest main() and the REAL ingest_food, whose
# CM019 subprocess is a stub that sleeps past a 1 s cap, so the timeout is a
# genuine subprocess.TimeoutExpired. Every other dispatch source is replaced by
# a canned ok, or by an error for the one key under test.
#
# Arms:
#   A  food timeout: the step stays rc 0, food is deferred (never run here),
#      the deferral is recorded and said, no warning, no WhatsApp text.
#   B  the deferred job exists: the hourly tick calls ingest_all with nothing
#      deferred (so it DOES run food), its LaunchAgent has a StartInterval,
#      and the real ingest_all with no defer reaches ingest_food.
#   C  every dispatch key, failed one at a time through the real leg: the
#      warning names THAT source in customer words, says WhatsApp only for
#      whatsapp, and the step still records rc 1.
#   D  the helper: food, an unknown key, several keys, and an unreadable file.
#
# Usage: test_hydrate_graph_food_deferred.sh [install.sh] [strings.sh] [vendor-dir]
# (the RED run points these at the v1.0.120 tree).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${1:-$REPO_ROOT/install.sh}"
STRINGS="${2:-$REPO_ROOT/install.sh.strings.en-GB.sh}"
VENDOR="${3:-$REPO_ROOT/vendor}"
BASH_BIN="${BASH_UNDER_TEST:-/bin/bash}"
PY="${PYTHON_UNDER_TEST:-python3}"

W="$(mktemp -d "${TMPDIR:-/tmp}/hyfood.XXXXXX")"
trap 'rm -rf "$W"' EXIT
fails=0
fail() { echo "  FAIL  $*" >&2; fails=$((fails+1)); }
pass() { echo "  ok    $*"; }

# Probe the REAL import, not a guessed dependency list: CI once had httpx and
# phonenumbers and still could not import pwg_ingest (nameparser), and every
# arm then read a broken interpreter as product behaviour.
if ! PYTHONPATH="$VENDOR" "$PY" -c 'import ostler_fda.pwg_ingest' 2>"$W/deps.err"; then
    echo "CANNOT-RUN: $PY cannot import the vendored ostler_fda.pwg_ingest:" >&2
    cat "$W/deps.err" >&2
    exit 2
fi

# ── extract the real code ────────────────────────────────────────────────
start="$(grep -n -- '-m ostler_fda.pwg_ingest' "$INSTALL" | head -1 | cut -d: -f1)"
[ -n "$start" ] || { echo "CANNOT-RUN: pwg_ingest CLI call not found in $INSTALL" >&2; exit 2; }
block_start="$(awk -v s="$start" 'NR<=s && /# Step 2: ingest the JSON/ {l=NR} END{print l}' "$INSTALL")"
end="$(awk -v s="$start" 'NR>=s && /unset _wa_ingest_rc/ {print NR; exit}' "$INSTALL")"
[ -n "$block_start" ] && [ -n "$end" ] || { echo "CANNOT-RUN: Step 2 block bounds not found" >&2; exit 2; }
sed -n "${block_start},$((end + 1))p" "$INSTALL" > "$W/block.sh"
# The helper is absent before v1.0.121; an empty file then, and arm D says so.
awk '/^_hydrate_ingest_failure_labels\(\) \{/ {on=1} on {print} on && /^\}/ {exit}' "$INSTALL" > "$W/helper.sh"

# ── the box: an FDA dir with one food extract, and a CM019 that hangs ────
OSTLER_DIR_T="$W/ostler"
mkdir -p "$OSTLER_DIR_T/imports/fda" "$OSTLER_DIR_T/services/cm019/.venv/bin" "$W/diag"
printf '[]\n' > "$OSTLER_DIR_T/imports/fda/calendar_events.json"
cat > "$OSTLER_DIR_T/services/cm019/.venv/bin/python3" <<'EOF'
#!/bin/sh
: > "$T_FOOD_RAN"
sleep 5
EOF
chmod 755 "$OSTLER_DIR_T/services/cm019/.venv/bin/python3"

cat > "$W/run_ingest.py" <<'EOF'
import os, sys
sys.path.insert(0, os.environ["T_VENDOR"])
import ostler_fda.pwg_ingest as p
import ostler_fda.apple_music_refresh as amr
amr.INGEST_TIMEOUT_S = 1.0  # the real 900 s cap, scaled; the stub sleeps 5 s
fail = os.environ.get("T_FAIL_KEY", "")
def _canned(n):
    def f(fda_dir):
        return {"status": "error", "error": "simulated"} if n == fail else {"status": "ok"}
    return f
for name, fn in p._INGEST_DISPATCH:
    if name != "food":
        setattr(p, fn, _canned(name))
args = sys.argv[1:]
with open(os.environ["T_ARGV_LOG"], "a") as fh:
    fh.write(" ".join(args) + "\n")
if args[:2] == ["-m", "ostler_fda.pwg_ingest"]:
    sys.argv = ["pwg_ingest"] + args[2:]
    p.main()
elif args[:1] == ["--dispatch-keys"]:
    print(" ".join(n for n, _ in p._INGEST_DISPATCH))
elif args[:1] == ["--tick"]:
    # What the hourly tick does: ingest_all(fda_dir), nothing deferred.
    from pathlib import Path
    print(p.ingest_all(Path(os.environ["OSTLER_DIR"]) / "imports" / "fda").get("food"))
EOF
cat > "$W/fakepy" <<EOF
#!/bin/sh
exec "$PY" "$W/run_ingest.py" "\$@"
EOF
chmod 755 "$W/fakepy"

# run_leg <fail-key>: runs the real block; prints its output.
run_leg() {
    rm -f "$W/food_ran" "$W/argv.log"
    cat > "$W/harness.sh" <<HARNESS
set -Eeuo pipefail
trap 'echo ERR_TRAP_FIRED; exit 97' ERR
OSTLER_DIR="$OSTLER_DIR_T"; export OSTLER_DIR
OSTLER_DIAG_DIR="$W/diag"
_HYDRATE_WHATSAPP_LOG="$W/diag/hydrate-whatsapp.log"
_HYDRATE_WHATSAPP_RC=0
_HYDRATE_WHATSAPP_PY="$W/fakepy"
warn() { echo "WARN: \$*"; }
info() { echo "INFO: \$*"; }
gui_step_record_rc() { echo "STEP_RC=\$1"; }
_hydrate_sentinel_record_no_data() { echo "SENTINEL_NO_DATA \$1 \$2"; }
source "$STRINGS"
source "$W/helper.sh"
source "$W/block.sh"
echo "REACHED whatsapp_rc=\${_HYDRATE_WHATSAPP_RC}"
HARNESS
    T_VENDOR="$VENDOR" T_FOOD_RAN="$W/food_ran" T_ARGV_LOG="$W/argv.log" T_FAIL_KEY="$1" \
        "$BASH_BIN" "$W/harness.sh" 2>&1
}
# The step's rc as install.sh would close it: a non-zero WhatsApp rc is folded
# in by the sentinel writer that follows the block; anything else directly.
step_rc() {
    local out="$1" n
    n="$(sed -n 's/^REACHED whatsapp_rc=//p' <<<"$out")"
    if [[ -n "$n" && "$n" != "0" ]]; then echo 1; return; fi
    if grep -Eq '^STEP_RC=[1-9]' <<<"$out"; then echo 1; return; fi
    echo 0
}

# ── A: a food timeout does not fail the step ─────────────────────────────
echo "[A] food times out (real ingest_food, 1 s cap, CM019 stub sleeps 5 s)"
out="$(run_leg "")"
echo "$out" | sed 's/^/      | /'
grep -q 'ERR_TRAP_FIRED' <<<"$out" && fail "A: ERR trap fired, the install would abort"
grep -q '^REACHED' <<<"$out" || fail "A: never reached the line after the block"
[[ "$(step_rc "$out")" == 0 ]] && pass "A: hydrate_graph stays rc 0" || fail "A: hydrate_graph closes rc 1 on a food timeout"
grep -q 'WhatsApp' <<<"$out" && fail "A: the customer is told about WhatsApp for a food problem"
grep -q '^WARN:' <<<"$out" && fail "A: a warning was raised for deferred work"
grep -q -- '--defer food' "$W/argv.log" 2>/dev/null && pass "A: the leg passes --defer food" || fail "A: the leg does not defer food"
[[ -e "$W/food_ran" ]] && fail "A: the food ingest ran inside the install step" || pass "A: the food ingest did not run inside the step"
grep -q '^SENTINEL_NO_DATA food deferred_to_hourly_ingest$' <<<"$out" && pass "A: the deferral is recorded for the Doctor" || fail "A: no food deferral record"
msg="$(. "$STRINGS"; printf '%s' "${MSG_HYDRATE_FOOD_DEFERRED:-}")"
if [[ -n "$msg" ]] && grep -qF "INFO: $msg" <<<"$out"; then
    pass "A: the customer is told food continues in the background"
else
    fail "A: no background notice for food"
fi

# ── B: the deferred job is scheduled and does run food ───────────────────
echo "[B] the hourly tick owns food"
grep -qF 'results = ingest_all(fda_dir) or {}' "$INSTALL" && pass "B: the fda-rerun tick calls ingest_all with nothing deferred" || fail "B: the tick's ingest_all call changed"
awk '/cat > "\$FDA_RERUN_PLIST"/ {on=1} on && /<key>StartInterval<\/key>/ {f=1} on && /^FDARPEOF/ {exit} END{exit !f}' "$INSTALL" \
    && pass "B: com.ostler.fda-rerun carries a StartInterval" || fail "B: the fda-rerun LaunchAgent has no StartInterval"
rm -f "$W/food_ran"
tick="$(OSTLER_DIR="$OSTLER_DIR_T" T_VENDOR="$VENDOR" T_FOOD_RAN="$W/food_ran" T_ARGV_LOG="$W/argv.log" "$W/fakepy" --tick 2>/dev/null | tail -n 1)"
[[ -e "$W/food_ran" ]] && pass "B: the tick path runs ingest_food (food -> $tick)" || fail "B: the tick path never reached ingest_food ($tick)"

# ── C: every dispatch key names itself ───────────────────────────────────
keys="$(T_VENDOR="$VENDOR" T_ARGV_LOG=/dev/null "$W/fakepy" --dispatch-keys)"
[[ -n "$keys" ]] || { echo "CANNOT-RUN: no dispatch keys read from $VENDOR" >&2; exit 2; }
echo "[C] each of: $keys"
n=0; c_before=$fails
for k in $keys; do
    [[ "$k" == "food" ]] && continue   # deferred here; its label is arm D's
    n=$((n+1))
    up="$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')"
    label="$(. "$STRINGS"; v="MSG_HYDRATE_SOURCE_LABEL_${up}"; printf '%s' "${!v:-}")"
    out="$(run_leg "$k")"
    if [[ -z "$label" ]]; then fail "C[$k]: no MSG_HYDRATE_SOURCE_LABEL_${up} in the strings"; continue; fi
    w="$(grep '^WARN:' <<<"$out" || true)"
    echo "      | $k: ${w:0:110}"
    grep -qF -- "$label" <<<"$w" || fail "C[$k]: warning does not name '$label': $w"
    if [[ "$k" == "whatsapp" ]]; then
        grep -q 'WhatsApp' <<<"$w" || fail "C[$k]: a WhatsApp failure does not say WhatsApp"
    else
        grep -q 'WhatsApp' <<<"$w" && fail "C[$k]: blamed on WhatsApp: $w"
    fi
    [[ "$(step_rc "$out")" == 1 ]] || fail "C[$k]: the failure no longer fails the step"
done
[[ "$fails" -eq "$c_before" ]] && pass "C: $n keys failed one at a time, each named by itself"

# ── D: the helper on its own ─────────────────────────────────────────────
echo "[D] label helper"
if [[ ! -s "$W/helper.sh" ]]; then
    fail "D: _hydrate_ingest_failure_labels is not in $INSTALL"
else
    dout="$("$BASH_BIN" -c '
        set -Eeuo pipefail; trap "echo ERR_TRAP_FIRED" ERR
        source "$1"; source "$2"
        d="$(mktemp -d)"
        printf "food\n" > "$d/a"; _hydrate_ingest_failure_labels "$d/a"; echo "food=[$_HY_FAILED_LABELS] wa=$_HY_FAILED_WHATSAPP"
        printf "zz_new\n" > "$d/b"; _hydrate_ingest_failure_labels "$d/b"; echo "unknown=[$_HY_FAILED_LABELS] wa=$_HY_FAILED_WHATSAPP"
        printf "calendar\nwhatsapp\n" > "$d/c"; _hydrate_ingest_failure_labels "$d/c"; echo "two=[$_HY_FAILED_LABELS] wa=$_HY_FAILED_WHATSAPP"
        _hydrate_ingest_failure_labels "$d/missing"; echo "missing=[$_HY_FAILED_LABELS] wa=$_HY_FAILED_WHATSAPP"
        rm -rf "$d"' _ "$STRINGS" "$W/helper.sh" 2>&1)"
    echo "$dout" | sed 's/^/      | /'
    grep -q 'ERR_TRAP_FIRED' <<<"$dout" && fail "D: ERR trap fired in the helper"
    grep -qF 'food=[food and restaurant preferences] wa=false' <<<"$dout" || fail "D: food label"
    grep -qF 'unknown=[another source (zz_new)] wa=false' <<<"$dout" || fail "D: an unknown key is not counted under its own name"
    grep -qF 'two=[Calendar, WhatsApp] wa=true' <<<"$dout" || fail "D: two keys"
    grep -qF 'missing=[one or more sources (Ostler could not tell which)] wa=true' <<<"$dout" || fail "D: unreadable file is not CANNOT-TELL"
fi

new_strings="$(grep -E '^MSG_HYDRATE_(SOURCE_LABEL|INGEST_SOURCES|FOOD_DEFERRED)' "$STRINGS" || true)"
if grep -q $'\xe2\x80\x94' <<<"$new_strings"; then
    fail "an em dash in the new strings"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: food deferred off hydrate_graph; failures named by source ($BASH_BIN, $("$BASH_BIN" -c 'echo $BASH_VERSION'))"
[[ "$fails" -eq 0 ]] || echo "FAIL: $fails check(s)" >&2
exit $(( fails > 0 ? 1 : 0 ))
