#!/usr/bin/env bash
#
# tests/test_reconnect_nudge_sender.sh
#
# The weekly reconnect nudge sender (wow gate item 3, v1.0.108), exercised as
# the REAL script extracted from install.sh, with a stub composer, a stub curl
# and a synthetic HOME. Nothing is sent anywhere.
#
# Asserted: it delivers what the composer wrote on the owner's own brief channel
# with kind=reconnect_nudge; it records who went out ONLY after a successful
# delivery (a refused /announce must not spend the week); "nothing due", an old
# daemon without the command, Ostler Pro paused and quiet hours are quiet exits;
# a composer failure and a refused announce are exit 75; no channel is 78.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

# The first python3 on the CALLER's PATH (it needs tomllib, 3.11+); the stubs put
# their own curl ahead of everything else.
PYDIR="$(dirname "$(command -v python3)")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SENDER="$WORK/sender.sh"
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-reconnect-nudge-sender" <<.RECONNECTEOF.$/{f=1;next} /^RECONNECTEOF$/{f=0} f' "$INSTALL" > "$SENDER"
if [ "$(wc -l < "$SENDER")" -lt 40 ]; then
    bad "could not extract the sender from install.sh"; echo "PASS=${PASS} FAIL=${FAIL}"; exit 1
fi
ok "extracted the sender from install.sh ($(wc -l < "$SENDER" | tr -d ' ') lines)"
bash -n "$SENDER" && ok "the extracted sender parses" || bad "the extracted sender does not parse"

# A stub curl first on PATH records every call and answers $CURL_RC.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'CURLSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/curl.log"
while [ $# -gt 0 ]; do
    if [ "$1" = "--data-binary" ]; then printf '%s' "$2" > "$STUB_DIR/body.json"; fi
    shift
done
exit "${CURL_RC:-0}"
CURLSTUB
chmod +x "$WORK/bin/curl"

# A stub composer. Behaviour by $COMPOSER_MODE.
cat > "$WORK/composer" <<'COMPSTUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/composer.log"
echo "ws=${ZEROCLAW_WORKSPACE:-unset}" >> "$STUB_DIR/composer.env"
case "$1 $2" in
  "reconnect-nudge --keys-file")
    case "$COMPOSER_MODE" in
      message)  printf 'k1\nk2\n' > "$3"; printf 'Worth saying hello this week\nJane Doe: quiet\nDraft: hi Jane\nNothing has been sent.\n'; exit 0 ;;
      nothing)  echo "reconnect-nudge: nothing to send (weekly limit reached or paused)" >&2; exit 3 ;;
      old)      echo "error: unrecognized subcommand 'reconnect-nudge'" >&2; exit 2 ;;
      broken)   echo "boom" >&2; exit 1 ;;
    esac ;;
  "reconnect-nudge --mark-sent") cp "$3" "$STUB_DIR/marked.keys"; exit 0 ;;
esac
exit 9
COMPSTUB
chmod +x "$WORK/composer"

run_sender() {  # run_sender <composer-mode> [env assignments...]
    local mode="$1"; shift
    rm -rf "$WORK/home" "$WORK/stub"; mkdir -p "$WORK/home/.ostler/assistant-config" "$WORK/stub"
    printf '[[cron.jobs]]\nid = "morning-brief"\n[cron.jobs.delivery]\nmode = "announce"\nchannel = "imessage"\nto = "owner"\n' \
        > "$WORK/home/.ostler/assistant-config/config.toml"
    env -i PATH="$WORK/bin:$PYDIR:/usr/bin:/bin" HOME="$WORK/home" STUB_DIR="$WORK/stub" \
        COMPOSER_MODE="$mode" OSTLER_BRIEF_COMPOSER="$WORK/composer" OSTLER_BRIEF_QUIET_START=25 OSTLER_BRIEF_QUIET_END=0 \
        "$@" bash "$SENDER" >/dev/null 2>"$WORK/stderr"
    return $?
}

echo "== delivered =="
run_sender message; rc=$?
[ "$rc" -eq 0 ] && ok "a composed nudge is delivered: exit 0" || bad "delivered case exit $rc"
grep -q '"kind": "reconnect_nudge"' "$WORK/stub/body.json" 2>/dev/null && ok "posted with kind=reconnect_nudge" || bad "announce body lacks kind=reconnect_nudge: $(cat "$WORK/stub/body.json" 2>/dev/null)"
grep -q '"channel": "imessage"' "$WORK/stub/body.json" 2>/dev/null && ok "posted on the owner's own brief channel (imessage, from config.toml)" || bad "wrong channel"
grep -q 'Draft: hi Jane' "$WORK/stub/body.json" 2>/dev/null && ok "the posted message is what the composer wrote" || bad "message not carried"
[ "$(cat "$WORK/stub/marked.keys" 2>/dev/null | tr '\n' ',')" = "k1,k2," ] && ok "the people who went out were recorded AFTER delivery" || bad "keys not recorded: $(cat "$WORK/stub/marked.keys" 2>/dev/null)"

grep -q "^ws=$WORK/home/.ostler/assistant-config$" "$WORK/stub/composer.env" 2>/dev/null && ok "the composer is given the assistant's workspace (ZEROCLAW_WORKSPACE) so it can read Pro state" || bad "composer ran without ZEROCLAW_WORKSPACE: $(cat "$WORK/stub/composer.env" 2>/dev/null)"

echo "== a refused announce must not spend the week =="
run_sender message CURL_RC=22; rc=$?
[ "$rc" -eq 75 ] && ok "announce refused: exit 75 (CANNOT-DELIVER)" || bad "refused announce exit $rc, wanted 75"
[ ! -e "$WORK/stub/marked.keys" ] && ok "nothing was recorded after a refused announce" || bad "recorded despite a failed delivery"

echo "== quiet steady states =="
run_sender nothing; rc=$?; [ "$rc" -eq 0 ] && [ ! -e "$WORK/stub/curl.log" ] && ok "nothing due: exit 0, no announce" || bad "nothing-due case: rc=$rc"
run_sender old; rc=$?; [ "$rc" -eq 0 ] && [ ! -e "$WORK/stub/curl.log" ] && ok "daemon without the command: exit 0, no announce" || bad "old-daemon case: rc=$rc"
run_sender message OSTLER_BRIEF_QUIET_START=0 OSTLER_BRIEF_QUIET_END=0; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$WORK/stub/composer.log" ] && ok "quiet hours: exit 0, composer not even run" || bad "quiet-hours case: rc=$rc"

echo "== failures are loud =="
run_sender broken; rc=$?; [ "$rc" -eq 75 ] && [ ! -e "$WORK/stub/curl.log" ] && ok "composer failure: exit 75, nothing announced" || bad "composer-failure case: rc=$rc"
rm -rf "$WORK/home"; mkdir -p "$WORK/home/.ostler/assistant-config" "$WORK/stub"; : > "$WORK/home/.ostler/assistant-config/config.toml"
env -i PATH="$WORK/bin:$PYDIR:/usr/bin:/bin" HOME="$WORK/home" STUB_DIR="$WORK/stub" COMPOSER_MODE=message \
    OSTLER_BRIEF_COMPOSER="$WORK/composer" OSTLER_BRIEF_QUIET_START=25 OSTLER_BRIEF_QUIET_END=0 bash "$SENDER" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 78 ] && ok "no brief channel configured: exit 78" || bad "no-channel case: rc=$rc, wanted 78"

echo "== Ostler Pro paused =="
rm -rf "$WORK/home" "$WORK/stub"; mkdir -p "$WORK/home/.ostler/assistant-config" "$WORK/home/.ostler/services/ical-server" "$WORK/stub"
printf '[[cron.jobs]]\nid = "morning-brief"\n[cron.jobs.delivery]\nmode = "announce"\nchannel = "imessage"\nto = "owner"\n' > "$WORK/home/.ostler/assistant-config/config.toml"
printf 'import sys\nsys.exit(3)\n' > "$WORK/home/.ostler/services/ical-server/subscription_gate.py"
env -i PATH="$WORK/bin:$PYDIR:/usr/bin:/bin" HOME="$WORK/home" STUB_DIR="$WORK/stub" COMPOSER_MODE=message \
    OSTLER_BRIEF_COMPOSER="$WORK/composer" OSTLER_BRIEF_QUIET_START=25 OSTLER_BRIEF_QUIET_END=0 bash "$SENDER" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$WORK/stub/composer.log" ] && ok "gate exit 3 pauses: exit 0, composer not run" || bad "paused case: rc=$rc"

echo "== wiring in install.sh =="
grep -q 'com\.ostler\.reconnect-nudge-sender' "$INSTALL" && ok "LaunchAgent label present" || bad "label missing"
grep -q '<key>StartCalendarInterval</key>' "$INSTALL" && ok "weekly calendar schedule present" || bad "no StartCalendarInterval"
grep -qE '^    com\.ostler\.reconnect-nudge-sender$' "$INSTALL" && ok "in OSTLER_LAUNCHAGENT_LABELS (the uninstaller removes it)" || bad "not in OSTLER_LAUNCHAGENT_LABELS"
grep -q 'MSG_OK_RECONNECT_NUDGE_SENDER_INSTALLED=' "$REPO_ROOT/install.sh.strings.en-GB.sh" && ok "customer strings are in the catalogue" || bad "strings missing"

echo
echo "PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ]
