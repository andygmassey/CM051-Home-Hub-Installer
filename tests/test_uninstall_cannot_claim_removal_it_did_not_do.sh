#!/usr/bin/env bash
# ===========================================================================
# The uninstaller must not print "Done. Ostler has been removed." when the
# store teardown did not run.
#
# `docker compose down -v` is the ONLY thing that removes qdrant_data,
# oxigraph_data, redis_data, wiki-docs and vane_data -- the named volumes
# holding the customer's people graph, vectors and compiled wiki. It used to be
# written as
#     cd "${HOME}/.ostler" 2>/dev/null && docker compose down -v 2>/dev/null || true
# so a failed cd, a stopped colima or an absent docker each left every one of
# those volumes on disk, printed nothing, and the script announced a complete
# removal. The same uninstaller already warns when it cannot delete an app
# bundle; it said nothing when it could not delete the personal data.
#
# ANTI-VACUITY. "Done. Ostler has been removed APART FROM the stores named
# above" CONTAINS "Ostler has been removed" as a substring, so a naive
# substring assertion passes on both arms and proves nothing. Every assertion
# here anchors on the WHOLE line.
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/install.sh"
[ -r "$SRC" ] || { printf 'CANNOT-RUN: %s is not readable.\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The uninstaller is a QUOTED heredoc, so its body is literal shell.
awk "/^cat > \"\\\${OSTLER_DIR}\\/bin\\/ostler-uninstall\" <<'UNINSTALLEOF'\$/{f=1;next} /^UNINSTALLEOF\$/{f=0} f" \
    "$SRC" > "${WORK}/uninstaller"
[ -s "${WORK}/uninstaller" ] || { printf 'CANNOT-RUN: could not extract the ostler-uninstall heredoc from install.sh.\n' >&2; exit 2; }

# Pull out the two regions under test. A moved marker must CANNOT-RUN, never
# silently examine nothing and report success.
awk '/^OSTLER_STORES_REMOVED=0$/,/^fi$/' "${WORK}/uninstaller" > "${WORK}/teardown"
awk '/^if \[\[ "\$OSTLER_STORES_REMOVED" -eq 1 \]\]; then$/,/^fi$/' "${WORK}/uninstaller" > "${WORK}/report"
for f in teardown report; do
    [ -s "${WORK}/${f}" ] || { printf 'CANNOT-RUN: the %s block was not found in the uninstaller; its marker moved.\n' "$f" >&2; exit 2; }
done

SUCCESS_LINE='  Done. Ostler has been removed.'
WARN_LINE='  WARNING: YOUR DATA STORES WERE NOT REMOVED.'

# $1 label  $2 docker exit code  $3 create ~/.ostler (yes|no)
run_case() {
    rm -rf "${WORK}/home" "${WORK}/bin"; mkdir -p "${WORK}/home" "${WORK}/bin"
    [ "$3" = "yes" ] && mkdir -p "${WORK}/home/.ostler"
    printf '#!/bin/sh\n[ "$2" = "down" ] && { echo "Cannot connect to the Docker daemon."; exit %s; }\nexit 0\n' "$2" \
        > "${WORK}/bin/docker"
    chmod +x "${WORK}/bin/docker"
    HOME="${WORK}/home" PATH="${WORK}/bin:$PATH" \
        /bin/bash -c ". '${WORK}/teardown'; . '${WORK}/report'" 2>&1
}

has_line() { grep -qxF "$2" <<< "$1"; }

fails=0
check() { # $1 desc  $2 actual(0=ok)
    if [ "$2" -eq 0 ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

printf 'uninstall removal honesty\n'

out_ok="$(run_case ok 0 yes)"
has_line "$out_ok" "$SUCCESS_LINE" && r=0 || r=1
check "teardown succeeded -> prints the unqualified success line" "$r"
has_line "$out_ok" "$WARN_LINE" && r=1 || r=0
check "teardown succeeded -> prints NO warning" "$r"

out_dead="$(run_case dockerdown 1 yes)"
has_line "$out_dead" "$WARN_LINE" && r=0 || r=1
check "docker daemon down -> warns the stores remain" "$r"
has_line "$out_dead" "$SUCCESS_LINE" && r=1 || r=0
check "docker daemon down -> does NOT print the unqualified success line" "$r"
grep -q 'Cannot connect to the Docker daemon' <<< "$out_dead" && r=0 || r=1
check "docker daemon down -> names the reason, not just the fact" "$r"

out_nodir="$(run_case nodir 1 no)"
has_line "$out_nodir" "$WARN_LINE" && r=0 || r=1
check "~/.ostler absent -> warns the teardown never ran" "$r"
has_line "$out_nodir" "$SUCCESS_LINE" && r=1 || r=0
check "~/.ostler absent -> does NOT print the unqualified success line" "$r"

# CONTROL: the assertion must be able to fail. The old shape printed the
# success line unconditionally; prove that shape would be caught here.
old_out="$(printf '%s\n' "$SUCCESS_LINE")"
has_line "$old_out" "$SUCCESS_LINE" && r=0 || r=1
check "CONTROL: the pre-fix output IS matched by the success predicate" "$r"
has_line "$old_out" "$WARN_LINE" && r=1 || r=0
check "CONTROL: the pre-fix output carries no warning, so the fix is what added it" "$r"

printf '  examined 9 assertions across 3 teardown outcomes\n'
[ "$fails" -eq 0 ] || { printf 'FAIL: %s assertion(s) failed.\n' "$fails" >&2; exit 1; }
printf 'PASS: the uninstaller cannot claim a removal it did not perform.\n'
