#!/usr/bin/env bash
# scripts/candidate_freeze.sh <version> [--push] [--dispatch] [--dry-run]
# ============================================================================
# STEP (e): freeze the cut branch, and optionally push it and dispatch cut.yml.
#
# The default is a REPORT: what branch cut/<version> would be, at which commit,
# and the exact dispatch command. --push creates the branch locally and pushes
# it; --dispatch (which needs --push) runs `gh workflow run cut.yml --ref
# cut/<version>`. This script never creates or pushes a tag, and cut.yml's
# workflow_dispatch builds a candidate only; nothing here can publish.
#
# Refuses on: a dirty tree; a version with no cuts/<v>/cut.env or
# cut-manifests/<v>.yaml; a cut.env whose CM051= names a commit whose install.sh
# blob differs from HEAD's (run candidate_pin.sh); a version whose tag already
# exists on origin; a cut/<version> branch that exists at a DIFFERENT commit
# locally or on origin (a frozen branch is never moved); --dispatch without
# --push.
# Idempotent: the branch already at HEAD is reported, not recreated.
#
# Exit: 0 done / already done, 1 refused, 2 CANNOT-RUN.
# ============================================================================
set -uo pipefail
CAND_ROOT="${CANDIDATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/candidate_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/candidate_lib.sh"
VER=""; PUSH=0; DISPATCH=0
for a in "$@"; do case "$a" in --dry-run) CAND_DRY=1 ;; --push) PUSH=1 ;; --dispatch) DISPATCH=1 ;; -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; -*) cand_cannot "unknown argument: $a" ;; *) VER="$a" ;; esac; done
[ -n "$VER" ] || cand_cannot "usage: candidate_freeze.sh <version> [--push] [--dispatch] [--dry-run]"
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || cand_refuse "version must look like v1.0.108 (got '$VER')"
[ "$DISPATCH" -eq 0 ] || [ "$PUSH" -eq 1 ] || cand_refuse "--dispatch needs --push: the workflow runs the pushed branch, not this checkout."
G=(git -C "$CAND_ROOT")
"${G[@]}" rev-parse --git-dir >/dev/null 2>&1 || cand_cannot "$CAND_ROOT is not a git checkout"
[ -z "$("${G[@]}" status --porcelain)" ] || cand_refuse "the working tree is dirty. Commit or stash first; a frozen branch is a commit, not a working tree."
[ -f "$CAND_ROOT/cuts/$VER/cut.env" ] || cand_refuse "no cuts/$VER/cut.env (scripts/new_cut.sh opens the cut)."
[ -f "$CAND_ROOT/cut-manifests/$VER.yaml" ] || cand_refuse "no cut-manifests/$VER.yaml."
pin="$(sed -n 's/^CM051=//p' "$CAND_ROOT/cuts/$VER/cut.env")"
[ -n "$pin" ] || cand_refuse "cut.env has no CM051= value."
pinsha="$("${G[@]}" rev-parse --verify -q "$pin^{commit}")" || cand_refuse "CM051=$pin does not resolve to a commit here."
[ "$("${G[@]}" rev-parse "$pinsha:install.sh")" = "$("${G[@]}" rev-parse HEAD:install.sh)" ] || \
	cand_refuse "CM051=$pin names an install.sh that is NOT the one at HEAD. Run scripts/candidate_pin.sh $VER."
head="$("${G[@]}" rev-parse HEAD)"; br="cut/$VER"
if "${G[@]}" ls-remote --exit-code --tags origin "refs/tags/$VER" >/dev/null 2>&1; then cand_refuse "tag $VER already exists on origin; a version gets one tag."; fi
loc="$("${G[@]}" rev-parse --verify -q "refs/heads/$br" || true)"
[ -z "$loc" ] || [ "$loc" = "$head" ] || cand_refuse "local $br is at ${loc:0:8}, HEAD is ${head:0:8}. A frozen branch is not moved; cut a new version."
rem="$("${G[@]}" ls-remote origin "refs/heads/$br" 2>/dev/null | cut -f1)"
[ -z "$rem" ] || [ "$rem" = "$head" ] || cand_refuse "origin $br is at ${rem:0:8}, HEAD is ${head:0:8}. A frozen branch is not moved; cut a new version."

cand_say "[freeze] $br at ${head:0:8} (CM051 pin ${pinsha:0:8}, install.sh blob matches)"
cand_say "[freeze] dispatch: gh workflow run cut.yml --ref $br"
if [ "$CAND_DRY" -eq 1 ] || [ "$PUSH" -eq 0 ]; then
	cand_say "[freeze] report only; add --push (and --dispatch) to act. No tag is ever pushed by this script."
	exit 0
fi
[ -n "$loc" ] || "${G[@]}" branch "$br" "$head" || cand_cannot "could not create $br"
[ -n "$rem" ] || "${G[@]}" push -u origin "$br" || cand_cannot "push of $br failed"
if [ "$DISPATCH" -eq 1 ]; then gh workflow run cut.yml --ref "$br" || cand_cannot "dispatch failed"; fi
exit 0
