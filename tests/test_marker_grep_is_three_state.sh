#!/usr/bin/env bash
#
# tests/test_marker_grep_is_three_state.sh
#
# A MARKER PATTERN THAT CANNOT RUN MUST NOT REPORT THE COMPONENT ABSENT.
#
# grep is a three-state command: 0 match, 1 no match, >=2 ERROR. Both wiki arms
# in verify_cut_provenance.sh used to read it with a two-state `if`, and threw
# grep's stderr away:
#
#     if grep -rq -- "$pattern" "$EXTRACT_DIR" 2>/dev/null; then ... else ... fi
#
# For wiki_image_grep that was fail-CLOSED by accident -- rc=2 landed in the
# else and printed RED, the safe direction, which is why it went unnoticed.
#
# For wiki_image_absent it failed OPEN: rc=2 printed "pattern is absent --
# green" about a pattern that never ran, on the #84 LOCK rows Andy asked for by
# name. A gate that reports a deliberately-removed component absent because its
# own regex would not compile is worse than no gate, because it gets quoted as
# evidence.
#
# Exit 0 all pass / 1 a check failed / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/scripts/verify_cut_provenance.sh"

[[ -r "$GATE" ]] || { echo "CANNOT-RUN: no ${GATE} (exit 2)" >&2; exit 2; }

# Pull the function out without running the gate: sourcing it would execute a
# whole cut preflight.
FN="$(sed -n '/^marker_grep() {$/,/^}$/p' "$GATE")"
if [[ -z "$FN" ]]; then
    echo "CANNOT-RUN: marker_grep() not found in ${GATE} -- renamed or inlined," >&2
    echo "  so this file is measuring nothing (exit 2)" >&2
    exit 2
fi
eval "$FN"
declare -F marker_grep >/dev/null || { echo "CANNOT-RUN: marker_grep did not define (exit 2)" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/markergrep-XXXXXX")" || exit 2
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
printf 'hello pwg-settling-bar world\n' > "$TMP/f.txt"

pass=0; fail=0
ok(){ printf '  [pass] %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
expect(){ local label="$1" want="$2" pat="$3" dir="$4"
    marker_grep "$pat" "$dir"; local got=$?
    if [[ "$got" -eq "$want" ]]; then ok "$label (rc=$got)"
    else bad "$label -- wanted rc=$want, got rc=$got${MARKER_GREP_ERR:+ [$MARKER_GREP_ERR]}"; fi; }

echo "== the three states =="
expect "(1) a present pattern is FOUND"        0 'pwg-settling-bar' "$TMP"
expect "(2) an absent pattern is NOT FOUND"    1 'pwg-hydration-bar' "$TMP"

# The whole point. Each of these makes grep exit >=2 on BSD grep, which is what
# a macOS cut runner uses. Any ONE of them reaching the `absent` arm as rc=1
# would print GREEN about an unsearched image.
echo "== a pattern that cannot COMPILE is cannot-run, never 'absent' =="
# CHOSEN TO ERROR UNDER *BOTH* BRE AND ERE, deliberately.
#
# The first version of this file used 'a\{2' and '\(' -- which error under BRE
# and are LITERALS under ERE. They passed, and then the very next commit turned
# marker_grep to -E and two of them went green: a fixture that had encoded the
# flag the code happened to use rather than the property under test. Measured
# on /usr/bin/grep, these three error either way, so this file keeps its meaning
# whichever flag marker_grep carries.
expect "(3) unterminated bracket"              2 '['            "$TMP"
expect "(4) bogus character class"             2 '[[:bogus:]]'  "$TMP"
expect "(5) doubled quantifier"                2 'a**'          "$TMP"

# THE FLAG ITSELF, pinned by behaviour rather than by reading the source.
# cut_markers.manifest's header has always documented `grep -rE`, and these arms
# ran BRE until the commit above. An alternation is the cheapest thing that
# tells the two apart: under BRE it does not match, under ERE it does. If
# someone quietly drops the -E, THIS is the check that goes red -- and it goes
# red loudly rather than turning an absent-row green.
expect "(6) marker_grep runs EXTENDED regex, as the manifest header promises" 0 'pwg-(settling|hydration)-bar' "$TMP"

echo "== a directory that cannot be READ is cannot-run =="
mkdir -p "$TMP/locked"; printf 'x\n' > "$TMP/locked/a.txt"; chmod 000 "$TMP/locked" 2>/dev/null
if [[ -r "$TMP/locked" ]]; then
    printf '  [skip] (7) cannot make a directory unreadable as this user\n'
else
    expect "(7) unreadable directory"          2 'pwg-settling-bar' "$TMP/locked"
fi
chmod 755 "$TMP/locked" 2>/dev/null

echo "== the error text is kept, not discarded =="
marker_grep '[' "$TMP" >/dev/null 2>&1
if [[ -n "${MARKER_GREP_ERR:-}" ]]; then
    ok "(8) MARKER_GREP_ERR carries grep's own message"
else
    bad "(8) MARKER_GREP_ERR is empty -- the operator gets a verdict with no reason"
fi
marker_grep 'pwg-settling-bar' "$TMP" >/dev/null 2>&1
if [[ -z "${MARKER_GREP_ERR:-}" ]]; then
    ok "(9) CONTROL: a clean run leaves no stale error text behind"
else
    bad "(9) MARKER_GREP_ERR is stale after a clean run: [${MARKER_GREP_ERR}]"
fi

echo "== and both arms actually consult it =="
for arm in wiki_image_grep wiki_image_absent; do
    if awk -v a="$arm" '
        $0 ~ ("    " a "\\)") {inarm=1}
        inarm && /marker_grep "\$\{pattern\}"/ {seen=1}
        inarm && /_mrc.*-eq 2/ {two=1}
        inarm && /^    [a-z_]+\)$/ && $0 !~ a {inarm=0}
        END{exit !(seen && two)}' "$GATE"; then
        ok "(10/$arm) reads marker_grep and branches on rc=2"
    else
        bad "(10/$arm) does not branch on rc=2 -- an unrunnable pattern still decides"
    fi
done

echo
printf 'marker_grep: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
exit 0
