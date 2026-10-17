#!/usr/bin/env bash
# scripts/candidate_lib.sh -- shared helpers for the scripts/candidate_*.sh steps.
# Sourced, never run. See scripts/candidate.sh for the chain and its contract.
#
# EXIT CODES, THE SAME THREE THE REST OF scripts/ USES:
#   0 done, or already done (idempotent no-op)
#   1 REFUSED: an inconsistency, said in words with the next step
#   2 CANNOT-RUN: a dependency or input is missing, so nothing was measured
#
# NOTHING HERE GUESSES A SHA OR A DIGEST. A commit comes from the GitHub API, a
# digest from the registry, a pin from the tree. A value that cannot be read is
# a refusal, never a default.
#
# TEST SEAMS (the tests use these, nothing else does):
#   CANDIDATE_GH            command standing in for `gh` (called as: $CANDIDATE_GH api <path> [--jq ...])
#   CANDIDATE_REGISTRY_CMD  command standing in for the registry; called as: <cmd> <image> <tag>
#                           and must print the digest, or print nothing and exit non-zero.

cand_red()   { printf '%s\n' "$*" >&2; }
cand_refuse() { cand_red "REFUSED: $*"; exit 1; }
cand_cannot() { cand_red "CANNOT-RUN: $*"; exit 2; }
cand_say()   { printf '%s\n' "$*"; }

CAND_DRY=0
CAND_TMP="$(mktemp -d "${TMPDIR:-/tmp}/candidate.XXXXXX")"
trap 'rm -rf "$CAND_TMP"' EXIT

cand_gh() { ${CANDIDATE_GH:-gh} api "$@"; }

# cand_resolve_commit <owner/repo> <ref> -> 40-hex sha on stdout, or refuses.
# The API resolves branches, tags (annotated included) and short shas to the
# commit; a value it does not return as 40 hex is not a commit.
cand_resolve_commit() {
	local slug="$1" ref="$2" out
	out="$(cand_gh "repos/$slug/commits/$ref" --jq .sha 2>/dev/null)" || \
		cand_refuse "the GitHub API could not resolve '$ref' in $slug. Check the ref exists and is pushed; nothing was guessed."
	[[ "$out" =~ ^[0-9a-f]{40}$ ]] || \
		cand_refuse "the GitHub API answered '$out' for $slug@$ref, which is not a 40-character commit sha."
	printf '%s\n' "$out"
}

# cand_registry_digest <image> <tag> -> sha256:<64 hex>. Reads the registry's
# own Docker-Content-Digest header; never a release note, never a build log.
cand_registry_digest() {
	local image="$1" tag="$2" d tok
	if [ -n "${CANDIDATE_REGISTRY_CMD:-}" ]; then
		d="$($CANDIDATE_REGISTRY_CMD "$image" "$tag" 2>/dev/null)" || d=""
	else
		command -v curl >/dev/null 2>&1 || cand_cannot "curl is not installed, so the registry cannot be read."
		tok="$(curl -fsS -m 20 "https://ghcr.io/token?scope=repository:$image:pull" 2>/dev/null | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')"
		[ -n "$tok" ] || cand_cannot "no registry token for $image (network or access)."
		d="$(curl -fsSI -m 20 -H "Authorization: Bearer $tok" \
			-H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json' \
			"https://ghcr.io/v2/$image/manifests/$tag" 2>/dev/null | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | head -1)" || d=""
	fi
	[[ "$d" =~ ^sha256:[a-f0-9]{64}$ ]] || \
		cand_refuse "the registry has no manifest for $image:$tag (answered '$d'). Is the image published at that tag?"
	printf '%s\n' "$d"
}

# cand_apply <target> <new-content-file>: show the diff under --dry-run, else write.
cand_apply() {
	local target="$1" new="$2"
	if cmp -s "$target" "$new"; then return 0; fi
	if [ "$CAND_DRY" -eq 1 ]; then
		diff -u --label "a/${target#"$CAND_ROOT"/}" --label "b/${target#"$CAND_ROOT"/}" "$target" "$new" || true
	else
		cat "$new" > "$target"
	fi
}

# cand_count <fixed-string> <file> -> occurrences, as a number (grep -c, never -q).
cand_count() { grep -cF -- "$1" "$2" || true; }
