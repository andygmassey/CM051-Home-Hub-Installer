#!/usr/bin/env bash
#
# tests/test_ollama_pin_install_verifies_sha256.sh
#
# Behavioural test of install.sh's pinned Ollama install
# (_ostler_ollama_pin_install, between the OSTLER-OLLAMA-PIN-FN markers).
# It EXECUTES the shipped function with a stub `curl` on PATH that "downloads"
# a fixture archive, and real shasum + tar. No network, no real Ollama, no
# keychain, no TCC.
#
#   case A  archive matches the recorded sha256        -> rc 0, engine + marker in place
#   case B  archive tampered (one byte appended)       -> rc 12, dest NOT created
#   case C  archive carries an Ollama.app (an updater) -> rc 14, dest NOT created
#           (the auto-update-off step: the engine we serve must have no app)
#   case D  download fails                             -> rc 11, dest NOT created
#   case E  pin marker for another version             -> _is_current says NO
#   case F  install.sh maps rc 12 to ERR-07-OLLAMA-PIN-SHA256-MISMATCH
#   case G  EXISTING install (our plist + an Ollama answering) and the
#           download fails -> _apply rc 0, OLLAMA_APP_BIN is the old binary,
#           plist byte-identical, ollama_pin=deferred recorded, and the
#           installer's own "already running" predicate matches (so the
#           plist is never rewritten)
#   case H  FRESH install (no plist) and the download fails -> rc 11, no
#           deferral: the caller's hard failure still fires
#   case I  plist present but nothing answers :11434 -> rc 11, no deferral
#           (a dead install is not a working one)
#   case J  EXISTING install and a tampered archive -> deferred too (rc 0)
#   case L  the installer's "agent must run the PINNED binary" block, run for
#           real: a plist running ${OLLAMA_PIN_DIR}/ollama passes; a plist
#           running the customer's self-updating /Applications/Ollama.app
#           FAILS ERR-07-OLLAMA-AGENT-NOT-PINNED; the same plist under a
#           DEFERRED pin is recorded (ollama_server=... pinned=no), not failed
#   case N  NO MODEL PULLS WHILE UNPINNED: the installer's real embed-model
#           block and pull wrapper run with a stub `ollama` that logs pulls.
#           Deferred pin + model absent -> ZERO pulls, the install does not
#           stop, the hold is warned and logged (model_pull=held). Control:
#           the same block with the pin installed DOES pull. Run with the
#           guard removed (bash $0 with a mutated install.sh) it goes RED.
#   case R  the next run RETRIES: after a deferral, a run whose download
#           works installs the pin and records ollama_pin=installed
#
# The sha256 in each case is computed from the fixture by this test and set on
# OLLAMA_PIN_SHA256 in the test shell, so case B is a real mismatch between a
# recorded value and the bytes on disk, exactly the production comparison.
#
# British English; " -- " not em dashes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
[ -f "$INSTALL_SH" ] || { echo "CANNOT RUN: ${INSTALL_SH} does not exist" >&2; exit 2; }
command -v shasum >/dev/null 2>&1 || { echo "CANNOT RUN: shasum not on PATH" >&2; exit 2; }

fails=0; ran=0
pass() { ran=$((ran + 1)); echo "  PASS  $1"; }
bad()  { ran=$((ran + 1)); fails=$((fails + 1)); echo "  FAIL  $1" >&2; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# ── extract the shipped function, refuse if the markers are absent ────────
FN="$W/pin_fn.sh"
sed -n '/^# OSTLER-OLLAMA-PIN-FN-BEGIN$/,/^# OSTLER-OLLAMA-PIN-FN-END$/p' "$INSTALL_SH" > "$FN"
if ! grep -q '_ostler_ollama_pin_install()' "$FN" || ! grep -q '_ostler_ollama_pin_is_current()' "$FN"; then
    echo "FAIL: install.sh has no _ostler_ollama_pin_install / _is_current between the OSTLER-OLLAMA-PIN-FN markers. The Ollama engine is not installed from a pinned, hash-verified release." >&2
    exit 1
fi

# ── fixtures ──────────────────────────────────────────────────────────────
mk_tree() {  # mk_tree <dir> [with_app]
    mkdir -p "$1"
    printf '#!/bin/sh\necho "ollama version is 0.0.0-fixture"\n' > "$1/ollama"
    printf '#!/bin/sh\nexit 0\n' > "$1/llama-server"
    chmod +x "$1/ollama" "$1/llama-server"
    if [ "${2:-}" = with_app ]; then mkdir -p "$1/Ollama.app/Contents/MacOS"; fi
}
mk_tree "$W/src_good"; tar -czf "$W/good.tgz" -C "$W/src_good" .
mk_tree "$W/src_app" with_app; tar -czf "$W/app.tgz" -C "$W/src_app" .
cp "$W/good.tgz" "$W/tampered.tgz"; printf 'x' >> "$W/tampered.tgz"
sha_of() { local s; s="$(shasum -a 256 "$1")"; echo "${s%% *}"; }
GOOD_SHA="$(sha_of "$W/good.tgz")"
APP_SHA="$(sha_of "$W/app.tgz")"
[ "$GOOD_SHA" != "$(sha_of "$W/tampered.tgz")" ] || { echo "CANNOT RUN: tampered fixture hashes equal to good" >&2; exit 2; }

# stub curl: copies $STUB_SRC to the -o target; STUB_FAIL=1 exits 22 (curl -f)
mkdir -p "$W/bin"
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
out=""; all="$*"
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
case "$all" in *11434*) [ "${STUB_TAGS:-1}" = 0 ] && exit 0; exit 7 ;; esac
echo "stub-curl called" >> "${STUB_LOG:?}"
[ "${STUB_FAIL:-0}" = 1 ] && exit 22
cp "${STUB_SRC:?}" "$out"
STUB
chmod +x "$W/bin/curl"

run_case() {  # run_case <src_archive> <expected_sha> <fail?> ; prints rc
    local dest="$W/fakehome/.ostler/runtime/ollama-9.9.9"
    rm -rf "$W/fakehome"; mkdir -p "$W/fakehome"
    : > "$W/curl.log"
    PATH="$W/bin:$PATH" STUB_SRC="$1" STUB_FAIL="$3" STUB_LOG="$W/curl.log" \
    OLLAMA_PIN_VERSION=9.9.9 OLLAMA_PIN_URL="https://example.invalid/ollama-darwin.tgz" \
    OLLAMA_PIN_SHA256="$2" bash -c '. "$1"; _ostler_ollama_pin_install "$2"' _ "$FN" "$dest" \
        2> "$W/stderr" && echo 0 || echo $?
}
DEST="$W/fakehome/.ostler/runtime/ollama-9.9.9"
leftover() { find "$W/fakehome" -name '*.partial.*' 2>/dev/null | wc -l | tr -d ' '; }

# A
rc="$(run_case "$W/good.tgz" "$GOOD_SHA" 0)"
if [ "$rc" = 0 ] && [ -x "$DEST/ollama" ] && [ -x "$DEST/llama-server" ] \
   && [ "$(cat "$DEST/.ostler-ollama-pin")" = "9.9.9 $GOOD_SHA" ] && [ "$(leftover)" = 0 ] \
   && grep -q 'stub-curl called' "$W/curl.log"; then
    pass "A: matching archive installs the engine and writes the pin marker (rc=0)"
else bad "A: matching archive -> rc=$rc, dest=$(ls "$DEST" 2>&1 | tr '\n' ' ') stderr=$(cat "$W/stderr")"; fi
A_OK=$rc
# E (uses A's tree)
if [ "$A_OK" = 0 ]; then
    OLLAMA_PIN_VERSION=9.9.9 OLLAMA_PIN_SHA256="$GOOD_SHA" bash -c '. "$1"; _ostler_ollama_pin_is_current "$2"' _ "$FN" "$DEST"
    e1=$?
    OLLAMA_PIN_VERSION=9.9.10 OLLAMA_PIN_SHA256="$GOOD_SHA" bash -c '. "$1"; _ostler_ollama_pin_is_current "$2"' _ "$FN" "$DEST"
    e2=$?
    if [ "$e1" = 0 ] && [ "$e2" != 0 ]; then pass "E: _is_current is YES for the pin, NO for a different version"
    else bad "E: _is_current pin=$e1 (want 0), other-version=$e2 (want non-0)"; fi
else bad "E: not run, case A did not install"; fi

# B
rc="$(run_case "$W/tampered.tgz" "$GOOD_SHA" 0)"
if [ "$rc" = 12 ] && [ ! -e "$DEST" ] && [ "$(leftover)" = 0 ] && grep -q 'sha256 mismatch' "$W/stderr"; then
    pass "B: tampered archive is refused (rc=12), nothing installed"
else bad "B: tampered archive -> rc=$rc (want 12), dest exists=$([ -e "$DEST" ] && echo yes || echo no), stderr=$(cat "$W/stderr")"; fi

# C
rc="$(run_case "$W/app.tgz" "$APP_SHA" 0)"
if [ "$rc" = 14 ] && [ ! -e "$DEST" ] && [ "$(leftover)" = 0 ]; then
    pass "C: an archive carrying an Ollama.app (self-updater) is refused (rc=14)"
else bad "C: archive with .app -> rc=$rc (want 14), stderr=$(cat "$W/stderr")"; fi

# D
rc="$(run_case "$W/good.tgz" "$GOOD_SHA" 1)"
if [ "$rc" = 11 ] && [ ! -e "$DEST" ] && [ "$(leftover)" = 0 ]; then
    pass "D: a failed download is refused (rc=11), nothing installed"
else bad "D: failed download -> rc=$rc (want 11)"; fi

# F: the caller maps each rc to its own error code
blk="$(sed -n '/_ostler_ollama_pin_apply "\$OLLAMA_PIN_DIR" .* || _ollama_pin_rc=\$?/,/esac/p' "$INSTALL_SH")"
if grep -qE '^[[:space:]]*12\) fail_with_code "ERR-07-OLLAMA-PIN-SHA256-MISMATCH"' <<<"$blk" \
   && grep -qE '^[[:space:]]*11\) fail_with_code "ERR-07-OLLAMA-PIN-DOWNLOAD-FAILED"' <<<"$blk" \
   && grep -qE '^[[:space:]]*\*\)  fail_with_code "ERR-07-OLLAMA-PIN-UNPACK-FAILED"' <<<"$blk"; then
    pass "F: install.sh maps rc 11/12/other to DOWNLOAD-FAILED / SHA256-MISMATCH / UNPACK-FAILED"
else bad "F: install.sh does not call _ostler_ollama_pin_install with the rc->error-code mapping"; fi

# ── G/H/I/J: a failed pin on an EXISTING install defers, on a FRESH one fails ──
OLD_BIN="$W/oldhome/Applications/Ollama.app/Contents/Resources/ollama"
mk_existing() {  # mk_existing: our plist pointing at a working old binary
    rm -rf "$W/oldhome"; mkdir -p "$(dirname "$OLD_BIN")" "$W/oldhome/Library/LaunchAgents"
    printf '#!/bin/sh\necho old\n' > "$OLD_BIN"; chmod +x "$OLD_BIN"
    cat > "$W/oldhome/Library/LaunchAgents/com.ostler.ollama.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ostler.ollama</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OLD_BIN}</string>
        <string>serve</string>
    </array>
</dict>
</plist>
PL
    cp "$W/oldhome/Library/LaunchAgents/com.ostler.ollama.plist" "$W/plist.before"
}
PLIST="$W/oldhome/Library/LaunchAgents/com.ostler.ollama.plist"
STATE="$W/oldhome/.ostler/state/ollama-pin"
run_apply() {  # run_apply <src> <sha> <fail?> <tags_answer 0|1> <plist> ; prints "rc|bin|outcome"
    local dest="$W/oldhome/.ostler/runtime/ollama-9.9.9"
    : > "$W/curl.log"
    PATH="$W/bin:$PATH" STUB_SRC="$1" STUB_FAIL="$3" STUB_TAGS="$4" STUB_LOG="$W/curl.log" \
    OLLAMA_PIN_VERSION=9.9.9 OLLAMA_PIN_URL="https://example.invalid/ollama-darwin.tgz" \
    OLLAMA_PIN_SHA256="$2" OLLAMA_PIN_STATE_FILE="$STATE" OLLAMA_APP_BIN="$dest/ollama" \
    bash -c '. "$1"; r=0; _ostler_ollama_pin_apply "$2" "$3" || r=$?; printf "%s|%s|%s\n" "$r" "$OLLAMA_APP_BIN" "${OLLAMA_PIN_OUTCOME:-}"' \
        _ "$FN" "$dest" "$5" 2> "$W/stderr"
}

# G
mk_existing
out="$(run_apply "$W/good.tgz" "$GOOD_SHA" 1 0 "$PLIST")"
g_rc="${out%%|*}"; g_rest="${out#*|}"; g_bin="${g_rest%%|*}"; g_out="${g_rest#*|}"
# the installer's own skip predicate, read from install.sh, against the result
skip_line="$(grep -m1 -E '^if curl -sf http://localhost:11434/api/tags &>/dev/null && \[\[ -f "\$OLLAMA_PLIST" \]\] && grep -qF "<string>\$\{OLLAMA_APP_BIN\}</string>" "\$OLLAMA_PLIST"; then$' "$INSTALL_SH")"
if [ "$g_rc" = 0 ] && [ "$g_bin" = "$OLD_BIN" ] && [ "$g_out" = deferred ] \
   && cmp -s "$PLIST" "$W/plist.before" \
   && grep -qx 'ollama_pin=deferred' "$STATE" && grep -qx 'ollama_pin_reason=pin_install_rc=11' "$STATE" \
   && [ ! -e "$W/oldhome/.ostler/runtime/ollama-9.9.9" ] \
   && [ -n "$skip_line" ] && grep -qF "<string>${g_bin}</string>" "$PLIST"; then
    pass "G: existing install + failed download -> rc 0, keeps $(basename "$g_bin") from the old plist, plist untouched, ollama_pin=deferred, installer skip predicate matches"
else bad "G: existing+fail -> rc=$g_rc bin=$g_bin outcome=$g_out plist_same=$(cmp -s "$PLIST" "$W/plist.before" && echo yes || echo no) state=$(tr '\n' ' ' < "$STATE" 2>/dev/null) skip_line=${skip_line:+found}"; fi

# J: tampered archive on an existing install defers the same way
mk_existing
out="$(run_apply "$W/tampered.tgz" "$GOOD_SHA" 0 0 "$PLIST")"
if [ "${out%%|*}" = 0 ] && [ "${out##*|}" = deferred ] && cmp -s "$PLIST" "$W/plist.before" \
   && grep -qx 'ollama_pin_reason=pin_install_rc=12' "$STATE"; then
    pass "J: existing install + sha256 mismatch -> deferred (rc 0), plist untouched"
else bad "J: existing+tampered -> $out state=$(tr '\n' ' ' < "$STATE" 2>/dev/null)"; fi

# H: fresh install, no plist
rm -rf "$W/oldhome"; mkdir -p "$W/oldhome"
out="$(run_apply "$W/good.tgz" "$GOOD_SHA" 1 0 "$W/oldhome/Library/LaunchAgents/com.ostler.ollama.plist")"
if [ "${out%%|*}" = 11 ] && [ "${out##*|}" = "" ] && [ ! -e "$STATE" ]; then
    pass "H: fresh install + failed download -> rc 11, not deferred (the caller's hard failure fires)"
else bad "H: fresh+fail -> $out (want 11 and no outcome), state exists=$([ -e "$STATE" ] && echo yes || echo no)"; fi

# I: plist present but nothing answers on :11434
mk_existing; rm -f "$STATE"
out="$(run_apply "$W/good.tgz" "$GOOD_SHA" 1 1 "$PLIST")"
if [ "${out%%|*}" = 11 ] && [ "${out##*|}" = "" ] && [ ! -e "$STATE" ]; then
    pass "I: plist present but Ollama not answering -> rc 11, not deferred"
else bad "I: dead existing -> $out"; fi

# K: the caller warns on deferral and still hard-fails otherwise
if grep -qE '^[[:space:]]*_ostler_ollama_pin_apply "\$OLLAMA_PIN_DIR" "\$\{HOME\}/Library/LaunchAgents/com\.ostler\.ollama\.plist" \|\| _ollama_pin_rc=\$\?$' "$INSTALL_SH" \
   && grep -qE 'warn "\$\(printf "\$MSG_WARN_OLLAMA_PIN_DEFERRED"' "$INSTALL_SH" \
   && grep -q '^MSG_WARN_OLLAMA_PIN_DEFERRED=' "${REPO_ROOT}/install.sh.strings.en-GB.sh"; then
    pass "K: install.sh calls _apply on the agent plist, warns MSG_WARN_OLLAMA_PIN_DEFERRED, and the string exists"
else bad "K: install.sh does not wire _ostler_ollama_pin_apply + the deferral warning"; fi

# L: the post-step pinned-agent check, lifted from install.sh and executed
post="$W/postcheck.sh"
awk '/^# ── THE AGENT MUST RUN THE PINNED BINARY/{f=1} /^# ── 3\.3b Ollama log rotation/{f=0} f{print}' "$INSTALL_SH" > "$post"
mk_plist() {  # mk_plist <path> <binary>
    mkdir -p "$(dirname "$1")"
    printf '<?xml version="1.0"?>\n<plist version="1.0">\n<dict>\n    <key>Label</key>\n    <string>com.ostler.ollama</string>\n    <key>ProgramArguments</key>\n    <array>\n        <string>%s</string>\n        <string>serve</string>\n    </array>\n</dict>\n</plist>\n' "$2" > "$1"
}
run_post() {  # run_post <plist binary> <outcome> ; prints "rc|code|log"
    local h="$W/posthome"; rm -rf "$h"; mkdir -p "$h"
    mk_plist "$h/com.ostler.ollama.plist" "$1"
    OLLAMA_PIN_DIR="$h/.ostler/runtime/ollama-9.9.9" OLLAMA_PLIST="$h/com.ostler.ollama.plist" \
    OLLAMA_PIN_OUTCOME="$2" INSTALL_LOG="$h/install.log" \
    bash -c '. "$1"; fail_with_code() { echo "CODE $1"; exit 1; }; MSG_FAIL_OLLAMA_AGENT_NOT_PINNED="%s %s %s"; . "$2"; echo REACHED' _ "$FN" "$post" > "$h/out" 2>&1
    printf '%s|%s|%s\n' "$(grep -c '^REACHED$' "$h/out")" "$(sed -n 's/^CODE //p' "$h/out")" "$(cat "$h/install.log" 2>/dev/null)"
}
APP="/Applications/Ollama.app/Contents/Resources/ollama"
if [ "$(wc -l < "$post" | tr -d ' ')" -ge 5 ] && grep -q 'ERR-07-OLLAMA-AGENT-NOT-PINNED' "$post"; then
    r_pin="$(run_post "$W/posthome/.ostler/runtime/ollama-9.9.9/ollama" installed)"
    r_app="$(run_post "$APP" installed)"
    r_def="$(run_post "$APP" deferred)"
    if [ "${r_pin%%|*}" = 1 ] && [ "${r_app%%|*}" = 0 ] && [ "$(cut -d'|' -f2 <<<"$r_app")" = ERR-07-OLLAMA-AGENT-NOT-PINNED ] \
       && [ "${r_def%%|*}" = 1 ] && grep -qF "ollama_server=${APP} pinned=no reason=pin_deferred" <<<"$r_def"; then
        pass "L: agent on the pinned binary passes; agent on /Applications/Ollama.app FAILS ERR-07-OLLAMA-AGENT-NOT-PINNED; under a deferred pin it is recorded, not failed"
    else bad "L: pinned=[$r_pin] app=[$r_app] deferred=[$r_def]"; fi
else bad "L: install.sh has no 'agent must run the PINNED binary' block ending at 3.3b"; fi

# N: no model pulls while the pin is deferred, through the REAL pull path
PULLFN="$W/pullfn.sh"
awk '/^_gui_ollama_pull\(\) \{/{f=1} f{print} f && /^}$/{f=0; n++} n==2{exit}' "$INSTALL_SH" > "$PULLFN"
awk '/^ollama_pull_with_retry\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$INSTALL_SH" >> "$PULLFN"
EMBED="$W/embed_block.sh"
awk '/^if ollama list 2>\/dev\/null \| grep -q "nomic-embed-text"; then$/{f=1} f{print} f && /^fi$/{exit}' "$INSTALL_SH" > "$EMBED"
mkdir -p "$W/obin"
cat > "$W/obin/ollama" <<'OL'
#!/bin/sh
case "$1" in
  list) exit 0 ;;
  pull) echo "$2" >> "${PULL_LOG:?}"; exit 0 ;;
esac
exit 0
OL
chmod +x "$W/obin/ollama"
run_embed() {  # run_embed <outcome> ; prints "pulls|reached|code|held_log"
    local d="$W/n_$1"; rm -rf "$d"; mkdir -p "$d"; : > "$d/pulls"
    PATH="$W/obin:$PATH" PULL_LOG="$d/pulls" OLLAMA_PIN_OUTCOME="$1" OLLAMA_PIN_VERSION=9.9.9 \
    INSTALL_LOG="$d/install.log" STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh" \
    bash -c 'set -Eeuo pipefail; . "$STRINGS"; ok(){ :; }; info(){ :; }; warn(){ echo "WARN $*"; }
             fail_with_code(){ echo "CODE $1"; exit 1; }; gui_emit(){ :; }; gui_log(){ :; }; sleep(){ :; }
             . "$1"; . "$2"; . "$3"; echo REACHED' _ "$FN" "$PULLFN" "$EMBED" > "$d/out" 2>&1
    printf '%s|%s|%s|%s\n' "$(grep -c . "$d/pulls")" "$(grep -c '^REACHED$' "$d/out")" \
        "$(sed -n 's/^CODE //p' "$d/out")" "$(grep -c '^model_pull=held model=nomic-embed-text reason=ollama_unpinned$' "$d/install.log" 2>/dev/null)"
}
if [ -s "$PULLFN" ] && [ -s "$EMBED" ] && grep -q 'ollama_pull_with_retry nomic-embed-text' "$EMBED"; then
    n_def="$(run_embed deferred)"; n_ok="$(run_embed installed)"
    if [ "$n_def" = "0|1||1" ] && [ "${n_ok%%|*}" = 1 ] && [ "$(cut -d'|' -f2 <<<"$n_ok")" = 1 ]; then
        pass "N: deferred pin -> 0 model pulls, install continues, model_pull=held logged; control: pin installed -> 1 pull"
    else bad "N: deferred=[pulls|reached|code|held]=$n_def installed=$n_ok (want 0|1||1 and 1|1|...)"; fi
else bad "N: could not lift the pull wrapper or the embed-model block from install.sh"; fi

# R: the next run retries the pin and clears the deferral
mk_existing; rm -f "$STATE"
first="$(run_apply "$W/good.tgz" "$GOOD_SHA" 1 0 "$PLIST")"
second="$(run_apply "$W/good.tgz" "$GOOD_SHA" 0 0 "$PLIST")"
if [ "${first##*|}" = deferred ] && [ "${second%%|*}" = 0 ] && [ "${second##*|}" = installed ] \
   && grep -qx 'ollama_pin=installed' "$STATE" && [ -x "$W/oldhome/.ostler/runtime/ollama-9.9.9/ollama" ]; then
    pass "R: after a deferral, the next run with a working download installs the pin and records ollama_pin=installed"
else bad "R: first=[$first] second=[$second] state=$(tr '\n' ' ' < "$STATE" 2>/dev/null)"; fi

echo ""
if [ "$fails" -gt 0 ] || [ "$ran" -ne 14 ]; then
    echo "FAIL: ollama pin install: ${fails} of ${ran} cases failed (expected 14 run)" >&2
    exit 1
fi
echo "PASS: ollama pin install: 14/14 -- sha256 enforced, updater refused, fresh failure loud, existing install deferred untouched, agent must run the pinned binary, no pulls while unpinned, next run retries"
