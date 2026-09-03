#!/usr/bin/env bash
# `launchctl bootout` is asynchronous: wait for the label to GO before
# bootstrapping onto it.
#
# ── THE DEFECT ──────────────────────────────────────────────────────────────
# bootout returns when launchd ACCEPTS the request, not when the job is gone.
# Bootstrapping into a half-torn-down label fails with EIO and the job never
# spawns. install.sh called bootout and bootstrap back to back.
#
# MEASURED ON THE MINI 16, install of 2026-09-03 (timestamps UTC):
#     18:42:10  ~/.ostler/doctor/web_ui.py written    (payload)
#     18:42:11  com.ostler.doctor.plist written
#     18:42:11  refusal recorded
# One second for the whole sequence. Recorded reason: "registered, then
# VANISHED from gui/501 before it ran", with launchd saying
# `Bootstrap failed: 5: Input/output error` and `Load failed: 5`.
# 2 of 20 ostler agents failed; the other 18 loaded.
#
# ⚠️ THIS FILE GRADES THE FIX, NOT THE DIAGNOSIS. The race is converging
# evidence, not a live reproduction -- see the note at the fix site. What is
# asserted here is only that the wait EXISTS, is ORDERED correctly, is FREE on
# a fresh install, and is BOUNDED. Those are true and useful regardless of
# whether the race turns out to be the whole story.
#
# rc=2 means the harness could not set itself up. That is not a pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/install.sh"

cannot() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }
[ -f "$SRC" ] || cannot "no-install-sh" "$SRC not found -- nothing was checked."

PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t ostler-settle)"
[ -n "$WORK" ] && [ -d "$WORK" ] || cannot "no-tmpdir" "could not create a work dir."
trap 'rm -rf "$WORK"' EXIT

# ── extract the REAL region: bootout .. just before the bootstrap ───────────
# Grading the shipped bytes, not a copy of them.
extract_region() {   # $1 = file
    awk '
        /launchctl bootout "\$\{_domain\}\/\$\{_label\}"/ { inr=1 }
        inr && /^    local _load_err/ { exit }
        inr { print }
    ' "$1"
}
extract_region "$SRC" > "${WORK}/region.sh"
[ -s "${WORK}/region.sh" ] || cannot "premise" "could not extract the bootout region from install.sh."
ok "premise: extracted the bootout region ($(wc -l < "${WORK}/region.sh" | tr -d ' ') lines)"

# ── E. ORDERING, checked on the file itself ─────────────────────────────────
# A wait placed AFTER the bootstrap would be decoration.
L_BOOTOUT="$(grep -n 'launchctl bootout "\${_domain}/\${_label}"' "$SRC" | head -1 | cut -d: -f1)"
L_SETTLE="$(grep -n '_settle_cap' "$SRC" | head -1 | cut -d: -f1)"
L_BOOTSTRAP="$(grep -n 'launchctl bootstrap "\$_domain" "\$_plist"' "$SRC" | head -1 | cut -d: -f1)"
if [ -z "$L_SETTLE" ]; then
    bad "there is NO settle wait at all: bootout and bootstrap run back to back, \
which is the defect (bootout is asynchronous)."
elif [ "$L_BOOTOUT" -lt "$L_SETTLE" ] && [ "$L_SETTLE" -lt "$L_BOOTSTRAP" ]; then
    ok "ordering: bootout(${L_BOOTOUT}) -> wait(${L_SETTLE}) -> bootstrap(${L_BOOTSTRAP})"
else
    bad "ordering wrong: bootout=${L_BOOTOUT} wait=${L_SETTLE} bootstrap=${L_BOOTSTRAP}. \
A wait that does not sit between them cannot prevent the race."
fi

# ── the behavioural harness ────────────────────────────────────────────────
# Stubs capture the harness's own args into named variables FIRST: inside a
# function, $1 is the FUNCTION's argument, and writing `return "$1"` here
# would read `print` and grade nothing -- that exact slip reddened two arms
# against correct code earlier tonight.
run() { # $1 present-count -> "<sleeps> <probes>"
    env -u OSTLER_LAUNCHAGENT_BOOTOUT_SETTLE_S bash -c '
        set -uo pipefail
        _PRESENT="$1"; _REGION="$2"
        SLEEPS=0; PROBES=0
        _domain="gui/501"; _label="com.ostler.doctor"
        launchctl() {
            case "${1:-}" in
                print) PROBES=$((PROBES+1))
                       [ "$PROBES" -le "$_PRESENT" ] && return 0
                       return 1 ;;
                *)     return 0 ;;
            esac
        }
        sleep() { SLEEPS=$((SLEEPS+1)); }
        _ostler_launchagent_note_refusal() { :; }
        # THE REGION DECLARES `local`, WHICH IS ONLY LEGAL INSIDE A FUNCTION.
        # Sourced at top level it errors, $_settle stays unset, `set -u` kills
        # the shell, and the harness printed NOTHING -- three arms read as
        # failures against correct code. A wrapper function is the whole fix.
        _run_region() { source "$_REGION"; }
        _run_region
        printf "%s %s" "$SLEEPS" "$PROBES"
    ' _ "$1" "${WORK}/region.sh"
}

# ── B. FRESH INSTALL COSTS NOTHING ─────────────────────────────────────────
# The customer path. A wait that delayed every install would be a tax paid by
# everyone to fix a reinstall-only fault.
read -r S P <<<"$(run 0)"
if [ "${S:-x}" = "0" ]; then
    ok "label absent (fresh install): ${S} sleeps, ${P} probe -- free"
else
    bad "a fresh install slept ${S}s waiting for a label that was never loaded. \
Every customer would pay that."
fi

# ── C. IT STOPS AS SOON AS THE LABEL GOES ──────────────────────────────────
read -r S P <<<"$(run 3)"
if [ "${S:-x}" = "3" ]; then
    ok "label present for 3 probes: waits ${S}s then proceeds (does not run to the cap)"
else
    bad "expected 3 sleeps when the label clears after 3 probes, got ${S}. \
Either it does not poll, or it ignores the label going away."
fi

# ── D. BOUNDED ─────────────────────────────────────────────────────────────
# An unbounded wait on a label that never clears would hang the installer,
# which is a worse failure than the one being fixed.
read -r S P <<<"$(run 9999)"
if [ "${S:-x}" = "10" ]; then
    ok "label never clears: stops at the ${S}s cap and proceeds (no hang)"
else
    bad "expected the wait to stop at the 10s default cap, got ${S} sleeps. \
An unbounded wait hangs the installer."
fi

# ── F. NEGATIVE CONTROL: the real pre-fix code must FAIL arm C ─────────────
# Without this, a region that never polls could pass B and D by doing nothing.
if git -C "$REPO_ROOT" show origin/main:install.sh > "${WORK}/main.sh" 2>/dev/null; then
    extract_region "${WORK}/main.sh" > "${WORK}/region_main.sh"
    PRE="$(env -u OSTLER_LAUNCHAGENT_BOOTOUT_SETTLE_S bash -c '
        set -uo pipefail
        SLEEPS=0; PROBES=0
        _domain="gui/501"; _label="com.ostler.doctor"
        launchctl() { case "${1:-}" in print) PROBES=$((PROBES+1)); return 0;; *) return 0;; esac; }
        sleep() { SLEEPS=$((SLEEPS+1)); }
        _ostler_launchagent_note_refusal() { :; }
        _run_region() { source "$1"; }
        _run_region "$1"
        printf "%s" "$SLEEPS"
    ' _ "${WORK}/region_main.sh")"
    if [ "${PRE:-0}" = "0" ]; then
        ok "CONTROL: origin/main waits ${PRE:-0}s after bootout -- the defect, and this file sees it"
    else
        bad "CONTROL: origin/main already waited ${PRE}s, so this file is not \
grading the change it claims to."
    fi
else
    printf 'note: origin/main unavailable, the pre-fix control did not run\n' >&2
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'BOOTOUT SETTLES BEFORE BOOTSTRAP, FREE WHEN THERE IS NOTHING TO WAIT FOR\n'
