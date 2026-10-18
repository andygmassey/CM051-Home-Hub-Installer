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
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
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
blk="$(sed -n '/_ostler_ollama_pin_install "\$OLLAMA_PIN_DIR" || _ollama_pin_rc=\$?/,/esac/p' "$INSTALL_SH")"
if grep -qE '^[[:space:]]*12\) fail_with_code "ERR-07-OLLAMA-PIN-SHA256-MISMATCH"' <<<"$blk" \
   && grep -qE '^[[:space:]]*11\) fail_with_code "ERR-07-OLLAMA-PIN-DOWNLOAD-FAILED"' <<<"$blk" \
   && grep -qE '^[[:space:]]*\*\)  fail_with_code "ERR-07-OLLAMA-PIN-UNPACK-FAILED"' <<<"$blk"; then
    pass "F: install.sh maps rc 11/12/other to DOWNLOAD-FAILED / SHA256-MISMATCH / UNPACK-FAILED"
else bad "F: install.sh does not call _ostler_ollama_pin_install with the rc->error-code mapping"; fi

echo ""
if [ "$fails" -gt 0 ] || [ "$ran" -ne 6 ]; then
    echo "FAIL: ollama pin install: ${fails} of ${ran} cases failed (expected 6 run)" >&2
    exit 1
fi
echo "PASS: ollama pin install: 6/6 -- sha256 enforced, updater refused, download failure loud"
