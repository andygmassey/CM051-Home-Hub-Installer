#!/bin/bash
# CM051 #979. THE SHIPPED COMPOSE HAD NO AI CONVERSATIONS MOUNT, SO THE WIKI
# PAGE WAS EMPTY FOR EVER AND SILENTLY.
#
# THIRD INSTANCE OF ONE SHAPE. #849 was the Pro licence mount, #482 was the
# usage journal mount, and both comments are still in the same service block
# in install.sh. Each time: CM044 added a mount to its OWN
# docker/docker-compose.yml, tested it THERE, and the test stayed green while
# the SHIPPING artefact, the heredoc in install.sh, had nothing. The #849
# comment says it in a line: a guard on the dev compose says nothing about the
# artefact.
#
# WHICH IS WHY THIS TEST READS install.sh AND NOTHING ELSE. A test that read
# CM044's compose would pass today for the same reason the last two did.
#
# The customer consequence: compiler/pages/ai_conversation_pages.py falls back
# to expanduser of ~/Documents/Ostler/AI Conversations, which inside a
# container with no HOME resolves to /root/... , never exists, and so takes
# its graceful episodic-store-not-present branch and writes an empty-state
# page. install.sh's own test_ai_conversations_leg_wired.sh proves the WRITER
# leg is wired and default-ON and writing real transcripts hourly. Producer
# green, consumer blind, no error anywhere.
#
# HAS IT EVER FAILED: ARM 5 rebuilds the pre-fix heredoc every run by deleting
# the two lines this change added, and asserts the predicate goes RED on it.
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

# 🔴 THE RANGE ITSELF NEEDS A CONTROL. My first attempt at this extraction got
# the terminator wrong and read 12,000 lines instead of 456, and every count
# taken from it was meaningless. wiki-compiler must appear, and the span must
# be plausible, or the arms below are measuring the wrong region.
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
[ "$(grep -c ':/ai-conversations' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(1) the bind mount is present" \
    || no "(1) no :/ai-conversations mount: the page is empty for ever (#979)"
[ "$(grep -c 'OSTLER_AI_CONVERSATIONS_DIR=/ai-conversations' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(2) the env var points the renderer at it" \
    || no "(2) the mount would be present and UNREAD, the same defect one layer up"

echo
echo "ARM 3: read-only, because nothing in the compiler writes transcripts"
[ "$(grep -c ':/ai-conversations:ro' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(3) the mount is :ro, so it is not a foothold on the customer's tree" \
    || no "(3) the mount is writable" "$(grep ':/ai-conversations' "$COMPOSE" || true)"

echo
echo "ARM 4: install.sh creates the host tree BEFORE compose can bind it"
# Docker creates a missing bind source itself, owned by root, and the hourly
# writer leg runs as the customer. A root-owned directory in the visible zone
# is worse than the empty page this fixes.
[ "$(grep -c 'mkdir -p "${OSTLER_AI_CONVERSATIONS_DIR:-${HOME}/Documents/Ostler/AI Conversations}"' "$INSTALL" || true)" -gt 0 ] \
    && ok "(4) the tree is created, so Docker cannot leave a root-owned one" \
    || no "(4) nothing creates the bind source before the mount"

echo
echo "ARM 5: THE MUTANT. The pre-fix compose must FAIL arms 1 and 2."
MUT="${WORK}/mutant.yml"
grep -v ':/ai-conversations' "$COMPOSE" | grep -v 'OSTLER_AI_CONVERSATIONS_DIR=/ai-conversations' > "$MUT"
if cmp -s "$COMPOSE" "$MUT"; then
    no "(5) the mutant is IDENTICAL to the subject, so it did not apply and arms 1-2 prove nothing"
else
    m1="$(grep -c ':/ai-conversations' "$MUT" || true)"
    m2="$(grep -c 'OSTLER_AI_CONVERSATIONS_DIR=/ai-conversations' "$MUT" || true)"
    if [ "$m1" -eq 0 ] && [ "$m2" -eq 0 ]; then
        ok "(5) the pre-fix compose has neither: 0 mounts, 0 env vars, which is #979"
    else
        no "(5) the mutant still has mount=${m1} env=${m2}"
    fi
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
