#!/usr/bin/env bash
# ===========================================================================
# ttywalk.sh --reset must not fall through its uninstaller search in silence.
#
# The reset looks for a shipped uninstaller at three paths. install.sh writes
# exactly ONE uninstaller -- ~/.ostler/bin/ostler-uninstall (install.sh:19984,
# chmod at :20395) -- and a repo-wide find for uninstall*.sh returns nothing,
# so on a box installed from this DMG all three paths name a file that does not
# exist. The loop matched nothing, no break fired, and the run read as "reset
# done" when no uninstall had happened.
#
# That matters because the store teardown (docker compose down -v over
# qdrant_data, oxigraph_data, redis_data, wiki-docs, vane_data) lives INSIDE
# that uninstaller. A reset that skips it leaves the graph, the vectors and the
# compiled wiki carried over, so every store-reading probe measures history
# rather than the artefact under test.
#
# This asserts the skip is ANNOUNCED. It deliberately does NOT assert that the
# real path is searched: adding it would make the next walk wipe stores, which
# is an operator decision and not a side effect of a logging fix.
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/scripts/ttywalk.sh"
[ -r "$SRC" ] || { printf 'CANNOT-RUN: %s is not readable.\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fails=0
chk() { if [ "$2" -eq 0 ]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi; }

printf 'a reset that did not uninstall says so\n'

# CONTROL: the search loop this test is about must exist, or every assertion
# below is vacuous.
grep -q 'Contents/Resources/uninstall.sh' "$SRC" || {
    printf 'CANNOT-RUN: the uninstaller search loop is not in ttywalk.sh; wrong subject.\n' >&2; exit 2; }
chk "CONTROL: the uninstaller search loop is present" 0

# Bounded extraction. NEVER sourced -- only run as its own script, and only
# after its size is checked, so a failed end anchor cannot execute the rest of
# the harness.
awk '/^        _ran_uninstaller=""$/,/^        fi$/' "$SRC" > "${WORK}/blk"
n="$(wc -l < "${WORK}/blk" | tr -d ' ')"
if [ "$n" -lt 10 ] || [ "$n" -gt 80 ]; then
    printf 'CANNOT-RUN: extracted %s lines for the reset block; the anchors moved.\n' "$n" >&2; exit 2
fi
chk "the guarded block extracts to a sane size ($n lines)" 0

# THE APOSTROPHE TRAP. The whole reset body is passed to ssh inside a
# SINGLE-QUOTED shell string, so one apostrophe closes it and the script dies
# at EOF. This was hit while writing the block.
if grep -q "'" "${WORK}/blk"; then r=1; else r=0; fi
chk "the block contains no apostrophe (it lives in a single-quoted ssh string)" "$r"

bash -n "$SRC" && r=0 || r=1
chk "ttywalk.sh still parses" "$r"

# BEHAVIOUR: no uninstaller anywhere -> the skip is announced.
rm -rf "${WORK}/h"; mkdir -p "${WORK}/h"
out_none="$(HOME="${WORK}/h" bash "${WORK}/blk" 2>&1)"
printf '%s' "$out_none" | grep -q 'This reset did NOT uninstall' && r=0 || r=1
chk "no uninstaller found -> the run says it did NOT uninstall" "$r"
printf '%s' "$out_none" | grep -q 'CARRIED OVER' && r=0 || r=1
chk "no uninstaller found -> it names the consequence for the stores" "$r"

# BEHAVIOUR: an uninstaller present -> it runs, and the warning does NOT fire.
rm -rf "${WORK}/h"; mkdir -p "${WORK}/h/.ostler"
printf '#!/bin/bash\necho FAKE_UNINSTALLER_RAN\n' > "${WORK}/h/.ostler/uninstall.sh"
chmod +x "${WORK}/h/.ostler/uninstall.sh"
out_some="$(HOME="${WORK}/h" bash "${WORK}/blk" 2>&1)"
printf '%s' "$out_some" | grep -q 'FAKE_UNINSTALLER_RAN' && r=0 || r=1
chk "an uninstaller present -> it is executed" "$r"
printf '%s' "$out_some" | grep -q 'did NOT uninstall' && r=1 || r=0
chk "an uninstaller present -> the warning does NOT fire" "$r"

printf '  examined 8 assertions across 2 reset outcomes\n'
[ "$fails" -eq 0 ] || { printf 'FAIL: %s assertion(s) failed.\n' "$fails" >&2; exit 1; }
printf 'PASS: a reset that skipped the uninstall announces it.\n'
