#!/usr/bin/env bash
# tests/test_fda_module_reachable.sh -- scripts/verify_fda_modules_reachable.py
#
# The gate exists because repair_placeholder_names.py is merged, tested, gated
# by its own workflow and PRESENT in the shipped DMG, and nothing calls it. A
# module with no caller reads as a shipped fix while doing nothing.
#
# A gate that compiles is not a gate. Every case below feeds a KNOWN-BAD tree
# and asserts the gate goes RED on it -- and, just as important, that it does
# NOT go red on the known-good one, because a gate that fails on everything
# says nothing either.
#
# The load-bearing case is COMMENT: a comment naming an orphan must not make it
# reachable. That is the #687 defect (a MENTION is not an INVOCATION) and the
# reason it recurs is that the work of draining this backlog IS writing
# comments that name the orphans being triaged.
#
# EXIT: 0 all assertions hold. 1 one or more failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON_BIN:-python3}"
GATE="$REPO/scripts/verify_fda_modules_reachable.py"
REGISTER="$REPO/scripts/fda_unwired_modules.tsv"

pass=0; fail=0
ok()  { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "ostler_fda reachability: a shipped module with no caller must be RED"
echo ""

[ -f "$GATE" ]     || { bad "gate script missing at $GATE";     printf '\033[0;31mRED\033[0m\n'; exit 1; }
[ -f "$REGISTER" ] || { bad "register missing at $REGISTER";    printf '\033[0;31mRED\033[0m\n'; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# A minimal synthetic tree, built rather than copied. The real repo is one of
# the cases below, but it cannot be the ONLY one: a gate can only be shown to
# fire by handing it something broken, and nothing in the real tree is broken
# on purpose.
#
# The shapes matter. extract_all imports apple_music from INSIDE a function,
# which is the case a top-level-import walk gets wrong, and install.sh names
# only extract_all, so apple_music is reachable transitively or not at all.
# ---------------------------------------------------------------------------
build_tree() {
    local root="$1"
    rm -rf "$root"
    mkdir -p "$root/vendor/ostler_fda" "$root/scripts"
    cp "$GATE" "$root/scripts/verify_fda_modules_reachable.py"
    : >"$root/vendor/ostler_fda/__init__.py"
    : >"$root/vendor/ostler_fda/apple_music.py"
    cat >"$root/vendor/ostler_fda/extract_all.py" <<'EOF'
def run():
    from .apple_music import extract_library
    return extract_library
EOF
    cat >"$root/install.sh" <<'EOF'
#!/usr/bin/env bash
"$PY" -m ostler_fda.extract_all
EOF
    printf '# columns: module\tblocked_by\tnote\n' >"$root/scripts/fda_unwired_modules.tsv"
}

run_gate() {
    "$PY" "$1/scripts/verify_fda_modules_reachable.py" "$1" 2>&1
    return $?
}

# --- 1. the known-GOOD synthetic tree ---------------------------------------
build_tree "$TMP/good"
out="$(run_gate "$TMP/good")"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "clean tree: rc=0"
else
    bad "clean tree went red (rc=$rc) -- a gate that fails on everything says nothing"
    printf '%s\n' "$out" | sed 's/^/      /'
fi
if printf '%s' "$out" | grep -q "positive control .*apple_music REACHABLE"; then
    ok "positive control: a FUNCTION-LOCAL import counts as reachable"
else
    bad "apple_music scored unreachable -- the walk cannot see function-local imports"
fi

# --- 2. a planted orphan must be RED ----------------------------------------
build_tree "$TMP/orphan"
: >"$TMP/orphan/vendor/ostler_fda/zz_probe_orphan.py"
out="$(run_gate "$TMP/orphan")"; rc=$?
if [ "$rc" -eq 1 ]; then
    ok "a module nothing calls: rc=1"
else
    bad "planted orphan did NOT fail the gate (rc=$rc) -- the gate is blind"
fi
if printf '%s' "$out" | grep -q "zz_probe_orphan"; then
    ok "the failing output NAMES the orphan"
else
    bad "the gate failed without naming what it failed on"
fi

# --- 3. THE #687 CASE: a comment naming it must not rescue it ---------------
build_tree "$TMP/comment"
: >"$TMP/comment/vendor/ostler_fda/zz_probe_orphan.py"
printf '# TODO wire ostler_fda.zz_probe_orphan one day\n' >>"$TMP/comment/install.sh"
out="$(run_gate "$TMP/comment")"; rc=$?
if [ "$rc" -eq 1 ]; then
    ok "a MENTION is not an INVOCATION: comment-only reference still rc=1"
else
    bad "a comment naming the module marked it reachable (rc=$rc) -- this is #687 again"
fi

# --- 4. control for case 3: a REAL caller must rescue it --------------------
# Without this, case 3 proves only that the gate ignores install.sh entirely.
build_tree "$TMP/caller"
: >"$TMP/caller/vendor/ostler_fda/zz_probe_orphan.py"
printf '"$PY" -m ostler_fda.zz_probe_orphan\n' >>"$TMP/caller/install.sh"
out="$(run_gate "$TMP/caller")"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "control: the SAME module with a real caller passes"
else
    bad "a genuinely-called module still failed (rc=$rc) -- case 3 proved nothing"
fi

# --- 5. a register row silences it, and only by name ------------------------
build_tree "$TMP/registered"
: >"$TMP/registered/vendor/ostler_fda/zz_probe_orphan.py"
printf 'zz_probe_orphan\tsynthetic\tprobe row\n' >>"$TMP/registered/scripts/fda_unwired_modules.tsv"
out="$(run_gate "$TMP/registered")"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "a recorded orphan passes, and the register prints in full"
else
    bad "a recorded orphan still failed (rc=$rc)"
fi
if printf '%s' "$out" | grep -q "zz_probe_orphan"; then
    ok "the recorded orphan is PRINTED, not silently swallowed"
else
    bad "the register row passed silently -- that is a warn bucket"
fi

# --- 6. a missing register is CANNOT RUN, never a pass ----------------------
build_tree "$TMP/noreg"
rm -f "$TMP/noreg/scripts/fda_unwired_modules.tsv"
out="$(run_gate "$TMP/noreg")"; rc=$?
if [ "$rc" -eq 2 ]; then
    ok "missing register: rc=2 CANNOT RUN, not a green"
else
    bad "a deleted register scored rc=$rc -- deleting the backlog would read as clean"
fi

# --- 7. an empty package is CANNOT RUN. A zero denominator reads as success -
build_tree "$TMP/empty"
rm -f "$TMP/empty"/vendor/ostler_fda/*.py
out="$(run_gate "$TMP/empty")"; rc=$?
if [ "$rc" -eq 2 ]; then
    ok "no modules to examine: rc=2, not 'zero orphans'"
else
    bad "an empty package scored rc=$rc -- 0 failures over 0 items is not clean"
fi

# --- 8. an empty shipping surface is CANNOT RUN, not 'everything is orphaned'
build_tree "$TMP/nosurface"
rm -f "$TMP/nosurface/install.sh"
out="$(run_gate "$TMP/nosurface")"; rc=$?
if [ "$rc" -eq 2 ]; then
    ok "nothing to search: rc=2, not a mass false accusation"
else
    bad "an empty surface scored rc=$rc -- every module would be a false orphan"
fi

# --- 9. a broken predicate must REFUSE, not accuse --------------------------
# Sever the only edge to apple_music. The census must notice that its own
# control failed and exit 2, rather than confidently reporting a module that
# runs on every install as dead.
build_tree "$TMP/blind"
cat >"$TMP/blind/vendor/ostler_fda/extract_all.py" <<'EOF'
def run():
    return None
EOF
out="$(run_gate "$TMP/blind")"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "positive control FAILED"; then
    ok "control broken: the census REFUSES (rc=2) instead of naming false orphans"
else
    bad "with its control severed the census answered anyway (rc=$rc)"
fi

# --- 10. the real repo ------------------------------------------------------
out="$(run_gate "$REPO")"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "this repo: rc=0, every module reachable or recorded"
else
    bad "this repo is RED (rc=$rc) -- a module ships that can never run"
    printf '%s\n' "$out" | sed 's/^/      /'
fi
if printf '%s' "$out" | grep -q "repair_placeholder_names"; then
    ok "the D658/D659 repair pass is on the record as unreachable"
else
    bad "repair_placeholder_names is not named -- the finding has gone quiet"
fi

echo ""
if [ "$fail" -eq 0 ]; then
    printf '\033[0;32mGREEN -- %d assertion(s); a shipped module with no caller is RED\033[0m\n' "$pass"
    exit 0
fi
printf '\033[0;31mRED -- %d of %d assertion(s) failed\033[0m\n' "$fail" "$((pass + fail))"
exit 1
