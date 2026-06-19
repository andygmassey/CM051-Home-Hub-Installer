#!/usr/bin/env bash
#
# test_contact_email_coverage_guard.sh
#
# Regression test for the silent email-drop class: at hydrate time a
# phone-only Contacts export imports "N contacts" and prints a clean
# "Imported N contacts", looking identical to a healthy run -- yet every
# card reached the graph phone-only (card->phone ~97%, card->email ~1%).
#
# The fix adds a post-hydrate EMAIL-COVERAGE GUARD in install.sh: after a
# successful contact import it compares phone vs email identifier counts in
# Oxigraph and warns LOUDLY when phones are plentiful but emails are
# essentially absent (the phone-only-export signature), so this drop can
# never silently ship again.
#
# Axes:
#   1. install.sh defines the _guard_email_coverage function.
#   2. The guard is wired INSIDE the count>0 success branch (the only path
#      where the drop is invisible), and uses the email-coverage string.
#   3. The string MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW exists.
#   4. Behaviour: carved + run with a stubbed curl -> phone-only graph
#      WARNS; healthy phone+email graph stays SILENT; tiny phone population
#      stays silent (no false alarm).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
STRINGS_SH="$REPO_ROOT/install.sh.strings.en-GB.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing"
    echo "test_contact_email_coverage_guard: FAILED" >&2
    exit 1
fi

# Axis 1: the guard function exists.
if ! grep -q '_guard_email_coverage()' "$INSTALL_SH"; then
    failure "install.sh never defines _guard_email_coverage -- no post-hydrate email-coverage check"
fi

# Axis 2: it is invoked inside the success branch and references the string.
if ! grep -q '_guard_email_coverage || true' "$INSTALL_SH"; then
    failure "_guard_email_coverage is defined but never invoked"
fi
if ! grep -q 'MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW' "$INSTALL_SH"; then
    failure "guard does not reference the email-coverage warning string"
fi

# Axis 3: the string is defined.
if ! grep -q '^MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW=' "$STRINGS_SH"; then
    failure "MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW not defined in the en-GB strings"
fi

# ---------------------------------------------------------------------------
# Axis 4: carve the function out and exercise it with a stubbed curl + warn.
# ---------------------------------------------------------------------------
GUARD_BLOCK="$(awk '/_guard_email_coverage\(\) \{/{p=1} p{print} p&&/^        \}$/{exit}' "$INSTALL_SH")"
if [[ -z "$GUARD_BLOCK" ]]; then
    failure "could not carve the _guard_email_coverage function body"
    echo "test_contact_email_coverage_guard: FAILED" >&2
    exit 1
fi

# Helper: run the guard with a curl stub that returns $1 phones then $2
# emails (curl is called phone-first, email-second in the function), and a
# warn stub that records whether it fired. Echoes "WARN" or "SILENT".
run_guard() {
    local phones="$1" emails="$2" contacts="$3"
    bash --noprofile --norc -c '
        set -uo pipefail
        _HYDRATE_OXIGRAPH="http://localhost:7878"
        _HYDRATE_CONTACTS_COUNT="'"$contacts"'"
        MSG_HYDRATE_CONTACTS_EMAIL_COVERAGE_LOW="low: %s %s %s"
        __PHONES="'"$phones"'"
        __EMAILS="'"$emails"'"
        # Stub curl: branch on the SPARQL query text (which carries the
        # identifierType) rather than a call counter -- the function calls
        # curl in $(...) subshells, so a counter would not survive.
        curl() {
            local args="$*"
            if [[ "$args" == *'"'"'"phone"'"'"'* ]]; then printf "n\n%s\n" "$__PHONES";
            else printf "n\n%s\n" "$__EMAILS"; fi
        }
        warn() { echo "WARN"; }
        '"$GUARD_BLOCK"'
        out="$(_guard_email_coverage)"
        if [[ -n "$out" ]]; then echo "WARN"; else echo "SILENT"; fi
    '
}

# Phone-only graph (1879 phones, 11 emails) -> WARN.
res="$(run_guard 1879 11 2398)"
if [[ "$res" != "WARN" ]]; then
    failure "phone-only graph (1879 phone / 11 email) did not warn (got: $res)"
fi

# Healthy graph (1879 phones, 1600 emails) -> SILENT.
res="$(run_guard 1879 1600 2398)"
if [[ "$res" != "SILENT" ]]; then
    failure "healthy graph (1879 phone / 1600 email) should stay silent (got: $res)"
fi

# Tiny phone population (10 phones, 0 emails) -> SILENT (no false alarm).
res="$(run_guard 10 0 12)"
if [[ "$res" != "SILENT" ]]; then
    failure "tiny phone population (10 phone) should not trip the guard (got: $res)"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_contact_email_coverage_guard: FAILED" >&2
    exit 1
fi
echo "test_contact_email_coverage_guard: PASSED"
