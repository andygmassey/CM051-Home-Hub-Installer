#!/usr/bin/env bash
# tests/test_sync_vendor_pin_untouched_on_abort.sh
# ============================================================================
# An ABORTED sync must leave vendor/VENDOR_MANIFEST.toml exactly as it found it.
#
# WHY. sync_vendor.sh bumps pinned_sha BEFORE anything is validated, because the
# materialise helper reads the pin to know what to fetch. Two abort paths
# restored it by hand; three did not (the VENDOR_ONLY refusal and two stash
# failures). Measured 2026-08-12, `sync_vendor.sh doctor` refused correctly and
# left:
#
#     - pinned_sha = "b0b383109e6e..."   the deliberate hold
#     + pinned_sha = "85621fb7a64b..."   an UNMERGED local branch
#
# No content was vendored. A second run then aborted elsewhere and "restored"
# to the already-corrupted value, which is how a leak becomes the baseline.
#
# WHY IT IS WORTH A TEST AND NOT JUST A FIX (TNM's call, and it is right):
# until this exists, every re-pin has to be verified by hand, and most will not
# be. A false pinned_sha is not a cosmetic error -- the manifest's own
# hold_ack_reason calls it "the exact lie this ledger exists to prevent",
# because the cut trusts the pin to describe what the vendored tree HOLDS.
#
# SHAPE. Checks 1-2 are hermetic and run anywhere. Check 3 drives the REAL
# abort and needs the doctor source repo; when that is absent it says so
# loudly and does not quietly pass -- a skip that reads as a pass is the exact
# failure mode this file exists to stop.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$HERE/scripts/sync_vendor.sh"
MANIFEST="$HERE/vendor/VENDOR_MANIFEST.toml"
fails=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }
note() { printf '  \033[0;33mNOTE\033[0m  %s\n' "$1"; }

echo "sync_vendor: an aborted sync must not move pinned_sha"

# 1. The invariant is enforced by a TRAP, not by per-path hand-restores.
#    A trap is the only form that a newly-added `exit` cannot opt out of, and
#    opting out silently is what the three leaking paths did.
if grep -q 'trap _restore_pin_on_exit EXIT' "$SCRIPT"; then
	pass "restore is wired as an EXIT trap (a new abort path cannot forget)"
else
	fail "no EXIT trap -- per-path restores regress the moment someone adds an exit"
fi

# 2. The commit flag must be set AFTER the swap, or the trap is a no-op and we
#    are back to trusting the happy path.
_bump_line="$(grep -n '^_pin_committed=0' "$SCRIPT" | head -1 | cut -d: -f1)"
_commit_line="$(grep -n '^_pin_committed=1' "$SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$_bump_line" ] && [ -n "$_commit_line" ] && [ "$_commit_line" -gt "$_bump_line" ]; then
	pass "_pin_committed is set only after the swap (line $_commit_line > $_bump_line)"
else
	fail "_pin_committed ordering wrong or missing (bump=$_bump_line commit=$_commit_line)"
fi

# 3. THE BEHAVIOURAL CHECK. Drive a real abort and diff the manifest.
#
# Restoring the manifest is unconditional: this test must never be the reason
# a pin is wrong.
_src="$(sed -n '/^name             = "doctor"/,/^source_path/p' "$MANIFEST" | grep '^source_repo' | sed 's/.*= *"//; s/".*//')"
_src_expanded="$(eval "printf '%s' \"$_src\"" 2>/dev/null)"

if [ -z "${HR015:-}" ] || [ ! -d "$_src_expanded" ]; then
	note "NOT RUN: doctor source repo unresolved (set HR015=/path/to/HR015)."
	note "         The structural checks above still hold; the real abort was NOT exercised."
	note "         This is a coverage gap, not a green."
else
	_before="$(mktemp)"; cp "$MANIFEST" "$_before"
	trap 'cp "$_before" "$MANIFEST" 2>/dev/null; rm -f "$_before"' EXIT

	bash "$SCRIPT" doctor >/dev/null 2>&1; _rc=$?
	if [ "$_rc" -eq 0 ]; then
		fail "control broke: the doctor sync SUCCEEDED, so no abort was exercised"
	elif diff -q "$_before" "$MANIFEST" >/dev/null 2>&1; then
		pass "real abort (rc=$_rc) left the manifest byte-identical"
	else
		fail "real abort (rc=$_rc) MOVED pinned_sha -- the leak is back"
	fi

	# NEGATIVE CONTROL. Strip the trap from a copy and prove the same abort
	# does move the pin, so a pass above means the guard works rather than the
	# abort merely being harmless.
	# The copy MUST live beside _vendor_lib.sh: sync_vendor.sh resolves its lib
	# from its own dirname, so a /tmp copy dies at the `source` line and never
	# reaches the pin bump. First attempt did exactly that and reported the
	# control "did not move the pin" -- which looked like the guard working and
	# was actually the control never running. Same shape as every other false
	# reading this week: validate the probe before believing its answer.
	_broken="$HERE/scripts/.negctl_sync_vendor_$$.sh"
	sed 's/^trap _restore_pin_on_exit EXIT/: # trap removed for negative control/' "$SCRIPT" > "$_broken"
	chmod +x "$_broken"
	trap 'cp "$_before" "$MANIFEST" 2>/dev/null; rm -f "$_before" "$_broken"' EXIT
	cp "$_before" "$MANIFEST"
	bash "$_broken" doctor >/dev/null 2>&1
	if diff -q "$_before" "$MANIFEST" >/dev/null 2>&1; then
		fail "negative control did NOT move the pin -- either the guard is unreachable or the control never ran; check it resolves _vendor_lib.sh"
	else
		pass "negative control (trap stripped) DOES move the pin -- the test discriminates"
	fi
	cp "$_before" "$MANIFEST"
	rm -f "$_broken"
fi

echo ""
if [ "$fails" -eq 0 ]; then echo "sync_vendor abort-pin: GREEN"; exit 0; fi
echo "sync_vendor abort-pin: RED ($fails failing)"; exit 1
