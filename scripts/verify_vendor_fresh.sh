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
# OR (FAIL-CLOSED DEFAULT) any tree that could not be verified.
#
# FAIL-CLOSED BY DEFAULT (changed 2026-06-18, ORM -- the v0.4.17 recurrence-killer):
# an UNVERIFIABLE tree (source repo unreachable, sha absent, or verify=skip) is a
# RED, not a warning. Rationale: when a tree's source cannot be materialised, the
# gate CANNOT run its source-advanced-past-pin check -- which is the EXACT blind
# spot that shipped the stale vendored ical-server green (CM041 #51 / 4931c53 was
# ahead of the assistant_api pin, but the source was unreachable in the cut so the
# tree only WARNed and the cut passed). "Could not verify a SHIPPING tree" must
# never be a pass. The cut inherits this safety with zero config.
#
# OPT-OUT (dev / CI that knowingly lacks cross-repo sources -- NEVER the cut):
#   VENDOR_FRESH_ALLOW_UNVERIFIED=1  (or legacy VENDOR_FRESH_STRICT=0)
# downgrades unverifiable trees to warnings. It is loud and explicit by design --
# the unsafe mode must be a deliberate choice, never the default a cut falls into.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_vendor_lib.sh
. "$SCRIPT_DIR/_vendor_lib.sh"

# Fail-closed by default. STRICT=1 means "unverifiable => RED". The explicit
# opt-out (ALLOW_UNVERIFIED=1, or legacy VENDOR_FRESH_STRICT=0) flips it to lenient.
if [ "${VENDOR_FRESH_ALLOW_UNVERIFIED:-0}" = "1" ] || [ "${VENDOR_FRESH_STRICT:-1}" = "0" ]; then
    STRICT=0
else
    STRICT=1
fi

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
    if vlib_shared_diff "$tmp" "$abs_vendor" "$tmp.diff"; then
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
    echo "GATE: RED (fail-closed) -- $warn tree(s) could not be verified (source unreachable / sha absent / verify=skip)." >&2
    echo "      An unverifiable SHIPPING tree is treated as STALE: the source-advanced-past-pin check could not run," >&2
    echo "      which is exactly how the stale vendored ical-server (CM041 #51) shipped green. Make every source repo" >&2
    echo "      reachable and re-run, or -- dev/CI only, NEVER the cut -- set VENDOR_FRESH_ALLOW_UNVERIFIED=1." >&2
    exit 1
fi

if [ "$warn" -gt 0 ]; then
    echo "GATE: GREEN with $warn warning(s) -- UNVERIFIED trees ALLOWED because VENDOR_FRESH_ALLOW_UNVERIFIED=1 (lenient)."
    echo "      This opt-out is for dev / CI without cross-repo sources. The CUT must NOT use it -- it re-opens the"
    echo "      exact blind spot that shipped the stale ical-server. Run with all sources reachable for a real verdict."
else
    echo "GATE: GREEN -- every vendored tree matches its pinned source."
fi
exit 0
