#!/usr/bin/env bash
# scripts/candidate_pin.sh <version> [--dry-run]
# ============================================================================
# Point cuts/<version>/cut.env CM051= at the commit that carries install.sh.
#
# The pin is checked by BLOB (verify_cut_pin_is_current.sh), so the right value
# is the commit that last changed install.sh: its install.sh is the one that
# ships. The value is read from git, never typed, and written at the width the
# file already uses.
#
# Refuses on: no cut.env or not exactly one CM051= line; an install.sh with
# uncommitted changes in a REAL run (the pin would name a blob that does not
# exist yet); a pin whose install.sh blob differs from HEAD's after the write.
# Under --dry-run an uncommitted install.sh is reported, not refused: the pin
# will name the commit you are about to make, which this cannot know.
# Idempotent.
#
# Exit: 0 done / already done, 1 refused, 2 CANNOT-RUN.
# ============================================================================
set -uo pipefail
CAND_ROOT="${CANDIDATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/candidate_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/candidate_lib.sh"
VER=""
for a in "$@"; do case "$a" in --dry-run) CAND_DRY=1 ;; -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; -*) cand_cannot "unknown argument: $a" ;; *) VER="$a" ;; esac; done
[ -n "$VER" ] || cand_cannot "usage: candidate_pin.sh <version> [--dry-run]"
ENVF="$CAND_ROOT/cuts/$VER/cut.env"
[ -f "$ENVF" ] || cand_cannot "no $ENVF"
[ "$(grep -c '^CM051=' "$ENVF" || true)" -eq 1 ] || cand_refuse "$ENVF must carry exactly one CM051= line."
git -C "$CAND_ROOT" rev-parse --git-dir >/dev/null 2>&1 || cand_cannot "$CAND_ROOT is not a git checkout"

old="$(sed -n 's/^CM051=//p' "$ENVF")"
width=${#old}; [ "$width" -ge 7 ] || cand_refuse "existing CM051= value '$old' is not a sha prefix."
dirty="$(git -C "$CAND_ROOT" status --porcelain -- install.sh)"
if [ -n "$dirty" ]; then
	[ "$CAND_DRY" -eq 1 ] || cand_refuse "install.sh has uncommitted changes. Commit them first; the pin names the commit that carries the shipped blob."
	cand_say "[pin] install.sh is uncommitted; CM051= would become the first $width characters of the commit you make for it ($old now)"
	exit 0
fi
sha="$(git -C "$CAND_ROOT" log -1 --format=%H -- install.sh)"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || cand_refuse "git could not name the commit that last changed install.sh."
[ "$(git -C "$CAND_ROOT" rev-parse "$sha:install.sh")" = "$(git -C "$CAND_ROOT" rev-parse HEAD:install.sh)" ] || cand_refuse "install.sh at $sha differs from HEAD."
new="${sha:0:$width}"
cand_say "[pin] CM051 $old -> $new (last commit to change install.sh)"
n="$CAND_TMP/cut.env"; sed "s/^CM051=.*/CM051=$new/" "$ENVF" > "$n"
cmp -s "$ENVF" "$n" && { cand_say "[pin] already pinned"; exit 0; }
cand_apply "$ENVF" "$n"
exit 0
