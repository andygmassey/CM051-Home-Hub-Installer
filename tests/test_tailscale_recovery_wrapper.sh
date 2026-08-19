#!/usr/bin/env bash
#
# test_tailscale_recovery_wrapper.sh
#
# Ostler runs tailscaled in USERSPACE mode on a private socket under
# ~/.ostler/tailscale/. The stock `tailscale` CLI talks to the SYSTEM socket,
# so every command a customer might reasonably try -- status, up, ip -4 --
# silently addresses the wrong daemon.
#
# That turned the 3-minute browser sign-in into a ONE-SHOT. Miss it and there
# was no supported way back: no CLI on PATH pointed at our socket, no menu-bar
# app (we install the headless formula deliberately), no helper. The v1.0.15
# walk hit exactly this. The timeout message even advised `tailscale ip -4` --
# the stock CLI on the wrong socket, advice that cannot work.
#
# install.sh now writes ${OSTLER_DIR}/bin/ostler-tailscale BEFORE any sign-in
# is attempted, so recovery exists on every path: success, timeout, skip, or a
# failed brew install. Recovery must not depend on the thing that failed.
#
# Renders the wrapper out of install.sh and RUNS it. The first draft used an
# unquoted heredoc with escaped dollars and produced a wrapper whose
# $OSTLER_TS_SOCK and "$@" had both collapsed to a bare backslash. It looked
# fine in the diff. Only executing it caught that.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

printf '== test_tailscale_recovery_wrapper ==\n'

start=$(awk '/cat > "\$\{OSTLER_DIR\}\/bin\/ostler-tailscale"/ {print NR; exit}' "$INSTALL_SH")
end=$(awk -v s="$start" 'NR>s && /chmod 0755/ {print NR; exit}' "$INSTALL_SH")
if [[ -z "$start" || -z "$end" ]]; then
    echo "  [FAIL] wrapper block not found in install.sh" >&2; exit 1
fi
ok "wrapper block found in install.sh (lines $start-$end)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export OSTLER_DIR="$TMP"; mkdir -p "$TMP/bin" "$TMP/tailscale" "$TMP/fakebin"
sed -n "${start},${end}p" "$INSTALL_SH" > "$TMP/block.sh"
bash "$TMP/block.sh" || { echo "  [FAIL] rendering the block failed" >&2; exit 1; }
W="$TMP/bin/ostler-tailscale"

[[ -x "$W" ]] && ok "wrapper written and executable" || bad "wrapper missing or not executable"
bash -n "$W" && ok "wrapper parses" || bad "wrapper has a syntax error"

# The escaping regression, stated directly.
grep -q 'exec tailscale --socket="\$OSTLER_TS_SOCK" "\$@"' "$W" \
    && ok 'exec line kept $OSTLER_TS_SOCK and "$@" intact' \
    || bad 'exec line mangled -- heredoc escaping regression (was: bare backslash)'
grep -q '\\"$' "$W" && bad "wrapper contains a stray trailing backslash" \
                    || ok "no stray backslashes from heredoc expansion"

# Self-locating: no absolute path baked in, so moving ~/.ostler cannot break it.
grep -q 'BASH_SOURCE' "$W" && ok "socket path is self-located, not interpolated" \
                           || bad "socket path appears baked in"

printf '#!/bin/sh\necho "STUB $*"\n' > "$TMP/fakebin/tailscale"
chmod +x "$TMP/fakebin/tailscale"
export PATH="$TMP/fakebin:$PATH"

out="$("$W" status 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$out" | grep -qi "does not appear to be running"; then
    ok "socket absent -> exit 1 with plain-language guidance"
else
    bad "socket absent -> wrong behaviour (rc=$rc): $out"
fi

python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$TMP/tailscale/tailscaled.sock" 2>/dev/null
out="$("$W" ip -4 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q -- "--socket=$TMP/tailscale/tailscaled.sock ip -4"; then
    ok "socket present -> passes --socket AND user args through"
else
    bad "pass-through wrong (rc=$rc): $out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
