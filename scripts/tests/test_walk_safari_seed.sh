#!/usr/bin/env bash
# test_walk_safari_seed.sh
# ============================================================================
# The walk plants a SYNTHETIC Safari History.db before install
# (scripts/lib_walk_safari_seed.sh, called from scripts/ttywalk.sh), so the walk
# covers the Safari reader instead of only excusing its absence.
#
# Proves, with HOME pointed at a scratch dir (no real account, no TCC call):
#   1. the generated fixture is read by the REAL vendored reader
#      (vendor/ostler_fda/safari_history.py) end to end: visits and domains
#      come back, and every URL is on a reserved example domain
#   2. seed on an empty account -> planted, marker says planted(visits=N)
#   3. a REAL History.db (no synthetic marker table) is left byte-identical
#   4. a previous synthetic fixture is replaced (idempotent across walks)
#   5. a refused plant (read-only Library) -> cannot-plant marker, not a claim
#   6. ttywalk.sh sources the lib and calls the apply BEFORE the RUN step
#   7. mutant: the real-history guard removed -> check 3 goes red
# bash 3.2; never touches a real keychain, TCC or the box.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
LIB="${ROOT}/scripts/lib_walk_safari_seed.sh"
GEN="${ROOT}/scripts/box_walk_probes/lib/safari_history_fixture.py"
TTY="${ROOT}/scripts/ttywalk.sh"
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t wsseed)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
FAILURES=""
note() { printf '  %s\n' "$1"; }
fail() { FAILURES="${FAILURES} $1"; printf '  FAIL [%s]: %s\n' "$1" "$2"; }

printf 'test_walk_safari_seed\n'
FX="${WORK}/fx.db"
python3 -I "$GEN" "$FX" >/dev/null || { echo "CANNOT-RUN: fixture generator failed" >&2; exit 2; }

# 1. the real reader reads it
R="$(cd "$ROOT/vendor" && python3 -I -c '
import sys; sys.path.insert(0, ".")
from pathlib import Path
from ostler_fda.safari_history import extract_history
e = extract_history(Path(sys.argv[1]))
doms = sorted({x.domain for x in e})
bad = [x.url for x in e if not x.domain.split(".")[-2:][0] == "example" and "example." not in x.domain]
print(len(e), len(doms), len(bad))
' "$FX" 2>&1)"
set -- $R
if [ "${1:-0}" -ge 10 ] 2>/dev/null && [ "${2:-0}" -ge 3 ] && [ "${3:-1}" = "0" ]; then note "1 real reader returns ${1} visits across ${2} domains, all reserved example domains ✅"
else fail reader "vendored reader on the fixture said '${R}', expected >=10 visits, >=3 domains, 0 non-example URLs"; fi

apply() { # $1 = HOME  $2 = lib
    HOME="$1" bash -c '. "$1"; walk_safari_seed_apply "$2"' _ "${2:-$LIB}" "$FX" 2>&1
}

# 2. empty account -> planted
H1="${WORK}/h1"; mkdir -p "$H1"
OUT="$(apply "$H1")"
if [ -s "$H1/Library/Safari/History.db" ] && grep -q '^planted(visits=[1-9]' "$H1/.walk-safari-seed-run"; then note "2 empty account -> planted, marker $(cat "$H1/.walk-safari-seed-run") ✅"
else fail plant "no plant on an empty account: ${OUT}; marker=$(cat "$H1/.walk-safari-seed-run" 2>/dev/null)"; fi

# 3. a REAL (marker-less) History.db is never overwritten
real_db() { rm -f "$1"; /usr/bin/sqlite3 "$1" 'create table history_items(id integer primary key, url text); insert into history_items values (1,"https://real-owner-placeholder.invalid/");'; }
H2="${WORK}/h2"; mkdir -p "$H2/Library/Safari"; real_db "$H2/Library/Safari/History.db"
SUM_BEFORE="$(shasum "$H2/Library/Safari/History.db" | cut -d' ' -f1)"
OUT="$(apply "$H2")"
if [ "$(shasum "$H2/Library/Safari/History.db" | cut -d' ' -f1)" = "$SUM_BEFORE" ] && grep -q '^skipped-real-history-present' "$H2/.walk-safari-seed-run"; then note "3 a real History.db is left byte-identical, marker skipped-real-history-present ✅"
else fail real-overwritten "a real History.db was touched or the marker is wrong: ${OUT}"; fi

# 4. an earlier synthetic fixture is replaced
OUT="$(apply "$H1")"
grep -q '^planted(visits=[1-9]' "$H1/.walk-safari-seed-run" && note "4 re-seed over its own earlier fixture -> planted again ✅" || fail replant "re-seed did not plant: ${OUT}"

# 5. a refused plant is recorded as cannot-plant, never as planted
H3="${WORK}/h3"; mkdir -p "$H3/Library"; chmod 555 "$H3/Library"
OUT="$(apply "$H3")"; chmod 755 "$H3/Library"
if grep -q '^cannot-plant:' "$H3/.walk-safari-seed-run" && ! grep -q planted "$H3/.walk-safari-seed-run"; then note "5 refused plant -> marker $(cut -c1-60 "$H3/.walk-safari-seed-run") ✅"
else fail refused "refused plant not recorded as cannot-plant: ${OUT}; marker=$(cat "$H3/.walk-safari-seed-run" 2>/dev/null)"; fi
if [ "$(id -u)" = "0" ]; then note "5 SKIPPED as root: chmod cannot refuse root (CANNOT-RUN, not a pass)"; fi

# 6. ttywalk wiring: sourced, called, and before the RUN step
LS="$(grep -n 'lib_walk_safari_seed.sh' "$TTY" | head -1 | cut -d: -f1)"
LA="$(grep -n 'walk_safari_seed_apply' "$TTY" | tail -1 | cut -d: -f1)"
LR="$(grep -n '^rule "RUN (unattended' "$TTY" | head -1 | cut -d: -f1)"
if [ -n "$LS" ] && [ -n "$LA" ] && [ -n "$LR" ] && [ "$LS" -lt "$LR" ] && [ "$LA" -lt "$LR" ]; then note "6 ttywalk.sh sources (line ${LS}) and calls (line ${LA}) the seed before RUN (line ${LR}) ✅"
else fail wiring "ttywalk.sh does not source+call the seed before RUN (source=${LS:-none} apply=${LA:-none} run=${LR:-none})"; fi

# 7. mutant: guard removed -> a real History.db IS overwritten (check 3 must go red)
MUT="${WORK}/mut_lib.sh"
sed 's/^        if \[ -z "\$n" \]; then$/        if false; then/' "$LIB" > "$MUT"
if cmp -s "$LIB" "$MUT"; then echo "CANNOT-RUN: mutant sed did not change the lib; the mutation target moved." >&2; exit 2; fi
H4="${WORK}/h4"; mkdir -p "$H4/Library/Safari"; real_db "$H4/Library/Safari/History.db"
S4="$(shasum "$H4/Library/Safari/History.db" | cut -d' ' -f1)"
apply "$H4" "$MUT" >/dev/null
if [ "$(shasum "$H4/Library/Safari/History.db" | cut -d' ' -f1)" != "$S4" ]; then note "7 MUTANT (real-history guard removed) overwrites a real History.db, so check 3 measures the guard ✅"
else fail mutant "the guard-less mutant did not overwrite a real History.db; check 3 proves nothing"; fi

echo
[ -n "$FAILURES" ] && { printf 'RESULT: FAILURES ->%s\n' "$FAILURES"; exit 1; }
printf 'RESULT: all arms passed\n'
