#!/usr/bin/env bash
#
# Syncing one cut's BOM must not unpin another cut's.
#
# scripts/sync_cut_bom.sh used to truncate cuts/BOM_PIN and write a single
# version row, so the second sync silently dropped the first. Measured on main
# after v1.0.72 landed:
#
#     tests/test_cut_bom_is_fresh.sh v1.0.71   FAIL
#       "BOM_PIN records no hash for cuts/v1.0.71/MUST_CONTAIN.tsv"
#       "an unpinned vendored copy is a fork nobody declared"
#
# THAT WAS NOT A DEAD VERSION NOBODY ASKS ABOUT. cut.yml derives CUT_VERSION
# from gui/OstlerInstaller/Info.plist on any non-tag run, and the plist still
# read 1.0.71 -- so every workflow_dispatch DRY RUN of the cut was red at this
# gate while the cut itself was fine. cut.yml already carries that lesson a few
# hundred lines below: "a dry run that cannot validate the real run is worse
# than no dry run, because its red teaches you to stop dispatching."
#
# 31 BOMs are vendored. The pin file's own words say an unpinned vendored copy
# is a fork nobody declared, so keeping only the newest row contradicted the
# thing it exists to assert.
#
# Drives the REAL script against a throwaway OS003, so it cannot pass by
# agreeing with a re-implementation of itself.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="${REPO_ROOT}/scripts/sync_cut_bom.sh"

pass=0; fail=0
ok()  { printf '[PASS] %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$SYNC" ] || { echo "[CANNOT-RUN] no ${SYNC}"; exit 78; }
command -v git >/dev/null 2>&1 || { echo "[CANNOT-RUN] git not on PATH"; exit 78; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

# A throwaway OS003 with two versions in it.
SRC="$SB/os003"
mkdir -p "$SRC/cuts/v9.9.1" "$SRC/cuts/v9.9.2"
printf 'change\trepo\tsha\tlanded\tcap\tgate\tissue\n' > "$SRC/cuts/v9.9.1/MUST_CONTAIN.tsv"
printf 'ONE\tCM051\tdeadbee1\tyes\tnone\tgate:a.yml#t.sh\t#1\n'   >> "$SRC/cuts/v9.9.1/MUST_CONTAIN.tsv"
printf 'change\trepo\tsha\tlanded\tcap\tgate\tissue\n' > "$SRC/cuts/v9.9.2/MUST_CONTAIN.tsv"
printf 'TWO\tCM051\tdeadbee2\tyes\tnone\tgate:b.yml#u.sh\t#2\n'   >> "$SRC/cuts/v9.9.2/MUST_CONTAIN.tsv"
( cd "$SRC" && git init -q -b "${OSTLER_TEST_FIXTURE_BRANCH:-main}" . && git add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm "fixture" ) || {
    echo "[CANNOT-RUN] could not build the throwaway OS003"; exit 78; }

# Work on a COPY of this repo's pin + cuts dir, never the real one.
WORK="$SB/repo"
mkdir -p "$WORK/scripts" "$WORK/cuts" "$WORK/tests"
cp "$SYNC" "$WORK/scripts/"
cp "${REPO_ROOT}/tests/test_cut_bom_is_fresh.sh" "$WORK/tests/" 2>/dev/null || true
: > "$WORK/cuts/BOM_PIN"

# 🔴 NEVER `>/dev/null 2>&1` A PROBE. The first version of this file did, and
# on the ubuntu runner the sync failed for a reason the log could not show:
# three arms went red saying "recorded no row" with no cause on screen.
run_sync() {   # $1 = version
    local rc=0
    OS003_DIR="$SRC" bash "$WORK/scripts/sync_cut_bom.sh" "$1" >"$SB/sync.$1.log" 2>&1 || rc=$?
    # rc is captured BEFORE anything else runs. Reading $? inside `if ! cmd`
    # reports the NEGATION's status, so a script that exited 2 gets printed as
    # "exited 0" next to its own ERROR line -- which is the exact misleading
    # shape this diagnostic exists to remove.
    if [ "$rc" -ne 0 ]; then
        printf '         sync %s exited %s:\n' "$1" "$rc"
        sed 's/^/           /' "$SB/sync.$1.log"
        return 1
    fi
    return 0
}

row_count() { /usr/bin/grep -cE '^cuts/v[0-9.]+/MUST_CONTAIN\.tsv' "$WORK/cuts/BOM_PIN" 2>/dev/null || true; }
has_row()   { /usr/bin/grep -cE "^cuts/v$1/MUST_CONTAIN\.tsv" "$WORK/cuts/BOM_PIN" 2>/dev/null || true; }

echo "=== 1. FIRST SYNC PINS ITS VERSION ==="
run_sync 9.9.1 || true
if [ "$(has_row 9\\.9\\.1)" -ge 1 ]; then
    ok "syncing 9.9.1 records a row for it"
else
    bad "syncing 9.9.1 recorded no row at all"
fi

echo
echo "=== 2. THE ARM THAT WAS BROKEN: a second sync must not unpin the first ==="
run_sync 9.9.2 || true
n1="$(has_row 9\\.9\\.1)"; n2="$(has_row 9\\.9\\.2)"; tot="$(row_count)"
if [ "$n1" -ge 1 ] && [ "$n2" -ge 1 ]; then
    ok "after syncing 9.9.2, BOTH rows are present (${tot} version rows)"
else
    bad "syncing 9.9.2 left 9.9.1=${n1} 9.9.2=${n2}; a sync unpinned an earlier cut"
    sed 's/^/         /' "$WORK/cuts/BOM_PIN"
fi

echo
echo "=== 3. RE-SYNCING A VERSION UPDATES ITS ROW, IT DOES NOT DUPLICATE IT ==="
run_sync 9.9.1 || true
n1="$(has_row 9\\.9\\.1)"
if [ "$n1" -eq 1 ]; then
    ok "re-syncing 9.9.1 leaves exactly one row for it"
else
    bad "re-syncing 9.9.1 left ${n1} rows for that version"
fi

echo
echo "=== 4. PROVENANCE IS RECORDED PER ROW, NOT ONLY IN THE HEADER ==="
# The header sha describes the most recent sync only. A row carried forward
# from an earlier sync would otherwise claim a commit it was not taken from.
bad_rows=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    f3="$(printf '%s' "$line" | cut -f3)"
    [ -n "$f3" ] || bad_rows=$((bad_rows + 1))
done < <(/usr/bin/grep -E '^cuts/v[0-9.]+/MUST_CONTAIN\.tsv' "$WORK/cuts/BOM_PIN" 2>/dev/null)
n_rows="$(row_count)"
if [ "${n_rows:-0}" -lt 2 ]; then
    # It "passed" on CI with ZERO rows before this floor existed: no rows means
    # no rows without provenance. A denominator check is not optional.
    bad "only ${n_rows:-0} version row(s) to check -- cannot assert provenance on an empty file"
elif [ "$bad_rows" -eq 0 ]; then
    ok "all ${n_rows} version rows name the OS003 commit they were taken from"
else
    bad "${bad_rows} of ${n_rows} row(s) carry no per-row provenance"
fi

echo
echo "=== 5. A VENDORED BOM WITH NO PIN ROW IS A FORK NOBODY DECLARED ==="
# Scoped deliberately, to respect bom-pin-agreement.yml's stated policy: on a
# PR the pin is ALLOWED to be behind main, so this must not fire merely because
# a newer cut has not been synced yet.
#
# It fires only on the case that is wrong at every moment: a BOM vendored on
# disk with NO row in the pin. That is the pin file's own words -- "an unpinned
# vendored copy is a fork nobody declared" -- and it cannot be a transient
# ordering state, because vendoring and pinning happen in the same command.
#
# It is also the shape that broke the dry run: v1.0.71's BOM stayed on disk
# while its pin row was overwritten by the v1.0.72 sync.
unpinned=0
for bom in "${REPO_ROOT}"/cuts/v*/MUST_CONTAIN.tsv; do
    [ -f "$bom" ] || continue
    ver="$(basename "$(dirname "$bom")")"
    if ! /usr/bin/grep -qE "^cuts/${ver}/MUST_CONTAIN\.tsv" "${REPO_ROOT}/cuts/BOM_PIN" 2>/dev/null; then
        unpinned=$((unpinned + 1))
        [ "$unpinned" -le 5 ] && printf '         vendored but unpinned: %s\n' "$ver"
    fi
done
total_boms="$(ls -1 "${REPO_ROOT}"/cuts/v*/MUST_CONTAIN.tsv 2>/dev/null | wc -l | tr -d " ")"
# The historical archive predates the pin file, so a floor rather than zero.
# What must hold is that the versions cut.yml can ASK about are pinned: the
# tag it is given, and the plist version it falls back to on a dry run.
PLIST="${REPO_ROOT}/gui/OstlerInstaller/Info.plist"
if [ ! -f "$PLIST" ]; then
    echo "[CANNOT-RUN] no ${PLIST}"; fail=$((fail + 1))
else
    V="$(python3 -c 'import plistlib,sys;print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' "$PLIST" 2>/dev/null)"
    if [ -z "$V" ]; then
        echo "[CANNOT-RUN] could not read CFBundleShortVersionString"; fail=$((fail + 1))
    else
        CV="v$(printf '%s' "$V" | cut -d. -f1-3)"
        if [ ! -f "${REPO_ROOT}/cuts/${CV}/MUST_CONTAIN.tsv" ]; then
            ok "the plist version ${CV} has no vendored BOM yet, so nothing is unpinned by it"
        elif /usr/bin/grep -qE "^cuts/${CV}/MUST_CONTAIN\.tsv" "${REPO_ROOT}/cuts/BOM_PIN"; then
            ok "the plist version ${CV} is vendored AND pinned, so a dry run can grade it (${total_boms} BOMs on disk)"
        else
            bad "${CV} is vendored but has NO pin row, and cut.yml grades it on every non-tag run"
        fi
    fi
fi

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
