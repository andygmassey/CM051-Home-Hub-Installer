#!/usr/bin/env bash
# The fda-rerun LaunchAgent must not be registered before the program it runs
# exists.
#
# WHY THIS EXISTS. MEASURED on the Mini 16, 2026-09-04, on a finished install:
#
#     ~/.ostler/logs/fda-rerun.err   08:23:35Z  "ostler-fda not found/executable
#                                    at ~/.ostler/bin/ostler-fda; re-run the
#                                    installer to repair."
#     ~/.ostler/bin/ostler-fda       08:24:13Z  written 38 SECONDS LATER
#
# launchd starts a StartInterval job IMMEDIATELY on load and then every
# interval. The plist is written inside a conditional ~3,300 lines before the
# binary is written at top level, so bootstrapping there fires a tick against a
# binary that does not exist yet. EVERY CUSTOMER INSTALL writes "re-run the
# installer to repair" into its own error log, on a run that is about to
# succeed -- harmless, and alarming to whoever reads it, which on a support
# call is exactly who does. Filed as v1063-D010.
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run. CANNOT-RUN is not a pass.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }

# The predicate, applied to any tree. Returns 0 when the LOAD happens strictly
# after the binary is made executable, 1 when it does not, 2 when the sites
# cannot be located at all.
#
# LINE ORDER IS THE PROPERTY UNDER TEST. install.sh is executed top to bottom,
# so "later in the file" IS "later in time" for two statements at the same
# reachability. That is why this is a line-number comparison and not a grep for
# a fix marker: a marker proves an edit was made, order proves the defect is
# gone.
_loads_after_binary() {
    local f="$1" chmod_at load_at
    chmod_at="$(grep -n -F 'chmod +x "${OSTLER_DIR}/bin/ostler-fda"' "$f" | head -1 | cut -d: -f1)"
    load_at="$(grep -n -F '_ostler_launchagent_load_verified "$FDA_RERUN_PLIST"' "$f" | head -1 | cut -d: -f1)"
    [ -n "$chmod_at" ] && [ -n "$load_at" ] || return 2
    [ "$load_at" -gt "$chmod_at" ]
}

echo "── subject: this tree ──"
_loads_after_binary "$SUBJECT"; rc=$?
case "$rc" in
    0) ok "the fda-rerun agent is loaded AFTER its binary is made executable" ;;
    1) bad "the agent is loaded BEFORE its binary exists -- launchd fires a StartInterval job on load, so the first tick cannot find the program" ;;
    2) echo "CANNOT-RUN: could not locate both the chmod and the load site" >&2; exit 2 ;;
esac

# Exactly one load site. Two would mean the deferred one was added and the
# eager one left behind, which reads as fixed and is not.
n="$(grep -c -F '_ostler_launchagent_load_verified "$FDA_RERUN_PLIST"' "$SUBJECT")"
if [ "$n" -eq 1 ]; then
    ok "exactly one load site (${n}), so the eager one was moved rather than duplicated"
else
    bad "${n} load sites -- a deferred load added beside the eager one is not a fix"
fi

# The deferred block must refuse rather than register when the binary is
# somehow still absent, or it reproduces the very defect it exists to remove.
if grep -q -F 'if [[ ! -x "${OSTLER_DIR}/bin/ostler-fda" ]]; then' "$SUBJECT"; then
    ok "the deferred load GUARDS on the binary being executable rather than assuming it"
else
    bad "no executability guard at the deferred load -- it would register the agent anyway"
fi

# ── NEGATIVE CONTROL, pinned to a tree that CARRIES the defect ────────────
# Pinned to a fixed sha, never a moving branch: a control reading origin/main
# inverts the moment this fix merges and then passes forever. 661c00c9 is the
# v1.0.64 tagged commit -- the tree that shipped this ordering to the box.
_CONTROL_SHA="661c00c9"
echo "── negative control: ${_CONTROL_SHA} (the tree that shipped the defect) ──"
_ctl="$(mktemp)"; trap 'rm -f "$_ctl"' EXIT
git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null || \
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it. Scanning nothing must not read as a" >&2
    echo "  passing control." >&2
    exit 2
fi
_loads_after_binary "$_ctl"; crc=$?
case "$crc" in
    1) ok "control: ${_CONTROL_SHA} is correctly detected as loading BEFORE the binary (the predicate can fail)" ;;
    0) bad "control: ${_CONTROL_SHA} reports correct ordering. It is not -- that tree wrote the error to the box. The predicate matches something other than the fix." ;;
    2) echo "CANNOT-RUN: could not locate both sites in the control blob." >&2; exit 2 ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
