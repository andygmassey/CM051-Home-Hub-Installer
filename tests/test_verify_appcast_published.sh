#!/usr/bin/env bash
#
# Controls for scripts/verify_appcast_published.sh.
#
# The gate under test exists because a publish that succeeds is not a feed
# that changed. These controls exist because a gate that returns 0 is not a
# gate that looked.
#
# THE DEMONSTRATED RED (control 2) is the exact shape production is in as of
# 2026-08-19: HTTP 200, valid Sparkle RSS, <channel> present, zero <item>. If
# this gate had existed at any point in the last 36 cuts it would have been
# red on every one of them. A gate is only worth its line count if it can be
# shown to FAIL on the tree that has the defect -- proving it passes on a
# healthy fixture proves nothing.
#
# Controls 4 and 5 are the ones that would catch a lazy reimplementation:
# `grep -q "$VERSION"` passes both of them while being wrong, because 1.0.3
# is a substring of 1.0.36. Sparkle's whole failure mode here is silent, so a
# version check that is loose by one character is worse than none.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
GATE="$REPO/scripts/verify_appcast_published.sh"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

if [ ! -f "$GATE" ]; then
    echo "  CANNOT RUN: gate not found at $GATE"
    echo "  A subject that does not exist is not a subject that passed."
    exit 2
fi
chmod +x "$GATE" 2>/dev/null || true

echo "verify_appcast_published controls"

# --- fixtures -------------------------------------------------------------
mk_feed() { # $1=path, $2...=version:build pairs
    local path="$1"; shift
    {
        echo '<?xml version="1.0" encoding="utf-8"?>'
        echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
        echo '  <channel><title>Ostler Hub</title>'
        local pair v b
        for pair in "$@"; do
            v="${pair%%:*}"; b="${pair##*:}"
            echo '    <item>'
            echo "      <sparkle:version>$b</sparkle:version>"
            echo "      <sparkle:shortVersionString>$v</sparkle:shortVersionString>"
            echo '    </item>'
        done
        echo '  </channel>'
        echo '</rss>'
    } > "$path"
}

EMPTY="$TMP/empty.xml"
{
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '  <channel><title>Ostler Hub</title>'
    echo '  </channel>'
    echo '</rss>'
} > "$EMPTY"

ONE="$TMP/one.xml";        mk_feed "$ONE" "1.0.36:2500"
OTHER="$TMP/other.xml";    mk_feed "$OTHER" "1.0.35:2499"
SHORT="$TMP/short.xml";    mk_feed "$SHORT" "1.0.3:2400"
JUNK="$TMP/junk.xml";      printf '{"ok":false,"error":"missing query parameter"}' > "$JUNK"
BLANK="$TMP/blank.xml";    printf '' > "$BLANK"
FLAT="$TMP/flat.xml";      tr -d '\n' < "$ONE" > "$FLAT"

run() { "$GATE" "$@" >"$TMP/out" 2>&1; echo $?; }

# --- 1. the healthy case --------------------------------------------------
rc=$(run --version 1.0.36 --fixture "$ONE")
[ "$rc" = "0" ] && ok "a feed carrying 1.0.36 reports PUBLISHED (rc 0)" \
                || bad "healthy feed gave rc=$rc, expected 0"

# --- 2. DEMONSTRATED RED: today's live production shape -------------------
rc=$(run --version 1.0.36 --fixture "$EMPTY")
if [ "$rc" = "1" ] && grep -q "VALID AND EMPTY" "$TMP/out"; then
    ok "DEMONSTRATED RED: valid-and-empty feed reports NOT PUBLISHED (rc 1)"
else
    bad "the exact live-production shape gave rc=$rc -- this gate would NOT have caught 36 cuts"
fi

# --- 3. discriminating: feed works, THIS release missing -------------------
rc=$(run --version 1.0.36 --fixture "$OTHER")
if [ "$rc" = "1" ] && grep -q "THIS release" "$TMP/out"; then
    ok "a populated feed missing THIS version is rc 1, and says so distinctly"
else
    bad "populated-but-missing gave rc=$rc (expected 1 with a distinct message)"
fi

# --- 4/5. substring boundary, both directions -----------------------------
# `grep -q` instead of `grep -Fxq` passes control 4 while being wrong.
rc=$(run --version 1.0.3 --fixture "$ONE")
[ "$rc" = "1" ] && ok "1.0.3 is NOT satisfied by a feed containing only 1.0.36 (no substring match)" \
                || bad "substring false-positive: asking for 1.0.3 against 1.0.36 gave rc=$rc"

rc=$(run --version 1.0.36 --fixture "$SHORT")
[ "$rc" = "1" ] && ok "1.0.36 is NOT satisfied by a feed containing only 1.0.3 (reverse direction)" \
                || bad "reverse substring false-positive gave rc=$rc"

# --- 6/7. the build is checked too ----------------------------------------
rc=$(run --version 1.0.36 --build 9999 --fixture "$ONE")
[ "$rc" = "1" ] && ok "right version + WRONG build is rc 1 (Sparkle compares on build)" \
                || bad "wrong build gave rc=$rc, expected 1"

rc=$(run --version 1.0.36 --build 2500 --fixture "$ONE")
[ "$rc" = "0" ] && ok "right version + right build is rc 0" \
                || bad "matching build gave rc=$rc, expected 0"

# --- 8/9/10/11. CANNOT-RUN is a THIRD state, never confused with a verdict -
rc=$(run --version 1.0.36 --fixture "$JUNK")
[ "$rc" = "2" ] && ok "a non-RSS body is CANNOT-RUN (rc 2), not a false 'unpublished'" \
                || bad "non-RSS body gave rc=$rc, expected 2"

rc=$(run --version 1.0.36 --fixture "$BLANK")
[ "$rc" = "2" ] && ok "an empty body is CANNOT-RUN (rc 2)" \
                || bad "empty body gave rc=$rc, expected 2"

rc=$(run --fixture "$ONE")
[ "$rc" = "2" ] && ok "a missing --version is CANNOT-RUN (rc 2), never a pass" \
                || bad "missing --version gave rc=$rc, expected 2"

rc=$(run --version 1.0.36 --fixture "$TMP/does-not-exist.xml")
[ "$rc" = "2" ] && ok "an absent fixture is CANNOT-RUN (rc 2)" \
                || bad "absent fixture gave rc=$rc, expected 2"

# --- 12. an unreachable feed must not read as 'not published' -------------
rc=$(OSTLER_APPCAST_FEED="https://127.0.0.1:9/appcast.xml" run --version 1.0.36)
[ "$rc" = "2" ] && ok "an unreachable feed is CANNOT-RUN (rc 2), distinct from rc 1" \
                || bad "unreachable feed gave rc=$rc, expected 2 -- a dead network must not read as a clean bill of health"

# --- 13. the parser must not depend on the generator's line breaks --------
rc=$(run --version 1.0.36 --fixture "$FLAT")
[ "$rc" = "0" ] && ok "a reflowed single-line feed still parses (not line-break dependent)" \
                || bad "single-line XML gave rc=$rc -- the parser is coupled to today's formatting"

# --- 14. POSITIVE CONTROL: prove the canary itself can fire ---------------
# Without this, "the canary passed" is an assertion about a branch that may
# be unreachable. Break the parser in a COPY and require the gate to refuse.
BROKEN="$TMP/broken_gate.sh"
sed 's|grep -o "<sparkle:\$2\[^<\]\*"|grep -o "<NOTHINGWILLEVERMATCH[^<]*"|' "$GATE" > "$BROKEN"
chmod +x "$BROKEN"
if ! cmp -s "$GATE" "$BROKEN"; then
    "$BROKEN" --version 1.0.36 --fixture "$ONE" >"$TMP/bout" 2>&1; brc=$?
    if [ "$brc" = "2" ] && grep -q "canary failed" "$TMP/bout"; then
        ok "POSITIVE CONTROL: a broken parser is caught by the canary and refuses (rc 2)"
    else
        bad "POSITIVE CONTROL FAILED: a broken parser gave rc=$brc -- the canary does not fire, so every 'not published' verdict is unguarded"
    fi
else
    bad "POSITIVE CONTROL INERT: could not break the parser copy, so the canary is unproven"
fi

echo ""
echo "=== $PASS passed / $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
