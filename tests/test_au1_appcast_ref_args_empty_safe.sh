#!/usr/bin/env bash
#
# tests/test_au1_appcast_ref_args_empty_safe.sh
#
# Regression test for the AU-1 appcast publish path: both documented
# SKIP branches hard-failed the publish.
#
# What it guards
# --------------
# gui/Makefile sets `SHELL := /bin/bash` with
# `.SHELLFLAGS := -euo pipefail -c`, so `set -u` is active for the whole
# publish-appcast recipe. On macOS /bin/bash is 3.2.57, where expanding
# an EMPTY array under `set -u` is an ERROR, not an empty expansion.
#
# The recipe builds REF_ARGS conditionally:
#
#     REF set + reference dir EXISTS   REF_ARGS=(--reference-app ...)   fine
#     REF set + reference dir ABSENT   REF_ARGS=()                      died
#     REF empty (guard disabled)       REF_ARGS=()                      died
#
# and then expanded it bare as "$${REF_ARGS[@]}". The last two rows are
# exactly the states the recipe prints "[NOTE] ... SKIPPED" for, on the
# documented "fresh box / first release" and "set empty to disable"
# paths. They printed the friendly note and then died four lines later
# on `REF_ARGS[@]: unbound variable` -- a message naming a shell
# variable, not the condition. A fail-open that failed closed.
#
# Nothing had ever executed those two branches. `publish-appcast` is
# reachable only from ORM's local `make ship`, on a box where
# /Applications/Ostler.app exists, which is the single branch that
# worked.
#
# WHY THIS TEST IS SPLIT IN TWO
# -----------------------------
# The defect is a bash 3.2 behaviour and it DOES NOT REPRODUCE on bash
# 4.4+. Measured:
#
#     bash 3.2.57  A=(); "${A[@]}"  ->  A[@]: unbound variable, rc=1
#     bash 5.3.15  A=(); "${A[@]}"  ->  argc unchanged,          rc=0
#
# CM051 CI runs on ubuntu-latest, which ships bash 5. A purely
# behavioural test would therefore pass GREEN on the runner while being
# completely blind to the defect it exists to catch -- the same
# green-while-blind shape this repo keeps finding.
#
# So:
#   ARMS 1-4  BEHAVIOURAL. Require bash 3.2 semantics. Where those are
#             unavailable they report CANNOT-RUN and are NOT counted as
#             passes. CANNOT-RUN is a third state, never a pass.
#   ARM 5     SOURCE GUARD. Portable, runs everywhere, and is the arm
#             that actually gates CI: the bare expansion must be absent
#             and the guarded expansion must be present.
#
# --selftest additionally proves ARM 5 can go RED, by running it against
# a mutated copy carrying the pre-fix bare expansion. A guard with no
# demonstrated RED is decoration.
#
# Pure bash + standard tools. Exit 0 on pass, non-zero on fail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="${REPO_ROOT}/gui/Makefile"

PASS=0
FAIL=0
CANNOT_RUN=0

ok()      { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()     { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
cannot()  { printf '  \033[0;33mCANNOT-RUN\033[0m  %s\n' "$1"; CANNOT_RUN=$((CANNOT_RUN + 1)); }

# The exact expansion the recipe uses, and the pre-fix one it replaced.
GUARDED_FORM='"$${REF_ARGS[@]+"$${REF_ARGS[@]}"}"'
BARE_FORM='"$${REF_ARGS[@]}"'

# ---------------------------------------------------------------------
# Does this machine have a bash whose empty-array-under-set-u ERRORS?
# Detected by BEHAVIOUR, not by parsing a version string, because the
# version is a proxy and the behaviour is the thing under test.
# ---------------------------------------------------------------------
find_strict_bash() {
    local candidate
    for candidate in /bin/bash "$(command -v bash 2>/dev/null || true)"; do
        [ -n "${candidate}" ] || continue
        [ -x "${candidate}" ] || continue
        if ! "${candidate}" -euo pipefail \
             -c 'A=(); set -- x "${A[@]}"' 2>/dev/null; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

printf '\n=== AU-1 appcast REF_ARGS empty-array safety ===\n\n'

STRICT_BASH="$(find_strict_bash || true)"

if [ -n "${STRICT_BASH}" ]; then
    printf 'behavioural arms using: %s (%s)\n\n' \
        "${STRICT_BASH}" "$("${STRICT_BASH}" --version | head -1)"

    # ARM 1 -- THE RED CONTROL.
    # The pre-fix expansion, empty array, under the Makefile's own flags.
    # This MUST fail. If it succeeds, this harness cannot see the defect
    # and every other arm below is meaningless.
    if "${STRICT_BASH}" -euo pipefail \
         -c 'REF_ARGS=(); set -- --min-os 13.0 "${REF_ARGS[@]}"' 2>/dev/null; then
        bad "ARM 1 RED CONTROL: pre-fix bare expansion did NOT fail -- harness is blind, ignore all other arms"
    else
        ok  "ARM 1 RED CONTROL: pre-fix bare expansion fails on empty array (defect reproduces)"
    fi

    # ARM 2 -- guarded + EMPTY: must survive, and must not inject a
    # phantom empty argument.
    argc="$("${STRICT_BASH}" -euo pipefail \
        -c 'REF_ARGS=(); set -- --min-os 13.0 "${REF_ARGS[@]+"${REF_ARGS[@]}"}"; printf %s "$#"' 2>/dev/null)"
    if [ "${argc:-}" = "2" ]; then
        ok  "ARM 2 guarded + empty: survives, argc=2 (no phantom empty arg)"
    else
        bad "ARM 2 guarded + empty: expected argc=2, got '${argc:-<died>}'"
    fi

    # ARM 3 -- guarded + NON-EMPTY: both args still reach the publisher.
    argc="$("${STRICT_BASH}" -euo pipefail \
        -c 'REF_ARGS=(--reference-app /tmp); set -- --min-os 13.0 "${REF_ARGS[@]+"${REF_ARGS[@]}"}"; printf %s "$#"' 2>/dev/null)"
    if [ "${argc:-}" = "4" ]; then
        ok  "ARM 3 guarded + non-empty: argc=4 (both --reference-app and its value passed)"
    else
        bad "ARM 3 guarded + non-empty: expected argc=4, got '${argc:-<died>}'"
    fi

    # ARM 4 -- guarded + a path CONTAINING A SPACE stays ONE argument.
    # This is the whole reason REF_ARGS is an array rather than a string,
    # and /Applications paths routinely contain spaces.
    last="$("${STRICT_BASH}" -euo pipefail \
        -c 'REF_ARGS=(--reference-app "/tmp/Ostler Reference.app"); set -- "${REF_ARGS[@]+"${REF_ARGS[@]}"}"; printf "%s|%s" "$#" "$2"' 2>/dev/null)"
    if [ "${last:-}" = "2|/tmp/Ostler Reference.app" ]; then
        ok  "ARM 4 guarded + path with a space: stays ONE argument, unsplit"
    else
        bad "ARM 4 guarded + path with a space: expected '2|/tmp/Ostler Reference.app', got '${last:-<died>}'"
    fi
else
    cannot "ARMS 1-4 behavioural: no bash on this machine errors on empty-array-under-set-u"
    printf '         (bash 4.4+ does not reproduce the defect. This is NOT a pass.\n'
    printf '          ARM 5 below is the portable arm and it still gates.)\n'
fi

# ---------------------------------------------------------------------
# ARM 5 -- SOURCE GUARD. Portable. This is what gates CI.
# ---------------------------------------------------------------------
printf '\n'
check_source() {
    local file="$1" label="$2" expect_pass="$3"
    local has_guarded=0 has_bare=0

    grep -qF -- "${GUARDED_FORM}" "${file}" && has_guarded=1
    # The bare form is a substring of the guarded one, so count only
    # occurrences that are NOT part of a guarded expansion.
    if grep -F -- "${BARE_FORM}" "${file}" | grep -qvF -- "${GUARDED_FORM}"; then
        has_bare=1
    fi

    if [ "${has_guarded}" = "1" ] && [ "${has_bare}" = "0" ]; then
        if [ "${expect_pass}" = "yes" ]; then
            ok "ARM 5 ${label}: guarded expansion present, bare expansion absent"
        else
            bad "ARM 5 ${label}: expected this MUTATED copy to be caught, it was not -- guard is blind"
        fi
    else
        if [ "${expect_pass}" = "yes" ]; then
            bad "ARM 5 ${label}: guarded=${has_guarded} bare=${has_bare} -- publish-appcast will die on both SKIP paths"
        else
            ok "ARM 5 ${label}: mutated copy correctly REFUSED (guard proved RED)"
        fi
    fi
}

if [ ! -f "${MAKEFILE}" ]; then
    bad "ARM 5: gui/Makefile not found at ${MAKEFILE} -- cannot verify, failing closed"
else
    check_source "${MAKEFILE}" "gui/Makefile" "yes"

    if [ "${1:-}" = "--selftest" ]; then
        MUTANT="$(mktemp -t au1_refargs_mutant)"
        # Reintroduce the pre-fix bare expansion. ARM 5 must catch it.
        #
        # LITERAL replace via awk index/substr, NOT sed. The forms contain
        # `[@]` and `$`, which sed reads as a character class and an
        # anchor, so a sed substitution silently matches nothing and the
        # "mutation" is a no-op -- a self-test that proves nothing while
        # printing PASS. Caught by the cmp guard below on the first run.
        awk -v g="${GUARDED_FORM}" -v b="${BARE_FORM}" '
            {
                i = index($0, g)
                if (i > 0) { $0 = substr($0, 1, i - 1) b substr($0, i + length(g)) }
                print
            }' "${MAKEFILE}" > "${MUTANT}"
        if cmp -s "${MAKEFILE}" "${MUTANT}"; then
            bad "ARM 5 selftest: mutation changed NOTHING -- the mutation itself is broken, not a pass"
        else
            check_source "${MUTANT}" "MUTATED copy (pre-fix form restored)" "no"
        fi
        rm -f "${MUTANT}"
    fi
fi

printf '\n---\nPASS %s   FAIL %s   CANNOT-RUN %s\n' "${PASS}" "${FAIL}" "${CANNOT_RUN}"

if [ "${FAIL}" -gt 0 ]; then
    printf '\nRESULT: FAIL\n'
    exit 1
fi
if [ "${PASS}" -eq 0 ]; then
    printf '\nRESULT: FAIL -- zero arms passed. A run that asserts nothing is not a pass.\n'
    exit 1
fi
printf '\nRESULT: PASS\n'
exit 0
