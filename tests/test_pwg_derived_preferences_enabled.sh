#!/usr/bin/env bash
# tests/test_pwg_derived_preferences_enabled.sh
# ============================================================================
# THE DEFECT (walk 132, dislike_respected_in_brief: the brief named 0 of 30
# served liked labels). The assistant's [pwg_derived_preferences] reader is
# off by default and install.sh never wrote the table, so the derived graph
# was built and never read.
#
# THE FIX under test: _ostler_ensure_pwg_derived_enabled in install.sh, run on
# config.toml after the regenerate. Three shapes, each parsed by python tomllib
# (a real TOML parser, not a grep):
#   A  fresh config (no table)                    -> table added, enabled = true
#   B  existing table with enabled = false        -> key edited IN PLACE, no
#                                                    second table (TOML error if
#                                                    it were appended)
#   C  existing table with other keys             -> enabled = true, every other
#                                                    key preserved verbatim
# plus idempotence (run twice = same bytes) and a missing file (fails, no write).
#
# CONTROL: the function is extracted from install.sh by range, so the test
# cannot pass against a copy of the logic. If the function is absent the
# extraction is empty and the test is RED.
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/derived-prefs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }

# 1. extract the shipped function body from install.sh
FN="$WORK/fn.sh"
awk '
    /^_ostler_ensure_pwg_derived_enabled\(\) \{/ { on = 1 }
    on { print }
    on && /^\}/ { exit }
' "$INSTALL" > "$FN"
if [[ -s "$FN" ]] && grep -q '^_ostler_ensure_pwg_derived_enabled() {' "$FN"; then
    ok "extracted _ostler_ensure_pwg_derived_enabled from install.sh ($(wc -l < "$FN" | tr -d ' ') lines)"
else
    bad "function not found in install.sh (extracted $(wc -l < "$FN" | tr -d ' ') lines)"
    echo "RESULT: 0 passed, 1 failed"; exit 1
fi

# 2. the call site exists on the regenerate path (wired, not just defined)
if grep -q '^_ostler_ensure_pwg_derived_enabled "\$ASSISTANT_CONFIG"' "$INSTALL"; then
    ok "call site present: _ostler_ensure_pwg_derived_enabled \"\$ASSISTANT_CONFIG\""
else
    bad "no call site for _ostler_ensure_pwg_derived_enabled on \$ASSISTANT_CONFIG"
fi

# shellcheck disable=SC1090
source "$FN"

check_toml() {  # $1 = config path, $2 = label, $3 = expected python predicate on dict d
    local out
    out="$(python3 -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f)
ok = eval(sys.argv[2], {"d": d})
print("parsed" if ok else "WRONG")
' "$1" "$3" 2>&1)" || { bad "$2: tomllib refused the file: $out"; return; }
    if [[ "$out" == "parsed" ]]; then ok "$2: tomllib parses and predicate holds"; else bad "$2: predicate failed"; fi
}

# ── Shape A: fresh config, no table ─────────────────────────────────────────
A="$WORK/A.toml"
printf '[memory]\nbackend = "sqlite"\n\n[security.sandbox]\nenabled = true\n' > "$A"
_ostler_ensure_pwg_derived_enabled "$A" && ok "A: function returned 0" || bad "A: function returned non-zero"
check_toml "$A" "A fresh" \
  'd["pwg_derived_preferences"]["enabled"] is True and d["memory"]["backend"] == "sqlite" and d["security"]["sandbox"]["enabled"] is True'

# ── Shape B: existing table, enabled = false (the Mini16 shape) ─────────────
B="$WORK/B.toml"
printf '[memory]\nbackend = "sqlite"\n\n[pwg_derived_preferences]\nenabled = false\n\n[security.sandbox]\nenabled = true\n' > "$B"
_ostler_ensure_pwg_derived_enabled "$B" && ok "B: function returned 0" || bad "B: function returned non-zero"
check_toml "$B" "B existing enabled=false" \
  'd["pwg_derived_preferences"]["enabled"] is True and d["security"]["sandbox"]["enabled"] is True'
n_hdr=$(grep -c '^\[pwg_derived_preferences\]' "$B")
[[ "$n_hdr" == 1 ]] && ok "B: exactly one [pwg_derived_preferences] header ($n_hdr)" || bad "B: header count $n_hdr"

# ── Shape C: existing table with other keys, table is LAST in the file ─────
C="$WORK/C.toml"
printf '[memory]\nbackend = "sqlite"\n\n[pwg_derived_preferences]\nmin_weight = 0.25\nenabled = false  # operator note\nmax_items = 30\n' > "$C"
_ostler_ensure_pwg_derived_enabled "$C" && ok "C: function returned 0" || bad "C: function returned non-zero"
check_toml "$C" "C other keys kept" \
  'd["pwg_derived_preferences"]["enabled"] is True and d["pwg_derived_preferences"]["min_weight"] == 0.25 and d["pwg_derived_preferences"]["max_items"] == 30'

# ── Idempotence: a second run leaves identical bytes ───────────────────────
for f in "$A" "$B" "$C"; do
    cp "$f" "$f.run1"; _ostler_ensure_pwg_derived_enabled "$f"
    cmp -s "$f" "$f.run1" && ok "idempotent: $(basename "$f")" || bad "second run changed $(basename "$f")"
done

# ── Negative control: a missing file fails and writes nothing ──────────────
if _ostler_ensure_pwg_derived_enabled "$WORK/absent.toml"; then
    bad "missing file returned 0"
else
    [[ -e "$WORK/absent.toml" ]] && bad "missing file was created" || ok "missing file: non-zero, nothing created"
fi

# ── No stray temp files left beside the config ─────────────────────────────
stray=$(find "$WORK" -maxdepth 1 -name '*.derived.*' | wc -l | tr -d ' ')
[[ "$stray" == 0 ]] && ok "no stray .derived.* temp files" || bad "stray temp files: $stray"

echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
