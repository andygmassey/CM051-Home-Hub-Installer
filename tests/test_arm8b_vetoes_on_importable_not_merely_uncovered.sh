#!/usr/bin/env bash
# walk_dmg.sh arm 8b must veto on "uncovered AND importable", not on "uncovered".
#
# THE DEFECT. A .pyc is only ever written for a module that is IMPORTED.
# CPython never caches bytecode for the script it runs as __main__. Measured on
# the pinned interpreter that ships (3.11.15, cache_tag cpython-311), control
# firing in the same run:
#
#     a module that is IMPORTED  -> __pycache__/x.cpython-311.pyc appears
#     a script run as __main__   -> nothing is written, ever
#
# Arm 8b counted every uncovered .py. That over-approximates the hazard, and
# arm 8b is a VETO arm, so over-approximating BLOCKS A GOOD CUT.
#
# It already would have. On v1.0.47 with the #1095 and #1096 seeds applied, the
# one remaining uncovered file is mark_first_ingest.py in the daemon's own
# bundle, which tick.sh:185 runs BY PATH as __main__ and nothing imports. It
# cannot write a .pyc. It is also not ours to seed: gui/Makefile:1230 ditto's
# that bundle in already signed and :1253 verifies its Developer ID, so writing
# into it would break the seal that check reads.
#
# WHAT THIS TEST DOES. It extracts arm 8b's counter from walk_dmg.sh and runs it
# against fixtures, then MUTATES each clause of the exemption and requires the
# matching fixture to flip. Every mutation is diffed first: a mutation that did
# not apply is reported as a broken apparatus, never as a pass. This test was
# written after a sed pattern with a trailing space silently mutated nothing and
# printed a clean "not caught".

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WALK="$REPO_ROOT/scripts/walk_dmg.sh"
FAILED=0

fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

if [[ ! -f "$WALK" ]]; then
    echo "FAIL [walk-missing]: $WALK not found -- nothing was checked. NOT a pass." >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COUNTER="$WORK/counter.py"

# ---- extract arm 8b's counter ---------------------------------------------
A=$(grep -n 'COVER_OUT=\$(' "$WALK" | head -1 | cut -d: -f1)
if [[ -z "$A" ]]; then
    echo "FAIL [no-counter]: no COVER_OUT heredoc in walk_dmg.sh -- arm 8b is not shaped as this test expects. NOT a pass." >&2
    exit 2
fi
B=$(awk -v a="$A" 'NR>a && $0=="COVER"{print NR; exit}' "$WALK")
if [[ -z "$B" ]]; then
    echo "FAIL [no-terminator]: COVER heredoc never closes. NOT a pass." >&2
    exit 2
fi
sed -n "$((A+1)),$((B-1))p" "$WALK" > "$COUNTER"
if [[ ! -s "$COUNTER" ]]; then
    echo "FAIL [empty-extract]: extracted 0 bytes of counter -- every arm below would print nothing and read as a pass. NOT a pass." >&2
    exit 2
fi
python3 -c "compile(open('$COUNTER').read(),'c','exec')" \
    || { echo "FAIL [counter-syntax]: extracted counter does not compile." >&2; exit 2; }
pass "extracted arm 8b's counter ($(wc -l < "$COUNTER" | tr -d ' ') lines) and it compiles"

# ---- fixtures --------------------------------------------------------------
mkfix() {
    local R="$1"; rm -rf "$R"
    mkdir -p "$R/app/Contents/Resources/ingest/email-ingest" \
             "$R/app/Contents/Resources/lib/__pycache__"
    cat > "$R/app/Contents/Resources/ingest/email-ingest/mark_first_ingest.py" <<'PYEOF'
import sys
def main(argv): return 0
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF
    cat > "$R/app/Contents/Resources/ingest/email-ingest/tick.sh" <<'SHEOF'
"$OSTLER_PYTHON" "$SCRIPT_DIR_REAL/mark_first_ingest.py" --sidecar "$SIDECAR"
SHEOF
    printf 'X = 1\n' > "$R/app/Contents/Resources/lib/helper.py"
    printf 'fake\n'   > "$R/app/Contents/Resources/lib/__pycache__/helper.cpython-311.pyc"
}

hazard() { python3 "${2:-$COUNTER}" "$1/app" 2>/dev/null | awk '{print $4}'; }
exempt() { python3 "${2:-$COUNTER}" "$1/app" 2>/dev/null | awk '{print $3}'; }

mkfix "$WORK/A"
mkfix "$WORK/B"; printf 'Y = 2\n' > "$WORK/B/app/Contents/Resources/lib/plain_module.py"
mkfix "$WORK/C"; printf 'import sys\nif __name__ == "__main__":\n    sys.exit(0)\n' \
                     > "$WORK/C/app/Contents/Resources/lib/__init__.py"
mkfix "$WORK/D"; printf 'import mark_first_ingest\n' >> "$WORK/D/app/Contents/Resources/lib/helper.py"
mkfix "$WORK/E"; printf 'python3 -c "import mark_first_ingest"\n' \
                     >> "$WORK/E/app/Contents/Resources/ingest/email-ingest/tick.sh"

# ---- 1. the real shape must NOT veto --------------------------------------
if [[ "$(hazard "$WORK/A")" == "0" && "$(exempt "$WORK/A")" == "1" ]]; then
    pass "a __main__-only helper nothing imports is exempt, not a veto"
else
    fail "false-veto" "the real v1.0.47 shape reports hazard=$(hazard "$WORK/A") exempt=$(exempt "$WORK/A"); expected 0 and 1. Arm 8b would block a good cut."
fi

# ---- 2. every genuinely importable uncovered file MUST veto ---------------
for arm in B:"an importable module with no __main__ guard" \
           C:"a package __init__.py, even with a __main__ guard" \
           D:"a helper another .py imports by name" \
           E:"a helper a .sh imports by name"; do
    k="${arm%%:*}"; desc="${arm#*:}"
    if [[ "$(hazard "$WORK/$k")" != "0" ]]; then
        pass "vetoes on $desc"
    else
        fail "missed-hazard-$k" "$desc did not veto (hazard=$(hazard "$WORK/$k")) -- an unguarded import would write into the seal"
    fi
done

# ---- 3. every clause of the exemption must be load-bearing ----------------
# A mutation is only evidence if it ACTUALLY changed the file.
mutate_and_check() {
    local label="$1" pattern="$2" fixture="$3"
    local mut="$WORK/mut.py"
    sed "$pattern" "$COUNTER" > "$mut"
    if diff -q "$COUNTER" "$mut" >/dev/null; then
        fail "mutation-inert-$label" "the '$label' mutation changed nothing -- the pattern does not match the source, so this proves NOTHING about the clause"
        return
    fi
    if [[ "$(hazard "$WORK/$fixture" "$mut")" == "0" ]]; then
        pass "clause '$label' is load-bearing (removing it lets fixture $fixture through)"
    else
        fail "clause-dead-$label" "removing '$label' did not change fixture $fixture's verdict -- the clause is not what catches it, so the exemption is not doing what the comment claims"
    fi
}

mutate_and_check "not named_by_py"    's|and not named_by_py ||'          D
mutate_and_check "not named_by_sh"    's|and not named_by_sh:|:|'         E
mutate_and_check "is_main"            's|and is_main ||'                  B
mutate_and_check 'f != "__init__.py"' 's|f != "__init__.py" and ||'       C

# ---- 4. the veto must read the hazard count, not the raw uncovered count --
if grep -qE 'say "FAIL".*VETO\..*\$UNCOVERED_N .py in the bundle' "$WALK"; then
    fail "vetoes-on-uncovered" "arm 8b still vetoes on \$UNCOVERED_N; it must veto on \$HAZARD_N or it blocks good cuts"
else
    pass "arm 8b's veto reads the hazard count, not the raw uncovered count"
fi

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi
echo
echo "ALL ARM 8B IMPORTABILITY TESTS PASSED"
