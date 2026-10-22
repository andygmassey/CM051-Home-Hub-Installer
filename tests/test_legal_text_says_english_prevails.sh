#!/usr/bin/env bash
# English prevails over any translation (Andy, 2026-10-22).
# The terms the installer shows, and the licence file, state it. Legal text
# stays English in every strings file, so the clause is English only.
#
# Asserts: the clause is defined; the terminal screen echoes it inside
# _ostler_ask_personal_use_terms; the GUI acknowledge sheet text (the HELP
# string) carries it; LICENSE carries it.
set -u
cd "$(dirname "$0")/.."
CLAUSE="These terms are written in English. Any translation is provided for convenience only. If a translation differs from the English version, the English version prevails."
fail=0
chk() { if ! "$@"; then echo "FAIL: $DESC"; fail=1; else echo "ok:   $DESC"; fi; }

DESC="strings define MSG_TERMS_LANGUAGE with the clause"
chk grep -qF "MSG_TERMS_LANGUAGE=\"Language. ${CLAUSE}\"" install.sh.strings.en-GB.sh

DESC="the GUI acknowledge sheet text carries the clause"
help_block="$(awk '/^MSG_PROMPT_TERMS_PERSONAL_USE_HELP=/{f=1} f{print} f&&/"$/{exit}' install.sh.strings.en-GB.sh)"
chk grep -qF "${CLAUSE}" <<<"${help_block}"

DESC="install.sh echoes MSG_TERMS_LANGUAGE inside _ostler_ask_personal_use_terms"
body="$(awk '/^_ostler_ask_personal_use_terms\(\)/{f=1} f{print} f&&/^}/{exit}' install.sh)"
chk grep -qF 'MSG_TERMS_LANGUAGE' <<<"${body}"

DESC="LICENSE carries the clause"
chk bash -c 'tr "\n" " " < LICENSE | tr -s " " | grep -qF "$1"' _ "${CLAUSE}"

DESC="no em dash in the clause lines"
chk bash -c '! grep -n "MSG_TERMS_LANGUAGE" install.sh.strings.en-GB.sh | grep -q $'"'"'\xe2\x80\x94'"'"''

exit "${fail}"
