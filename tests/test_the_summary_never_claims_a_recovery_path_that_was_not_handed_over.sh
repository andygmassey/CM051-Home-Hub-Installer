#!/usr/bin/env bash
# #1540: the completion summary must not assert a recovery capability the
# customer cannot use.
# ============================================================================
# NOT A SOURCE GREP, and the issue says why: "a gate that greps install.sh for
# a display call will pass while the call sits behind a condition that never
# fires -- which is the shape of this defect." So this LIFTS the real summary
# block out of install.sh and EXECUTES it under each state, judging the words
# the customer would actually read.
#
# Measured on archie2 (a virgin account), Mini 16, v1.0.68: the install ended
# DONE status=ok failed_steps=0 errors=0, wrote a live recovery block, printed
# "Encryption: passphrase-wrapped DEK (recovery passphrase)", and the whole run
# contained 2 prompts, neither of them the key. The key is never stored, so
# that disclosure could never happen later.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$HERE/install.sh"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }
cant() { echo "  [CANNOT-RUN] $*" >&2; exit 2; }

[[ -f "$INSTALL" ]] || cant "no install.sh at ${INSTALL}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── lift the block, by its opening condition, to the matching `fi` ───────────
lift() {   # $1 = source file -> block on stdout
    awk '
        /^if \[\[ ! -f "\$\{SECURITY_CONFIG_DIR\}\/passkey.json" && -f "\$\{SECURITY_CONFIG_DIR\}\/keychain.json" \]\]; then$/ { f=1 }
        f { print }
        f && /^fi$/ { exit }
    ' "$1"
}

BLOCK="$WORK/block.sh"
lift "$INSTALL" > "$BLOCK"
if [[ ! -s "$BLOCK" ]]; then
    cant "could not lift the summary block from install.sh. Refusing: a test that ran an EMPTY block would pass every arm and prove nothing."
fi
# The lifted text must be a complete construct, or every arm below is vacuous.
bash -n "$BLOCK" 2>/dev/null || cant "the lifted block is not valid bash on its own; the extraction is wrong"

run_state() {   # $1=delivered $2=preexisted $3=passkey(0|1) -> OUT
    local d="$1" p="$2" pk="$3" dir="$WORK/sec.$RANDOM"
    mkdir -p "$dir"
    : > "$dir/keychain.json"
    [[ "$pk" == "1" ]] && : > "$dir/passkey.json"
    OUT="$(
        SECURITY_CONFIG_DIR="$dir" \
        RECOVERY_KEY_DELIVERED="$d" \
        SECURITY_PREEXISTED="$p" \
        YELLOW="" BOLD="" NC="" \
        bash "$BLOCK" 2>&1
    )"
}

echo "── subject: ${INSTALL} (summary block, executed) ──"

# ── arm 1: minted AND handed over ───────────────────────────────────────────
run_state true false 0
if grep -qi 'shown above' <<<"$OUT" && ! grep -qi 'UNAVAILABLE' <<<"$OUT"; then
    ok "key handed over this run: the summary says so, and does not warn"
else
    bad "expected a 'shown above' claim and no warning. Got: $OUT"
fi

# ── arm 2: an EARLIER run owed the disclosure ───────────────────────────────
run_state false true 0
if grep -qi 'earlier run' <<<"$OUT" && ! grep -qi 'shown above' <<<"$OUT" && ! grep -qi 'UNAVAILABLE' <<<"$OUT"; then
    ok "pre-existing keychain: neither claims to have shown it nor cries wolf"
else
    bad "expected an 'earlier run' line only. Got: $OUT"
fi

# ── arm 3: THE DEFECT. minted here, never handed over ───────────────────────
run_state false false 0
if grep -qi 'UNAVAILABLE' <<<"$OUT" && ! grep -qi 'recovery passphrase)' <<<"$OUT"; then
    ok "minted but NOT handed over: the summary says recovery is UNAVAILABLE"
else
    bad "the summary still asserted a recovery capability nobody can use. Got: $OUT"
fi

# ── arm 4: CONTROL -- the passkey path must be untouched ────────────────────
# Without this the block could satisfy arms 1-3 by firing unconditionally.
run_state false false 1
if [[ -z "${OUT//[[:space:]]/}" ]]; then
    ok "CONTROL: with passkey.json present this block prints nothing at all"
else
    bad "the passkey path was disturbed. Got: $OUT"
fi

# ── arm 5: NEGATIVE CONTROL -- the pre-fix blob must FAIL arm 3 ─────────────
# Pinned to a full 40-char sha, never a branch: a control that reads origin/main
# inverts the moment this merges, and an ABBREVIATED sha cannot be fetched.
_PRE_FIX_SHA="75c3267825b81b2412e41a07ac4e1e95c7ac6785"
echo "── negative control: pre-fix blob ${_PRE_FIX_SHA} ──"
PRE="$WORK/pre-install.sh"
if ! git -C "$HERE" cat-file -e "${_PRE_FIX_SHA}:install.sh" 2>/dev/null; then
    git -C "$HERE" fetch --quiet --depth=1 origin "$_PRE_FIX_SHA" 2>/dev/null || true
fi
if ! git -C "$HERE" show "${_PRE_FIX_SHA}:install.sh" > "$PRE" 2>/dev/null; then
    cant "could not read the pre-fix install.sh; a control that scanned nothing is not a pass"
fi
PRE_BLOCK="$WORK/pre-block.sh"
# The pre-fix form is a one-line `[[ ... ]] && echo`, not an if-block, so it is
# lifted by its own shape. If that lift comes back empty the control is broken
# and must say so rather than quietly passing.
grep -F 'passphrase-wrapped DEK (recovery passphrase)' "$PRE" | grep -F '[[ ! -f' > "$PRE_BLOCK" || true
if [[ ! -s "$PRE_BLOCK" ]]; then
    cant "the pre-fix summary line was not found in ${_PRE_FIX_SHA}; re-point the control"
fi
if grep -q 'RECOVERY_KEY_DELIVERED' "$PRE_BLOCK"; then
    cant "the 'pre-fix' blob already carries this change, so it cannot discriminate"
fi
d="$WORK/presec"; mkdir -p "$d"; : > "$d/keychain.json"
PRE_OUT="$(SECURITY_CONFIG_DIR="$d" bash "$PRE_BLOCK" 2>&1)"
if grep -qi 'recovery passphrase)' <<<"$PRE_OUT" && ! grep -qi 'UNAVAILABLE' <<<"$PRE_OUT"; then
    ok "CONTROL: the pre-fix summary claims the capability with nothing handed over -- the defect reproduces"
else
    bad "the pre-fix blob did not reproduce the defect, so arm 3 proves nothing. Got: $PRE_OUT"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail =="
[[ $FAIL -eq 0 ]]
