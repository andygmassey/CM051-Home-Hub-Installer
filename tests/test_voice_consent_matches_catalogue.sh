#!/usr/bin/env bash
#
# tests/test_voice_consent_matches_catalogue.sh
#
# The installer's EU voice-consent screen and the legal catalogue must agree
# about WHERE the voice fingerprint is stored and WHERE consent is withdrawn.
#
# WHY THIS EXISTS
# ---------------
# Until 2026-08-15 they contradicted each other, on main, on an Article 9
# screen. install.sh told the customer the fingerprint is stored "locally on
# this Mac", that it "stays on this Mac", and that they could turn it off in
# "Settings -> Privacy -> Voice recognition" on the Mac.
#
# vendor/legal/consent_strings.py (EU_VOICE_SPEAKER_ID_CONSENT, the version
# whose hash the consent record pins) says the opposite: the fingerprint lives
# in an encrypted store on the iPhone, is "never sent to this Mac", and is
# withdrawn in the iPhone app.
#
# The shipped code settles it. vendor/cm041/assistant_api/ical-server.py
# records it as a locked invariant: "the Hub holds no voiceprint registry. The
# biometric never crosses the wire in either direction." The Hub sees a text
# label and an opaque reference the DEVICE supplied. So the installer was the
# only artefact making the claim, and it was the one the customer read before
# ticking the box.
#
# Two harms, and the second is the one that bites daily: the Article 9 consent
# was taken against a false description of where special-category data is
# processed, AND the withdrawal route was fiction -- a customer following the
# Mac Settings path finds nothing to turn off, because there is nothing there.
#
# WHAT THIS ASSERTS, AND WHY IT IS SHAPED THIS WAY
# ------------------------------------------------
# Not string equality. install.sh reflows the catalogue for an 80-column
# terminal and wraps runs in colour escapes, so a byte-compare would be red on
# every harmless rewrap -- the red-while-fixed shape this repo has already been
# bitten by three times in one night. It asserts the CLAIMS instead, on
# whitespace-normalised text with the escapes stripped:
#
#   PRESENCE  the installer makes each load-bearing claim the catalogue makes
#   ABSENCE   the installer makes none of the four retracted Mac-side claims
#
# The absence half is the load-bearing half. A future edit that ADDS correct
# iPhone wording while LEAVING the old Mac wording in place would satisfy a
# presence-only check while shipping a screen that says both.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
CATALOGUE="$REPO_ROOT/vendor/legal/consent_strings.py"
fails=0

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

for f in "$INSTALL_SH" "$CATALOGUE"; do
    [ -f "$f" ] || {
        echo "test_voice_consent_matches_catalogue: CANNOT RUN -- missing $f" >&2
        echo "                                      Nothing was compared. Not a pass." >&2
        exit 2
    }
done

# The installer block: from the voice-consent heading to the prompt that closes
# it. Comment lines are stripped -- the rationale comment above the block
# legitimately QUOTES the retracted Mac wording to explain why it went, and an
# absence check that read comments would fail on its own explanation.
BLOCK="$(awk '/Recognising voices on calls/{f=1} f{print} /consent_voice_eu/{if(f) exit}' "$INSTALL_SH" \
         | grep -v '^[[:space:]]*#')"

if [ -z "$BLOCK" ]; then
    echo "test_voice_consent_matches_catalogue: CANNOT RUN -- could not locate the" >&2
    echo "  voice-consent block in install.sh. An empty extract compares clean," >&2
    echo "  which is exactly the false green this file exists to prevent." >&2
    exit 2
fi

# Normalise to PROSE, which is the thing being compared.
#
# The shell wrapper has to come off before the newlines do. A first cut of this
# stripped escapes and collapsed lines but left `echo "` / `"` in place, so a
# sentence the installer wraps across two echo calls flattened to
#     ... any time in the" echo "  iPhone app under Settings ...
# and every multi-line phrase missed. Three assertions failed on a tree that
# was correct -- the same red-while-fixed shape this test exists to catch,
# reproduced inside the test itself.
#
# Order matters: drop `echo`/`echo -e` and the quotes that delimit each
# argument, unescape \", drop colour variables and raw ANSI, THEN join lines.
norm() {
    sed -E 's/^[[:space:]]*echo( -e)?[[:space:]]*//; s/\\"/\x01/g; s/"//g; s/\x01/"/g' \
        | sed -E 's/\$\{[A-Z_]+\}//g; s/\\033\[[0-9;]*m//g' \
        | tr '\n' ' ' | tr -s ' ' | tr '[:upper:]' '[:lower:]'
}
FLAT="$(printf '%s' "$BLOCK" | norm)"
CAT_FLAT="$(sed -n '/EU_VOICE_SPEAKER_ID_CONSENT/,/^)/p' "$CATALOGUE" | norm)"

echo "voice consent: installer copy vs legal catalogue"

# --- the catalogue itself must still say what we are pinning to -------------
# If the catalogue is edited to the Mac story, this test must not keep
# asserting the iPhone story against install.sh. Check the source of truth
# first, or this becomes a gate comparing a file to a memory of another file.
for claim in "on your iphone" "never sent to this mac" "in the iphone app"; do
    case "$CAT_FLAT" in
        *"$claim"*) ;;
        *) fail "catalogue no longer says \"$claim\" -- source of truth moved; re-derive this test before trusting it" ;;
    esac
done
[ "$fails" -eq 0 ] && pass "catalogue still states the iPhone-side storage model"

# --- PRESENCE: the installer makes the catalogue's load-bearing claims ------
present() {
    case "$FLAT" in
        *"$1"*) pass "installer states: \"$1\"" ;;
        *) fail "installer does NOT state: \"$1\"" ;;
    esac
}
present "in the ostler iphone app"
present "on your iphone"
present "never sent to this mac"
present "in the iphone app under settings -> voice recognition"
present "no voice fingerprint is ever created"

# --- ABSENCE: none of the four retracted Mac-side claims survive ------------
# The load-bearing half. Adding the right words without removing the wrong ones
# ships a screen that says both, and a presence-only check would pass it.
absent() {
    case "$FLAT" in
        *"$1"*) fail "installer STILL claims: \"$1\" -- retracted Mac-side wording survived" ;;
        *) pass "retracted wording absent: \"$1\"" ;;
    esac
}
absent "locally on this mac"
absent "the fingerprints stay on this mac"
absent "voice fingerprints stored on this mac"
absent "settings -> privacy -> voice recognition"

# --- the screen must still be an Article 9 screen ---------------------------
# A well-meaning simplification could strip the legal framing along with the
# wrong location. The lawful basis is not optional copy.
for claim in "article 9(1)" "article 9(2)(a)" "biometric data"; do
    case "$FLAT" in
        *"$claim"*) pass "article 9 framing intact: \"$claim\"" ;;
        *) fail "article 9 framing lost: \"$claim\" no longer in the block" ;;
    esac
done

echo ""
if [ "$fails" -gt 0 ]; then
    printf '\033[0;31mvoice consent: %d mismatch(es) between the installer and the catalogue\033[0m\n' "$fails"
    exit 1
fi
printf '\033[0;32mvoice consent: installer and catalogue agree on where the biometric lives\033[0m\n'
