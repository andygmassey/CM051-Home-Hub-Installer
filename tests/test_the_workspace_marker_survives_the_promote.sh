#!/usr/bin/env bash
# tests/test_the_workspace_marker_survives_the_promote.sh
# ============================================================================
# THE DEFECT, measured on the v1.0.79 box in walk record #2.
# usage_journal_producers read 346 journal lines from
#
#     /tmp/ostler-prelaunch-50840/assistant-config/workspace/state/costs.jsonl
#
# on a FULLY INSTALLED machine. ${HOME}/.ostler/active_workspace.toml records
# ASSISTANT_CONFIG_DIR by VALUE, and ASSISTANT_CONFIG_DIR is derived from
# OSTLER_DIR, which still names the /tmp/ostler-prelaunch-<pid> staging tree
# when the marker is written. Every main-flow call of
# _ostler_promote_prelaunch_tree happens AFTER that write, and nothing rewrote
# the marker, so on every installed box it kept the staging prefix for the life
# of the install, pointing the usage-journal readers at a directory macOS clears
# on boot.
#
# SIXTH INSTANCE OF ONE CLASS. install.sh already catalogues five: the ollama
# plists, nine more plists, the store-credential wiring default, the WhatsApp
# Web session path, and the store curl config. Each was fixed as an instance.
# The class gate -- enumerate every staging-time capture and require each to be
# rebound -- is still owed, and this test is keyed to THIS marker, so it does
# not cover the class either. Said plainly rather than implied.
#
# WHAT IS ASSERTED, behaviourally: write the marker the way the main flow does
# while OSTLER_DIR is the staging tree, promote (rebind and delete staging), run
# the region extracted from the SHIPPED install.sh, and require the marker to
# name a path that EXISTS and carries no staging prefix. The must-fail arm skips
# the region and requires the staging prefix to still be there.
#
# HOME IS REDIRECTED. The marker lives at ${HOME}/.ostler/active_workspace.toml
# and this machine has a real one. A test that wrote there would corrupt the
# resolver it is measuring.
#
# NO PIPE INTO grep -q: it SIGPIPEs the producer and under pipefail reports
# failure for a pattern it found. Counted form only.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/install.sh"

PASS=0
FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$*" | sed 's/^/         /'; FAIL=$((FAIL + 1)); }

[ -r "$SRC" ] || { printf 'CANNOT-RUN: no install.sh at %s\n' "$SRC"; exit 78; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'THE WORKSPACE MARKER SURVIVES THE PROMOTE\n\n'

# ---------------------------------------------------------------------------
# Extract the post-promote rewrite from the SHIPPED file.
# ---------------------------------------------------------------------------
region="$(awk '
    /^    if declare -f _ostler_write_workspace_marker >\/dev\/null 2>&1; then$/ { f = 1 }
    f { print }
    f && /^    fi$/ { exit }
' "$SRC")"

n="$(printf '%s\n' "$region" | grep -c .)"
if [ "$n" -lt 3 ] || [ "$n" -gt 12 ]; then
    bad "extracted ${n} lines for the post-promote rewrite, implausible; refusing to eval" \
        "the anchor moved, so this suite measures nothing until it is fixed"
    printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
    exit 78
fi
ok "extracted the post-promote marker rewrite from the shipped install.sh (${n} lines)"

[ "$(printf '%s\n' "$region" | grep -c 'declare -f _ostler_write_workspace_marker')" -gt 0 ] \
    && ok "and it guards on the writer existing, for the promote call that precedes its definition" \
    || bad "the call is unguarded; on the early-promote path it would silently do nothing"

# THE WRITE MUST BE A FUNCTION, CALLED TWICE. If the main-flow write were still
# an inline block, the promote copy would be a second implementation and the two
# would drift. This is structural, so it carries its own control below.
# awk, not a grep alternation. `grep` on PATH here is a ugrep wrapper whose
# BRE `\|` does not answer the same as /usr/bin/grep's, and this arm read 0
# call sites against a file that has two. Name the tool or use one that has no
# dialect: awk counts lines whose FIRST word is the call, which is exact.
n_calls="$(awk '$1 == "_ostler_write_workspace_marker" && $0 !~ /^[[:space:]]*#/ && $0 !~ /\(\)/ { n++ } END { print n + 0 }' "$SRC")"
[ "$n_calls" -ge 2 ] \
    && ok "the marker writer is a function with ${n_calls} call sites, not two copies of one block" \
    || bad "fewer than two call sites: the main-flow write and the promote rewrite cannot both be using it"
[ "$(grep -c '^_ostler_write_workspace_marker() {' "$SRC")" -eq 1 ] \
    && ok "CONTROL: it is defined exactly once, so those calls reach one implementation" \
    || bad "the writer is not defined exactly once"

# ---------------------------------------------------------------------------
# Drive it. The writer is the shipped one's shape: capture by value from
# ASSISTANT_CONFIG_DIR, which is derived from OSTLER_DIR.
# ---------------------------------------------------------------------------
scenario() { # $1 = region to run ("" for the pre-fix behaviour)
    local rgn="$1"
    (
        set +u
        local staging="$WORK/tmp/ostler-prelaunch-$$" final="$WORK/final" home="$WORK/home.$$"
        rm -rf "$staging" "$final" "$home"
        mkdir -p "$staging/assistant-config" "$final/assistant-config" "$home"
        HOME="$home"; export HOME
        dbg()  { :; }
        warn() { :; }

        _ostler_write_workspace_marker() {
            local _m="${HOME}/.ostler/active_workspace.toml"
            mkdir -p "${HOME}/.ostler"
            printf 'config_dir = "%s"\n' "$ASSISTANT_CONFIG_DIR" > "${_m}.tmp.$$" \
                && mv -f "${_m}.tmp.$$" "$_m"
        }

        # Main flow: OSTLER_DIR is still the staging tree when the marker is
        # written. This is the ordering measured in the shipped file.
        OSTLER_DIR="$staging"
        ASSISTANT_CONFIG_DIR="${OSTLER_DIR}/assistant-config"
        _ostler_write_workspace_marker

        # Promote: move the tree, delete staging, rebind.
        rm -rf "$staging"
        OSTLER_DIR="$final"
        ASSISTANT_CONFIG_DIR="${OSTLER_DIR}/assistant-config"

        [ -n "$rgn" ] && eval "$rgn"

        local got
        got="$(sed -n 's/^config_dir = "\(.*\)"$/\1/p' "${HOME}/.ostler/active_workspace.toml" 2>/dev/null)"
        printf 'MARKER=%s EXISTS=%s\n' "$got" "$([ -d "$got" ] && echo yes || echo no)"
    )
}

out="$(scenario "$region")"
[ "$(printf '%s\n' "$out" | grep -c 'ostler-prelaunch')" -eq 0 ] \
    && ok "after promote the marker carries NO staging prefix" \
    || bad "the marker still names the staging tree" "$out"
[ "$(printf '%s\n' "$out" | grep -c 'EXISTS=yes')" -gt 0 ] \
    && ok "and it names a directory that EXISTS, so the readers resolve somewhere real" \
    || bad "the marker names a directory that is not there" "$out"
[ "$(printf '%s\n' "$out" | grep -c 'MARKER=.*final/assistant-config')" -gt 0 ] \
    && ok "and it is the promoted assistant-config, not merely any surviving path" \
    || bad "the marker is not the promoted config dir" "$out"

# ---------------------------------------------------------------------------
# MUST-FAIL: without the rewrite the marker keeps the staging prefix. This is
# the shipped behaviour that put /tmp/ostler-prelaunch-50840 into a walk record.
# ---------------------------------------------------------------------------
out_m="$(scenario "")"
if [ "$(printf '%s\n' "$out_m" | grep -c 'ostler-prelaunch')" -gt 0 ]; then
    ok "MUST-FAIL: without the rewrite the marker keeps the staging prefix, so the fix is what does the work"
else
    bad "MUST-FAIL: the marker was clean without the rewrite; the arms above prove nothing" "$out_m"
fi
[ "$(printf '%s\n' "$out_m" | grep -c 'EXISTS=no')" -gt 0 ] \
    && ok "and that path does NOT exist, which is the readers' actual failure" \
    || bad "the pre-fix path still existed; the defect is not reproduced" "$out_m"

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
