#!/usr/bin/env bash
# test_installer_app_pyc_is_seeded.sh
# =============================================================================
# ASSERTS THE INVOCATION, NOT A MENTION (board #757).
#
# WHY THIS EXISTS. seed-hub-payload-pyc.sh runs on $(OSTLER_APP_PATH) -- the
# SOURCE Ostler.app -- and nothing has ever seeded $(APP_PATH), the staged
# OstlerInstaller.app. Measured on the shipped v1.0.47 artefact:
#
#   ROOT                                                    .py   uncovered
#   OstlerInstaller.app (whole)                            1888         440
#     +- Resources/assistant-agent/OstlerAssistant.app        1           1
#     +- Resources/email-ingest (not a bundle)                1           1
#
# The two nested copies are ARM 8. The third (email-ingest) is outside any
# nested .app and was invisible to every framing used while hunting arm 8.
#
# WHY $(APP_PATH) AND NOT THE 1-FILE NESTED APP: the seeder's anti-vacuity floor
# refuses a root with fewer than 20 .py ("the payload did not stage"). The
# nested daemon app has ONE. $(APP_PATH) has ~1888, so it clears the floor by
# construction and covers all three uncovered copies at once.
#
# WHY IT IS SAFE HERE: gui/Makefile's sign-python-bundle already runs
# `codesign --force` over $(APP_PATH)/Contents/Resources/assistant-agent/
# OstlerAssistant.app and over the outer app. Seeding immediately BEFORE that
# step means the reseal is one named step away, in the same file -- not a
# reliance on some later --force --deep.
# =============================================================================
set -uo pipefail
MK="$(dirname "${BASH_SOURCE[0]}")/../Makefile"
fail=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

[ -r "${MK}" ] || { echo "CANNOT-RUN: no Makefile at ${MK}" >&2; exit 2; }

# --- extract the ship: prerequisite list, structurally ----------------------
SHIP="$(awk '/^ship:[[:space:]]/{sub(/^ship:[[:space:]]*/,""); print; exit}' "${MK}")"
[ -n "${SHIP}" ] || { echo "CANNOT-RUN: could not read the ship: prerequisite list" >&2; exit 2; }

idx() { local n=0 t; for t in ${SHIP}; do n=$((n+1)); [ "${t}" = "$1" ] && { echo "${n}"; return 0; }; done; echo 0; }

# --- CONTROLS FIRST: if these fail the extraction is broken, not the subject -
R="$(idx release)"; S="$(idx sign-python-bundle)"
[ "${R}" -gt 0 ] && ok "control: 'release' found in ship: at position ${R}" \
                || bad "control: 'release' NOT in ship: -- extraction is broken, not the subject"
[ "${S}" -gt 0 ] && ok "control: 'sign-python-bundle' found at position ${S}" \
                || bad "control: 'sign-python-bundle' NOT in ship: -- extraction is broken"
[ "${R}" -gt 0 ] && [ "${S}" -gt "${R}" ] \
  && ok "control: release (${R}) precedes sign-python-bundle (${S})" \
  || bad "control: ordering assumption does not hold"

# --- THE SUBJECT ------------------------------------------------------------
T="$(idx seed-installer-app-pyc)"
[ "${T}" -gt 0 ] \
  && ok "seed-installer-app-pyc IS a ship: prerequisite (position ${T})" \
  || bad "seed-installer-app-pyc is NOT invoked by ship: -- \$(APP_PATH) is never seeded"

if [ "${T}" -gt 0 ]; then
  [ "${T}" -gt "${R}" ] && [ "${T}" -lt "${S}" ] \
    && ok "it runs AFTER release (${R}) and BEFORE sign-python-bundle (${S})" \
    || bad "wrong position: ${T} is not strictly between ${R} and ${S}"
fi

# --- and the recipe must really call the seeder ON $(APP_PATH) --------------
#
# 🔴 NARROWED AFTER MY OWN MUTATION TEST CAUGHT THIS TEST BEING WRONG.
# The first version grepped the WHOLE recipe body for '$(APP_PATH)'. That body
# also contains the guard `[ ! -d "$(APP_PATH)" ]`, so when I mutated the SEEDER
# CALL to $(OSTLER_APP_PATH) the assertion still passed -- satisfied by a SIBLING
# LINE, not by its subject. A control a neighbour can satisfy is not a control.
# So: isolate the seeder invocation (its line plus backslash continuations) and
# assert the ROOT ARGUMENT on that alone.
BODY="$(awk '/^seed-installer-app-pyc:/{f=1;next} f&&/^[a-zA-Z0-9_.-]+:/{exit} f{print}' "${MK}")"
printf '%s' "${BODY}" | grep -q 'seed-hub-payload-pyc.sh' \
  && ok "recipe invokes seed-hub-payload-pyc.sh" \
  || bad "recipe does not invoke seed-hub-payload-pyc.sh"

# join continuations, then keep only the seeder command itself
# Join backslash continuations. ⚠️ TEST THE FLAG BEFORE STRIPPING IT -- my first
# attempt gsub'd the trailing backslash and THEN asked whether the line had one,
# so every line looked terminal and nothing ever joined. The test then failed on
# an UNMUTATED tree, which is how I caught it.
CALL="$(printf '%s\n' "${BODY}" \
        | awk '{ cont = ($0 ~ /\\[[:space:]]*$/); sub(/\\[[:space:]]*$/, ""); printf "%s", $0; if (!cont) print "" }' \
        | tr '\t' ' ' | tr -s ' ' | grep 'seed-hub-payload-pyc.sh' | head -1)"
# ⚠️ tabs FIRST, then squeeze. A Makefile continuation joins as `…pyc.sh" <TAB>
# "$(APP_PATH)"`, and `tr -s ' '` alone leaves the tab, so an adjacency pattern
# never matches and the test fails on a CORRECT tree. Found by running the
# unmutated case, which is the only reason the ladder below means anything.
[ -n "${CALL}" ] || bad "could not isolate the seeder invocation line"
case "${CALL}" in
  *'seed-hub-payload-pyc.sh" "$(APP_PATH)"'*|*"seed-hub-payload-pyc.sh\" \"\$(APP_PATH)\""*)
      ok "the seeder INVOCATION passes \$(APP_PATH) as its first argument" ;;
  *)  bad "the seeder invocation's root is not \$(APP_PATH) -- got: ${CALL}" ;;
esac

[ "${fail}" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL"; exit 1; }
