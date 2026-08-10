#!/usr/bin/env bash
# tests/test_vendor_only_survives_sync.sh -- gate for v1018-D024.
#
# Every path declared in vendor/VENDOR_ONLY.tsv must exist in vendor/, and must
# survive a wholesale vendor-tree swap.
#
# The second half is the point. Asserting only "the files are here" would have
# passed happily on every commit before the v1.0.18 re-vendor deleted them --
# it would have been green right up until the moment it mattered, then gone red
# after the damage. So this test REPRODUCES the swap against a scratch copy and
# proves the restore logic actually fires. Per the v1.0.19 contract, a gate with
# no demonstrated RED is not a gate; here the RED is demonstrated in-line, every
# run, by a control that omits the protection.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSV="$REPO_ROOT/vendor/VENDOR_ONLY.tsv"
fails=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

echo "v1018-D024: vendor-only files must survive a re-vendor"

[ -f "$TSV" ] || { fail "vendor/VENDOR_ONLY.tsv is missing"; echo "v1018-D024: RED"; exit 1; }

declared=0
while IFS=$'\t' read -r p repo why; do
	case "${p:-}" in ''|'#'*) continue ;; esac
	declared=$((declared + 1))

	# 1. Declared file must actually be present.
	if [ -e "$REPO_ROOT/vendor/$p" ]; then pass "present: $p"
	else fail "DECLARED BUT MISSING: $p -- a re-vendor has already eaten it"; continue; fi

	# 2. Every row must carry a reason. A row that says nothing gets copied
	#    forever by people who cannot tell whether it is still needed.
	if [ -n "${why:-}" ] && [ "${#why}" -ge 20 ]; then pass "reason recorded: $p"
	else fail "no why_no_upstream for $p -- undocumented exceptions become permanent"; fi

	# 3. Must genuinely have no upstream counterpart. If it DOES exist
	#    upstream, the row is stale and is now masking real drift.
	if [ -n "${repo:-}" ]; then pass "owning repo declared: $p ($repo)"
	else fail "no owning_repo for $p"; fi
done < "$TSV"

[ "$declared" -gt 0 ] && pass "$declared vendor-only path(s) declared" \
                      || fail "no rows parsed -- is the TSV tab-separated?"

# 4. THE CONTROL. Simulate the wholesale swap on a scratch tree, twice:
#    without the restore (must LOSE the file) and with it (must KEEP it).
scratch="$(mktemp -d)"
mkdir -p "$scratch/vendor/doctor/agent" "$scratch/upstream/doctor/agent"
echo "vendor-only marker" > "$scratch/vendor/doctor/agent/daemon_cron.py"
echo "from upstream"      > "$scratch/upstream/doctor/agent/other.py"

# 4a. Unprotected swap -- the pre-fix behaviour.
rm -rf "$scratch/vendor"; mkdir -p "$scratch/vendor"
( cd "$scratch/upstream" && tar -cf - . ) | ( cd "$scratch/vendor" && tar -xf - )
if [ ! -e "$scratch/vendor/doctor/agent/daemon_cron.py" ]; then
	pass "control: unprotected swap DOES delete the vendor-only file (gate can go red)"
else
	fail "control did not reproduce the deletion -- this gate proves nothing"
fi

# 4b. Protected swap -- stash, swap, restore.
mkdir -p "$scratch/vendor/doctor/agent"
echo "vendor-only marker" > "$scratch/vendor/doctor/agent/daemon_cron.py"
stash="$(mktemp -d)"
mkdir -p "$stash/doctor/agent"
cp -p "$scratch/vendor/doctor/agent/daemon_cron.py" "$stash/doctor/agent/daemon_cron.py"
rm -rf "$scratch/vendor"; mkdir -p "$scratch/vendor"
( cd "$scratch/upstream" && tar -cf - . ) | ( cd "$scratch/vendor" && tar -xf - )
( cd "$stash" && tar -cf - . ) | ( cd "$scratch/vendor" && tar -xf - )
if [ -e "$scratch/vendor/doctor/agent/daemon_cron.py" ] \
   && [ -e "$scratch/vendor/doctor/other.py" -o -e "$scratch/vendor/doctor/agent/other.py" ]; then
	pass "protected swap keeps the vendor-only file AND the upstream files"
else
	fail "protected swap lost something -- restore logic is wrong"
fi
rm -rf "$scratch" "$stash"

# 5. EXECUTE THE REAL CODE. Everything above proves an algorithm that this
#    test file implements. That is the same defect class the algorithm exists
#    to fix: a hand-written re-implementation carries the belief that caused
#    the bug. The previous version of this step was
#    `grep -q 'VENDOR_ONLY.tsv' sync_vendor.sh` -- a string check that passes
#    on a wrong $abs_vendor, on a restore block sitting after an early exit,
#    and on the restore half simply not being there.
#
#    So: lift the real stash/swap/restore region out of scripts/sync_vendor.sh
#    and run it against a scratch fixture, unmodified.
SV="$REPO_ROOT/scripts/sync_vendor.sh"
MARK_START='^# Preserve vendor-only files across the swap'
MARK_END='^\[ -n "\$_vo_stash" \] && rm -rf "\$_vo_stash"'

run_real_region() {   # $1 = script to lift from, $2 = scratch root; echoes verdict
	local src="$1" root="$2" s e
	s="$(grep -n "$MARK_START" "$src" | head -1 | cut -d: -f1)"
	e="$(grep -n "$MARK_END"   "$src" | head -1 | cut -d: -f1)"
	[ -n "$s" ] && [ -n "$e" ] && [ "$e" -gt "$s" ] || { echo "NOREGION"; return; }

	# Fixture laid out so the region's own path arithmetic resolves into it:
	# it computes the TSV as "$(dirname BASH_SOURCE)/../vendor/VENDOR_ONLY.tsv".
	mkdir -p "$root/scripts" "$root/vendor/doctor/agent" "$root/upstream/doctor/agent"
	cp "$REPO_ROOT/vendor/VENDOR_ONLY.tsv" "$root/vendor/VENDOR_ONLY.tsv"
	while IFS=$'\t' read -r vp _ _; do
		case "${vp:-}" in ''|'#'*) continue ;; esac
		mkdir -p "$root/vendor/$(dirname "$vp")"
		printf 'vendor-only marker for %s\n' "$vp" > "$root/vendor/$vp"
	done < "$root/vendor/VENDOR_ONLY.tsv"
	echo "from upstream" > "$root/upstream/doctor/agent/other.py"

	{
		echo 'set -uo pipefail'
		echo 'abs_vendor="'"$root"'/vendor"'
		echo 'tmp="'"$root"'/upstream"'
		sed -n "${s},${e}p" "$src"
	} > "$root/scripts/region.sh"

	( cd "$root" && bash "$root/scripts/region.sh" ) >"$root/run.log" 2>&1
	echo "rc=$?"
}

verdict_lost=0
scratch2="$(mktemp -d)"
res="$(run_real_region "$SV" "$scratch2")"
if [ "$res" = "NOREGION" ]; then
	fail "could not locate the stash/restore region in sync_vendor.sh -- markers moved; this check is now blind"
else
	missing=""
	while IFS=$'\t' read -r vp _ _; do
		case "${vp:-}" in ''|'#'*) continue ;; esac
		# EXISTENCE is not enough. A restore that recreates the path and
		# loses the bytes passes an -e test, and that is not a hypothetical
		# shape: a tar built from the wrong cwd, a cp that fails on one file
		# while the pipeline exit stays 0, a truncating redirect. The two
		# files this gate exists for were "deleted by the v1.0.18 re-vendor,
		# recovered by hand" -- recovering an EMPTY file by hand is worse
		# than recovering a missing one, because nothing tells you.
		# The fixture writes a known marker into each file (see
		# run_real_region); require it back. 5d proves this line fires.
		[ -e "$scratch2/vendor/$vp" ] || { missing="$missing $vp"; continue; }
		grep -q "vendor-only marker for $vp" "$scratch2/vendor/$vp" 2>/dev/null \
			|| missing="$missing $vp(empty-or-corrupt)"
	done < "$REPO_ROOT/vendor/VENDOR_ONLY.tsv"
	if [ -z "$missing" ] && [ -e "$scratch2/vendor/doctor/agent/other.py" ]; then
		pass "REAL sync_vendor.sh code preserves every declared file across the swap ($res)"
	else
		fail "REAL sync_vendor.sh code LOST:${missing:- (upstream files)} -- see $scratch2/run.log"
		verdict_lost=1
	fi
fi
rm -rf "$scratch2"

# 5b. THE RED. Delete only the restore line from a COPY and prove step 5 fails.
#     Without this, step 5 could be passing for a reason unrelated to the
#     restore -- e.g. if the swap never deleted anything in the first place.
scratch3="$(mktemp -d)"; sv_broken="$scratch3/sync_vendor_broken.sh"
sed '/( cd "\$_vo_stash" \&\& tar -cf - \. ) | ( cd "\$abs_vendor" \&\& tar -xf - )/d' "$SV" > "$sv_broken"
if cmp -s "$SV" "$sv_broken"; then
	fail "self-test could not remove the restore line -- the RED below proves nothing"
else
	res3="$(run_real_region "$sv_broken" "$scratch3/root")"
	lost=0
	while IFS=$'\t' read -r vp _ _; do
		case "${vp:-}" in ''|'#'*) continue ;; esac
		[ -e "$scratch3/root/vendor/$vp" ] || lost=1
	done < "$REPO_ROOT/vendor/VENDOR_ONLY.tsv"
	if [ "$lost" -eq 1 ]; then
		pass "RED demonstrated: removing the restore line DOES lose the declared files"
	else
		fail "removing the restore line changed nothing -- step 5 is not testing the restore"
	fi
fi
rm -rf "$scratch3"

# 5d. THE SECOND RED, for the CONTENT half of check 5. 5b deletes the restore
#     entirely, so it only proves check 5 notices a file that is GONE. It says
#     nothing about a file that comes back empty. Replace the restore with one
#     that recreates every stashed path as a zero-byte file and prove check 5
#     still goes red. Without this, the content assertion added above could
#     itself be inert and nobody would know -- which is the whole defect class
#     this gate is about.
scratch4="$(mktemp -d)"; sv_touch="$scratch4/sync_vendor_touch.sh"
# SUBSTRING replacement, not whole-line. The restore line ends in ` || { ... }`
# and the first version of this probe replaced the entire line, silently
# orphaning that brace block. The region then died before restoring, the files
# came back MISSING rather than EMPTY, and a counter that lumped missing in
# with intact reported "content RED did not fire". Two wrong instruments
# cancelling out is exactly the shape this gate exists to catch, so the
# replacement now preserves everything either side of the pipeline.
_VO_TAR='( cd "$_vo_stash" && tar -cf - . ) | ( cd "$abs_vendor" && tar -xf - )'
_VO_TOUCH='( cd "$_vo_stash" && find . -type f -print ) | ( cd "$abs_vendor" && while IFS= read -r _p; do mkdir -p "$(dirname "$_p")"; : > "$_p"; done )'
awk -v find="$_VO_TAR" -v repl="$_VO_TOUCH" '
	{
		n = index($0, find)
		if (n > 0) {
			print substr($0, 1, n - 1) repl substr($0, n + length(find))
			next
		}
		print
	}
' "$SV" > "$sv_touch"
if cmp -s "$SV" "$sv_touch"; then
	fail "self-test could not swap in a content-losing restore -- the RED below proves nothing"
elif ! sh -n "$sv_touch" 2>/dev/null; then
	fail "the content-losing injection does not parse -- it would fail for the wrong reason"
else
	run_real_region "$sv_touch" "$scratch4/root" >/dev/null
	empty=0; gone=0; intact=0
	while IFS=$'\t' read -r vp _ _; do
		case "${vp:-}" in ''|'#'*) continue ;; esac
		if [ ! -e "$scratch4/root/vendor/$vp" ]; then
			gone=$((gone + 1))
		elif grep -q "vendor-only marker for $vp" "$scratch4/root/vendor/$vp" 2>/dev/null; then
			intact=$((intact + 1))
		else
			empty=$((empty + 1))
		fi
	done < "$REPO_ROOT/vendor/VENDOR_ONLY.tsv"
	# The three states are counted separately ON PURPOSE. "missing" would also
	# make check 5 go red, but for the reason 5b already covers -- it would
	# prove nothing about the CONTENT assertion.
	if [ "$empty" -gt 0 ] && [ "$intact" -eq 0 ] && [ "$gone" -eq 0 ]; then
		pass "RED demonstrated: a path-only restore is caught by the CONTENT assertion ($empty present-but-empty)"
	else
		fail "content RED did not fire cleanly: empty=$empty gone=$gone intact=$intact (want empty>0, gone=0, intact=0)"
	fi
fi
rm -rf "$scratch4"

# 5c. ORDERING. Executing the region in isolation cannot see a restore block
#     that sits after an early exit in the real control flow. Assert position.
_swap_ln="$(grep -n '^rm -rf "\$abs_vendor"' "$SV" | head -1 | cut -d: -f1)"
_rest_ln="$(grep -n '( cd "\$_vo_stash" && tar -cf - \. )' "$SV" | head -1 | cut -d: -f1)"
if [ -n "$_swap_ln" ] && [ -n "$_rest_ln" ] && [ "$_rest_ln" -gt "$_swap_ln" ]; then
	# Match exit/return ANYWHERE on the line, not just at line start. The
	# first version of this check anchored with ^[[:space:]]* and sailed
	# straight past an injected `[ "$FLAG" = 9 ] && exit 1` -- asserting a
	# FORMATTING of the hazard instead of the hazard. Any reachable exit
	# between the rm -rf and the restore means the tree can be deleted and
	# the vendor-only files never put back.
	_between="$(sed -n "$((_swap_ln + 1)),$((_rest_ln - 1))p" "$SV" \
	            | grep -vE '^[[:space:]]*#' \
	            | grep -cE '\b(exit|return)\b')"
	if [ "$_between" -eq 0 ]; then
		pass "restore follows the swap with no unconditional exit between them"
	else
		fail "$_between exit/return between swap and restore -- the restore can be skipped"
	fi
else
	fail "could not order swap vs restore in sync_vendor.sh -- structure changed"
fi

echo ""
if [ "$fails" -eq 0 ]; then echo "v1018-D024: GREEN"; exit 0; fi
echo "v1018-D024: RED ($fails failing)"; exit 1
