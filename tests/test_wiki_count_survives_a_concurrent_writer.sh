#!/usr/bin/env bash
# A find ERROR during the wiki page count is "could not count", never "zero".
#
# THE DEFECT (v1.0.117 thin walk, W6). install.sh counted wiki pages with
# `find | wc -l | tr` under pipefail and `|| WIKI_PAGE_COUNT=""`, then read
# the empty value as 0. The first-day catch-up agent's tick ran a second
# compile in parallel, its Obsidian rewrite removed a directory while find
# walked the tree, find exited 1, and the installer said the compile
# "produced ZERO pages" and set HEALTHY=false on a wiki that had pages.
#
# WHAT THIS DOES. It carves the REAL count block out of install.sh (from the
# WIKI_DOCS_DIR assignment to the gui_step_record_rc line) and executes it
# under the installer's own `set -Eeuo pipefail` with an ERR trap armed, with
# the compiler having reported rc 0, in three shapes:
#
#   A. RACE: a real concurrent writer creates and deletes directory trees
#      under the wiki while the block counts it, over many iterations. A
#      `find` shim (execs the system find, records its rc) proves the race
#      was actually hit; if it never was, this limb is CANNOT-RUN, not PASS.
#   B. DETERMINISTIC: a `find` that lists some pages and exits 1 with ENOENT,
#      every time. The block must not say ZERO and must not set HEALTHY=false.
#   C. CONTROL: a genuinely empty tree (directories, no files) with a working
#      find MUST still say ZERO pages and set HEALTHY=false. Without this, a
#      fix that silenced the zero check entirely would pass A and B.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$REPO/install.sh}"
RACE_ITERS="${RACE_ITERS:-400}"   # cap; the loop stops early once 3 find errors are seen
PASS=0; FAIL=0; CANNOT=0
ok()     { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()    { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
cannot() { printf '  CANNOT-RUN  %s\n' "$1"; CANNOT=$((CANNOT+1)); }

[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: no install.sh at $INSTALL_SH" >&2; exit 2; }
REAL_FIND="$(PATH=/usr/bin:/bin command -v find)"
[ -n "$REAL_FIND" ] || { echo "CANNOT-RUN: no system find" >&2; exit 2; }

TMP="$(mktemp -d)"; WRITER=""
cleanup() { [ -n "$WRITER" ] && kill "$WRITER" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

awk '/^WIKI_DOCS_DIR="\$\{OSTLER_WIKI_DIR/{p=1} /^gui_step_record_rc "\$\{WIKI_BASELINE_RC/{exit} p' \
    "$INSTALL_SH" > "$TMP/block.sh"
n_lines="$(wc -l < "$TMP/block.sh" | tr -d ' ')"
if [ "$n_lines" -lt 5 ] || ! grep -q 'ZERO pages' "$TMP/block.sh"; then
    echo "CANNOT-RUN: could not carve the wiki count block ($n_lines lines)" >&2; exit 2
fi
printf '  carved count block: %s lines\n' "$n_lines"

# The harness the block runs in: the installer's shell options, an armed
# ERR trap, and stubs for the two log functions it calls.
cat > "$TMP/run.sh" <<'EOF'
set -Eeuo pipefail
trap 'echo "ERR-TRAP-FIRED line $LINENO" >&2; exit 97' ERR
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
HEALTHY=true
WIKI_BASELINE_RC=0
. "$1"
printf 'RESULT HEALTHY=%s RC=%s\n' "$HEALTHY" "$WIKI_BASELINE_RC"
EOF

# find shim: run the real find, record its rc, pass everything through.
mkdir -p "$TMP/shim"
cat > "$TMP/shim/find" <<EOF
#!/bin/bash
"$REAL_FIND" "\$@"; rc=\$?
echo "\$rc" >> "$TMP/find_rcs"
exit \$rc
EOF
chmod +x "$TMP/shim/find"

run_block() {  # $1 = wiki dir, $2 = PATH prefix
    OSTLER_WIKI_DIR="$1" OSTLER_WIKI_COUNT_RETRY_S=0 PATH="$2:/usr/bin:/bin" \
        /bin/bash "$TMP/run.sh" "$TMP/block.sh" 2>&1
}

judge_healthy() {  # $1 = output, $2 = label
    if grep -q 'ERR-TRAP-FIRED' <<<"$1"; then bad "$2: the ERR trap fired during the count (install.sh runs set -E, so the installer's _ostler_on_err sees a failure)"; return; fi
    if grep -q 'ZERO pages' <<<"$1"; then bad "$2: a wiki with pages was reported as ZERO pages"; return; fi
    if ! grep -q 'RESULT HEALTHY=true RC=0' <<<"$1"; then bad "$2: HEALTHY/RC flipped: $(grep RESULT <<<"$1")"; return; fi
    ok "$2"
}

# ── A. RACE with a real concurrent writer ─────────────────────────────────
W="$TMP/wiki"; mkdir -p "$W"
for i in $(seq 1 40); do mkdir -p "$W/People/p$i"; : > "$W/People/p$i/Sam Doe $i.md"; done
(
    k=0
    while :; do
        k=$((k+1)); mkdir -p "$W/t$k"
        for j in $(seq 1 30); do mkdir -p "$W/t$k/d$j"; : > "$W/t$k/d$j/Jane Smith.md"; done
        rm -rf "$W/t$((k-1))"
    done
) & WRITER=$!
sleep 0.3
race_bad=""; : > "$TMP/find_rcs"
for n in $(seq 1 "$RACE_ITERS"); do
    out="$(run_block "$W" "$TMP/shim")"
    if grep -q 'ZERO pages\|ERR-TRAP-FIRED' <<<"$out" || ! grep -q 'RESULT HEALTHY=true RC=0' <<<"$out"; then
        race_bad="$out"; break
    fi
    [ "$(grep -vc '^0$' "$TMP/find_rcs" || true)" -ge 3 ] && break
done
kill "$WRITER" 2>/dev/null; wait "$WRITER" 2>/dev/null; WRITER=""
n_find="$(wc -l < "$TMP/find_rcs" | tr -d ' ')"
n_err="$(grep -vc '^0$' "$TMP/find_rcs" || true)"
printf '  race: %s find calls, %s exited non-zero under the concurrent writer\n' "$n_find" "$n_err"
if [ -n "$race_bad" ]; then
    bad "RACE: a concurrent writer turned the count into a failure: $(grep -E 'WARN|RESULT|ERR' <<<"$race_bad" | head -2 | tr '\n' ' ')"
elif [ "$n_err" -eq 0 ]; then
    cannot "RACE: the writer never made find fail in $n_find calls, so the race was not exercised"
else
    ok "RACE: $n_err find error(s) under a concurrent writer, and no run reported ZERO pages or went unhealthy"
fi

# ── B. DETERMINISTIC: find lists pages then fails ─────────────────────────
mkdir -p "$TMP/badfind" "$TMP/wiki_b/People"
: > "$TMP/wiki_b/People/Tom Jones.md"
cat > "$TMP/badfind/find" <<'EOF'
#!/bin/bash
echo "$2/People/Tom Jones.md"
echo "$2/People/Sam Doe.md"
echo "find: $2/People/tmp: No such file or directory" >&2
exit 1
EOF
chmod +x "$TMP/badfind/find"
out_b="$(run_block "$TMP/wiki_b" "$TMP/badfind")"
judge_healthy "$out_b" "DETERMINISTIC: find listed 2 pages then exited 1; reported as a lower bound, not ZERO"
if grep -q 'at least 2' <<<"$out_b"; then ok "DETERMINISTIC: the log states the lower bound (at least 2)"
else bad "DETERMINISTIC: no lower bound in the log: $(grep -E 'INFO|WARN' <<<"$out_b" | head -1)"; fi

# B2: find fails with NOTHING listed. Still not ZERO, still healthy on rc 0.
cat > "$TMP/badfind/find" <<'EOF'
#!/bin/bash
echo "find: $2: Permission denied" >&2
exit 1
EOF
out_b2="$(run_block "$TMP/wiki_b" "$TMP/badfind")"
judge_healthy "$out_b2" "DETERMINISTIC: find listed nothing and exited 1; reported as could-not-count, not ZERO"
if grep -q 'Could not count' <<<"$out_b2"; then ok "DETERMINISTIC: the log says it could not count"
else bad "DETERMINISTIC: no could-not-count line: $(grep -E 'INFO|WARN' <<<"$out_b2" | head -1)"; fi

# ── C. CONTROL: a real empty tree must still be ZERO and unhealthy ────────
mkdir -p "$TMP/wiki_c/People" "$TMP/wiki_c/Years"
out_c="$(run_block "$TMP/wiki_c" "/usr/bin")"
if grep -q 'ZERO pages' <<<"$out_c" && grep -q 'RESULT HEALTHY=false RC=1' <<<"$out_c"; then
    ok "CONTROL: a tree of empty directories is still ZERO pages and unhealthy"
else
    bad "CONTROL: an empty tree was not judged empty: $(grep -E 'WARN|RESULT' <<<"$out_c" | tr '\n' ' ')"
fi

printf '\n%s passed, %s failed, %s cannot-run\n' "$PASS" "$FAIL" "$CANNOT"
[ "$FAIL" -eq 0 ] || exit 1
[ "$CANNOT" -eq 0 ] || exit 2
exit 0
