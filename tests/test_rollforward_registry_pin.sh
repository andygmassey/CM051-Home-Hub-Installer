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
		fail "$path DIFFERS from the pin (fix it in OS003 and re-sync, do not edit the copy)"
		echo "        pinned ${want:0:16}...  actual ${got:0:16}..."
	fi
done < "$PIN"

# A pin listing nothing would pass every check above while asserting nothing --
# the vacuous-green shape. Require the full set.
if [ "$listed" -eq 4 ]; then
	pass "pin covers all 4 vendored files"
else
	fail "pin lists $listed file(s), expected 4 -- an under-populated pin passes vacuously"
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
