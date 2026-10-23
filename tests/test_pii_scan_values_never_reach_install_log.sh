#!/usr/bin/env bash
# A wiki pii_scan hit must never reach install.log with its value.
#
# THE DEFECT (v1.0.117 thin walk, S6). The pinned wiki-compiler image's
# pii_scan printed each hit as `path:line: [category] 'value' | line`, and
# install.sh wrote that compile output into ~/.ostler/logs/install.log (and the
# detached summary compile into wiki-background-compile.log). The GUI's raw
# "Copy log" ships install.log text to support. CM044 now logs counts only,
# but the image this file pins may predate that, so install.sh scrubs.
#
# WHAT THIS DOES. A stub `docker` prints pii_scan output in the OLD format
# with a synthetic phone, email and home path (fictional cast only), then
# exits with a chosen rc. Two shipped surfaces are driven end to end:
#
#   A. BASELINE: the real install.sh lines from the public-lookups helper to
#      the WIKI_BASELINE_RC capture, carved and executed. Its stdout is what
#      tee writes to install.log.
#   B. DETACHED: the real `nohup bash -c '...'` body, carved and executed on
#      the fallback-lock path. Its stdout is wiki-background-compile.log.
#
# Each must hold no value and no file name, must still name the category
# (an empty log cannot pass), and must keep the compiler's rc (piping the
# output must not swallow a failure). A drift check holds the two copies of
# the scrub expression equal.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$REPO/install.sh}"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: no install.sh at $INSTALL_SH" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PHONE="+852 9000 0000"
EMAIL="sam.doe""@""example.org"
HOMEUSER="tomjones"
FORBIDDEN=("$PHONE" "9000 0000" "$EMAIL" "sam.doe" "$HOMEUSER" "Sam Doe" "Jane Smith")

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<EOF
#!/bin/bash
echo "Compiled 120 pages"
echo "WARNING compiler.pii_scan: pii_scan: 3 hit(s) found:"
echo "People/Sam Doe.md:1: [andy_hk_phone] '${PHONE}'  | Phone: ${PHONE}"
echo "People/Sam Doe.md:2: [personal_email] '${EMAIL}'  | Email: ${EMAIL}"
echo "  People/Jane Smith.md:7: [users_home_path] '/Users/${HOMEUSER}/'  | at /Users/${HOMEUSER}/Documents" >&2
echo "pii_scan: operator build (broadcast redaction OFF) -- 3 hit(s) logged but NOT fatal"
exit \${STUB_DOCKER_RC:-0}
EOF
chmod +x "$TMP/bin/docker"

judge() {  # $1 label, $2 file
    local label="$1" f="$2" v leaked=""
    for v in "${FORBIDDEN[@]}"; do grep -qF -- "$v" "$f" && leaked="$leaked [$v]"; done
    if [ -n "$leaked" ]; then bad "$label: log carries PII values:$leaked"; else ok "$label: no value, no file name in the log"; fi
    local n; n="$(grep -c 'value withheld' "$f" || true)"
    if [ "$n" -eq 3 ] && grep -q 'value withheld: personal_email' "$f"; then
        ok "$label: all 3 hits still named by category"
    else
        bad "$label: categories missing ($n of 3 withheld lines), so the scrub may have eaten the evidence"
    fi
}

# ── A. BASELINE (install.log) ─────────────────────────────────────────────
awk '/^ostler_public_lookups_flag\(\) \{/{p=1} p; /^WIKI_BASELINE_RC=/{if(p) exit}' "$INSTALL_SH" > "$TMP/base.sh"
if ! grep -q 'profile compile run' "$TMP/base.sh" || ! grep -q '^WIKI_BASELINE_RC=' "$TMP/base.sh"; then
    echo "CANNOT-RUN: could not carve the baseline compile ($(wc -l < "$TMP/base.sh") lines)" >&2; exit 2
fi
cat > "$TMP/run_base.sh" <<'EOF'
set -Eeuo pipefail
OSTLER_DIR="$1"
. "$2"
echo "RC=${WIKI_BASELINE_RC}"
EOF
mkdir -p "$TMP/od"
for rc in 0 3; do
    STUB_DOCKER_RC=$rc PATH="$TMP/bin:/usr/bin:/bin" /bin/bash "$TMP/run_base.sh" "$TMP/od" "$TMP/base.sh" \
        > "$TMP/install_log_$rc" 2>&1
done
judge "BASELINE install.log" "$TMP/install_log_0"
if grep -q '^RC=0$' "$TMP/install_log_0" && grep -q '^RC=3$' "$TMP/install_log_3"; then
    ok "BASELINE: the compiler's rc survives the scrub pipe (0 -> 0, 3 -> 3)"
else
    bad "BASELINE: rc lost through the pipe: $(grep RC= "$TMP/install_log_0") / $(grep RC= "$TMP/install_log_3")"
fi

# ── B. DETACHED summary compile (wiki-background-compile.log) ─────────────
awk "/^        nohup bash -c '\$/ { f = 1; next }
     f && /^        ' _ \"\\\$_wiki_slot\"/ { exit }
     f { print }" "$INSTALL_SH" > "$TMP/body.sh"
if [ "$(grep -c . "$TMP/body.sh")" -lt 20 ]; then
    echo "CANNOT-RUN: could not carve the detached compile body" >&2; exit 2
fi
for rc in 0 3; do
    h="$TMP/box$rc"; mkdir -p "$h/ws" "$h/wd"
    STUB_DOCKER_RC=$rc PATH="$TMP/bin:/usr/bin:/bin" HOME="$h" \
        /bin/bash "$TMP/body.sh" "$h/ws/ingest-ollama.lock.d" "$h/wd" "$h/no-such-lib.sh" \
        > "$TMP/bg_log_$rc" 2>&1
    echo "EXIT=$?" >> "$TMP/bg_log_$rc"
done
judge "DETACHED wiki-background-compile.log" "$TMP/bg_log_0"
if grep -q 'compile finished OK' "$TMP/bg_log_0" && grep -q '^EXIT=0$' "$TMP/bg_log_0" \
   && grep -q 'compile FAILED' "$TMP/bg_log_3" && grep -q '^EXIT=1$' "$TMP/bg_log_3"; then
    ok "DETACHED: the compiler's rc survives the scrub pipe (0 -> OK, 3 -> FAILED)"
else
    bad "DETACHED: rc lost through the pipe: $(grep -E 'finished OK|FAILED|EXIT=' "$TMP/bg_log_0" | tr '\n' ' ') / $(grep -E 'finished OK|FAILED|EXIT=' "$TMP/bg_log_3" | tr '\n' ' ')"
fi

# B2: the same body on the shared-slot-library path (the one a box with the
# library takes), so both docker call sites in the body are exercised.
LIB="$REPO/lib/ostler-ingest-slot.sh"
if [ -r "$LIB" ]; then
    for rc in 0 3; do
        h="$TMP/libbox$rc"; mkdir -p "$h/ws" "$h/wd" "$h/lib"; cp "$LIB" "$h/lib/ostler-ingest-slot.sh"
        STUB_DOCKER_RC=$rc PATH="$TMP/bin:/usr/bin:/bin" HOME="$h" OSTLER_STATE_DIR="$h/ws" \
            OSTLER_SLOT_WAIT_SECS=1 OSTLER_SLOT_POLL_SECS=1 OSTLER_SLOT_GRACE_SECS=0 \
            /bin/bash "$TMP/body.sh" "$h/ws/ingest-ollama.lock.d" "$h/wd" "$h/lib/ostler-ingest-slot.sh" \
            > "$TMP/lib_log_$rc" 2>&1
        echo "EXIT=$?" >> "$TMP/lib_log_$rc"
    done
    if grep -q 'slot acquired via the shared library' "$TMP/lib_log_0"; then
        judge "DETACHED (slot library path)" "$TMP/lib_log_0"
        if grep -q '^EXIT=0$' "$TMP/lib_log_0" && grep -q 'compile FAILED' "$TMP/lib_log_3" && grep -q '^EXIT=1$' "$TMP/lib_log_3"; then
            ok "DETACHED (slot library path): rc survives the scrub pipe"
        else
            bad "DETACHED (slot library path): rc lost through the pipe"
        fi
    else
        bad "DETACHED (slot library path): the library path was not taken: $(head -5 "$TMP/lib_log_0" | tr '\n' ' ')"
    fi
else
    bad "DETACHED (slot library path): no lib/ostler-ingest-slot.sh to drive it"
fi

# ── DRIFT: the two copies of the expression are identical ─────────────────
e1="$(sed -n "s/^OSTLER_PII_HIT_SCRUB_SED='\(.*\)'\$/\1/p" "$INSTALL_SH")"
e2="$(sed -n 's/^            _scrub="\(.*\)"$/\1/p' "$INSTALL_SH")"
if [ -n "$e1" ] && [ "$e1" = "$e2" ]; then
    ok "DRIFT: the baseline and detached scrub expressions are identical"
else
    bad "DRIFT: scrub expressions differ or are missing (baseline='${e1}' detached='${e2}')"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
