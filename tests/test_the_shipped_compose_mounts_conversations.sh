#!/bin/bash
# CM051 #979, FOURTH INSTANCE. THE SHIPPED COMPOSE HAD NO MOUNT FOR THE HUMAN
# CONVERSATION BUNDLES, SO EVERY WhatsApp, iMessage, EMAIL AND CALL BUNDLE WAS
# INVISIBLE TO THE WIKI, FOR EVER AND SILENTLY.
#
# This is the sibling of test_the_shipped_compose_mounts_ai_conversations.sh
# and it exists because that test could not catch this. That one asserts
# ~/Documents/Ostler/AI Conversations. THIS one asserts
# ~/Documents/Ostler/Conversations, a DIFFERENT tree with a different producer
# and a different reader, and the shipping heredoc had the first and not the
# second. #849 was the Pro licence mount, #482 the usage journal mount, #979
# the AI conversations mount, and the comment for each is still in the same
# service block in install.sh, one under the other. This is the fourth.
#
# MEASURED on origin/main 7ecd4907, on install.sh, before this change:
#     OSTLER_CONVERSATIONS_DIR     -> 0
#     CONTROL, same file, same query:
#     OSTLER_AI_CONVERSATIONS_DIR  -> 8
# so the zero was real absence and not a false read of the wrong file.
#
# THE CUSTOMER CONSEQUENCE. Four shipped launchd feeds (vendor/imessage_source,
# vendor/email_source, vendor/whatsapp_source, vendor/spoken_source) write
# <date>/<slug>-<short-id>/{summary,transcript,todos}.md into that tree, which
# is the locked four-artefact conversation directive. THREE wiki generators
# read it and ALL THREE ARE CALLED: bundle_conversation_pages.generate
# (compile.py:906), commitment_pages.generate (:957), reply_debt_pages.generate
# (:985). Each resolves compiler/config.py::bundles_dir, which without the env
# var below falls back to expanduser("~/Documents/Ostler/Conversations"). The
# image declares no USER and no ENV HOME, so that is /root/... inside the
# container, a path no install has ever had. root.exists() is False, all three
# take their graceful no-captures branch, and each writes an empty page and
# returns status=skipped reason=no_root. Exit 0. No error line anywhere.
#
# WHICH IS WHY THIS TEST READS install.sh AND NOTHING ELSE. A test that read
# CM044's own docker/docker-compose.yml would pass today for the same reason
# the last three did: a guard on the dev compose says nothing about the
# artefact.
#
# HAS IT EVER FAILED: ARM 6 rebuilds the pre-fix heredoc every run by deleting
# the two lines this change added, and asserts the predicate goes RED on it.
# ARM 7 is the independence control: it deletes the AI-conversations lines
# instead and asserts these arms stay GREEN, so a pass here can never be the
# sibling's mount being counted twice.
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

# 🔴 THE RANGE ITSELF NEEDS A CONTROL, for the reason the sibling test records:
# a wrong terminator once read 12,000 lines instead of 456 and every count
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
[ "$(grep -c ':/conversations' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(1) the bind mount is present" \
    || no "(1) no :/conversations mount: every bundle page is empty for ever (#979)"
[ "$(grep -c 'OSTLER_CONVERSATIONS_DIR=/conversations' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(2) the env var points the three readers at it" \
    || no "(2) the mount would be present and UNREAD, the same defect one layer up"

echo
echo "ARM 3: read-only, because nothing in the compiler writes bundles"
[ "$(grep -c ':/conversations:ro' "$COMPOSE" || true)" -gt 0 ] \
    && ok "(3) the mount is :ro, so it is not a foothold on the customer's tree" \
    || no "(3) the mount is writable" "$(grep ':/conversations' "$COMPOSE" || true)"

echo
echo "ARM 4: the mount TARGET and the env var name the SAME in-container path"
# Two hardcoded strings can agree with each other and disagree with reality.
# Derive the container path from the mount line and compare, so a rename of
# one side is caught rather than silently producing a mount nothing reads.
MOUNT_TARGET="$(grep ':/conversations' "$COMPOSE" | head -1 | sed 's/:ro[[:space:]]*$//' | sed 's/.*:\(\/conversations[^:]*\)$/\1/')"
ENV_TARGET="$(grep 'OSTLER_CONVERSATIONS_DIR=' "$COMPOSE" | head -1 | sed 's/.*OSTLER_CONVERSATIONS_DIR=//' | sed 's/[[:space:]]*$//')"
echo "          mount target='${MOUNT_TARGET}'  env target='${ENV_TARGET}'"
if [ -n "$MOUNT_TARGET" ] && [ "$MOUNT_TARGET" = "$ENV_TARGET" ]; then
    ok "(4) both name ${MOUNT_TARGET}"
else
    no "(4) mount target and env var disagree, so the readers look at nothing"
fi

echo
echo "ARM 5: install.sh creates the host tree BEFORE compose can bind it"
# Docker creates a missing bind source itself, owned by root, and all four
# bundle writer feeds run as the customer. A root-owned directory in the
# visible zone is worse than the empty page this fixes.
[ "$(grep -c 'mkdir -p "${OSTLER_CONVERSATIONS_DIR:-${HOME}/Documents/Ostler/Conversations}"' "$INSTALL" || true)" -gt 0 ] \
    && ok "(5) the tree is created, so Docker cannot leave a root-owned one" \
    || no "(5) nothing creates the bind source before the mount"

echo
echo "ARM 6: THE MUTANT. The pre-fix compose must FAIL arms 1 and 2."
MUT="${WORK}/mutant.yml"
grep -v ':/conversations' "$COMPOSE" | grep -v 'OSTLER_CONVERSATIONS_DIR=/conversations' > "$MUT"
if cmp -s "$COMPOSE" "$MUT"; then
    no "(6) the mutant is IDENTICAL to the subject, so it did not apply and arms 1-2 prove nothing"
else
    m1="$(grep -c ':/conversations' "$MUT" || true)"
    m2="$(grep -c 'OSTLER_CONVERSATIONS_DIR=/conversations' "$MUT" || true)"
    if [ "$m1" -eq 0 ] && [ "$m2" -eq 0 ]; then
        ok "(6) the pre-fix compose has neither: 0 mounts, 0 env vars, which is #979"
    else
        no "(6) the mutant still has mount=${m1} env=${m2}"
    fi
fi

echo
echo "ARM 7: INDEPENDENCE CONTROL. These arms must not be reading the SIBLING."
# 🔴 A CONTROL PROVES THE PREDICATE, AND THIS ONE HAS TO RULE OUT THE ONE WAY
# THIS TEST COULD BE GREEN WITHOUT THE FIX: the AI Conversations mount sits two
# lines away and carries a near-identical string. Delete the AI lines and
# nothing here may move; delete OUR lines (arm 6) and both must die. Only both
# halves together show the predicate discriminates between the two trees.
SIB="${WORK}/no_ai.yml"
grep -v ':/ai-conversations' "$COMPOSE" | grep -v 'OSTLER_AI_CONVERSATIONS_DIR=/ai-conversations' > "$SIB"
if cmp -s "$COMPOSE" "$SIB"; then
    no "(7) the AI lines were not found, so this control did not apply"
else
    s1="$(grep -c ':/conversations' "$SIB" || true)"
    s2="$(grep -c 'OSTLER_CONVERSATIONS_DIR=/conversations' "$SIB" || true)"
    if [ "$s1" -gt 0 ] && [ "$s2" -gt 0 ]; then
        ok "(7) with the AI mount and env var gone, mount=${s1} env=${s2} still stand"
    else
        no "(7) removing the AI lines removed these too (mount=${s1} env=${s2}): this test has been measuring the sibling"
    fi
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
