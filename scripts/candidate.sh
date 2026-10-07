#!/usr/bin/env bash
# scripts/candidate.sh <version> [options]
# ============================================================================
# CHAIN THE CANDIDATE STEPS THAT NEED NO JUDGEMENT.
#
# After feature PRs merge in the source repos, a candidate DMG needs the same
# bookkeeping every time. Each step is its own idempotent script that refuses in
# words on any inconsistency and reads every sha and digest from the GitHub API
# or the registry. This runs the ones you name, in this order:
#
#   (a) --vendor TREE=REF         scripts/candidate_vendor.sh      graft into vendor/
#   (c) --hub-version V           scripts/candidate_repin_hub.sh   daemon pin + cut.env DAEMON_COMMIT
#   (c) --wiki-tag T              scripts/candidate_repin_wiki.sh  both wiki images + provenance rows
#   (d) --manifest-rows FILE      scripts/candidate_manifest_row.sh  one entry per line of FILE
#       --pin                     scripts/candidate_pin.sh         cut.env CM051= from git
#   (e) --freeze [--push] [--dispatch]   scripts/candidate_freeze.sh  cut/<version> branch
#
# --manifest-rows FILE: tab separated, one entry per line:
#     id <TAB> title <TAB> source-pr <TAB> grep|absent <TAB> install.sh ERE
#
# --dry-run prints every intended change. The file-editing steps run FOR REAL in
# a scratch copy of the tracked tree and the whole result is shown as one diff,
# so steps that touch the same file compose exactly as a real run would. The
# vendor step prints its plan; the pin and freeze steps report. Nothing in the
# working tree, git, or GitHub is changed.
#
# A real run is TWO PHASES, because the pin names a commit and that commit
# carries the steps before it:
#   1. scripts/candidate.sh v1.0.108 --hub-version ... --wiki-tag ... --manifest-rows F
#      review the diff, commit it, open the PR
#   2. scripts/candidate.sh v1.0.108 --pin     (commit the pin)
#      scripts/candidate.sh v1.0.108 --freeze --push [--dispatch]
#
# THE OS003 HALF (BOM rows, digest re-keys, re-cites) lives in OS003 bin/ and runs
# AFTER this PR merges, because its rows cite the merged CM051 commit:
#   bin/candidate.sh <version> --cm051-dir <this checkout> --cm051-ref <merged sha> ...
#
# What stays a person's: the cut_markers.manifest rows and manifest patterns that
# say what a fix looks like; capability rows in OS003; reading the source diff;
# deciding what the candidate is for; Andy's walk.
#
# Exit: 0 every step done or already done, 1 a step refused, 2 CANNOT-RUN.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$HERE/scripts"
red() { printf '%s\n' "$*" >&2; }

VER=""; DRY=0; HUB=""; WIKI=""; ROWS=""; PIN=0; FREEZE=0; PUSH=0; DISPATCH=0; VENDORS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--vendor) [ $# -ge 2 ] || { red "CANNOT-RUN: --vendor needs TREE=REF"; exit 2; }; VENDORS+=("$2"); shift 2 ;;
		--hub-version) HUB="${2:-}"; shift 2 ;;
		--wiki-tag) WIKI="${2:-}"; shift 2 ;;
		--manifest-rows) ROWS="${2:-}"; shift 2 ;;
		--pin) PIN=1; shift ;;
		--freeze) FREEZE=1; shift ;;
		--push) PUSH=1; shift ;;
		--dispatch) DISPATCH=1; shift ;;
		--dry-run) DRY=1; shift ;;
		-h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) red "CANNOT-RUN: unknown argument: $1"; exit 2 ;;
		*) VER="$1"; shift ;;
	esac
done
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { red "CANNOT-RUN: usage: candidate.sh <version like v1.0.108> [options]"; exit 2; }
[ -z "$ROWS" ] || [ -f "$ROWS" ] || { red "CANNOT-RUN: no manifest rows file at $ROWS"; exit 2; }
if [ "$PIN" -eq 1 ] || [ "$FREEZE" -eq 1 ]; then
	if [ -n "$HUB$WIKI$ROWS" ] || [ "${#VENDORS[@]}" -gt 0 ]; then
		red "REFUSED: --pin/--freeze are phase two and need a committed tree; run them in a separate invocation from the content steps."; exit 1; fi
fi
[ "$DISPATCH" -eq 0 ] || [ "$FREEZE" -eq 1 ] || { red "REFUSED: --dispatch is part of --freeze."; exit 1; }

worst=0
note() { [ "$1" -le "$worst" ] || worst="$1"; }
run() {  # run <root> <label> <script> args...
	local root="$1" label="$2" script="$3"; shift 3
	printf '\n=== %s ===\n' "$label"
	CANDIDATE_ROOT="$root" bash "$S/$script" "$@"; local rc=$?
	if [ "$rc" -ne 0 ]; then red "--- $label stopped with exit $rc; later steps NOT run."; exit "$rc"; fi
}
content_steps() {  # content_steps <root> <vendor-flag>
	local root="$1" vflag="$2" v row id title pr kind pat
	for v in ${VENDORS[@]+"${VENDORS[@]}"}; do
		case "$v" in *=*) ;; *) red "REFUSED: --vendor wants TREE=REF (got '$v')"; exit 1 ;; esac
		run "$root" "vendor ${v%%=*}" candidate_vendor.sh "${v%%=*}" --to "${v#*=}" $vflag
	done
	if [ -n "$HUB" ]; then run "$root" "hub $HUB" candidate_repin_hub.sh --version "$HUB" --cut "$VER"; fi
	if [ -n "$WIKI" ]; then run "$root" "wiki $WIKI" candidate_repin_wiki.sh --tag "$WIKI"; fi
	if [ -n "$ROWS" ]; then
		while IFS=$'\t' read -r id title pr kind pat || [ -n "${id:-}" ]; do
			case "$id" in ''|'#'*) continue ;; esac
			case "$kind" in grep) kind=--grep-installer ;; absent) kind=--absent-installer ;; *) red "REFUSED: rows file: kind must be grep or absent (got '$kind')"; exit 1 ;; esac
			run "$root" "manifest row $id" candidate_manifest_row.sh "$VER" --id "$id" --title "$title" --source-pr "$pr" "$kind" "$pat"
		done < "$ROWS"
	fi
}

if [ "$DRY" -eq 1 ]; then
	if [ -n "$HUB$WIKI$ROWS" ] || [ "${#VENDORS[@]}" -gt 0 ]; then
		SCR="$(mktemp -d "${TMPDIR:-/tmp}/candidate-scratch.XXXXXX")"; trap 'rm -rf "$SCR"' EXIT
		( cd "$HERE" && git ls-files -z | tar -cf - --null -T - | tar -xf - -C "$SCR" ) 2>/dev/null || { red "CANNOT-RUN: could not stage a scratch copy"; exit 2; }
		# vendor steps only PLAN under --dry-run (they need local source checkouts); the rest run for real in the scratch tree
		( content_steps "$SCR" "--dry-run" )
		rc=$?; [ "$rc" -eq 0 ] || exit "$rc"
		printf '\n=== DRY RUN: the whole change set, exactly as a real run would write it ===\n'
		( cd "$HERE" && git ls-files | while IFS= read -r f; do cmp -s "$f" "$SCR/$f" || diff -u --label "a/$f" --label "b/$f" "$f" "$SCR/$f"; done ) || true
	fi
	[ "$PIN" -eq 0 ] || { printf '\n=== pin ===\n'; CANDIDATE_ROOT="$HERE" bash "$S/candidate_pin.sh" "$VER" --dry-run || exit $?; }
	[ "$FREEZE" -eq 0 ] || { printf '\n=== freeze ===\n'; CANDIDATE_ROOT="$HERE" bash "$S/candidate_freeze.sh" "$VER" --dry-run || exit $?; }
	exit 0
fi

content_steps "$HERE" ""
[ "$PIN" -eq 0 ] || run "$HERE" "pin" candidate_pin.sh "$VER"
if [ "$FREEZE" -eq 1 ]; then
	extra=(); [ "$PUSH" -eq 0 ] || extra+=(--push); [ "$DISPATCH" -eq 0 ] || extra+=(--dispatch)
	run "$HERE" "freeze" candidate_freeze.sh "$VER" ${extra[@]+"${extra[@]}"}
fi
exit 0
