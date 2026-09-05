#!/usr/bin/env bash
#
# THE PROMOTE IS FOLKLORE UNLESS THE SCRIPT SAYS HOW.
#
# publish_release.sh publishes a PRERELEASE when there is no clean walk record,
# and prints "to release it to customers ... 4. re-run this script". Measured
# 2026-09-05: that was the ONLY description of the promote anywhere.
#
#   grep -rn publish_release over the whole tree, excluding tests:
#     cut.yml:1223 is the ONLY invocation
#   grep -rni promote over docs/ and *.md in CM051:  0 hits
#   OS003 CUT_MECHANISM_CANONICAL.md:                0 mentions of promote
#   OS003 docs/RUNBOOK_daemon_release.md:            documents the DAEMON promote
#                                                    to ostler-releases, not this
#
# So the customer download has sat on v1.0.41 since 2026-08-22 -- the day BEFORE
# the walk gate landed -- and "re-run this script" omitted the two things that
# make the re-run fail.
#
# WHAT THIS ASSERTS. Not prose, and not that the words are pretty: that the block
# names each fact whose absence costs a cycle, and that the command it prints is
# CONSISTENT WITH WHAT THE SCRIPT ITSELF UPLOADS.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/scripts/publish_release.sh"
[ -f "$SRC" ] || { printf 'CANNOT-RUN: no publish_release.sh\n' >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }

BLOCK="$(awk '/To release it to customers:/,/^MSG$/' "$SRC")"
n="$(printf '%s' "$BLOCK" | grep -c .)"
if [ "$n" -lt 10 ]; then
    printf 'CANNOT-RUN: the promote block extracted %s lines. It was reworded or removed,\n' "$n" >&2
    printf '  so this file is measuring nothing. Re-point the anchor; do not delete the arms.\n' >&2
    exit 2
fi
ok "the promote block extracts to a sane size (${n} lines)"

has() {  # has <label> <fixed string>
    # `grep -cF`, NEVER `... | grep -qF` IN A CONDITION. This file runs under
    # `set -uo pipefail`, and grep -q exits on the first match and SIGPIPEs the
    # producer, so the pipeline can report FAILURE ON A MATCH. That would make
    # every arm below report the string absent when it is present.
    #
    # 🔴 THE RATCHET CAUGHT THIS, and it is the SECOND time in one session I
    # wrote it -- the first was a CI step in another PR. Writing the lesson down
    # did not stop me repeating it two hours later; the ratchet did.
    if [ "$(printf '%s' "$BLOCK" | grep -cF -- "$2")" -gt 0 ]; then
        ok "$1"
    else
        bad "$1 -- '$2' is absent"
    fi
}

# 1. THE STORES. A walk on carried-over stores grades the previous build's data,
#    which is what left three artefact-owned probes red on v1.0.68.
has "step 1 names --wipe-stores, so the walk grades THIS build's data"        "--wipe-stores"

# 2. THE RECORD MUST BE COMMITTED. verify_walk_record.sh reads walks/<v>.tsv
#    FROM THE REPO; a record in a working tree gates nothing. That happened.
has "step 3 says a record in a working tree gates nothing"                    "gates nothing"

# 3. THE BYTES. The walk record binds artefact_sha256, so a rebuild of the same
#    version is the wrong file. This is the one that silently burns a walk.
has "step 4a says hand it the PUBLISHED bytes, not a rebuild"                 "NOT A REBUILD"
has "step 4a gives the fetch command"                                         "gh release download"

# 4. THE TOKEN. A hard failure the operator meets only after doing everything else.
has "step 4b names PUBLISH_RELEASE_TOKEN"                                     "PUBLISH_RELEASE_TOKEN"

# 5. RE-RUNNING MUST BE SAFE, AND SAY SO, or nobody will.
has "it says the re-run is safe"                                              "--clobber"

# 6. THE LOAD-BEARING CONSISTENCY CHECK, and the reason this is a test rather
#    than a doc: the asset the instructions tell you to DOWNLOAD must be one the
#    script actually UPLOADS. Both sides are read from the file.
ASSET="$(grep -m1 '^ASSET_NAME=' "$SRC" | sed 's/.*="//; s/"$//')"
if [ -z "$ASSET" ]; then
    printf 'CANNOT-RUN: could not read ASSET_NAME from %s\n' "$SRC" >&2; exit 2
fi
PATTERN="$(printf '%s' "$BLOCK" | sed -n 's/.*--pattern \([^ ]*\).*/\1/p' | head -1)"
if [ -z "$PATTERN" ]; then
    bad "the instructions give no --pattern, so the operator must guess which of three assets to fetch"
elif [ "$PATTERN" = "$ASSET" ]; then
    ok "the --pattern the instructions print (${PATTERN}) is exactly the asset this script uploads (ASSET_NAME)"
else
    bad "the instructions say --pattern ${PATTERN} but this script uploads ASSET_NAME=${ASSET}. The fetch would miss, or fetch the wrong file."
fi

# 7. AND THE ASSET MUST REALLY BE UPLOADED, not merely named in a variable.
if [ "$(grep -c '\${WORK}/\${ASSET_NAME}' "$SRC")" -ge 2 ]; then
    ok "ASSET_NAME is uploaded on both the create and the clobber path"
else
    bad "ASSET_NAME is not uploaded on both paths; the download command would work on one kind of release and not the other"
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
