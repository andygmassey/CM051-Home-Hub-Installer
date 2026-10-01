#!/bin/bash
# CM051 #979, FIFTH INSTANCE. CM044 #295 (CM051 #2537) made the wiki's "Needs
# you now" band read the Hub app's own feed (cm059_editor's
# ~/.ostler/editor/front_page.json) instead of running an independent SPARQL
# query that disagreed with the Hub app about who needs attention. That PR's
# tests pass because its conftest sets OSTLER_FRONT_PAGE_JSON itself to a
# fixture path; nothing in the SHIPPED compose ever gave the wiki-compiler
# container a mount or an env var pointing at the real file. In the product
# the feed is therefore always absent and the band falls back to the
# (still-independent) SPARQL cards -- #2537 ships dark on the Hub-feed path,
# the exact #979 shape: wired and tested, never reaches the container. #849
# was the Pro licence mount, #482 the usage journal mount, #979 itself the AI
# conversations mount, its fourth instance the human conversations mount.
# This is the fifth.
#
# WHICH IS WHY THIS TEST READS install.sh AND NOTHING ELSE. A test that read
# CM044's own docker/docker-compose.yml would pass today for the same reason
# the last four did: a guard on the dev compose says nothing about the
# artefact.
#
# HAS IT EVER FAILED: ARM 6 rebuilds the pre-fix heredoc every run by
# deleting the two lines this change added, and asserts the predicate goes
# RED on it. ARM 7 is the independence control: it deletes the sibling
# conversations mount instead and asserts these arms stay GREEN, so a pass
# here can never be the sibling's mount being counted twice.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
[ -r "$INSTALL" ] || { echo "CANNOT-RUN: ${INSTALL} is not readable."; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
COMPOSE="${WORK}/compose.yml"

# Extract the SHIPPED heredoc by its own delimiters, never by line number.
START="$(grep -n '^cat > "${OSTLER_DIR}/docker-compose.yml" <<.DCEOF.$' "$INSTALL" | head -1 | cut -d: -f1)"
if [ -z "${START:-}" ]; then
    echo "CANNOT-RUN: could not find the docker-compose heredoc in install.sh."
    echo "            It has been renamed or restructured; re-point this test."
    exit 2
fi
END="$(awk -v s="$START" 'NR>s && /^DCEOF$/ { print NR; exit }' "$INSTALL")"
if [ -z "${END:-}" ]; then
    echo "CANNOT-RUN: found the heredoc opener at ${START} but no DCEOF terminator."
    exit 2
fi
awk -v s="$START" -v e="$END" 'NR>s && NR<e' "$INSTALL" > "$COMPOSE"
LINES="$(grep -c . "$COMPOSE" || true)"
echo "EXAMINED: install.sh:${START}..${END}, ${LINES} lines of the SHIPPED compose"

# 🔴 THE RANGE ITSELF NEEDS A CONTROL: a wrong terminator once read 12,000
# lines instead of 456 and every count taken from it was meaningless.
WC="$(grep -c 'wiki-compiler' "$COMPOSE" || true)"
if [ "${WC:-0}" -lt 1 ] || [ "${LINES:-0}" -lt 50 ] || [ "${LINES:-0}" -gt 2000 ]; then
    echo "CANNOT-RUN: the extracted span looks wrong (${LINES} lines,"
    echo "            wiki-compiler x${WC}). Refusing to measure it."
    exit 2
fi
echo "          RANGE CONTROL: wiki-compiler appears ${WC} times in that span"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; return 0; }

echo
echo "ARM 1-2: the mount and the env var are both in the SHIPPED compose"
[ "$(grep -c ':/editor:ro' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(1) the read-only bind mount is present" \
    || no "(1) no :/editor:ro mount: the Hub feed path is dark for ever (#979)"
[ "$(grep -c 'OSTLER_FRONT_PAGE_JSON=/editor/front_page.json' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(2) the env var points _editor_need_cards() at it" \
    || no "(2) the mount would be present and UNREAD, the same defect one layer up"

echo
echo "ARM 3: read-only, because nothing in the compiler writes the feed"
[ "$(grep -c ':/editor:ro' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(3) the mount is :ro, so it is not a foothold on the Hub's editor state" \
    || no "(3) the mount is writable" "$(grep ':/editor' "$COMPOSE" || true)"

echo
echo "ARM 4: the mount TARGET DIR and the env var's directory agree"
# Two hardcoded strings can agree with each other and disagree with reality.
MOUNT_TARGET="$(grep ':/editor:ro' "$COMPOSE" | head -1 | sed 's/:ro[[:space:]]*$//' | sed 's/.*:\(\/editor\)$/\1/')"
ENV_DIR="$(grep 'OSTLER_FRONT_PAGE_JSON=' "$COMPOSE" | head -1 | sed 's/.*OSTLER_FRONT_PAGE_JSON=//' | sed 's/[[:space:]]*$//' | sed 's#/[^/]*$##')"
echo "          mount target='${MOUNT_TARGET}'  env dir='${ENV_DIR}'"
if [ -n "$MOUNT_TARGET" ] && [ "$MOUNT_TARGET" = "$ENV_DIR" ]; then
    ok "(4) both name ${MOUNT_TARGET}"
else
    no "(4) mount target and the env var's directory disagree, so the reader looks at nothing"
fi

echo
echo "ARM 5: install.sh creates the host tree BEFORE compose can bind it"
# Docker creates a missing bind source itself, owned by root; the
# cm059_editor LaunchAgent runs as the customer and could never write into a
# root-owned directory afterwards.
[ "$(grep -c 'mkdir -p "${HOME}/.ostler/editor"' "$INSTALL" || true)" -gt 0 ] \
    && ok "(5) the tree is created, so Docker cannot leave a root-owned one" \
    || no "(5) nothing creates the bind source before the mount"

echo
echo "ARM 6: THE MUTANT. The pre-fix compose must FAIL arms 1 and 2."
MUT="${WORK}/mutant.yml"
grep -v ':/editor:ro' "$COMPOSE" | grep -v 'OSTLER_FRONT_PAGE_JSON=/editor/front_page.json' > "$MUT"
if cmp -s "$COMPOSE" "$MUT"; then
    no "(6) the mutant is IDENTICAL to the subject, so it did not apply and arms 1-2 prove nothing"
else
    m1="$(grep -c ':/editor:ro' "$MUT" || true)"
    m2="$(grep -c 'OSTLER_FRONT_PAGE_JSON=/editor/front_page.json' "$MUT" || true)"
    if [ "$m1" -eq 0 ] && [ "$m2" -eq 0 ]; then
        ok "(6) the pre-fix compose has neither: 0 mounts, 0 env vars, which is #979"
    else
        no "(6) the mutant still has mount=${m1} env=${m2}"
    fi
fi

echo
echo "ARM 7: INDEPENDENCE CONTROL. These arms must not be reading the SIBLING."
# The conversations mount sits a short distance away and carries a similarly
# shaped string (":/conversations:ro" / "OSTLER_CONVERSATIONS_DIR=..."). Delete
# those lines and nothing here may move; delete OUR lines (arm 6) and both
# must die. Only both halves together show the predicate discriminates.
SIB="${WORK}/no_conv.yml"
grep -v ':/conversations:ro' "$COMPOSE" | grep -v 'OSTLER_CONVERSATIONS_DIR=/conversations' > "$SIB"
if cmp -s "$COMPOSE" "$SIB"; then
    no "(7) the conversations lines were not found, so this control did not apply"
else
    s1="$(grep -c ':/editor:ro' "$SIB" || true)"
    s2="$(grep -c 'OSTLER_FRONT_PAGE_JSON=/editor/front_page.json' "$SIB" || true)"
    if [ "$s1" -gt 0 ] && [ "$s2" -gt 0 ]; then
        ok "(7) with the conversations mount and env var gone, mount=${s1} env=${s2} still stand"
    else
        no "(7) removing the conversations lines removed these too (mount=${s1} env=${s2}): this test has been measuring the sibling"
    fi
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
