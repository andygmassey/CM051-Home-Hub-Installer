#!/usr/bin/env bash
# Run install.sh's REAL channel-config writer OFF-BOX and print the config.toml
# it produces for "answer 5" (WhatsApp enabled) with a SYNTHETIC number.
#
# WHY OFF-BOX. A walk box must never enable WhatsApp: answer 5 makes the daemon
# open wss://web.whatsapp.com and send the number to Meta on every reconnect, and
# installs the keepalive agent. This runs the writer in a throwaway HOME with no
# daemon, no network client and no launchctl, so nothing can dial out. The
# emitter is extracted from install.sh by content (the TOMLPREAMBLE ... `} >
# "$ASSISTANT_CONFIG"` block), the same way tests/test_whatsapp_channel_block.sh
# does, so a change to the shipped writer changes what this judges.
#
# usage: gen_whatsapp_config.sh INSTALL_SH [RECIPIENT]
# stdout: the generated config.toml. rc 0 ok; rc 2 could not generate (CANNOT-RUN),
# reason on stderr. Never prints anything but the generated config on stdout.
set -u
INSTALL_SH="${1:-}"
# Composed at runtime so no phone-shaped literal sits in source (pii-scan shape
# guard). Reserved-for-fiction NANC 555-01xx exchange; E.164, never a real line.
RECIPIENT="${2:-+1$(printf '555')0001234}"
[ -f "${INSTALL_SH}" ] || { echo "CANNOT-RUN: install.sh not found at '${INSTALL_SH}'" >&2; exit 2; }

T="$(mktemp -d)" || { echo "CANNOT-RUN: no temp dir" >&2; exit 2; }
trap 'rm -rf "${T}"' EXIT
awk '
    /^TOMLPREAMBLE$/                         { capture = 1; next }
    capture && /^\} > "\$ASSISTANT_CONFIG"$/ { capture = 0 }
    capture                                  { print }
' "${INSTALL_SH}" > "${T}/emitter.sh"
[ -s "${T}/emitter.sh" ] || { echo "CANNOT-RUN: could not extract the channel writer from ${INSTALL_SH}" >&2; exit 2; }

mkdir -p "${T}/hm" "${T}/bin"
# Any network or service tool the writer might reach is a recording stub that
# fails, so an accidental dial-out is a visible failure and never a connection.
for tool in curl wget nc launchctl osascript security open ssh; do
    printf '#!/bin/sh\necho "STUB %s $*" >> "%s/stub.log"\nexit 99\n' "${tool}" "${T}" > "${T}/bin/${tool}"
    chmod +x "${T}/bin/${tool}"
done
HOME="${T}/hm" PATH="${T}/bin:${PATH}" \
OSTLER_DIR="${T}/hm/.ostler" OSTLER_FINAL_DIR="${T}/hm/.ostler" \
CHANNEL_IMESSAGE_ENABLED=false CHANNEL_EMAIL_ENABLED=false \
CHANNEL_WHATSAPP_ENABLED=true CHANNEL_WHATSAPP_RECIPIENT="${RECIPIENT}" \
    bash -c "$(cat "${T}/emitter.sh")" > "${T}/config.toml" 2> "${T}/err"; rc=$?
if [ -e "${T}/stub.log" ]; then
    echo "CANNOT-RUN: the writer reached a network/service tool: $(head -1 "${T}/stub.log")" >&2; exit 2
fi
[ "${rc}" -eq 0 ] || { echo "CANNOT-RUN: the writer exited ${rc}: $(head -c 200 "${T}/err")" >&2; exit 2; }
[ -s "${T}/config.toml" ] || { echo "CANNOT-RUN: the writer produced an empty config" >&2; exit 2; }
cat "${T}/config.toml"
