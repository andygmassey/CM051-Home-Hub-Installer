#!/bin/bash
# install.sh NEVER installs gws (the Google Workspace CLI), and never runs one.
#
# Privacy blocker from the v1.0.123 walk: install.sh downloaded gws into
# /usr/local/bin, and ical-server then ran it about every 4 minutes with no
# Google account and no consent, opening TLS to Google each time. v1 has no
# Google connector, so the gws_install step is now a no-op (the gate inside
# ical-server is pinned by tests/test_vendored_gws_never_spawned_without_consent.py).
#
# This EXECUTES the real step: the gws_install region is cut out of install.sh
# (from GWS_VERSION= to the ical-query.sh section), the destination is moved
# into a temp dir, and curl is a stub on PATH that records every call. Run
# under /bin/bash (3.2 on macOS, the shell install.sh ships under).
#   A. cold box: no curl, no file at the destination, the "not installed" line.
#   B. a gws from an earlier install: left in place and NOT executed (the old
#      step ran "$GWS_BIN_DEST" --version as an idempotency probe).
#   C. MUTANT, every run: the guard reverted to the shipped-before condition
#      must call curl. If it does not, this harness is blind and says so.
#   D. the closing message names no gws sign-in, and the uninstall note
#      mentions gws only when one is present.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${SUBJECT:-$ROOT/install.sh}"
T="$(mktemp -d -t gws-step.XXXXXX)"
trap 'rm -rf "$T"' EXIT
fail=0
FAIL() { echo "FAIL: $*"; fail=$((fail+1)); }

region() {  # $1 = install.sh path -> the gws step, destination moved under $T
    awk '/^GWS_VERSION="/{on=1} /^# 2\. ~\/\.ostler\/ical\/ical-query\.sh/{on=0} on' "$1" \
        | sed -e "s#/usr/local/bin/gws#$T/dest/gws#g"
}

run_step() {  # $1 = region file; prints the step's log; records curl + gws calls
    mkdir -p "$T/stub" "$T/dest"
    : > "$T/curl.calls"; : > "$T/gws.calls"
    printf '#!/bin/sh\necho "$*" >> "%s"\nexit 1\n' "$T/curl.calls" > "$T/stub/curl"
    chmod +x "$T/stub/curl"
    PATH="$T/stub:/usr/bin:/bin" /bin/bash -c '
        progress() { echo "PROGRESS $*"; }
        ok()   { echo "OK $*"; }
        warn() { echo "WARN $*"; }
        info() { echo "INFO $*"; }
        source "$1"' _ "$1" 2>&1
}

region "$SUBJECT" > "$T/region.sh"
[[ -s "$T/region.sh" ]] || { echo "CANNOT-RUN: gws_install region not found in $SUBJECT"; exit 2; }
grep -q '"gws_install"' "$T/region.sh" || { echo "CANNOT-RUN: region has no gws_install step id"; exit 2; }

# A. cold box
out="$(run_step "$T/region.sh")"
[[ -s "$T/curl.calls" ]] && FAIL "A: curl was called: $(cat "$T/curl.calls")"
[[ -e "$T/dest/gws" ]] && FAIL "A: a gws binary was written to the destination"
grep -q "Google Workspace CLI not installed" <<<"$out" || FAIL "A: no 'not installed' line; got: $out"
[[ $fail -eq 0 ]] && echo "PASS: A cold box: curl calls 0, destination absent"

# B. a gws from an earlier install
rm -rf "$T/dest"; mkdir -p "$T/dest"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/gws.calls" > "$T/dest/gws"; chmod +x "$T/dest/gws"
before="$(cksum < "$T/dest/gws")"
out="$(run_step "$T/region.sh")"
[[ -s "$T/gws.calls" ]] && FAIL "B: the existing gws was EXECUTED: $(cat "$T/gws.calls")"
[[ -s "$T/curl.calls" ]] && FAIL "B: curl was called"
[[ "$(cksum < "$T/dest/gws")" == "$before" ]] || FAIL "B: the existing gws was modified"
grep -q "INFO A Google Workspace CLI from an earlier install" <<<"$out" || FAIL "B: no info line; got: $out"
[[ $fail -eq 0 ]] && echo "PASS: B earlier gws: executed 0 times, unchanged"

# C. mutant: the guard reverted must reach curl (proves A can see a download)
rm -rf "$T/dest"
grep -q '^if true; then  # PRIVACY' "$T/region.sh" || FAIL "C: guard line not found (moved?)"
sed -e 's/^if true; then  # PRIVACY.*/if [[ -z "$GWS_ARCH_LABEL" ]]; then/' \
    -e 's/^    if \[\[ -e "\$GWS_BIN_DEST" \]\]; then info .*/    warn "unsupported arch"/' \
    "$T/region.sh" > "$T/mutant.sh"
run_step "$T/mutant.sh" >/dev/null
if [[ -s "$T/curl.calls" ]]; then
    echo "PASS: C mutant (guard reverted) called curl $(wc -l < "$T/curl.calls" | tr -d ' ') time(s): caught"
else
    FAIL "C: the mutant called no curl, so A is blind"
fi

# D. customer-facing text
f0=$fail
if grep -nE '^echo .*(sign-in through the gws|Run gws with no arguments)' "$SUBJECT"; then
    FAIL "D: the closing message still sends the customer to gws"
fi
unguarded="$(grep -nE '^echo .*/usr/local/bin/gws' "$SUBJECT" || true)"
[[ -n "$unguarded" ]] && FAIL "D: uninstall note names gws unconditionally: $unguarded"
grep -qE '^if \[\[ -e /usr/local/bin/gws \]\]; then echo ' "$SUBJECT" || FAIL "D: guarded uninstall note not found"
[[ $fail -eq $f0 ]] && echo "PASS: D closing message and uninstall note checked"

if [[ $fail -ne 0 ]]; then echo "RESULT: $fail failure(s)"; exit 1; fi
echo "RESULT: all pass"
