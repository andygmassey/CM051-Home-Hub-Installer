#!/usr/bin/env bash
# The spoken-capture consent screen must not tell the customer their
# captured audio is KEPT on their Mac. CM042 (Andy, 2026-10-18) now
# deletes call audio straight after on-device transcription, on success,
# failure and cancel, with no retention setting. The old copy said
# "Keeping the captured audio on your own Mac ...", which is now false.
#
# Reads the two surfaces the customer actually sees: the GUI legal_note
# (ViewCopy.json, parsed as JSON) and the TTY line (the strings file,
# sourced by bash exactly as install.sh sources it).
#
# Self-test first: the predicate must REJECT both earlier wordings (audio
# kept; audio transcribed "on this Mac", false for iPhone captures), or a
# passing run proves nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() { # $1 surface, $2 text
    local t="$2"
    if grep -qiE 'keeping the captured audio|audio on your own mac|storing (it|them) locally' <<< "$t"; then
        echo "FAIL $1: still claims captured audio is kept: $t"; return 1
    fi
    if grep -qiE 'transcribes captured audio on this Mac' <<< "$t"; then
        echo "FAIL $1: says audio is transcribed on this Mac, false for iPhone captures: $t"; return 1
    fi
    if ! grep -qF 'on the device that captured it and deletes the audio straight away' <<< "$t"; then
        echo "FAIL $1: does not say audio is deleted on the capturing device: $t"; return 1
    fi
    if ! grep -qF 'including to your own Mac' <<< "$t"; then
        echo "FAIL $1: does not say audio is never sent to the owner's Mac: $t"; return 1
    fi
    echo "PASS $1"
}

old="Keeping the captured audio on your own Mac does not remove this duty – Ostler never sends it anywhere, but you still need consent where your local law requires it."
if check self-test "$old" >/dev/null; then
    echo "FAIL self-test: predicate accepted the old retained-audio wording"; exit 1
fi
echo "PASS self-test: old wording rejected"
mac="Ostler transcribes captured audio on this Mac and deletes it straight away – it is never kept and never sent anywhere – but that does not remove this duty: you still need consent where your local law requires it."
if check self-test-mac "$mac" >/dev/null; then
    echo "FAIL self-test: predicate accepted the on-this-Mac wording"; exit 1
fi
echo "PASS self-test: on-this-Mac wording rejected"

gui="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["consent_spoken_capture"]["legal_note"])' gui/OstlerInstaller/Resources/ViewCopy.json)"
check "ViewCopy.json consent_spoken_capture.legal_note" "$gui" || fail=1

tty="$(bash -c 'source ./install.sh.strings.en-GB.sh >/dev/null 2>&1; printf "%s" "${MSG_CONSENT_SPOKEN_CAPTURE_LOCAL:-}"')"
[[ -n "$tty" ]] || { echo "FAIL tty: MSG_CONSENT_SPOKEN_CAPTURE_LOCAL is empty or unset"; exit 1; }
check "install.sh.strings MSG_CONSENT_SPOKEN_CAPTURE_LOCAL" "$tty" || fail=1

exit "$fail"
