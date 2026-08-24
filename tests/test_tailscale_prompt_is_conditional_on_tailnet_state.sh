#!/usr/bin/env bash
# ============================================================================
# test_tailscale_prompt_is_conditional_on_tailnet_state.sh          (#875)
#
# THE DEFECT, measured on Andy's v1.0.44 UPGRADE walk, 2026-08-24.
#
# The installer re-asked "Connect your iPhone and Watch -- set up or skip?"
# on a box where Tailscale had already been set up. The customer answers a
# question they answered on the previous install, about a thing that is
# already done.
#
# WHY IT HAPPENED. There are two sites in install.sh that ask this question,
# and on main NEITHER of them looks at whether setup already happened:
#
#   Phase 2 (early, hoisted by WALK-1)  -- asks whenever the early prompt has
#       not already run in THIS process.
#   Phase 3 (late, "3.15 Tailscale")    -- same guard, and it is the one that
#       fired on the walk: a re-run over an existing install sets
#       SKIP_PHASE2=true, so the whole Phase-2 block (which contains the early
#       prompt) is jumped, TAILSCALE_CONFIRM_SHOWN_EARLY is never set, and the
#       late site asks from scratch.
#
# The only Tailscale-state-shaped test anywhere near this code is
#
#       if ! command -v tailscale &>/dev/null; then ... brew install ...
#
# and that is NOT the same question. "Is the tailscale binary on PATH" answers
# "do we need to install a package". The prompt is asking "has this customer
# already joined this Mac to their tailnet", and the evidence for that is the
# TAILNET STATE that tailscaled writes, not the presence of a CLI. A box can
# have the binary and no tailnet (brew ran, sign-in never completed), and a
# box can have a tailnet and be mid-upgrade with the binary being reinstalled.
#
# ----------------------------------------------------------------------------
# WHAT THIS TEST ASSERTS -- and it is behavioural, not a grep
# ----------------------------------------------------------------------------
#
# It EXTRACTS the two real prompt blocks out of install.sh (and the predicate
# they call), stubs gui_read/info/warn, and RUNS them against synthetic
# tailnet-state fixtures. A prompt firing is observed by gui_read actually
# being called, not by a pattern in the source. So the test cannot pass by the
# code merely mentioning the right identifier, and it cannot drift from what
# ships, because it runs what ships.
#
# FOUR STATES, and they must not share an appearance:
#
#   state present and proves a completed sign-in  -> CONFIGURED     -> no ask
#   binary present, no usable state               -> NOT CONFIGURED -> ask
#   neither                                       -> NOT CONFIGURED -> ask
#   state present but empty / corrupt / unreadable-> CANNOT-RUN     -> SAY SO,
#                                                                      then ask
#
# The fourth is the one that gets collapsed. An unreadable file must never
# read as "configured" (that silently skips setup and the iPhone never reaches
# the Hub), and it must not read as a clean "no state" either, because those
# are different facts and only one of them is a customer's own choice. It gets
# its own warning, and then -- having said what it could not determine -- the
# installer asks.
#
# THE DISCRIMINATOR IS NOT FILE EXISTENCE, AND NOT FILE SIZE. tailscaled
# writes its state store as soon as the daemon starts, BEFORE any login, so a
# state file can exist on a box that has never signed in. The property that
# separates them is structural: a store that only carries the pre-login
# machine key is not a configured tailnet. Control C below plants exactly that
# file and requires a mere-existence check to get it WRONG, so the fixture is
# encoding the property and not the flag.
#
# Exit codes:
#   0  every arm passed
#   1  at least one arm failed
#   3  CANNOT-RUN. A fixture could not be built, so nothing was proved. Not a
#      pass. (Running as root cannot produce an unreadable file; no JSON-
#      capable python3 means the corrupt-file arm cannot be judged.)
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
STRINGS="${HERE}/../install.sh.strings.en-GB.sh"
WORK="$(mktemp -d -t ostler-ts-prompt.XXXXXX)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

cannot_run() {
    echo "" >&2
    echo "CANNOT-RUN: $1" >&2
    echo "  NOTHING was proved by this run. This is not a pass." >&2
    exit 3
}

[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at $INSTALL_SH"
[[ -f "$STRINGS"    ]] || cannot_run "string catalogue not found at $STRINGS"

# A shell that cannot parse cannot be reasoned about at all.
bash -n "$INSTALL_SH" || cannot_run "install.sh fails bash -n"
ok "install.sh parses (bash -n)"

# The corrupt/empty arms need an interpreter that can actually attempt a JSON
# parse; without one we cannot tell a broken file from a good one, which is
# the very distinction under test.
PY="$(command -v python3 2>/dev/null || true)"
[[ -n "$PY" ]] && "$PY" -c 'import json' >/dev/null 2>&1 \
    || cannot_run "no python3 with json here; the corrupt-state arm cannot be judged"

# chmod 000 does not stop root, so the unreadable arm would silently score as
# readable. Refuse rather than report a pass we did not earn.
[[ "$(id -u)" != "0" ]] \
    || cannot_run "running as root: a chmod 000 fixture is still readable, so the unreadable-state arm cannot be judged"

# ============================================================================
# Fixtures. Each builds a fake OSTLER_DIR and echoes its path.
# ============================================================================

# The pre-login machine key. tailscaled writes this when the daemon first
# starts; it is present on a box that has never once signed in.
MK='"_machinekey":"privkey:1f3a9c7d0b5e46228a1c93f0de77b41c6a5820e9f3c1d4b7a80e26f95c3d1a8b"'

# Fixtures are called more than once (self-check, then each arm), and one of
# them deliberately ends up mode 000. Reset the subtree first so a rebuild is
# never fighting the previous build's permissions -- otherwise the second call
# fails to write and the arm silently measures a stale file.
_mk_home() {                       # $1 = subdir name -> echoes fake OSTLER_DIR
    local d="${WORK}/$1/.ostler"
    [[ -e "${WORK}/$1" ]] && chmod -R u+rwX "${WORK}/$1"
    mkdir -p "${d}/tailscale"
    printf '%s' "$d"
}

# 1. CONFIGURED: machine key PLUS a profile entry carrying a non-empty value.
#    That pair is only ever written after a login has produced a node.
fx_configured() {
    local d; d="$(_mk_home configured)"
    printf '{%s,"_current-profile":"cHJvZmlsZS1hMWIy","profile-a1b2":"eyJOb2RlSUQiOiJuMTIzIn0="}\n' \
        "$MK" > "${d}/tailscale/tailscaled.state"
    printf '%s' "$d"
}

# 2. DAEMON STARTED, NEVER SIGNED IN: machine key only. A file exists, it is
#    well-formed and non-empty -- and it is NOT a configured tailnet.
fx_machinekey_only() {
    local d; d="$(_mk_home machinekey_only)"
    printf '{%s}\n' "$MK" > "${d}/tailscale/tailscaled.state"
    printf '%s' "$d"
}

# 3. PROFILE SLOT PRESENT BUT EMPTY: the shape a daemon leaves when a sign-in
#    was started and abandoned. Extra key, no value -- still not configured.
fx_profile_empty() {
    local d; d="$(_mk_home profile_empty)"
    printf '{%s,"_current-profile":""}\n' "$MK" > "${d}/tailscale/tailscaled.state"
    printf '%s' "$d"
}

# 4. NEITHER: no state file at all.
fx_absent() { _mk_home absent; }

# 5. BINARY PRESENT, NO STATE. The whole point of #875: this must still ask.
#    The stub tailscale is put on PATH by the caller.
fx_binary_no_state() {
    local d; d="$(_mk_home binary_no_state)"
    mkdir -p "${WORK}/stubbin"
    printf '#!/bin/sh\nexit 0\n' > "${WORK}/stubbin/tailscale"
    printf '#!/bin/sh\nexit 0\n' > "${WORK}/stubbin/tailscaled"
    chmod +x "${WORK}/stubbin/tailscale" "${WORK}/stubbin/tailscaled"
    printf '%s' "$d"
}

# 6. EMPTY: the file is there and carries nothing. Half-made, not absent.
fx_empty() {
    local d; d="$(_mk_home empty)"
    : > "${d}/tailscale/tailscaled.state"
    printf '%s' "$d"
}

# 7. CORRUPT: truncated mid-write.
fx_corrupt() {
    local d; d="$(_mk_home corrupt)"
    printf '{%s,"_current-prof' "$MK" > "${d}/tailscale/tailscaled.state"
    printf '%s' "$d"
}

# 8. NOT JSON AT ALL.
fx_not_json() {
    local d; d="$(_mk_home not_json)"
    printf 'this is not a tailscale state store\n' > "${d}/tailscale/tailscaled.state"
    printf '%s' "$d"
}

# 9. UNREADABLE: present, well-formed, and we are not allowed to look.
fx_unreadable() {
    local d; d="$(_mk_home unreadable)"
    printf '{%s,"profile-a1b2":"eyJOb2RlSUQiOiJuMTIzIn0="}\n' "$MK" \
        > "${d}/tailscale/tailscaled.state"
    chmod 000 "${d}/tailscale/tailscaled.state"
    printf '%s' "$d"
}

# 10. A DIRECTORY WHERE THE FILE SHOULD BE.
fx_dir_in_the_way() {
    local d; d="$(_mk_home dir_in_the_way)"
    mkdir -p "${d}/tailscale/tailscaled.state"
    printf '%s' "$d"
}

# Fixture self-check: a fixture that failed to build would make every arm
# report the same thing, which is the uniform-zero shape.
for _f in fx_configured fx_machinekey_only fx_profile_empty fx_absent \
          fx_binary_no_state fx_empty fx_corrupt fx_not_json fx_unreadable \
          fx_dir_in_the_way; do
    _d="$("$_f")"
    [[ -d "${_d}/tailscale" ]] || cannot_run "fixture ${_f} did not build a state dir"
done
ok "all 10 state fixtures built"

# ============================================================================
# CONTROL C -- the fixtures encode the PROPERTY, not the flag.
#
# If a mere-existence (or non-empty) check could tell these fixtures apart,
# then this suite would pass against a check that is still wrong, and #875
# would come back the first time a customer's daemon started without a login.
# Require the naive check to get the machine-key-only file WRONG.
# ============================================================================
_naive_says_configured() { [[ -s "$1/tailscale/tailscaled.state" ]]; }
if _naive_says_configured "$(fx_machinekey_only)"; then
    ok "control C: a mere-existence check MISREADS the never-signed-in store (so the fixture tests the property)"
else
    bad "control C: the machine-key-only fixture is already rejected by a naive size check -- it is not testing the property"
fi
if _naive_says_configured "$(fx_configured)"; then
    ok "control C: the naive check does fire on the configured store (control is live, not stuck off)"
else
    bad "control C: naive check does not fire even on the configured store -- the control is broken"
fi

# ============================================================================
# ARM 1 -- the predicate itself, extracted from install.sh.
#
#   rc 0 = configured, rc 1 = not configured, rc 2 = CANNOT-RUN
# ============================================================================
PREDICATE_PRESENT=0
HELPER="$(awk '/^_ts_already_configured\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL_SH")"
if [[ -n "$HELPER" ]] && printf '%s\n' "$HELPER" | grep -q 'tailscaled.state'; then
    PREDICATE_PRESENT=1
    ok "extracted the real _ts_already_configured from install.sh"
else
    bad "install.sh defines no _ts_already_configured that reads tailscaled.state -- the prompt has no evidence to be conditional on (#875)"
fi

# The predicate must be defined BEFORE the first site that asks, or it is
# unbound at the call and the installer dies under set -u.
FIRST_PROMPT_LN="$(grep -n 'tailscale_confirm")' "$INSTALL_SH" | head -1 | cut -d: -f1)"
PRED_LN="$(grep -n '^_ts_already_configured() {' "$INSTALL_SH" | head -1 | cut -d: -f1)"
PYRES_LN="$(grep -n '^_ostler_licence_python() {' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -n "$PRED_LN" && -n "$FIRST_PROMPT_LN" && "$PRED_LN" -lt "$FIRST_PROMPT_LN" ]]; then
    ok "predicate is defined (line ${PRED_LN}) before the first prompt site (line ${FIRST_PROMPT_LN})"
else
    bad "predicate is not defined before the first prompt site (predicate=${PRED_LN:-<none>}, prompt=${FIRST_PROMPT_LN:-<none>})"
fi

if [[ "$PREDICATE_PRESENT" == "1" ]]; then
    # The predicate leans on install.sh's hardened interpreter resolver rather
    # than a second copy of it. Stub that one identifier and nothing else, so
    # the body under test is the shipped body.
    _ostler_licence_python() { printf '%s' "$PY"; }
    eval "$HELPER"

    # OSTLER_FINAL_DIR, not OSTLER_DIR: before the FDA re-probe
    # _ostler_set_paths has OSTLER_DIR pointing at the per-PID /tmp staging
    # tree, which never holds tailnet state. Driving the fixture through the
    # variable the code happens to read is how a test passes while the fix is
    # inert, so the staging-tree arm below pins the two apart.
    _verdict() {                    # $1 = fixture ostler dir -> echoes rc
        local rc=0
        ( OSTLER_FINAL_DIR="$1"; _ts_already_configured ) || rc=$?
        printf '%s' "$rc"
    }
    _expect() {                     # $1 = fixture fn, $2 = want rc, $3 = label
        local d rc; d="$("$1")"; rc="$(_verdict "$d")"
        if [[ "$rc" == "$2" ]]; then ok "predicate: $3 -> rc $rc"
        else bad "predicate: $3 -> rc $rc (expected $2)"; fi
    }

    _expect fx_configured      0 "state proves a completed sign-in => CONFIGURED"
    _expect fx_machinekey_only 1 "machine key only (daemon ran, never signed in) => NOT CONFIGURED"
    _expect fx_profile_empty   1 "profile slot present but empty => NOT CONFIGURED"
    _expect fx_absent          1 "no state file at all => NOT CONFIGURED"
    _expect fx_empty           2 "state file present but EMPTY => CANNOT-RUN"
    _expect fx_corrupt         2 "state file truncated mid-write => CANNOT-RUN"
    _expect fx_not_json        2 "state file is not a state store => CANNOT-RUN"
    _expect fx_unreadable      2 "state file present but unreadable => CANNOT-RUN"
    _expect fx_dir_in_the_way  2 "a directory sits where the state file goes => CANNOT-RUN"

    # The binary is NOT the evidence. Same empty state dir, tailscale on PATH.
    D_BIN="$(fx_binary_no_state)"
    RC_BIN=0
    ( PATH="${WORK}/stubbin:${PATH}"; OSTLER_FINAL_DIR="$D_BIN"; _ts_already_configured ) || RC_BIN=$?
    if [[ "$RC_BIN" == "1" ]]; then
        ok "predicate: tailscale binary ON PATH with no tailnet state => still NOT CONFIGURED (#875 core)"
    else
        bad "predicate: binary on PATH with no state returned rc ${RC_BIN} (expected 1) -- this is a binary check, not a state check"
    fi

    # THE STAGING-TREE ARM. install.sh rebinds OSTLER_DIR to /tmp/ostler-
    # prelaunch-$$ until the FDA re-probe, so the Phase-2 site would read an
    # empty staging tree and answer "not configured" on EVERY install -- a fix
    # that is present in the source and does nothing. Point the two variables
    # at opposite fixtures and require the canonical one to win. If this arm
    # ever inverts, the predicate has started reading the staging tree.
    RC_STAGE=0
    ( OSTLER_DIR="$(fx_configured)"; OSTLER_FINAL_DIR="$(fx_absent)"; _ts_already_configured ) || RC_STAGE=$?
    [[ "$RC_STAGE" == "1" ]] \
        && ok "predicate: reads the canonical dir, not the /tmp staging OSTLER_DIR" \
        || bad "predicate: staging OSTLER_DIR decided the answer (rc ${RC_STAGE}, expected 1) -- the Phase-2 site would be inert"
    RC_STAGE2=0
    ( OSTLER_DIR="$(fx_absent)"; OSTLER_FINAL_DIR="$(fx_configured)"; _ts_already_configured ) || RC_STAGE2=$?
    [[ "$RC_STAGE2" == "0" ]] \
        && ok "predicate: canonical dir alone is enough to prove CONFIGURED (arm is live in both directions)" \
        || bad "predicate: canonical dir did not yield CONFIGURED (rc ${RC_STAGE2}, expected 0)"

    # Independence control: the predicate must not be quietly satisfied by
    # something in the ambient environment. Point it at a directory that has
    # never existed and require a clean NOT CONFIGURED, not a crash and not a 0.
    RC_VOID=0
    ( OSTLER_FINAL_DIR="${WORK}/never-existed"; _ts_already_configured ) || RC_VOID=$?
    [[ "$RC_VOID" == "1" ]] \
        && ok "predicate: a nonexistent ostler dir => NOT CONFIGURED (rc 1), no crash" \
        || bad "predicate: nonexistent ostler dir returned rc ${RC_VOID} (expected 1)"
else
    bad "ARM 1 skipped: no predicate to drive (this is a FAIL, not a skip)"
fi

# ============================================================================
# ARM 2 -- the two REAL prompt blocks, run against the fixtures.
#
# A prompt is observed by gui_read being CALLED. Extraction is by structure --
# the enclosing column-0 `if ... fi` around each `tailscale_confirm` gui_read
# -- so it survives the guard being rewritten, which is exactly what the fix
# does.
# ============================================================================
_extract_block() {                  # $1 = 1 (early) or 2 (late)
    awk -v want="$1" '
        /^if /                            { buf=$0 "\n"; inblk=1; hit=0; next }
        inblk                             { buf = buf $0 "\n" }
        inblk && /tailscale_confirm"\)"/  { hit=1 }
        inblk && /^fi$/                   { if (hit) { n++; if (n==want) { printf "%s", buf; exit } }
                                            inblk=0; buf="" }
    ' "$INSTALL_SH"
}

BLOCK_EARLY="$(_extract_block 1)"
BLOCK_LATE="$(_extract_block 2)"
[[ -n "$BLOCK_EARLY" ]] || cannot_run "could not extract the Phase-2 tailscale prompt block from install.sh"
[[ -n "$BLOCK_LATE"  ]] || cannot_run "could not extract the Phase-3 tailscale prompt block from install.sh"
ok "extracted both real prompt blocks from install.sh"

# Run one prompt block against one fixture. Echoes "<asked> <verdictword>"
# where asked is 1 if gui_read fired. GUI_LOG / WARN_LOG are files so the
# subshell's writes survive it.
_run_block() {                      # $1 = block text, $2 = OSTLER_DIR, $3 = extra env line
    local block="$1" odir="$2" extra="${3:-}"
    local glog="${WORK}/gui.$$.log" wlog="${WORK}/warn.$$.log" ilog="${WORK}/info.$$.log"
    : > "$glog"; : > "$wlog"; : > "$ilog"
    (
        set -uo pipefail
        # shellcheck disable=SC1090
        . "$STRINGS"
        gui_read() { printf 'ASKED %s\n' "${6:-}" >> "$glog"; printf 'setup'; }
        info()     { printf '%s\n' "$*" >> "$ilog"; }
        ok()       { printf '%s\n' "$*" >> "$ilog"; }
        warn()     { printf '%s\n' "$*" >> "$wlog"; }
        _ostler_licence_python() { printf '%s' "$PY"; }
        [[ -n "$HELPER" ]] && eval "$HELPER"
        OSTLER_FINAL_DIR="$odir"
        [[ -n "$extra" ]] && eval "$extra"
        eval "$block"
    ) >/dev/null 2>&1
    local asked=0 warned=0
    grep -q '^ASKED' "$glog" && asked=1
    [[ -s "$wlog" ]] && warned=1
    printf '%s %s' "$asked" "$warned"
}

_check_block() {                    # $1 label, $2 block, $3 fixture fn, $4 want_asked, $5 want_warned, $6 extra
    local d r asked warned
    d="$("$3")"
    r="$(_run_block "$2" "$d" "${6:-}")"
    asked="${r%% *}"; warned="${r##* }"
    if [[ "$asked" == "$4" && "$warned" == "$5" ]]; then
        ok "$1"
    else
        bad "$1  (asked=${asked} want ${4}; warned=${warned} want ${5})"
    fi
}

for _which in early late; do
    if [[ "$_which" == "early" ]]; then B="$BLOCK_EARLY"; else B="$BLOCK_LATE"; fi

    # CONTROL P -- the harness can see a prompt at all. Without this, every
    # "did not ask" below could just be a broken stub.
    _check_block "[${_which}] CONTROL P: with no tailnet state the customer IS asked" \
        "$B" fx_absent 1 0

    _check_block "[${_which}] tailnet state proves sign-in => NOT asked again (#875)" \
        "$B" fx_configured 0 0

    _check_block "[${_which}] tailscale binary present, no tailnet state => asked" \
        "$B" fx_binary_no_state 1 0

    _check_block "[${_which}] machine key only (never signed in) => asked" \
        "$B" fx_machinekey_only 1 0

    _check_block "[${_which}] EMPTY state file => warns AND asks (CANNOT-RUN is its own appearance)" \
        "$B" fx_empty 1 1

    _check_block "[${_which}] CORRUPT state file => warns AND asks" \
        "$B" fx_corrupt 1 1

    _check_block "[${_which}] UNREADABLE state file => warns AND asks, never silently 'configured'" \
        "$B" fx_unreadable 1 1

    # An answer already given IN THIS RUN is the customer's, and must win over
    # anything on disk. A returning customer who says "skip" this time must
    # not have it overridden by last install's state.
    _check_block "[${_which}] an answer already given this run is honoured, not re-asked or overridden" \
        "$B" fx_configured 0 0 'TAILSCALE_CONFIRM=skip; TAILSCALE_CONFIRM_SHOWN_EARLY=1'
done

# The skip answer must actually SURVIVE the configured branch, not just avoid
# a re-prompt. Check the value, not only the absence of a question.
SKIP_OUT="$(
    (
        set -uo pipefail
        # shellcheck disable=SC1090
        . "$STRINGS"
        gui_read() { printf 'setup'; }
        info() { :; }; ok() { :; }; warn() { :; }
        _ostler_licence_python() { printf '%s' "$PY"; }
        [[ -n "$HELPER" ]] && eval "$HELPER"
        OSTLER_FINAL_DIR="$(fx_configured)"
        TAILSCALE_CONFIRM=skip
        TAILSCALE_CONFIRM_SHOWN_EARLY=1
        eval "$BLOCK_LATE"
        printf '%s' "${TAILSCALE_CONFIRM}"
    ) 2>/dev/null
)"
[[ "$SKIP_OUT" == "skip" ]] \
    && ok "a customer's 'skip' is not overwritten by on-disk tailnet state" \
    || bad "a customer's 'skip' became '${SKIP_OUT}' -- on-disk state overrode a human answer"

# ============================================================================
# ARM 3 -- structural facts the behavioural arms cannot see.
# ============================================================================
if grep -q 'MSG_INFO_TAILSCALE_ALREADY_CONFIGURED' "$STRINGS"; then
    ok "catalogue defines MSG_INFO_TAILSCALE_ALREADY_CONFIGURED"
else
    bad "catalogue is missing MSG_INFO_TAILSCALE_ALREADY_CONFIGURED"
fi
if grep -q 'MSG_WARN_TAILSCALE_STATE_UNREADABLE' "$STRINGS"; then
    ok "catalogue defines MSG_WARN_TAILSCALE_STATE_UNREADABLE (CANNOT-RUN has words of its own)"
else
    bad "catalogue is missing MSG_WARN_TAILSCALE_STATE_UNREADABLE"
fi

# The interpreter resolver must already exist above the predicate; a second
# copy of it would be the vendored-twin defect the tailscale block's own
# comments call out.
if [[ -n "$PYRES_LN" && -n "$PRED_LN" && "$PYRES_LN" -lt "$PRED_LN" ]]; then
    ok "predicate reuses the existing interpreter resolver (defined line ${PYRES_LN}) rather than copying it"
else
    bad "_ostler_licence_python is not defined above the predicate (resolver=${PYRES_LN:-<none>}, predicate=${PRED_LN:-<none>})"
fi

echo ""
printf ' RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
