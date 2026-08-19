#!/usr/bin/env bash
# tests/test_rollforward_registry_pin.sh
# ============================================================================
# The vendored rollforward gate and defect registry must be byte-identical to
# the OS003 commit cuts/REGISTRY_PIN names.
#
# WHY. CM051 #540 vendored bin/rollforward_gate.sh out of OS003 with nothing
# holding the copy to its source, and it drifted 239 diff lines behind: no
# outbound redactor, no claim-coverage pass, and a parse bug OS003 had already
# fixed. It also arrived without cuts/DEFECTS_ROLLFORWARD.md, the file the
# runner reads, so cut.yml's pre-signing gate could not have passed on any tag.
#
# A vendored copy with no pin is a fork nobody declared. This makes the fork
# fail loudly, at PR time, in the repo that holds the copy.
#
# WHAT THIS PROVES, AND WHAT IT CANNOT
#   PROVES:  the four vendored files match the hashes recorded in REGISTRY_PIN,
#            and the pin names a specific OS003 commit.
#   CANNOT:  that the named commit is still OS003's HEAD. CM051's GITHUB_TOKEN
#            cannot read OS003 and there is no cross-repo token, so freshness
#            is an OPERATOR check -- run scripts/sync_rollforward_registry.sh
#            --check before tagging. Stated here rather than left implied,
#            because a gate that is quiet about its blind spot gets read as
#            covering it.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$HERE/cuts/REGISTRY_PIN"
fails=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

echo "vendored rollforward gate: pinned to OS003"

if [ ! -f "$PIN" ]; then
	fail "cuts/REGISTRY_PIN is missing -- the vendored copy has no declared source"
	echo "Run scripts/sync_rollforward_registry.sh to create it."
	exit 1
fi

os003_sha="$(awk -F'\t' '$1 == "os003_sha" {print $2}' "$PIN")"
if [ -n "$os003_sha" ] && [ "${#os003_sha}" -eq 40 ]; then
	pass "pin names an OS003 commit (${os003_sha:0:8})"
else
	fail "pin has no usable os003_sha -- provenance is not recorded"
fi

# Every file the pin lists must exist and hash to the recorded value.
listed=0
while IFS=$'\t' read -r path want; do
	case "$path" in ''|\#*|os003_*) continue ;; esac
	listed=$((listed + 1))
	if [ ! -f "$HERE/$path" ]; then
		fail "$path is pinned but ABSENT from this repo"
		continue
	fi
	got="$(shasum -a 256 "$HERE/$path" | awk '{print $1}')"
	if [ "$got" = "$want" ]; then
		pass "$path matches the pin"
	else
		# DO NOT NAME A DIRECTION THIS CHECK CANNOT KNOW.
		#
		# This used to read "fix it in OS003 and re-sync, do not edit the copy",
		# which assumes the vendored copy is the stale side. It is not always.
		# Measured 2026-08-15: the vendored registry was 10,381 words AHEAD of
		# the OS003 original and held gate `v1018-D008`, which OS003 did not have
		# at all. Following that advice would have deleted both.
		#
		# The mirror case is real too, and is why the advice was written: the
		# header of cuts/REGISTRY_PIN records CM051 once running "a rollforward
		# gate 239 diff lines behind the original". Both directions have
		# happened, and a hash comparison cannot tell them apart -- it only knows
		# the two differ.
		#
		# So report the fact and hand the reader the command that establishes the
		# direction, rather than asserting one.
		fail "$path DIFFERS from the pin"
		echo "        pinned ${want:0:16}...  actual ${got:0:16}..."
		echo ""
		echo "        This says the two DIFFER. It does NOT say which is right,"
		echo "        and this check cannot know. Establish that before acting:"
		echo ""
		echo "          diff \"\${OS003_DIR:-\$HOME/Developer/OS003-Ostler-Release}/$path\" \"$HERE/$path\""
		echo ""
		echo "        If OS003 is ahead, re-sync and re-pin."
		echo "        If the vendored copy is ahead, port those changes UP to"
		echo "        OS003 first -- a re-sync would delete them. scripts/"
		echo "        sync_rollforward_registry.sh now refuses in that case."
		echo "        If the copy was edited in place and the change is correct,"
		echo "        land it in OS003 and re-pin so the two agree again."
	fi
done < "$PIN"

# A pin listing nothing would pass every check above while asserting nothing --
# the vacuous-green shape. Require the full set.
if [ "$listed" -eq 4 ]; then
	pass "pin covers all 4 vendored files"
else
	fail "pin lists $listed file(s), expected 4 -- an under-populated pin passes vacuously"
fi

# ---------------------------------------------------------------------------
# THE NEWEST CUT MANIFEST MUST HAVE A cut.env BESIDE IT.
#
# THE DEFECT. cut.yml demands two files of a tag and until 2026-08-13 they
# lived in different repos:
#
#   "Tag must match the in-repo cut record"  cut-manifests/<TAG>.yaml   CM051
#   "Rollforward claims" runs --cut <TAG>    cuts/<TAG>/cut.env         OS003
#
# Nothing asserted the pairing and nothing carried the second across, so
# `cuts/v*/cut.env` here matched NOTHING and --cut could not resolve for ANY
# tag. Not a missing v1.0.24; a missing category. The v1.0.24 tag push died on
# it, the cut job was SKIPPED, and nothing was signed.
#
# SCOPED TO THE NEWEST MANIFEST, AND NO WIDER. A draft of this asserted the
# pairing for EVERY manifest and went red on 13, because CM051 keeps manifests
# back to v1.0.11 while only six cuts ever had a cut.env. That gate would have
# been permanently red on main, curable only by retro-filling nine dead cuts
# with invented pins. A version nobody will cut again does not need a
# resolvable cut.env, so demanding one is a gate stricter than the defect it
# names -- the v1018-D011 shape.
#
# COMPUTED, never a remembered version list: `sort -V` picks the newest, so a
# new manifest is covered the day it lands with nobody editing this file.
newest="$(ls "$HERE"/cut-manifests/v*.yaml 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.yaml$//' | sort -V | tail -1)"
if [ -z "${newest:-}" ]; then
	# Zero manifests would make this pass by examining nothing. Say what was
	# examined; a zero denominator reads as success.
	fail "no cut-manifests/v*.yaml found -- this check examined nothing, which is not the same as finding nothing wrong"
elif [ -f "$HERE/cuts/$newest/cut.env" ]; then
	pass "newest manifest $newest has a resolvable cuts/$newest/cut.env"
else
	fail "cut-manifests/$newest.yaml is the newest cut but cuts/$newest/cut.env does NOT exist -- 'rollforward_gate.sh --cut $newest' dies with PARSE ERROR, preflight goes red, and the cut job is SKIPPED with nothing signed"
fi

# BOTH declared pins must actually bind. A cut.env that exists but sets
# neither key satisfies the check above while binding nothing, which is how a
# repo gate ends up asserting main -- the failure the runner's own header
# describes. OS003's v1.0.24 cut.env was exactly this: 62 lines of pins, and
# neither of the two keys the gate reads.
if [ -n "${newest:-}" ] && [ -f "$HERE/cuts/$newest/cut.env" ]; then
	for k in DAEMON_COMMIT CM051; do
		v="$( set +u; . "$HERE/cuts/$newest/cut.env" >/dev/null 2>&1; eval "printf '%s' \"\${$k:-}\"" )"
		if [ -n "$v" ]; then
			pass "$newest binds $k=$v"
		else
			fail "cuts/$newest/cut.env sets no $k -- the gate binds an empty pin and every gate needing it goes CANNOT-RUN, while the cut still reads as pinned"
		fi
	done
fi

# The runner must be able to FIND the registry at its default path, which is
# the exact defect that killed the v1.0.19 cut. Assert the default, not a path
# this test supplies, or the test proves something the cut does not use.
if [ -f "$HERE/cuts/DEFECTS_ROLLFORWARD.md" ]; then
	pass "registry is at the runner's default path (cuts/DEFECTS_ROLLFORWARD.md)"
else
	fail "registry absent at the default path -- this is the v1.0.19 cut failure exactly"
fi

echo ""
if [ "$fails" -gt 0 ]; then
	printf '\033[0;31mrollforward pin: %d FAILED\033[0m\n' "$fails"
	exit 1
fi
printf '\033[0;32mrollforward pin: vendored copy matches OS003 %s\033[0m\n' "${os003_sha:0:8}"
