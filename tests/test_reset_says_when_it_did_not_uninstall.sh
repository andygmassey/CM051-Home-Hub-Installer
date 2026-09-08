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

# ── #1828: config-only teardown clears setup-gating config + poison, and
#    NEVER reaches the store volumes or the store-wiping uninstaller. ────────
{ printf '_ran_uninstaller=""\n'; awk '/# #1828 config-only teardown/,/^        fi$/' "$SRC"; } > "${WORK}/td"
tdn="$(wc -l < "${WORK}/td" | tr -d ' ')"
if [ "$tdn" -lt 8 ] || [ "$tdn" -gt 60 ]; then
    printf 'CANNOT-RUN: extracted %s lines for the teardown; anchors moved.\n' "$tdn" >&2; exit 2; fi
chk "the config-only teardown extracts to a sane size ($tdn lines)" 0

if grep -q "'" "${WORK}/td"; then r=1; else r=0; fi
chk "the teardown block contains no apostrophe" "$r"

# strip comment lines first: prose that MENTIONS docker to explain what the
# teardown leaves alone is fine; an actual store-wiping COMMAND is not.
if grep -vE '^[[:space:]]*#' "${WORK}/td" | grep -qE 'docker|compose|ostler-uninstall|qdrant_data|oxigraph_data|redis_data|vane_data'; then r=1; else r=0; fi
chk "the teardown runs no store-wiping command (docker/compose/uninstaller/volume rm)" "$r"

rm -rf "${WORK}/h"; mkdir -p "${WORK}/h/.ostler/config" "${WORK}/h/.ostler/security" "${WORK}/h/.ostler/assistant-config/workspace/memory" "${WORK}/h/.ostler/imports" "${WORK}/h/.ostler/data"
printf 'USER_ID=old\n' > "${WORK}/h/.ostler/config/.env"
printf 'poison\n'      > "${WORK}/h/.ostler/assistant-config/workspace/memory/brain.db"
printf 'vcf\n'         > "${WORK}/h/.ostler/imports/icloud-contacts.vcf"
printf 'keys\n'        > "${WORK}/h/.ostler/security/keychain.json"
printf 'runtime\n'     > "${WORK}/h/.ostler/data/keep"
HOME="${WORK}/h" bash "${WORK}/td" >/dev/null 2>&1
r=0
[ -e "${WORK}/h/.ostler/config" ] && r=1
[ -e "${WORK}/h/.ostler/security" ] && r=1
[ -e "${WORK}/h/.ostler/assistant-config" ] && r=1
[ -e "${WORK}/h/.ostler/imports" ] && r=1
chk "teardown removed config, security, assistant-config (brain.db), imports" "$r"
[ -f "${WORK}/h/.ostler/data/keep" ] && r=0 || r=1
chk "teardown left the non-config ~/.ostler/data untouched (targeted, not blanket)" "$r"

printf '  examined 13 assertions across 3 reset outcomes\n'
[ "$fails" -eq 0 ] || { printf 'FAIL: %s assertion(s) failed.\n' "$fails" >&2; exit 1; }
printf 'PASS: a reset that skipped the uninstall announces it.\n'
