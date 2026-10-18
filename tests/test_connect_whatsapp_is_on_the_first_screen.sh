#!/usr/bin/env bash
# The Connect WhatsApp step renders ABOVE the iPhone download and the
# pairing QR on the install-complete screen (v1.0.106).
#
# Andy's v1.0.105 console walk: the step never appeared for him although his
# config enabled it. The section sat third from the top, after the iPhone app
# download and the pairing QR, below the first screen. A code that expires in
# 180 seconds must be where the customer is already looking.
#
# EXIT: 0 pass, 1 fail, 2 CANNOT-RUN.
set -u
F="$(cd "$(dirname "$0")/.." && pwd)/gui/OstlerInstaller/Views/InstallCompleteView.swift"
[ -r "$F" ] || { echo "CANNOT-RUN: $F unreadable"; exit 2; }
body="$(awk '/var body: some View/{f=1} f' "$F")"
line_of() { printf '%s\n' "$body" | grep -n -E "^[[:space:]]*$1[[:space:]]*$" | head -1 | cut -d: -f1; }
wa="$(line_of 'WhatsAppLinkSection\(\)')"; ios="$(line_of 'getIosAppSection')"; pair="$(line_of 'pairingSection')"; now="$(line_of 'whatsHappeningSection')"
for v in wa ios pair now; do
  [ -n "${!v}" ] || { echo "CANNOT-RUN: could not find the $v call in the body"; exit 2; }
done
fail=0
[ "$wa" -lt "$ios" ] && echo "  ok    WhatsApp step is above the iPhone download" || { echo "  FAIL  WhatsApp step is below the iPhone download"; fail=1; }
[ "$wa" -lt "$pair" ] && echo "  ok    WhatsApp step is above the pairing QR" || { echo "  FAIL  WhatsApp step is below the pairing QR"; fail=1; }
[ "$now" -lt "$wa" ] && echo "  ok    WhatsApp step follows What's happening now" || { echo "  FAIL  WhatsApp step is above What's happening now"; fail=1; }
exit $fail
