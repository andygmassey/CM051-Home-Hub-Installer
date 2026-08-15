#!/usr/bin/env bash
# verify_vendor_fresh.sh -- THE vendor-freshness gate.
# ===================================================
#
# Kills the divergent-vendored-twin class. The DMG ships VENDORED copies of
# upstream source trees (CM041/CM048/ostler_fda/CM019/CM021/...). A fix that
# lands in a SOURCE repo does not reach the customer until it is grafted into
# vendor/. The old guard (tests/test_no_divergent_vendor_twin.sh) compared
# vendor/<pkg> against a top-level ./<pkg> twin that does NOT exist inside
# CM051 -- so it trivially passed and was BLIND to real cross-repo drift.
#
# This gate is cross-repo. For each entry in vendor/VENDOR_MANIFEST.toml it:
#   1. materialises source_repo @ pinned_sha (restricted to the vendored
#      file-set via the entry's exclude globs),
#   2. applies the recorded divergence patch (legitimate vendor-side grafts,
#      e.g. contact_syncer's identity_resolver import + en-dash house style),
#   3. diffs the result against the vendored tree -- ANY mismatch FAILS,
#   4. AND checks whether the SOURCE repo has advanced past pinned_sha for
#      the vendored sub-path; if so the vendor is STALE (an ungrafted fix) --
#      that FAILS too, naming the tree and the unshipped commits.
#
# (1)-(3) catch in-place rot / a vendor edited without a source change.
# (4) catches the headline class: a fix merged to source but never grafted.
#
# Productised: source repo paths are overridable per operator/CI (see
# _vendor_lib.sh resolve_source_repo). If a source repo is not locally
# available the tree is reported as "could not verify (source repo not
# found)" and counted as a WARNING -- never a silent pass.
#
# Exit: 0 = all verifiable trees fresh; 1 = at least one stale/divergent tree,
# OR at least one tree that could not be verified at all.
#
# FAIL-CLOSED SINCE 2026-08-15, AND HERE IS WHY IT HAD TO CHANGE.
#
# This defaulted to VENDOR_FRESH_STRICT=0. An unverifiable tree printed
# "GATE: GREEN with N warning(s)" and exited 0 -- a warn that reads as a pass,
# on the gate that guards what ships, with the reassuring word GREEN in front
# of it.
#
# The intent was never in doubt. What was missing was anyone actually setting
# the flag:
#
#   OS003/CUT_MECHANISM_CANONICAL.md:40,119  "VENDOR_FRESH_STRICT=1 ... GREEN"
#   CM051 .github/workflows/vendor-integrity.yml:106  a COMMENT promising the
#     real gate runs "with all source repos present, VENDOR_FRESH_STRICT=1"
#   OS003/pipeline/release.yml:75  the actual cut invocation:
#     `bash vendor/verify_vendor_fresh.sh`   <-- no flag
#
# Measured 2026-08-15: NOTHING anywhere sets VENDOR_FRESH_STRICT=1. Two
# documents and a comment described a strict gate; every invocation ran the
# lenient one. A mention is not an invocation.
#
# So the default is now 1. An environment that genuinely cannot verify -- CI
# without the sibling source repos checked out -- must now say so explicitly by
# setting VENDOR_FRESH_STRICT=0, which makes the degradation visible at the
# call site instead of inherited silently by everything including the cut.
#
# The asymmetry is deliberate. Getting this wrong in the lenient direction
# ships an unverified vendored tree to a customer. Getting it wrong in the
# strict direction turns one CI job red until somebody adds one word.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_vendor_lib.sh
. "$SCRIPT_DIR/_vendor_lib.sh"

STRICT="${VENDOR_FRESH_STRICT:-1}"

fail=0
warn=0
ok=0
checked=0

echo "vendor-freshness gate -- manifest: $VLIB_MANIFEST"
echo

# Does the source sub-path have commits newer than pinned_sha?
# Prints the short log of unshipped commits (empty if up to date).
unshipped_commits() {
    local tree="$1"
    local repo subpath sha
    repo="$(resolve_source_repo "$tree")"
    subpath="$(vlib_field "$tree" source_path)"
    sha="$(vlib_field "$tree" pinned_sha)"
    [ "$sha" = "WORKING_TREE" ] && return 0
    [ -d "$repo" ] || return 0
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
    git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null || return 0
    local pathspec="."
    [ -n "$subpath" ] && [ "$subpath" != "." ] && pathspec="$subpath"
    # Commits on HEAD that touch the vendored sub-path and are not ancestors
    # of pinned_sha.
    git -C "$repo" log --oneline "${sha}..HEAD" -- "$pathspec" 2>/dev/null
}

while IFS= read -r tree; do
    [ -z "$tree" ] && continue
    checked=$((checked + 1))
    vendor_path="$(vlib_field "$tree" vendor_path)"
    abs_vendor="$VLIB_REPO_ROOT/$vendor_path"

    verify="$(vlib_field "$tree" verify)"
    if [ "$verify" = "skip" ]; then
        reason="$(vlib_field "$tree" note)"
        echo "WARN  $tree -- verification skipped: ${reason:-marked verify=skip}"
        warn=$((warn + 1))
        continue
    fi

    if [ ! -d "$abs_vendor" ]; then
        echo "FAIL  $tree -- vendored tree missing on disk: $vendor_path" >&2
        fail=$((fail + 1))
        continue
    fi

    tmp="$(mktemp -d)"
    rc=0
    vlib_materialise "$tree" "$tmp" || rc=$?

    if [ "$rc" = "2" ] || [ "$rc" = "3" ]; then
        # Source not available / sha absent -> warning, not a silent pass.
        echo "WARN  $tree -- could not verify (see above)"
        warn=$((warn + 1))
        rm -rf "$tmp"
        continue
    fi

    # Apply the recorded legitimate divergence.
    if ! vlib_apply_patch "$tree" "$tmp"; then
        echo "FAIL  $tree -- divergence patch failed to apply (source moved under the patch; re-graft)" >&2
        fail=$((fail + 1))
        rm -rf "$tmp"
        continue
    fi

    # Compare ONLY files present in BOTH source@sha+patch and the vendored
    # tree. Source-only files (tests/, un-vendored src/) and vendor-only files
    # (grafts) are out of scope -- "stale" means a shared file has drifted.
    if vlib_vendor_diff "$tree" "$tmp" "$abs_vendor" "$tmp.diff"; then
        content_ok=1
    else
        content_ok=0
    fi

    # Has the source advanced past the pin without a re-graft?
    behind="$(unshipped_commits "$tree" || true)"

    if [ "$content_ok" = "1" ] && [ -z "$behind" ]; then
        echo "OK    $tree -- vendor == source@$(vlib_field "$tree" pinned_sha | cut -c1-8) (+patch)"
        ok=$((ok + 1))
    else
        if [ "$content_ok" != "1" ]; then
            echo "FAIL  $tree -- vendored tree DIFFERS from source@pinned_sha+patch:" >&2
            sed 's/^/        /' "$tmp.diff" | head -40 >&2
            [ "$(wc -l < "$tmp.diff")" -gt 40 ] && echo "        ... (diff truncated)" >&2
        fi
        if [ -n "$behind" ]; then
            echo "FAIL  $tree -- source has advanced past pinned_sha; UNGRAFTED commits:" >&2
            printf '%s\n' "$behind" | sed 's/^/        /' >&2
            echo "        -> graft them: scripts/sync_vendor.sh $tree" >&2
        fi
        fail=$((fail + 1))
    fi
    rm -rf "$tmp" "$tmp.diff"
done < <(vlib_tree_names)

echo
echo "vendor-freshness: $checked tree(s) -- $ok fresh, $fail stale/divergent, $warn unverifiable"

if [ "$fail" -gt 0 ]; then
    echo "GATE: RED -- $fail tree(s) are stale or have drifted from source." >&2
    exit 1
fi

if [ "$warn" -gt 0 ] && [ "$STRICT" = "1" ]; then
    echo "GATE: RED -- $warn tree(s) could NOT BE VERIFIED." >&2
    echo "      Not verified is not the same as verified fresh. This gate guards" >&2
    echo "      what ships; an unverifiable vendored tree is exactly the state it" >&2
    echo "      exists to refuse." >&2
    echo "      Check the source repos out, or set VENDOR_FRESH_STRICT=0 at the" >&2
    echo "      call site to accept the degradation ON PURPOSE and in writing." >&2
    exit 1
fi

if [ "$warn" -gt 0 ]; then
    # Reached only when a caller has explicitly opted out. Do NOT print GREEN.
    # The previous wording was "GATE: GREEN with N warning(s)", which is the
    # whole defect in one line: the reader takes the first word and moves on.
    echo "GATE: DEGRADED -- $warn tree(s) NOT VERIFIED (VENDOR_FRESH_STRICT=0 was set explicitly)."
    echo "      $ok tree(s) were checked and are fresh. The other $warn were not checked at all."
    echo "      This is not a pass for those trees. The cut must run with all source"
    echo "      repos present and the default strictness."
else
    echo "GATE: GREEN -- every vendored tree matches its pinned source."
fi
exit 0
