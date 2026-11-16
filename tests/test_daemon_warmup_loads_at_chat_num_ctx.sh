#!/usr/bin/env bash
# test_daemon_warmup_loads_at_chat_num_ctx.sh -- the daemon this installer
# ships must warm the chat model at the SAME num_ctx every chat turn uses.
#
# WHY THIS EXISTS (v1.0.109, measured on the Mini16, 2026-10-18)
#   Ollama started the chat runner twice on a fresh boot: `-c 8192`, then
#   `-c 65536` (4096 and 32768, each times OLLAMA_NUM_PARALLEL=2). A different
#   num_ctx is a different runner, so every customer's first chat paid for two
#   cold loads where the warm-up was meant to give zero.
#
#   The warm call is the DAEMON's, not install.sh's:
#   ostler-assistant crates/zeroclaw-providers/src/ollama.rs `warmup_model`
#   posted /api/generate with no `options.num_ctx`. Fixed upstream by
#   ostler-assistant #560 (merged 0a9c455b). Measured by reading the
#   warmup_model body at each tag: hub-v0.5.19 carries 0 `num_ctx`, hub-v0.5.20
#   and hub-v0.5.21 carry 1. This installer pins DAEMON_VERSION in gui/Makefile,
#   so the fix reaches a customer only when that pin is >= 0.5.20.
#
#   CM051's own chat warm call, the watchdog prewarm in install.sh, already
#   sends num_ctx and is guarded by tests/test_ollama_watchdog_heals_only_a_wedge.sh.
#
# WHAT IT ASSERTS
#   1. gui/Makefile pins DAEMON_VERSION >= 0.5.20 (the first hub tag whose
#      warm-up sends num_ctx).
#   2. The assistant plist sets OLLAMA_NUM_CTX, the value the daemon's
#      resolve_num_ctx() reads for both the warm-up and every chat turn.
#      Without it both fall back to Ollama's 4096 default.
#
# CONTRACT
#   rc=0 both hold; rc=1 a limb fails; rc=2 CANNOT RUN (a surface is absent or
#   a control did not fire).
#
# The daemon source is private, so this cannot read warmup_model itself. It
# binds the pin to the measured first-fixed tag instead. RAISE the floor only
# against a new measurement of the warm-up body at a tag.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FIRST_FIXED="0.5.20"
MAKEFILE_REL="gui/Makefile"
PLIST_REL="assistant-agent/launchd/com.creativemachines.ostler.assistant.plist"

rc=0
say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; rc=1; }
cannot_run() { printf 'CANNOT RUN  %s\n' "$*"; exit 2; }

# ver_ge A B -> true when dotted version A >= B (numeric per field).
ver_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".");
        n = (na > nb) ? na : nb;
        for (i = 1; i <= n; i++) {
            xi = (i <= na) ? x[i] + 0 : 0; yi = (i <= nb) ? y[i] + 0 : 0;
            if (xi > yi) exit 0; if (xi < yi) exit 1;
        }
        exit 0 }'
}

pinned_version() {
    sed -n 's/^DAEMON_VERSION[[:space:]]*?=[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$1/$MAKEFILE_REL" 2>/dev/null | head -1
}

plist_num_ctx() {
    grep -A1 '<key>OLLAMA_NUM_CTX</key>' "$1/$PLIST_REL" 2>/dev/null \
        | sed -n 's/.*<string>\([0-9][0-9]*\)<\/string>.*/\1/p' | head -1
}

# Returns 0 pass, 1 fail, 3 cannot read.
limb_pin() {
    local v; v="$(pinned_version "$1")"
    [ -n "$v" ] || return 3
    ver_ge "$v" "$FIRST_FIXED" && return 0
    return 1
}
limb_ctx() {
    local c; c="$(plist_num_ctx "$1")"
    [ -n "$c" ] || return 1
    [ "$c" -gt 4096 ] && return 0
    return 1
}

for f in "$MAKEFILE_REL" "$PLIST_REL"; do
    [ -f "$ROOT/$f" ] || cannot_run "$ROOT/$f is absent"
done

# ══ CONTROLS FIRST, on synthetic copies in a temp dir ══════════════════
CTL="$(mktemp -d -t ostler-warm-ctx-ctl)"
trap 'rm -rf "$CTL"' EXIT
fixture() {
    local d="$CTL/$1"
    mkdir -p "$d/gui" "$d/$(dirname "$PLIST_REL")"
    cp "$ROOT/$MAKEFILE_REL" "$d/$MAKEFILE_REL"
    cp "$ROOT/$PLIST_REL" "$d/$PLIST_REL"
    printf '%s' "$d"
}
set_pin() { sed -i '' -e "s/^DAEMON_VERSION\([[:space:]]*?=[[:space:]]*\)[0-9][0-9.]*/DAEMON_VERSION\1$2/" "$1/$MAKEFILE_REL"; }

say "== controls =="
_c="$(fixture below)"; set_pin "$_c" "0.5.19"
[ "$(pinned_version "$_c")" = "0.5.19" ] || cannot_run "could not plant 0.5.19 in the control Makefile"
limb_pin "$_c"; [ $? -eq 1 ] && say "  ok  pin limb goes RED on 0.5.19 (no num_ctx in warm-up)" || cannot_run "pin limb did not fire on 0.5.19"
_c="$(fixture at)"; set_pin "$_c" "$FIRST_FIXED"
limb_pin "$_c"; [ $? -eq 0 ] && say "  ok  pin limb stays GREEN at $FIRST_FIXED" || cannot_run "pin limb fired at $FIRST_FIXED"
_c="$(fixture minor)"; set_pin "$_c" "0.6.0"
limb_pin "$_c"; [ $? -eq 0 ] && say "  ok  pin limb compares numerically (0.6.0 >= $FIRST_FIXED)" || cannot_run "pin limb is not numeric"
_c="$(fixture noctx)"
sed -i '' -e '/<key>OLLAMA_NUM_CTX<\/key>/{n;s/<string>[0-9]*<\/string>/<string><\/string>/;}' "$_c/$PLIST_REL"
limb_ctx "$_c"; [ $? -eq 1 ] && say "  ok  ctx limb goes RED when the plist sets no OLLAMA_NUM_CTX" || cannot_run "ctx limb did not fire on an empty OLLAMA_NUM_CTX"
say ""

# ══ THE REAL TREE ═════════════════════════════════════════════════════
say "== subject: $ROOT =="
_v="$(pinned_version "$ROOT")"; _n="$(plist_num_ctx "$ROOT")"
limb_pin "$ROOT"
case $? in
    0) say "  PASS  DAEMON_VERSION=${_v} >= ${FIRST_FIXED}: the shipped warm-up sends num_ctx" ;;
    1) fail "gui/Makefile pins DAEMON_VERSION=${_v}. Its warm-up posts /api/generate without num_ctx, so Ollama loads the chat model at 4096 and again at ${_n:-32768}: two cold loads before the first reply. Re-pin to >= hub-v${FIRST_FIXED} (ostler-assistant #560)." ;;
    *) cannot_run "could not read DAEMON_VERSION from $MAKEFILE_REL" ;;
esac
limb_ctx "$ROOT" \
    && say "  PASS  plist OLLAMA_NUM_CTX=${_n}, so warm-up and chat resolve the same window" \
    || fail "plist OLLAMA_NUM_CTX is '${_n}': warm-up and chat fall back to Ollama's 4096"
exit "$rc"
