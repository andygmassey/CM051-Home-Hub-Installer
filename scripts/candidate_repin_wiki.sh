#!/usr/bin/env bash
# scripts/candidate_repin_wiki.sh --tag 0.1.43 [--dry-run]
# ============================================================================
# STEP (c), WIKI HALF: re-pin both wiki images from the registry.
#
# Reads, never types:
#   - the site and compiler digests from ghcr.io (the Docker-Content-Digest of
#     <image>:<tag>)
#   - the CM044 commit the tag points at, from the GitHub API
# Writes the same two files scripts/repin_wiki_images.sh writes, in the same
# shape: the two image lines in install.sh and two rows appended to
# scripts/wiki_image_provenance.tsv. That older script needs a CM044 checkout
# and four typed arguments; this one needs the tag.
#
# Refuses on: an image with no manifest at the tag, identical site and compiler
# digests, a pin that is not currently readable, a digest present more than once
# in install.sh, a provenance row that already binds the digest to ANOTHER
# commit, or a half-applied state (one image already on the target, one not).
# Idempotent: a tree already on the target digests with both rows present is a
# no-op.
#
# It does NOT write the scripts/cut_markers.manifest rows that name what the new
# images contain. Those are the fix's own fingerprints (a pattern and a reason)
# and only a person who read the CM044 diff can state them.
#
# Exit: 0 done / already done, 1 refused, 2 CANNOT-RUN.
# ============================================================================
set -uo pipefail
CAND_ROOT="${CANDIDATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/candidate_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/candidate_lib.sh"

TAG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--tag) [ $# -ge 2 ] || cand_cannot "--tag needs a value"; TAG="$2"; shift 2 ;;
		--dry-run) CAND_DRY=1; shift ;;
		-h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) cand_cannot "unknown argument: $1" ;;
	esac
done
[[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || cand_refuse "--tag must be a bare version like 0.1.43 (got '$TAG')"

INSTALL_SH="${OSTLER_INSTALL_SH:-$CAND_ROOT/install.sh}"
PROV="${OSTLER_WIKI_PROVENANCE:-$CAND_ROOT/scripts/wiki_image_provenance.tsv}"
ORG="${CANDIDATE_WIKI_ORG:-creativemachines-ai}"
CM044_SLUG="${CANDIDATE_CM044_REPO:-andygmassey/CM044-PWG-Personal-Wiki}"
[ -f "$INSTALL_SH" ] || cand_cannot "no install.sh at $INSTALL_SH"
[ -f "$PROV" ] || cand_cannot "no provenance ledger at $PROV"

site="$(cand_registry_digest "$ORG/ostler-wiki-site" "$TAG")" || exit $?
comp="$(cand_registry_digest "$ORG/ostler-wiki-compiler" "$TAG")" || exit $?
[ "$site" != "$comp" ] || cand_refuse "site and compiler resolve to the same digest ($site); one of them is not the image it claims to be."
sha="$(cand_resolve_commit "$CM044_SLUG" "v$TAG")" || exit $?

old_site="$(grep -oE 'ostler-wiki-site@sha256:[a-f0-9]{64}' "$INSTALL_SH" | head -1 | sed 's/.*@//')"
old_comp="$(grep -oE 'ostler-wiki-compiler@sha256:[a-f0-9]{64}' "$INSTALL_SH" | head -1 | sed 's/.*@//')"
[ -n "$old_site" ] && [ -n "$old_comp" ] || cand_cannot "could not read the current wiki pins from $INSTALL_SH"

cand_say "[repin-wiki] tag $TAG  CM044 $sha"
cand_say "[repin-wiki] site     $old_site -> $site"
cand_say "[repin-wiki] compiler $old_comp -> $comp"

have_row() { grep -cxF "$(printf '%s\t%s\t%s' "$1" "$2" "$3")" "$PROV" || true; }
other_row() { awk -F'\t' -v i="$1" -v d="$2" -v s="$3" '$1==i && $2==d && $3!=s {n++} END{print n+0}' "$PROV"; }
for pair in "wiki-compiler $comp" "wiki-site $site"; do
	set -- $pair
	[ "$(other_row "$1" "$2" "$sha")" -eq 0 ] || \
		cand_refuse "$PROV already binds $1 $2 to a DIFFERENT CM044 commit than $sha. Resolve that by hand; a digest has one source."
done

pinned_site=0; pinned_comp=0
[ "$old_site" = "$site" ] && pinned_site=1
[ "$old_comp" = "$comp" ] && pinned_comp=1
if [ $((pinned_site + pinned_comp)) -eq 1 ]; then
	cand_refuse "half-applied: exactly one wiki image is already on $TAG in install.sh. Repair the tree so both or neither are, then re-run."
fi

new="$CAND_TMP/install.sh"; cp "$INSTALL_SH" "$new"
if [ "$pinned_site" -eq 0 ]; then
	[ "$(cand_count "ostler-wiki-site@$old_site" "$INSTALL_SH")" -eq 1 ] || cand_refuse "the outgoing site digest appears other than once in install.sh; a blind replace could change a non-pin line."
	[ "$(cand_count "ostler-wiki-compiler@$old_comp" "$INSTALL_SH")" -eq 1 ] || cand_refuse "the outgoing compiler digest appears other than once in install.sh."
	sed -i.bak "s#ostler-wiki-site@$old_site#ostler-wiki-site@$site#; s#ostler-wiki-compiler@$old_comp#ostler-wiki-compiler@$comp#" "$new" && rm -f "$new.bak"
fi

newprov="$CAND_TMP/prov.tsv"; cp "$PROV" "$newprov"
[ -z "$(tail -c1 "$newprov")" ] || printf '\n' >> "$newprov"
[ "$(have_row wiki-compiler "$comp" "$sha")" -ge 1 ] || printf 'wiki-compiler\t%s\t%s\n' "$comp" "$sha" >> "$newprov"
[ "$(have_row wiki-site "$site" "$sha")" -ge 1 ] || printf 'wiki-site\t%s\t%s\n' "$site" "$sha" >> "$newprov"

if cmp -s "$INSTALL_SH" "$new" && cmp -s "$PROV" "$newprov"; then
	cand_say "[repin-wiki] already on $TAG with both provenance rows -- nothing to do"
	exit 0
fi
cand_apply "$INSTALL_SH" "$new"
cand_apply "$PROV" "$newprov"
if [ "$CAND_DRY" -eq 0 ]; then
	[ "$(cand_count "ostler-wiki-site@$site" "$INSTALL_SH")" -eq 1 ] && [ "$(cand_count "ostler-wiki-compiler@$comp" "$INSTALL_SH")" -eq 1 ] \
		|| cand_refuse "read-back failed: install.sh does not carry exactly one of each new digest."
	cand_say "[repin-wiki] written and read back"
fi
exit 0
