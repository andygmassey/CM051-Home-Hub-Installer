#!/usr/bin/env bash
# tests/test_enrichment_on_by_default_with_optout.sh
#
# Owner ruling this session: public-data enrichment is ON by default, and the
# customer can opt OUT at install. This runs the REAL consent block lifted from
# install.sh (not a grep alone) under three recorded answers:
#   Enter (no input)  -> accepted, agent installed      (default is yes)
#   n                 -> declined, agent not installed  (opt-out works)
#   y                 -> accepted
# and checks the install-screen copy key exists in every locale, with the
# opt-out-scope sentence in the English sources.
#
# Overrides for red-on-main runs:
#   INSTALL_SH=<path>        default: <repo>/install.sh
#   STRINGS_DIR=<dir>        default: <repo>
# Exit: 0 pass, 1 fail, 2 cannot-run.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${REPO}/install.sh}"
STRINGS_DIR="${STRINGS_DIR:-${REPO}}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cannot() { echo "CANNOT RUN: $*" >&2; exit 2; }
[ -r "$INSTALL_SH" ] || cannot "install.sh not readable: $INSTALL_SH"

status=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; status=1; }

# --- 1. the block, lifted verbatim from install.sh -------------------------
start="$(grep -n -m1 '^OSTLER_ENRICH_AGENT_ENABLED=' "$INSTALL_SH" | cut -d: -f1)"
end="$(grep -n -m1 '^export OSTLER_CONSENT_ENRICHMENT_DECISION' "$INSTALL_SH" | cut -d: -f1)"
[ -n "$start" ] && [ -n "$end" ] || cannot "could not locate the enrichment consent block"
sed -n "${start},${end}p" "$INSTALL_SH" > "$WORK/block.sh"

# Stub gui_read exactly as the installer's GUI contract behaves for a yesno:
# an empty answer takes the seeded default; the answer is given on stdin.
# legal_prevails_note is a display helper, stubbed to a no-op.
run_block() {  # $1 = answer ("" for Enter)
    local ans="$1"
    bash -c '
        set -u
        MSG_PROMPT_CONSENT_ENRICHMENT_TITLE=t; MSG_PROMPT_CONSENT_ENRICHMENT_HELP=h
        legal_prevails_note() { :; }
        gui_read() {
            local title="$1" kind="$2" def="$3" ans
            IFS= read -r ans || true
            [ -z "$ans" ] && ans="$def"
            printf "%s" "$ans"
        }
        source "$1" >/dev/null 2>&1
        case "$OSTLER_ENRICH_AGENT_ENABLED" in 1) w=on;; *) w=off;; esac
        printf "%s|%s" "$w" "$OSTLER_CONSENT_ENRICHMENT_DECISION"
    ' _ "$WORK/block.sh" <<< "$ans"
}

out_default="$(run_block "")"
out_no="$(run_block "n")"
out_yes="$(run_block "y")"

[ "$out_default" = "on|accepted" ] && pass "default (Enter) enables the agent: $out_default" \
    || fail "default (Enter) should enable the agent, got: $out_default"
[ "$out_no" = "off|declined" ] && pass "opt-out (n) disables the agent: $out_no" \
    || fail "opt-out (n) should disable the agent, got: $out_no"
[ "$out_yes" = "on|accepted" ] && pass "explicit yes enables the agent: $out_yes" \
    || fail "explicit yes should enable the agent, got: $out_yes"

# --- 2. the gate that installs the agent reads the same flag ---------------
if grep -q 'if \[\[ "${OSTLER_ENRICH_AGENT_ENABLED:-0}" == "1" \]\]; then' "$INSTALL_SH" \
   && grep -q '_install_enrichment_agent$' "$INSTALL_SH"; then
    pass "install gate reads OSTLER_ENRICH_AGENT_ENABLED before _install_enrichment_agent"
else
    fail "install gate for _install_enrichment_agent not found in the expected shape"
fi

# --- 3. copy key exists in every locale; scope sentence in the English source
missing=0
for f in "$STRINGS_DIR"/install.sh.strings.*.sh; do
    grep -q '^MSG_PROMPT_CONSENT_ENRICHMENT_HELP=' "$f" || { echo "  missing in $(basename "$f")"; missing=$((missing+1)); }
done
n_locales="$(ls "$STRINGS_DIR"/install.sh.strings.*.sh | wc -l | tr -d ' ')"
[ "$missing" -eq 0 ] && pass "consent help key present in all $n_locales locales" \
    || fail "consent help key missing in $missing of $n_locales locales"

for f in en-GB en-US; do
    if grep -q 'Ostler looks up public topics such as music, books, films and places online' "$STRINGS_DIR/install.sh.strings.$f.sh" \
       && grep -q 'or the people you know' "$STRINGS_DIR/install.sh.strings.$f.sh"; then
        pass "scope sentence present in $f"
    else
        fail "scope sentence absent from $f"
    fi
done

# no em dashes in the new copy
if grep -q '—' "$STRINGS_DIR/install.sh.strings.en-GB.sh"; then
    fail "em dash found in en-GB strings"
else
    pass "no em dash in en-GB strings"
fi

exit $status
