#!/usr/bin/env bash
# sync_vendor.sh <tree> [--to-sha <sha>] [--regen-patch]
# =====================================================
#
# The one command to "pull a fix into the vendor".
#
# Default behaviour (graft a source fix):
#   1. materialise source_repo @ <target sha> (default: source HEAD),
#      restricted to the vendored file-set,
#   2. re-apply the tree's existing divergence patch (the legitimate
#      vendor-side grafts -- en-dash house style, extra imports, vendor-only
#      files like subscription_gate.py),
#   3. copy the result over vendor/<tree>,
#   4. regenerate the divergence patch from (fresh source@sha -> new vendor)
#      so the gate stays green,
#   5. bump pinned_sha in VENDOR_MANIFEST.toml to the target sha.
#
# --regen-patch  : do NOT touch the vendored tree; just (re)build the
#                  divergence patch capturing how the CURRENT vendor differs
#                  from source@pinned_sha, and write it under
#                  vendor/divergences/. Used to bootstrap the patches for the
#                  current state of the repo. Also bumps nothing.
#
# British English; " -- " not em-dashes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_vendor_lib.sh
. "$SCRIPT_DIR/_vendor_lib.sh"

TREE="${1:-}"
if [ -z "$TREE" ]; then
    echo "usage: sync_vendor.sh <tree> [--to-sha <sha>] [--regen-patch]" >&2
    echo "trees:" >&2
    vlib_tree_names | sed 's/^/  /' >&2
    exit 2
fi
shift || true

TO_SHA=""
REGEN_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --to-sha) TO_SHA="$2"; shift 2 ;;
        --regen-patch) REGEN_ONLY=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Validate tree exists in manifest.
if ! vlib_tree_names | grep -qx "$TREE"; then
    echo "no such tree in manifest: $TREE" >&2
    exit 2
fi

vendor_path="$(vlib_field "$TREE" vendor_path)"
abs_vendor="$VLIB_REPO_ROOT/$vendor_path"
patch_rel="$(vlib_field "$TREE" divergence_patch)"
[ -z "$patch_rel" ] && patch_rel="vendor/divergences/${TREE//\//_}.patch"
abs_patch="$VLIB_REPO_ROOT/$patch_rel"

repo="$(resolve_source_repo "$TREE")"
if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    echo "source repo for $TREE not found: $repo" >&2
    exit 2
fi

# Generate a (source@sha -> vendor) divergence patch into <out>, given a
# materialised source dir <srcdir> and the live vendored tree. Captures ONLY
# the content drift of files present in BOTH trees (house-style edits, extra
# imports). Source-only and vendor-only files are out of scope. Empty diff ->
# remove the patch file and clear the manifest reference (no divergence).
gen_patch() {
    local srcdir="$1" out="$2"
    local d
    d="$(mktemp)"
    if vlib_shared_diff "$srcdir" "$abs_vendor" "$d"; then
        # identical -> no patch needed
        rm -f "$d"
        [ -f "$out" ] && rm -f "$out" && echo "  no divergence: removed stale patch ${out#"$VLIB_REPO_ROOT"/}"
        return 1
    fi
    if [ -s "$d" ]; then
        mkdir -p "$(dirname "$out")"
        mv "$d" "$out"
        echo "  wrote divergence patch: ${out#"$VLIB_REPO_ROOT"/} ($(grep -cE '^--- ' "$out") shared file(s) diverge)"
        return 0
    fi
    rm -f "$d"
    return 1
}

if [ "$REGEN_ONLY" = "1" ]; then
    # Bootstrap / refresh the patch for the CURRENT vendor vs source@pinned_sha.
    tmp="$(mktemp -d)"
    rc=0
    vlib_materialise "$TREE" "$tmp" || rc=$?
    if [ "$rc" != "0" ]; then
        echo "cannot regen patch for $TREE: materialise failed (rc=$rc)" >&2
        rm -rf "$tmp"
        exit 1
    fi
    if gen_patch "$tmp" "$abs_patch"; then
        ensure_manifest_patch_ref "$TREE" "$patch_rel"
    else
        clear_manifest_patch_ref "$TREE"
    fi
    rm -rf "$tmp"
    echo "regen-patch done for $TREE"
    exit 0
fi

# Full sync. Target sha defaults to source HEAD.
if [ -z "$TO_SHA" ]; then
    if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        TO_SHA="$(git -C "$repo" rev-parse HEAD)"
    else
        TO_SHA="WORKING_TREE"
    fi
fi

echo "syncing $TREE from $repo @ ${TO_SHA:0:12} ..."

# Materialise the NEW source.
tmp="$(mktemp -d)"
# Temporarily pin to the target sha for the materialise helper.
_orig_pin="$(vlib_field "$TREE" pinned_sha)"
set_manifest_field "$TREE" pinned_sha "$TO_SHA"
rc=0
vlib_materialise "$TREE" "$tmp" || rc=$?
if [ "$rc" != "0" ]; then
    echo "materialise of new source failed (rc=$rc); reverting manifest" >&2
    set_manifest_field "$TREE" pinned_sha "$_orig_pin"
    rm -rf "$tmp"
    exit 1
fi

# Re-apply the existing divergence patch onto the fresh source so the
# vendor-side grafts survive the sync.
if [ -f "$abs_patch" ]; then
    if ! ( cd "$tmp" && git apply --whitespace=nowarn "$abs_patch" 2>/dev/null ); then
        echo "WARN: existing divergence patch did not apply onto the new source." >&2
        echo "      The fix likely overlaps the divergence. Resolve by hand, then re-run with --regen-patch." >&2
        echo "      Leaving vendor/ untouched. New source is staged at: $tmp" >&2
        set_manifest_field "$TREE" pinned_sha "$_orig_pin"
        exit 1
    fi
fi

# Preserve vendor-only files across the swap (v1018-D024).
#
# The swap below is a wholesale replace: rm -rf the vendored tree, untar the
# upstream export over it. That is right for a mirror -- but it means any file
# with no upstream counterpart is deleted, silently, every single sync. The
# divergence patch is not a backstop: --regen-patch strips vendor-only new-file
# hunks, so the protection disappears the next time the patch is regenerated.
#
# vendor/VENDOR_ONLY.tsv declares those files. We stash them before the swap and
# put them back after. Fail closed: if a declared file is present and cannot be
# stashed, stop rather than proceed into a delete we cannot undo.
_vendor_only_tsv="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vendor/VENDOR_ONLY.tsv"
_vo_stash=""
_vo_kept=0
if [ -f "$_vendor_only_tsv" ]; then
    _vo_stash="$(mktemp -d)"
    while IFS=$'\t' read -r _vo_path _vo_repo _vo_why; do
        case "${_vo_path:-}" in ''|'#'*) continue ;; esac
        _vo_src="$abs_vendor/$_vo_path"
        [ -e "$_vo_src" ] || continue
        mkdir -p "$_vo_stash/$(dirname "$_vo_path")"
        cp -p "$_vo_src" "$_vo_stash/$_vo_path" || {
            echo "ERROR: could not stash vendor-only file: $_vo_path" >&2
            echo "       Refusing to sync -- the swap would delete it unrecoverably." >&2
            rm -rf "$_vo_stash"; exit 1; }
        _vo_kept=$((_vo_kept + 1))
    done < "$_vendor_only_tsv"
fi

# Swap the vendored tree.
rm -rf "$abs_vendor"
mkdir -p "$abs_vendor"
( cd "$tmp" && tar -cf - . ) | ( cd "$abs_vendor" && tar -xf - )
rm -rf "$tmp"

# Restore the vendor-only files the swap just deleted.
if [ -n "$_vo_stash" ] && [ "$_vo_kept" -gt 0 ]; then
    ( cd "$_vo_stash" && tar -cf - . ) | ( cd "$abs_vendor" && tar -xf - ) || {
        echo "ERROR: failed restoring vendor-only files after the swap." >&2
        echo "       Stash retained at: $_vo_stash" >&2
        exit 1; }
    echo "  restored $_vo_kept vendor-only file(s) (see vendor/VENDOR_ONLY.tsv)"
fi
[ -n "$_vo_stash" ] && rm -rf "$_vo_stash"

# Regenerate the patch from clean source@to_sha -> new vendor and bump sha.
tmp2="$(mktemp -d)"
set_manifest_field "$TREE" pinned_sha "$TO_SHA"
vlib_materialise "$TREE" "$tmp2" >/dev/null 2>&1 || true
if gen_patch "$tmp2" "$abs_patch"; then
    ensure_manifest_patch_ref "$TREE" "$patch_rel"
else
    clear_manifest_patch_ref "$TREE"
fi
rm -rf "$tmp2"

echo "synced $TREE -> pinned_sha ${TO_SHA:0:12}. Review 'git diff vendor/$vendor_path' and the regenerated patch, then commit."
