#!/bin/bash
# v1.0.111 contact photos, and the SIXTH instance of #979: a consumer wired and
# tested in CM044 that never reaches the container because the SHIPPED compose
# has no mount for it. CM041's contact syncer runs on the host and records the
# HOST path of each photo (foaf:img / profile_photo_path, default
# ~/.pwg/people/photos). CM044 compiler/person_photo.py reads only producer-
# shaped basenames from WIKI_PEOPLE_PHOTOS_DIR. Without the mount AND the env
# var here, every People page draws initials and CM044's own e2e test stays
# green, because it sets the env var itself.
#
# So this reads install.sh and nothing else.
#
# HAS IT EVER FAILED: ARM 5 rebuilds the pre-fix heredoc every run by deleting
# the lines this change added, and asserts the predicate goes RED on it. ARM 6
# is the independence control: it deletes the sibling editor mount instead and
# asserts these arms stay GREEN.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
[ -r "$INSTALL" ] || { echo "CANNOT-RUN: ${INSTALL} is not readable."; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
COMPOSE="${WORK}/compose.yml"

START="$(grep -n '^cat > "${OSTLER_DIR}/docker-compose.yml" <<.DCEOF.$' "$INSTALL" | head -1 | cut -d: -f1)"
[ -n "${START:-}" ] || { echo "CANNOT-RUN: no docker-compose heredoc in install.sh; re-point this test."; exit 2; }
END="$(awk -v s="$START" 'NR>s && /^DCEOF$/ { print NR; exit }' "$INSTALL")"
[ -n "${END:-}" ] || { echo "CANNOT-RUN: heredoc opener at ${START} but no DCEOF terminator."; exit 2; }
awk -v s="$START" -v e="$END" 'NR>s && NR<e' "$INSTALL" > "$COMPOSE"
LINES="$(grep -c . "$COMPOSE" || true)"
WC="$(grep -c 'wiki-compiler' "$COMPOSE" || true)"
echo "EXAMINED: install.sh:${START}..${END}, ${LINES} lines of the SHIPPED compose; RANGE CONTROL wiki-compiler x${WC}"
if [ "${WC:-0}" -lt 1 ] || [ "${LINES:-0}" -lt 50 ] || [ "${LINES:-0}" -gt 2000 ]; then
    echo "CANNOT-RUN: the extracted span looks wrong. Refusing to measure it."
    exit 2
fi

# The wiki-compiler service block alone: from its key to the next top-level
# service key (two-space indent), so a match in another service cannot count.
SVC="${WORK}/svc.yml"
awk '/^  wiki-compiler:$/ {on=1; print; next} on && /^  [a-z][a-z0-9_-]*:$/ {exit} on {print}' "$COMPOSE" > "$SVC"
SL="$(grep -c . "$SVC" || true)"
[ "${SL:-0}" -ge 10 ] || { echo "CANNOT-RUN: wiki-compiler service block is ${SL} lines; re-point this test."; exit 2; }

MOUNT_RE=':/people-photos:ro$'
ENV_RE='WIKI_PEOPLE_PHOTOS_DIR=/people-photos$'

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; return 0; }
count() { grep -cE "$1" "$2" || true; }

echo "ARM 1: the read-only photo mount is in the wiki-compiler service"
[ "$(count "$MOUNT_RE" "$SVC")" -eq 1 ] && ok "(1) one :/people-photos:ro mount" \
    || no "(1) no :/people-photos:ro mount: every People page draws initials for ever"

echo "ARM 2: the env var points compiler/person_photo.py at the mount"
[ "$(count "$ENV_RE" "$SVC")" -eq 1 ] && ok "(2) WIKI_PEOPLE_PHOTOS_DIR=/people-photos" \
    || no "(2) the mount would be present and UNREAD"

echo "ARM 3: the mount source defaults to the producer's PHOTO_DIR default"
# CM041 contact_syncer/config.py: PHOTO_DIR = ~/.pwg/people/photos
[ "$(count '\$\{HOME\}/\.pwg/people/photos\}:/people-photos:ro$' "$SVC")" -eq 1 ] \
    && ok "(3) source is \${HOME}/.pwg/people/photos" \
    || no "(3) the mount source is not the directory the producer writes"

echo "ARM 4: install.sh creates the host directory before compose binds it"
[ "$(grep -cF 'mkdir -p "${OSTLER_PEOPLE_PHOTOS_DIR:-${HOME}/.pwg/people/photos}"' "$INSTALL" || true)" -ge 1 ] \
    && ok "(4) created, so Docker cannot leave a root-owned one" \
    || no "(4) nothing creates the bind source before the mount"

echo "ARM 5: THE MUTANT. The pre-fix service block must FAIL arms 1 and 2."
MUT="${WORK}/mutant.yml"
grep -vE "$MOUNT_RE" "$SVC" | grep -vE "$ENV_RE" > "$MUT"
if cmp -s "$SVC" "$MUT"; then
    no "(5) the mutant is IDENTICAL to the subject, so it did not apply"
elif [ "$(count "$MOUNT_RE" "$MUT")" -eq 0 ] && [ "$(count "$ENV_RE" "$MUT")" -eq 0 ]; then
    ok "(5) the pre-fix block has 0 mounts and 0 env vars, and arms 1-2 would be RED"
else
    no "(5) the mutant still matches"
fi

echo "ARM 6: INDEPENDENCE CONTROL. Removing the sibling editor mount leaves arms 1-2 GREEN."
SIB="${WORK}/sibling.yml"
grep -v ':/editor:ro' "$SVC" > "$SIB"
if cmp -s "$SVC" "$SIB"; then
    no "(6) the sibling mount was not present to remove, so this control proves nothing"
elif [ "$(count "$MOUNT_RE" "$SIB")" -eq 1 ] && [ "$(count "$ENV_RE" "$SIB")" -eq 1 ]; then
    ok "(6) arms 1-2 do not depend on the editor mount"
else
    no "(6) arms 1-2 changed when an unrelated mount was removed"
fi

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
