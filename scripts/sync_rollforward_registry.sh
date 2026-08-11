#!/usr/bin/env bash
# scripts/sync_rollforward_registry.sh
# ============================================================================
# Brings the rollforward gate and the defect registry over from OS003, and
# records exactly what was taken in cuts/REGISTRY_PIN.
#
# WHY THIS EXISTS
# ---------------
# CM051 #540 vendored bin/rollforward_gate.sh out of OS003 and did NOT bring
# the registry it reads. The runner defaults to $REPO/cuts/DEFECTS_ROLLFORWARD.md
# and CM051 had no cuts/ directory, so cut.yml's pre-signing gate could never
# have passed on any tag. Measured 2026-08-11 on the v1.0.19 tag push, run
# 31449951403 -- the first and only run cut.yml has ever had:
#
#     PARSE ERROR: registry not found: .../CM051-Home-Hub-Installer/cuts/DEFECTS_ROLLFORWARD.md
#
# Then, because a hand copy has no mechanism keeping it honest, the vendored
# runner drifted 239 diff lines behind the OS003 original: no outbound
# redactor, no claim-coverage pass, and a parse bug OS003 had already fixed.
#
# So a copy is not the problem. A copy WITHOUT A PIN is the problem. This
# script makes the copy reproducible and records its provenance; the companion
# test (tests/test_rollforward_registry_pin.sh) makes any hand edit to the
# vendored side fail loudly.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT
# --------------------------------------
# It proves the vendored files are byte-identical to a NAMED OS003 commit.
# It does NOT prove that commit is still OS003's HEAD -- a hosted CI runner
# cannot check, because CM051's GITHUB_TOKEN cannot read OS003 and no
# cross-repo token exists. Staleness is therefore an OPERATOR check, the same
# shape as scripts/verify_cut_freshness.sh: re-run this script before tagging.
# If it changes anything, the vendored copy was stale, and the cut's
# uncommitted-state gates will say so.
#
# USAGE
#   scripts/sync_rollforward_registry.sh [--check]
#     (no args)  copy from OS003 and rewrite cuts/REGISTRY_PIN
#     --check    copy nothing; report whether a sync WOULD change anything
#
#   OS003_DIR=/path/to/OS003-Ostler-Release   override the source checkout
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${OS003_DIR:-$HOME/Developer/OS003-Ostler-Release}"
MODE="${1:-sync}"

die() { printf '\033[0;31mERROR: %s\033[0m\n' "$1" >&2; exit 2; }

[ -d "$SRC/.git" ] || [ -f "$SRC/.git" ] || die "OS003 checkout not found at $SRC (set OS003_DIR)"

# The four files that must travel together. The runner sources lib_redact.sh
# and shells out to redact_selftest.sh, so taking the runner alone produces a
# copy that cannot start.
FILES=(
	"bin/rollforward_gate.sh"
	"bin/lib_redact.sh"
	"bin/redact_selftest.sh"
	"cuts/DEFECTS_ROLLFORWARD.md"
)

for f in "${FILES[@]}"; do
	[ -f "$SRC/$f" ] || die "source file missing: $SRC/$f"
done

# REFUSE TO PIN A DIRTY OR DETACHED SOURCE. A pin naming a commit whose tree
# does not match what was copied is worse than no pin: it reads as provenance
# while describing something else.
src_dirty="$(git -C "$SRC" status --porcelain -- "${FILES[@]}" 2>/dev/null | head -5)"
if [ -n "$src_dirty" ]; then
	printf '%s\n' "$src_dirty" >&2
	die "OS003 checkout has uncommitted changes to the files being vendored. Commit them first, or the pin names a commit that does not contain what you copied."
fi
src_sha="$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" || die "cannot read OS003 HEAD"
src_branch="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null)"

# REFUSE TO PIN A SOURCE CHECKOUT THAT IS NOT origin/main.
#
# WHY (measured 2026-08-11, Archie). Everything above pins `git rev-parse HEAD`
# of a LOCAL checkout, whatever that happens to be. Mine was sitting on
# 06dda1b0 while OS003 main was 0e4c3aff, so `--check` reported "STALE ...
# from main @ 06dda1b0" and a plain run would have written a REGISTRY_PIN
# naming 06dda1b0 -- three commits short, including the `--cut` pin binding.
# The pin test would then have passed, because it verifies the copy matches
# the pin, not that the pin is current. A stale sync is indistinguishable
# from a fresh one once it is written down.
#
# That is the same shape as the thing this script exists to prevent. The pin
# was honest about WHAT it copied and silent about WHETHER that was current,
# and silence reads as currency.
#
# Offline is a refusal, not a warning. A pin is provenance; writing one you
# could not verify is worse than not writing one. ALLOW_STALE_SOURCE=1 is the
# deliberate escape hatch, and it says so in the output so it cannot be used
# by accident.
if [ "${ALLOW_STALE_SOURCE:-0}" = "1" ]; then
	printf '\033[0;33mWARNING: ALLOW_STALE_SOURCE=1 -- pinning %s @ %s WITHOUT checking it is origin/main\033[0m\n' \
		"$src_branch" "${src_sha:0:8}" >&2
else
	[ "$src_branch" = "main" ] || die "OS003 checkout is on '$src_branch', not main. A pin taken off a feature branch names a commit that is not what CM051 should be vendoring. Check out main, or set ALLOW_STALE_SOURCE=1 deliberately."
	git -C "$SRC" fetch -q origin main 2>/dev/null \
		|| die "cannot fetch OS003 origin/main, so freshness is UNVERIFIABLE. Refusing to write a pin that claims provenance it could not check. Set ALLOW_STALE_SOURCE=1 to override deliberately."
	src_remote="$(git -C "$SRC" rev-parse origin/main 2>/dev/null)" || die "cannot read OS003 origin/main"
	if [ "$src_sha" != "$src_remote" ]; then
		behind="$(git -C "$SRC" rev-list --count "$src_sha".."$src_remote" 2>/dev/null || echo '?')"
		die "OS003 checkout is ${behind} commit(s) behind origin/main (local ${src_sha:0:8}, remote ${src_remote:0:8}). Pull first. Pinning now would record a stale commit AND pass the pin test, because that test checks the copy against the pin, not the pin against OS003."
	fi
fi

hash_of() { shasum -a 256 "$1" | awk '{print $1}'; }

changed=0
for f in "${FILES[@]}"; do
	dest="$HERE/$f"
	if [ ! -f "$dest" ] || ! cmp -s "$SRC/$f" "$dest"; then
		changed=$((changed + 1))
		echo "  DIFFERS  $f"
		[ "$MODE" = "--check" ] || { mkdir -p "$(dirname "$dest")"; cp "$SRC/$f" "$dest"; }
	else
		echo "  same     $f"
	fi
done

if [ "$MODE" = "--check" ]; then
	echo ""
	if [ "$changed" -gt 0 ]; then
		printf '\033[0;31mSTALE: %d file(s) differ from %s @ %s\033[0m\n' "$changed" "$src_branch" "${src_sha:0:8}"
		echo "Run scripts/sync_rollforward_registry.sh (no args) and commit the result."
		exit 1
	fi
	printf '\033[0;32mfresh against %s @ %s\033[0m\n' "$src_branch" "${src_sha:0:8}"
	exit 0
fi

chmod +x "$HERE/bin/rollforward_gate.sh" "$HERE/bin/redact_selftest.sh" 2>/dev/null

{
	echo "# cuts/REGISTRY_PIN -- generated by scripts/sync_rollforward_registry.sh."
	echo "# DO NOT HAND EDIT. It records which OS003 commit the vendored gate and"
	echo "# registry were taken from, and the hash of each file as taken."
	echo "#"
	echo "# tests/test_rollforward_registry_pin.sh recomputes these and goes RED on"
	echo "# any mismatch, so editing the vendored copy in CM051 instead of fixing it"
	echo "# in OS003 cannot pass quietly. That divergence is what left CM051 running"
	echo "# a rollforward gate 239 diff lines behind the original."
	echo "os003_repo	andygmassey/OS003-Ostler-Release"
	echo "os003_sha	$src_sha"
	echo "os003_branch	$src_branch"
	for f in "${FILES[@]}"; do
		echo "$f	$(hash_of "$HERE/$f")"
	done
} > "$HERE/cuts/REGISTRY_PIN"

echo ""
printf '\033[0;32mpinned to %s @ %s (%d file(s) updated)\033[0m\n' "$src_branch" "${src_sha:0:8}" "$changed"
echo "Wrote cuts/REGISTRY_PIN. Commit it with the vendored files, never separately."
