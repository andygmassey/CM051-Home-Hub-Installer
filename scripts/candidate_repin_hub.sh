#!/usr/bin/env bash
# scripts/candidate_repin_hub.sh --version 0.5.2 [--cut v1.0.NNN] [--dry-run]
# ============================================================================
# STEP (c), HUB HALF: re-pin the hub release, then name its commit in the cut.
#
# scripts/repin_hub_app.sh already moves the six daemon values in gui/Makefile
# and install.sh, downloading both tarballs and computing the digests from the
# bytes. This wrapper adds what it deliberately leaves alone:
#   - a refusal to move BACKWARDS or to re-pin the version already pinned
#   - cuts/<cut>/cut.env DAEMON_COMMIT, read from the GitHub API as the commit
#     the release tag hub-v<version> points at, in the hub app repo
#   - a true --dry-run: the delegate runs against a scratch copy of the two
#     files it edits, and the result is shown as a diff
#
# Refuses on: a version that is not newer than the pinned one, a release tag the
# API cannot resolve, a missing cut.env or one without exactly one DAEMON_COMMIT
# line. Idempotent: the version already pinned with the cut.env commit already
# matching is a no-op.
#
# Exit: 0 done / already done, 1 refused, 2 CANNOT-RUN.
# ============================================================================
set -uo pipefail
CAND_ROOT="${CANDIDATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/candidate_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/candidate_lib.sh"

VER=""; CUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--version) [ $# -ge 2 ] || cand_cannot "--version needs a value"; VER="$2"; shift 2 ;;
		--cut) [ $# -ge 2 ] || cand_cannot "--cut needs a value"; CUT="$2"; shift 2 ;;
		--dry-run) CAND_DRY=1; shift ;;
		-h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) cand_cannot "unknown argument: $1" ;;
	esac
done
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || cand_refuse "--version must be a bare version like 0.5.2 (got '$VER')"

MK="$CAND_ROOT/gui/Makefile"
[ -f "$MK" ] || cand_cannot "no gui/Makefile at $MK"
mkvar() { sed -n "s/^$1  *?*:*= *//p" "$MK" | head -1 | tr -d ' '; }
OLD="$(mkvar DAEMON_VERSION)"; HUB_REPO="$(mkvar HUB_APP_REPO)"
[ -n "$OLD" ] && [ -n "$HUB_REPO" ] || cand_cannot "could not read DAEMON_VERSION / HUB_APP_REPO from $MK"

top="$(printf '%s\n%s\n' "$OLD" "$VER" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
if [ "$VER" != "$OLD" ] && [ "$top" = "$OLD" ]; then
	cand_refuse "$VER is OLDER than the pinned $OLD. A re-pin moves forward; a rollback is a human decision."
fi

ENVF=""
if [ -n "$CUT" ]; then
	ENVF="$CAND_ROOT/cuts/$CUT/cut.env"
	[ -f "$ENVF" ] || cand_cannot "no $ENVF"
	[ "$(grep -c '^DAEMON_COMMIT=' "$ENVF" || true)" -eq 1 ] || cand_refuse "$ENVF must carry exactly one DAEMON_COMMIT= line."
fi
commit="$(cand_resolve_commit "$HUB_REPO" "hub-v$VER")" || exit $?
short="${commit:0:8}"
cand_say "[repin-hub] $OLD -> $VER  hub-v$VER = $HUB_REPO@$short"

# cut.env DAEMON_COMMIT
newenv=""
if [ -n "$CUT" ]; then
	newenv="$CAND_TMP/cut.env"
	sed "s/^DAEMON_COMMIT=.*/DAEMON_COMMIT=$short/" "$ENVF" > "$newenv"
fi

# the six-value move, in a scratch tree under --dry-run
if [ "$VER" != "$OLD" ]; then
	DELEGATE="$CAND_ROOT/scripts/repin_hub_app.sh"
	[ -f "$DELEGATE" ] || cand_cannot "no $DELEGATE"
	if [ "$CAND_DRY" -eq 1 ]; then
		S="$CAND_TMP/tree"; mkdir -p "$S/scripts" "$S/gui"
		cp "$DELEGATE" "$S/scripts/"; cp "$MK" "$S/gui/Makefile"; cp "$CAND_ROOT/install.sh" "$S/install.sh"
		bash "$S/scripts/repin_hub_app.sh" "$VER" >"$CAND_TMP/delegate.log" 2>&1 || { cat "$CAND_TMP/delegate.log" >&2; cand_refuse "repin_hub_app.sh refused $VER (above). Nothing was written."; }
		diff -u --label a/gui/Makefile --label b/gui/Makefile "$MK" "$S/gui/Makefile" || true
		diff -u --label a/install.sh --label b/install.sh "$CAND_ROOT/install.sh" "$S/install.sh" || true
	else
		bash "$DELEGATE" "$VER" || cand_refuse "repin_hub_app.sh refused $VER (above)."
	fi
fi
if [ -n "$newenv" ]; then
	if cmp -s "$ENVF" "$newenv"; then cand_say "[repin-hub] cut.env DAEMON_COMMIT already $short"; else cand_apply "$ENVF" "$newenv"; fi
fi
exit 0
