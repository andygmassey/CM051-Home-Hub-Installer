#!/usr/bin/env bash
# scripts/repin_wiki_images.sh -- re-pin the wiki images WITHOUT anyone typing a sha.
# ============================================================================
#
# WHY THIS EXISTS, MEASURED 2026-08-23.
#
# Re-pinning was two hand edits: paste two digests into install.sh, then append
# two rows to scripts/wiki_image_provenance.tsv naming the CM044 commit the
# images were built from. CM044's release_wiki_images.sh prints the digests. It
# does NOT print the commit, so the sha in the provenance row is typed.
#
# On 2026-08-23 the row was written as
#
#     7bfcc58c876c7c9d5f80e17b0f2f9a5a4fa72c1e
#
# produced by taking the real 12-character short sha and INVENTING the other 28.
# Forty hex characters, indistinguishable from a measured value, and it resolves
# to nothing: `git cat-file -t` answers "could not get object info". The real
# commit is 7bfcc58c876c1ef939cc90215488fbf7e6cdd5e4.
#
# 🔴 THE FIRST TWELVE CHARACTERS MATCH. wiki_image_provenance.tsv is read by
# scripts/wiki_hold_ack.tsv's contract on an 8+ character PREFIX, so a
# prefix-tolerant reader accepts the fabrication and reports the pin as
# provenanced. It was caught by chance, one command before the push.
#
# A VALUE THAT IS TYPED CAN BE INVENTED. A VALUE THAT IS RESOLVED CANNOT.
# So this script resolves the commit from a checkout, asserts the object exists,
# and writes both files itself. Nothing here is transcribed.
#
# USAGE
#   scripts/repin_wiki_images.sh --cm044 <dir> --ref <tag|sha> \
#                                --site sha256:... --compiler sha256:...
#   scripts/repin_wiki_images.sh --self-test
#
#   --check   resolve and validate, change nothing, report what WOULD change.
#
# EXIT: 0 done (or, with --check, nothing to object to). 1 refused. 2 CANNOT-RUN.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

red()   { printf '\033[0;31m%s\033[0m\n' "$1" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

CM044="" ; REF="" ; SITE="" ; COMPILER="" ; CHECK=0 ; SELFTEST=0
INSTALL_SH="${OSTLER_INSTALL_SH:-$HERE/install.sh}"
PROV="${OSTLER_WIKI_PROVENANCE:-$HERE/scripts/wiki_image_provenance.tsv}"

need_val() { [ "$2" -ge 2 ] || { red "error: $1 requires a value"; exit 2; }; }
while [ $# -gt 0 ]; do
	case "$1" in
		--cm044)    need_val --cm044 "$#";    CM044="$2"; shift 2 ;;
		--ref)      need_val --ref "$#";      REF="$2"; shift 2 ;;
		--site)     need_val --site "$#";     SITE="$2"; shift 2 ;;
		--compiler) need_val --compiler "$#"; COMPILER="$2"; shift 2 ;;
		--check)     CHECK=1; shift ;;
		--self-test) SELFTEST=1; shift ;;
		-h|--help)   sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) red "unknown argument: $1"; exit 2 ;;
	esac
done

DIGEST_RE='^sha256:[a-f0-9]{64}$'

# ---------------------------------------------------------------------------
# resolve_commit -- the whole point of the file.
#
# rev-parse ALONE IS NOT ENOUGH. `git rev-parse <40 hex>` echoes its argument
# back for ANY well-formed hex string, present or not, so it would have happily
# returned the fabricated sha. The object must be asserted to EXIST and to be a
# COMMIT, which is what cat-file -t does and rev-parse does not.
# ---------------------------------------------------------------------------
resolve_commit() {   # resolve_commit <repo-dir> <ref>  -> full sha on stdout
	local dir="$1" ref="$2" sha kind
	git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || {
		red "CANNOT-RUN: $dir is not a git checkout"; return 2; }
	sha="$(git -C "$dir" rev-parse --verify -q "${ref}^{commit}" 2>/dev/null)" || {
		red "REFUSED: '$ref' does not resolve to a commit in $dir"; return 1; }
	kind="$(git -C "$dir" cat-file -t "$sha" 2>/dev/null)" || {
		red "REFUSED: $sha does not exist as an object in $dir"; return 1; }
	[ "$kind" = "commit" ] || { red "REFUSED: $sha is a $kind, not a commit"; return 1; }
	[ "${#sha}" -eq 40 ] || { red "REFUSED: resolved sha is ${#sha} chars, not 40: $sha"; return 1; }
	printf '%s\n' "$sha"
}

repin() {
	local cm044="$1" ref="$2" site="$3" compiler="$4" check="$5"

	[ -n "$cm044" ] && [ -n "$ref" ] && [ -n "$site" ] && [ -n "$compiler" ] || {
		red "CANNOT-RUN: need --cm044, --ref, --site and --compiler"; return 2; }
	[ -f "$INSTALL_SH" ] || { red "CANNOT-RUN: no install.sh at $INSTALL_SH"; return 2; }
	[ -f "$PROV" ]       || { red "CANNOT-RUN: no provenance ledger at $PROV"; return 2; }

	local d
	for d in "$site" "$compiler"; do
		[[ "$d" =~ $DIGEST_RE ]] || { red "REFUSED: '$d' is not sha256:<64 hex>"; return 1; }
	done
	[ "$site" != "$compiler" ] || { red "REFUSED: site and compiler digests are identical"; return 1; }

	local sha rc
	sha="$(resolve_commit "$cm044" "$ref")"; rc=$?
	[ "$rc" -eq 0 ] || return "$rc"

	# The digests currently pinned, read from the file rather than passed in.
	local old_site old_comp
	old_site="$(grep -oE 'ostler-wiki-site@sha256:[a-f0-9]{64}' "$INSTALL_SH" | head -1 | sed 's/.*@//')"
	old_comp="$(grep -oE 'ostler-wiki-compiler@sha256:[a-f0-9]{64}' "$INSTALL_SH" | head -1 | sed 's/.*@//')"
	[ -n "$old_site" ] && [ -n "$old_comp" ] || {
		red "CANNOT-RUN: could not read the current wiki pins from $INSTALL_SH"; return 2; }

	if [ "$old_site" = "$site" ] && [ "$old_comp" = "$compiler" ]; then
		green "already pinned to these digests -- nothing to do"
		return 0
	fi

	# A count, not a boolean. If a digest appears twice, a blind replace would
	# silently change both and the second might not be the wiki pin at all.
	local n_site n_comp
	n_site="$(grep -c "$old_site" "$INSTALL_SH")"
	n_comp="$(grep -c "$old_comp" "$INSTALL_SH")"
	dim "install.sh   : site x$n_site  compiler x$n_comp"
	dim "CM044 $ref -> $sha"
	dim "site         : $old_site"
	dim "          -> : $site"
	dim "compiler     : $old_comp"
	dim "          -> : $compiler"

	if [ "$check" -eq 1 ]; then
		green "--check: would re-pin both images and append 2 provenance rows"
		return 0
	fi

	python3 - "$INSTALL_SH" "$old_site" "$site" "$old_comp" "$compiler" <<'PY'
import sys
p, os_, ns, oc, nc = sys.argv[1:6]
s = open(p, encoding='utf-8').read()
a, b = s.count(os_), s.count(oc)
assert a >= 1 and b >= 1, f"old digests not found: site={a} compiler={b}"
s = s.replace(os_, ns).replace(oc, nc)
assert s.count(ns) == a and s.count(nc) == b
assert os_ not in s and oc not in s
open(p, 'w', encoding='utf-8').write(s)
print(f"install.sh: replaced site x{a}, compiler x{b}")
PY
	rc=$?
	[ "$rc" -eq 0 ] || { red "REFUSED: install.sh rewrite failed (rc=$rc)"; return 1; }

	printf 'wiki-compiler\t%s\t%s\n' "$compiler" "$sha" >> "$PROV"
	printf 'wiki-site\t%s\t%s\n'     "$site"     "$sha" >> "$PROV"

	green "re-pinned, and the provenance sha was RESOLVED, not typed: $sha"
	dim "Now run: tests/test_wiki_image_namespace_matches_ci.sh"
	dim "         tests/test_pinned_images_are_pullable.sh"
	dim "         CM044_DIR=$cm044 tests/test_pinned_wiki_image_has_design_system.sh"
	return 0
}

# ---------------------------------------------------------------------------
# Self-test. The case that matters is the LAST one: the exact fabricated sha
# that reached a commit on 2026-08-23 must be REFUSED here.
# ---------------------------------------------------------------------------
if [ "$SELFTEST" -eq 1 ]; then
	TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
	fail=0
	note() { printf '  %s\n' "$*"; }

	git init -q "$TMP/src" && git -C "$TMP/src" -c user.email=t@t -c user.name=t \
		commit -q --allow-empty -m "fixture"
	REAL="$(git -C "$TMP/src" rev-parse HEAD)"
	FAKE="${REAL:0:12}$(printf '0%.0s' $(seq 1 28))"

	D1='sha256:'"$(printf 'a%.0s' $(seq 1 64))"
	D2='sha256:'"$(printf 'b%.0s' $(seq 1 64))"
	D3='sha256:'"$(printf 'c%.0s' $(seq 1 64))"
	D4='sha256:'"$(printf 'd%.0s' $(seq 1 64))"

	mkfix() {
		printf 'image: ghcr.io/x/ostler-wiki-site@%s\nimage: ghcr.io/x/ostler-wiki-compiler@%s\n' "$D1" "$D2" > "$TMP/install.sh"
		: > "$TMP/prov.tsv"
	}
	run() {  # run <want_rc> <label> -- rest are repin args
		local want="$1" label="$2"; shift 2
		mkfix
		INSTALL_SH="$TMP/install.sh" PROV="$TMP/prov.tsv" repin "$@" >/dev/null 2>&1
		local rc=$?
		if [ "$rc" -eq "$want" ]; then note "PASS  rc=$rc  $label"; else note "FAIL  rc=$rc want=$want  $label"; fail=1; fi
	}

	run 0 "positive control: a real ref re-pins"              "$TMP/src" "$REAL" "$D3" "$D4" 0
	run 1 "🔴 THE FABRICATED SHA IS REFUSED"                   "$TMP/src" "$FAKE" "$D3" "$D4" 0
	run 1 "a ref that names nothing is refused"                "$TMP/src" "v9.9.99-nope" "$D3" "$D4" 0
	run 1 "a malformed digest is refused"                      "$TMP/src" "$REAL" "sha256:zzz" "$D4" 0
	run 1 "two identical digests are refused"                  "$TMP/src" "$REAL" "$D3" "$D3" 0
	run 2 "a non-git --cm044 is CANNOT-RUN, not a refusal"     "$TMP" "$REAL" "$D3" "$D4" 0
	run 2 "missing arguments are CANNOT-RUN"                   "" "" "" "" 0

	mkfix
	INSTALL_SH="$TMP/install.sh" PROV="$TMP/prov.tsv" repin "$TMP/src" "$REAL" "$D1" "$D2" 0 >/dev/null 2>&1
	if [ $? -eq 0 ] && [ ! -s "$TMP/prov.tsv" ]; then
		note "PASS  re-pinning to the SAME digests is a no-op and writes no row"
	else
		note "FAIL  a no-op re-pin still wrote a provenance row"; fail=1
	fi

	mkfix
	INSTALL_SH="$TMP/install.sh" PROV="$TMP/prov.tsv" repin "$TMP/src" "$REAL" "$D3" "$D4" 0 >/dev/null 2>&1
	if grep -q "$REAL" "$TMP/prov.tsv" && [ "$(grep -c . "$TMP/prov.tsv")" -eq 2 ] \
	   && grep -q "$D3" "$TMP/install.sh" && ! grep -q "$D1" "$TMP/install.sh"; then
		note "PASS  the written rows carry the RESOLVED sha, and install.sh moved"
	else
		note "FAIL  the write did not land as specified"; fail=1
	fi

	echo
	if [ "$fail" -eq 0 ]; then
		echo "RESULT: PASSED -- a typed sha cannot get past this, and a real one still can"
		exit 0
	fi
	echo "RESULT: FAILED"
	exit 1
fi

repin "$CM044" "$REF" "$SITE" "$COMPILER" "$CHECK"
