#!/usr/bin/env bash
# The install-time baseline compile holds the tick's own lock, so every job
# that recompiles the wiki waits for it.
#
# THE DEFECT (v1.0.117 thin walk, W6; Archie review of #3134 item 3). The
# installer's baseline compile ran WITHOUT ${OSTLER_DIR}/.wiki-recompile.lock.
# Four LaunchAgent jobs can start a compile mid-install: the daily recompile,
# the first-day catch-up, ostler-contact-resync and ostler-dedupe-catchup. A
# second compile rewrote the tree while install.sh counted it.
#
# WHAT THIS PINS
#   1. BEHAVIOUR of the real wiki_tick_lock_take (carved, executed): takes a
#      free lock and records its pid; waits on a LIVE holder and takes the
#      lock when it is released; reclaims a DEAD holder's lock; gives up
#      after its bounded wait (rc 1) rather than hanging the install.
#   2. ORDER in install.sh: take < baseline compile < page count < release.
#   3. SAME LOCK: the path install.sh takes is the path the tick checks.
#   4. EVERY RACER GOES THROUGH THE TICK: the daily plist, the catch-up, the
#      contact-resync and the dedupe-catchup wrappers each invoke
#      wiki-recompile-tick.sh, and none runs the compiler directly. That the
#      tick itself skips on a live holder is pinned behaviourally by
#      wiki-recompile/tests/test_wiki_recompile_tick.py::
#      test_mutex_skips_when_another_tick_holds_the_lock.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$REPO/install.sh}"
TICK_SH="$REPO/wiki-recompile/bin/wiki-recompile-tick.sh"
DAILY_PLIST="$REPO/wiki-recompile/launchd/com.creativemachines.ostler.wiki-recompile.plist"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
for f in "$INSTALL_SH" "$TICK_SH" "$DAILY_PLIST"; do [ -r "$f" ] || { echo "CANNOT-RUN: $f missing" >&2; exit 2; }; done

TMP="$(mktemp -d)"; HOLDER=""
cleanup() { [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# ── 1. behaviour of the real function ─────────────────────────────────────
awk '/^wiki_tick_lock_take\(\) \{/{p=1} p{print} p && /^\}/{exit}' "$INSTALL_SH" > "$TMP/fn.sh"
if ! grep -q 'mkdir "\$lock"' "$TMP/fn.sh"; then
    bad "install.sh has no wiki_tick_lock_take: the baseline compile takes no lock"
else
    run_take() {  # $1 lock dir -> rc
        OSTLER_WIKI_LOCK_WAIT_S="${2:-2}" OSTLER_WIKI_LOCK_POLL_S=1 /bin/bash -c '. "$1"; wiki_tick_lock_take "$2"' _ "$TMP/fn.sh" "$1"
    }
    L="$TMP/free.lock"
    run_take "$L"; rc=$?
    if [ "$rc" -eq 0 ] && [ -d "$L" ] && grep -Eq '^[0-9]+$' "$L/pid"; then ok "a free lock is taken and its pid recorded"; else bad "free lock: rc=$rc"; fi

    L="$TMP/live.lock"; mkdir "$L"; /bin/bash -c 'sleep 60' & HOLDER=$!; echo "$HOLDER" > "$L/pid"
    run_take "$L" 2; rc=$?
    if [ "$rc" -eq 1 ] && [ "$(cat "$L/pid")" = "$HOLDER" ]; then ok "a LIVE holder is waited on, bounded, and never stolen (rc 1)"; else bad "live holder: rc=$rc pid=$(cat "$L/pid" 2>/dev/null)"; fi

    ( sleep 1; rm -rf "$L" ) &
    run_take "$L" 10; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "$L/pid")" != "$HOLDER" ]; then ok "the lock is taken once the live holder releases it"; else bad "after release: rc=$rc"; fi
    kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; DEAD="$HOLDER"; HOLDER=""

    L="$TMP/dead.lock"; mkdir "$L"; echo "$DEAD" > "$L/pid"
    run_take "$L" 2; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "$L/pid")" != "$DEAD" ]; then ok "a DEAD holder's lock is reclaimed, so an aborted run cannot wedge it"; else bad "dead holder: rc=$rc"; fi
fi

# ── 2. order in install.sh ────────────────────────────────────────────────
ln() { /usr/bin/grep -n -- "$1" "$INSTALL_SH" | head -1 | cut -d: -f1; }
l_take="$(ln '^if wiki_tick_lock_take "\$WIKI_TICK_LOCK"; then')"
l_comp="$(ln 'OSTLER_WIKI_SKIP_LLM=1 wiki-compiler </dev/null 2>&1')"
l_count="$(ln 'wiki_count_pages "\$WIKI_DOCS_DIR"')"
l_rel="$(ln '    rm -rf "\$WIKI_TICK_LOCK"')"
if [ -n "$l_take" ] && [ -n "$l_comp" ] && [ -n "$l_count" ] && [ -n "$l_rel" ] \
   && [ "$l_take" -lt "$l_comp" ] && [ "$l_comp" -lt "$l_count" ] && [ "$l_count" -lt "$l_rel" ]; then
    ok "order: take ($l_take) < baseline compile ($l_comp) < count ($l_count) < release ($l_rel)"
else
    bad "order: take=${l_take:-none} compile=${l_comp:-none} count=${l_count:-none} release=${l_rel:-none}"
fi

# ── 3. the same lock ──────────────────────────────────────────────────────
if grep -q '^WIKI_TICK_LOCK="\${OSTLER_DIR}/.wiki-recompile.lock"$' "$INSTALL_SH" \
   && grep -q '^LOCK_DIR="\${OSTLER_DIR}/.wiki-recompile.lock"$' "$TICK_SH"; then
    ok "install.sh and the tick name the same lock: \${OSTLER_DIR}/.wiki-recompile.lock"
else
    bad "the installer's lock and the tick's lock are not the same path"
fi

# ── 4. every racer goes through the tick ──────────────────────────────────
carve() {  # $1 = opening line regex, $2 = heredoc terminator
    awk -v o="$1" -v t="$2" '$0 ~ o {p=1; next} p && $0 == t {exit} p' "$INSTALL_SH"
}
check_racer() {  # $1 label, $2 body
    local body="$2"
    if [ -z "$body" ]; then bad "$1: could not carve its wrapper"; return; fi
    if grep -Eq 'TICK"|wiki-recompile-tick\.sh' <<<"$body" && ! grep -Eq 'profile compile run|wiki-compiler' <<<"$(grep -v '^[[:space:]]*#' <<<"$body")"; then
        ok "$1 invokes the tick and never runs the compiler itself"
    else
        bad "$1 does not go through the tick (or runs the compiler directly)"
    fi
}
check_racer "first-day catch-up"   "$(carve 'bin/ostler-wiki-recompile-catchup" <<' 'WCUEOF')"
check_racer "contact-resync"       "$(carve 'bin/ostler-contact-resync" <<' 'CRSEOF')"
check_racer "dedupe-catchup"       "$(carve 'cat > "[$]wrapper" <<.DCUEOF.' 'DCUEOF')"
if grep -q 'wiki-recompile-tick.sh</string>' "$DAILY_PLIST"; then ok "the daily recompile agent runs the tick"; else bad "the daily recompile agent does not run the tick"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
