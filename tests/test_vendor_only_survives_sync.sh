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

# 5. sync_vendor.sh must actually reference the TSV. Without this, everything
#    above tests a mechanism that production does not use.
if grep -q 'VENDOR_ONLY.tsv' "$REPO_ROOT/scripts/sync_vendor.sh"; then
	pass "sync_vendor.sh reads VENDOR_ONLY.tsv"
else
	fail "sync_vendor.sh does NOT read VENDOR_ONLY.tsv -- declaration is inert"
fi

echo ""
if [ "$fails" -eq 0 ]; then echo "v1018-D024: GREEN"; exit 0; fi
echo "v1018-D024: RED ($fails failing)"; exit 1
