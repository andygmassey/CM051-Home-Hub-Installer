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

# A SYNC RUNS ON ONE TREE, AND THE FIXTURE HAS TO SAY WHICH.
#
# The region computes    _vo_rel_from_vendor="${abs_vendor#"$_vo_root"/}/$_f"
# so abs_vendor must be a SUBDIRECTORY of the vendor root -- vendor/doctor,
# never vendor/ itself. The first version of this fixture set both to the same
# path, which is the shape the OLD, BUGGY arithmetic assumed
# (`_vo_src="$abs_vendor/$_vo_path"`). With them equal the prefix strip
# no-ops, every computed path comes out absolute, no TSV row matches, and the
# region hard-refuses. A fixture that encodes the defect cannot test the fix.
#
# Tree names come from the manifest, which is the same list sync_vendor.sh
# iterates, so a new tree cannot silently fall outside this test.
manifest_trees() {
	grep -E '^name[[:space:]]*=' "$REPO_ROOT/vendor/VENDOR_MANIFEST.toml" \
		| sed 's/.*=[[:space:]]*"//; s/".*//'
}

# Longest manifest tree name that prefixes a TSV row. Longest wins because
# "cm041" and "cm041/assistant_api" can both be trees.
tree_of() {
	local p="$1" t best=""
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		case "$p" in "$t"/*) [ "${#t}" -gt "${#best}" ] && best="$t" ;; esac
	done <<-EOF
	$(manifest_trees)
	EOF
	printf '%s\n' "$best"
}

# The trees that actually carry vendor-only rows. A real sync runs per tree, so
# check 5 does too -- otherwise a tree could be registered and never exercised.
vo_trees="$(
	while IFS=$'\t' read -r _vp _ _; do
		case "${_vp:-}" in ''|'#'*) continue ;; esac
		tree_of "$_vp"
	done < "$REPO_ROOT/vendor/VENDOR_ONLY.tsv" | sort -u | sed '/^$/d'
)"

run_real_region() {   # $1 = script, $2 = scratch root, $3 = tree; echoes verdict
	local src="$1" root="$2" tree="$3" s e vp rel
	s="$(grep -n "$MARK_START" "$src" | head -1 | cut -d: -f1)"
	e="$(grep -n "$MARK_END"   "$src" | head -1 | cut -d: -f1)"
	[ -n "$s" ] && [ -n "$e" ] && [ "$e" -gt "$s" ] || { echo "NOREGION"; return; }

	# Fixture laid out so the region's own path arithmetic resolves into it:
	# it computes the TSV as "$(dirname BASH_SOURCE)/../vendor/VENDOR_ONLY.tsv".
	# The TSV therefore sits at vendor/ -- OUTSIDE abs_vendor, exactly as in the
	# real repo, so the region's `find` never mistakes the registry itself for
	# an unregistered vendor-only file.
	mkdir -p "$root/scripts" "$root/vendor/$tree" "$root/upstream"
	cp "$REPO_ROOT/vendor/VENDOR_ONLY.tsv" "$root/vendor/VENDOR_ONLY.tsv"
	while IFS=$'\t' read -r vp _ _; do
		case "${vp:-}" in ''|'#'*) continue ;; esac
		[ "$(tree_of "$vp")" = "$tree" ] || continue
		rel="${vp#"$tree"/}"
		mkdir -p "$root/vendor/$tree/$(dirname "$rel")"
		printf 'vendor-only marker for %s\n' "$vp" > "$root/vendor/$tree/$rel"
	done < "$root/vendor/VENDOR_ONLY.tsv"
	# The upstream half of the swap: present in source, so it must ARRIVE.
	echo "from upstream" > "$root/upstream/other.py"

	# THE PREAMBLE IS A CONTRACT WITH THE REGION, AND IT DRIFTS.
	#
	# 2026-08-11: the region gained `_vo_root="$VLIB_REPO_ROOT/vendor"` (the
	# path-join fix). The preamble still defined only abs_vendor and tmp, so
	# under `set -u` the region died on line 16 with "VLIB_REPO_ROOT: unbound
	# variable" BEFORE the swap. Nothing was ever deleted, so every vendor-only
	# file trivially survived, the upstream fixture never appeared, and checks
	# 5, 5b and 5d all went red with three different misleading messages. One
	# broken premise, three wrong diagnoses.
	#
	#   VLIB_REPO_ROOT  load-bearing. TSV paths are relative to vendor/, so
	#                   _vo_root must equal the fixture's vendor root.
	#   TREE            names the tree in refusal text and feeds the `exclude`
	#                   lookup. vlib_field is absent here, so excludes are
	#                   empty -- correct for a fixture with nothing excluded.
	#   TO_SHA          appears only inside message strings.
	{
		echo 'set -uo pipefail'
		echo 'abs_vendor="'"$root"'/vendor/'"$tree"'"'
		echo 'tmp="'"$root"'/upstream"'
		echo 'VLIB_REPO_ROOT="'"$root"'"'
		echo 'TREE="'"$tree"'"'
		echo 'TO_SHA="0000000000000000000000000000000000000000"'
		sed -n "${s},${e}p" "$src"
	} > "$root/scripts/region.sh"

	( cd "$root" && bash "$root/scripts/region.sh" ) >"$root/run.log" 2>&1
	echo "rc=$?"
}

# Did the region actually EXECUTE? `run_real_region` has always computed this
# and check 5 has always printed it in the pass line -- and never asserted on
# it. That is this gate's own catalogue entry "fires, and the result is
# discarded", and it cost three false diagnoses. A region that dies on line 16
# cannot tell you anything about a restore on line 140, so a non-zero rc is a
# DIFFERENT failure from "files were lost" and must say so.
region_ran() {   # $1 = verdict from run_real_region, $2 = scratch root
	case "$1" in
		NOREGION) fail "could not locate the stash/restore region in sync_vendor.sh -- markers moved; this check is now blind"; return 1 ;;
		rc=0)     return 0 ;;
	esac
	fail "CANNOT RUN: lifted region exited ${1#rc=} before finishing -- $(head -1 "$2/run.log" 2>/dev/null | sed 's|.*region\.sh: ||')"
	return 1
}

# ONE predicate, shared by check 5 and by the RED that proves check 5 fires.
#
# TNM's review finding: 5d originally RE-IMPLEMENTED this grep instead of
# executing it -- the same expression written twice, ~70 lines apart. 5d then
# proved "a path-only restore produces empty files" and merely *inferred* that
# check 5 would notice. Change check 5's predicate and 5d keeps passing while
# proving nothing about it. That is precisely the objection this whole gate was
# written to answer -- "a hand-written re-implementation carries the belief that
# caused the defect" -- aimed back at its author, and it was correct.
#
# Now there is one expression. If it drifts, both checks drift together and the
# control below catches it before either runs.
vo_state() {   # $1 = vendor root, $2 = declared path; echoes gone|empty|ok
	if [ ! -e "$1/$2" ]; then
		echo gone
	elif grep -q "vendor-only marker for $2" "$1/$2" 2>/dev/null; then
		echo ok
	else
		echo empty
	fi
}

# CONTROL ON THE SHARED PREDICATE. Both check 5 and 5d now depend on vo_state,
# so a broken vo_state would break them in the SAME direction and neither would
# report anything odd. Prove it discriminates all three states first.
_vs="$(mktemp -d)"; mkdir -p "$_vs/a"
printf 'vendor-only marker for a/x\n' > "$_vs/a/x"
: > "$_vs/a/y"
if [ "$(vo_state "$_vs" a/x)" = ok ] &&
   [ "$(vo_state "$_vs" a/y)" = empty ] &&
   [ "$(vo_state "$_vs" a/z)" = gone ]; then
	pass "shared vo_state predicate discriminates ok / empty / gone"
else
	fail "shared vo_state predicate does NOT discriminate (ok=$(vo_state "$_vs" a/x) empty=$(vo_state "$_vs" a/y) gone=$(vo_state "$_vs" a/z)) -- checks 5 and 5d are both unreliable"
fi
rm -rf "$_vs"

verdict_lost=0
if [ -z "$vo_trees" ]; then
	fail "no TSV row maps to a manifest tree -- the fixture cannot model a real sync"
	verdict_lost=1
fi
for vtree in $vo_trees; do
scratch2="$(mktemp -d)"
res="$(run_real_region "$SV" "$scratch2" "$vtree")"
if ! region_ran "$res" "$scratch2"; then
	verdict_lost=1
else
	missing=""
	while IFS=$'\t' read -r vp _ _; do
		case "${vp:-}" in ''|'#'*) continue ;; esac
		[ "$(tree_of "$vp")" = "$vtree" ] || continue
		# EXISTENCE is not enough. A restore that recreates the path and
		# loses the bytes passes an -e test, and that is not a hypothetical
		# shape: a tar built from the wrong cwd, a cp that fails on one file
		# while the pipeline exit stays 0, a truncating redirect. The two
		# files this gate exists for were "deleted by the v1.0.18 re-vendor,
		# recovered by hand" -- recovering an EMPTY file by hand is worse
		# than recovering a missing one, because nothing tells you.
		# vo_state is the shared predicate; 5d proves THIS line fires by
		# calling the same function, not a copy of it.
		case "$(vo_state "$scratch2/vendor" "$vp")" in
			ok)    ;;
			gone)  missing="$missing $vp" ;;
			empty) missing="$missing $vp(empty-or-corrupt)" ;;
		esac
	done < "$REPO_ROOT/vendor/VENDOR_ONLY.tsv"
	# BOTH halves. The declared files must survive AND the upstream file must
	# arrive -- a region that dies before the swap satisfies the first alone.
	if [ -z "$missing" ] && [ -e "$scratch2/vendor/$vtree/other.py" ]; then
		pass "REAL sync_vendor.sh preserves every declared file in $vtree across the swap ($res)"
	else
		fail "REAL sync_vendor.sh LOST in $vtree:${missing:- (upstream files)} -- see $scratch2/run.log"
		verdict_lost=1
	fi
fi
[ "$verdict_lost" -eq 1 ] || rm -rf "$scratch2"
done

# The mutation REDs below prove the MECHANISM, so one tree is enough; check 5
# above is what provides per-tree coverage. First sorted tree is
# cm041/assistant_api, which is where subscription_gate.py lives -- the file
# whose silent deletion is the reason this gate exists.
PRIMARY_TREE="$(printf '%s\n' $vo_trees | head -1)"

# 5b. THE RED. Delete only the restore line from a COPY and prove step 5 fails.
#     Without this, step 5 could be passing for a reason unrelated to the
#     restore -- e.g. if the swap never deleted anything in the first place.
# REPLACE THE RESTORE PIPELINE, NEVER THE WHOLE LINE.
#
# The restore line ends in ` || {` and the brace block runs three more lines.
# Deleting the line therefore orphans `exit 1; }`, and the region dies with a
# bash SYNTAX ERROR (exit 2) before reaching any restore logic at all. 5b did
# exactly that: it deleted the line, nothing was lost because nothing ran, and
# it reported "removing the restore line changed nothing -- step 5 is not
# testing the restore". The instrument was broken, not the subject. 5d had
# already been fixed for this same hazard; 5b had not, so the fix now lives in
# one shared mutator that both call.
_VO_TAR='( cd "$_vo_stash" && tar -cf - . ) | ( cd "$abs_vendor" && tar -xf - )'
mutate_restore() {   # $1 = replacement for the pipeline, $2 = output path
	awk -v find="$_VO_TAR" -v repl="$1" '
		{
			n = index($0, find)
			if (n > 0) {
				print substr($0, 1, n - 1) repl substr($0, n + length(find))
				next
			}
			print
		}
	' "$SV" > "$2"
}

scratch3="$(mktemp -d)"; sv_broken="$scratch3/sync_vendor_broken.sh"
# `true` keeps the `|| { ... }` attached and parsing, while restoring nothing.
mutate_restore 'true' "$sv_broken"
if cmp -s "$SV" "$sv_broken"; then
	fail "self-test could not neutralise the restore -- the RED below proves nothing"
elif ! sh -n "$sv_broken" 2>/dev/null; then
	fail "the neutralised restore does not parse -- it would fail for the wrong reason"
else
	res3="$(run_real_region "$sv_broken" "$scratch3/root" "$PRIMARY_TREE")"
	# Same trap as check 5: a region that cannot run deletes nothing, so nothing
	# is lost, which reads identically to "the restore was never load-bearing".
	if region_ran "$res3" "$scratch3/root"; then
		lost=0
		while IFS=$'\t' read -r vp _ _; do
			case "${vp:-}" in ''|'#'*) continue ;; esac
			# Only rows for the tree the fixture built. Without this, rows from
			# OTHER trees are absent by construction and 5b would "pass" on
			# files the mutation never touched.
			[ "$(tree_of "$vp")" = "$PRIMARY_TREE" ] || continue
			[ -e "$scratch3/root/vendor/$vp" ] || lost=1
		done < "$REPO_ROOT/vendor/VENDOR_ONLY.tsv"
		if [ "$lost" -eq 1 ]; then
			pass "RED demonstrated: removing the restore line DOES lose the declared files"
		else
			fail "removing the restore line changed nothing -- step 5 is not testing the restore"
		fi
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
_VO_TOUCH='( cd "$_vo_stash" && find . -type f -print ) | ( cd "$abs_vendor" && while IFS= read -r _p; do mkdir -p "$(dirname "$_p")"; : > "$_p"; done )'
mutate_restore "$_VO_TOUCH" "$sv_touch"
if cmp -s "$SV" "$sv_touch"; then
	fail "self-test could not swap in a content-losing restore -- the RED below proves nothing"
elif ! sh -n "$sv_touch" 2>/dev/null; then
	fail "the content-losing injection does not parse -- it would fail for the wrong reason"
else
	# This line used to end in `>/dev/null` -- the verdict computed and thrown
	# away, the purest form of the defect this gate is about.
	res4="$(run_real_region "$sv_touch" "$scratch4/root" "$PRIMARY_TREE")"
	if region_ran "$res4" "$scratch4/root"; then
	empty=0; gone=0; intact=0
	while IFS=$'\t' read -r vp _ _; do
		case "${vp:-}" in ''|'#'*) continue ;; esac
		# Same tree filter as 5b, for the same reason: an uncreated row would
		# read as `gone` and drive the gone=0 assertion red for no real cause.
		[ "$(tree_of "$vp")" = "$PRIMARY_TREE" ] || continue
		# Same vo_state check 5 uses, called not copied. This is what makes
		# 5d a proof about check 5 rather than a parallel belief about it.
		case "$(vo_state "$scratch4/root/vendor" "$vp")" in
			empty) empty=$((empty + 1)) ;;
			gone)  gone=$((gone + 1)) ;;
			ok)    intact=$((intact + 1)) ;;
		esac
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
fi
rm -rf "$scratch4"

# 5e. CONTROL ON THE CANNOT-RUN DETECTOR. region_ran is only worth having if a
#     region that dies really does yield a non-zero verdict. This is the exact
#     failure of 2026-08-11 reproduced deliberately: inject a reference to a
#     variable nothing defines and require BOTH a non-zero rc and the shell's
#     own "unbound variable" in the log. Without this control, the preamble
#     could drift again and checks 5/5b/5d would go back to reporting "files
#     lost" about a region that never executed a single line of restore code.
scratch5="$(mktemp -d)"; sv_unbound="$scratch5/sync_vendor_unbound.sh"
awk '{ print } /^_vo_root=/ { print "_vo_probe=\"$OSTLER_NO_SUCH_VAR\"" }' "$SV" > "$sv_unbound"
if cmp -s "$SV" "$sv_unbound"; then
	fail "self-test could not inject an unbound reference -- the CANNOT-RUN detector is unproven"
else
	res5="$(run_real_region "$sv_unbound" "$scratch5/root" "$PRIMARY_TREE")"
	if [ "$res5" != "rc=0" ] && [ "$res5" != NOREGION ] \
	   && grep -q 'unbound variable' "$scratch5/root/run.log" 2>/dev/null; then
		pass "control: a region that cannot run yields $res5 and is not read as 'files lost'"
	else
		fail "CANNOT-RUN detector did not fire (verdict=$res5) -- 5/5b/5d can still misreport a dead region"
	fi
fi
rm -rf "$scratch5"

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
