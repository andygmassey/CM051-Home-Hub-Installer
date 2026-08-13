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
    if vlib_vendor_diff "$TREE" "$srcdir" "$abs_vendor" "$d"; then
        # identical -> no patch needed
        rm -f "$d"
        [ -f "$out" ] && rm -f "$out" && echo "  no divergence: removed stale patch ${out#"$VLIB_REPO_ROOT"/}"
        return 1
    fi
    if [ -s "$d" ]; then
        mkdir -p "$(dirname "$out")"
        mv "$d" "$out"
        _gp_new="$(grep -cE '^--- /dev/null$' "$out" || true)"
        _gp_all="$(grep -cE '^--- ' "$out" || true)"
        _gp_mod=$(( ${_gp_all:-0} - ${_gp_new:-0} ))
        echo "  wrote divergence patch: ${out#"$VLIB_REPO_ROOT"/} (${_gp_mod} modified, ${_gp_new:-0} vendor-only new file(s))"
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
# ---------------------------------------------------------------------------
# REFUSE TO SYNC A TREE THAT IS NOT RECONSTRUCTIBLE.
#
# The swap replaces vendor/<tree> with source@TO_SHA + the divergence patch.
# Anything in the vendored tree that the patch does NOT describe is therefore
# DELETED, silently, and step 4 then regenerates the patch from the lossy
# result -- so the freshness gate goes green over the deletion.
#
# This is NOT the "patch failed to apply" case below. That one already refuses.
# Here the patch applies perfectly; it is simply INCOMPLETE.
#
# MEASURED 2026-08-12 on ostler_fda. The vendored pwg_ingest.py carried 273
# lines over upstream while the checked-in patch described about 64 of them.
# `sync_vendor.sh ostler_fda --to-sha ab63b7be` returned rc=0, printed a clean
# summary, and deleted 230 lines -- every one of them vendor-only, verified
# against upstream with a control:
#
#     _KINSHIP_DEFAULT / _kinship_words / _is_relationship_label   v1018-D659,
#         "a kinship word must never be a name"
#     _NAME_TIER_* / _display_name_tier / _upsert_display_name     the
#         display-name tier ladder (phone < email < human name)
#
# Two tracked launch fixes, removed from a shipped ingest module by a command
# that reported success. verify_vendor_fresh.sh DOES flag the precondition
# ("vendored tree DIFFERS from source@pinned_sha+patch") -- and then prints
# "-> graft them: scripts/sync_vendor.sh <tree>", which is this command. The
# gate's own remedy was the thing that destroyed the code.
#
# So the order has to be capture-then-sync, and the tool has to enforce it
# rather than document it: --regen-patch first (which captures the undescribed
# divergence at the CURRENT pin), then sync. Proven on ostler_fda: after
# --regen-patch the patch went 283 -> 557 lines and all six symbols survived
# the same sync that had deleted them.
#
# Checked BEFORE the pin is bumped, so vlib_materialise reads the OLD pin.
if [ "${SYNC_ACCEPT_DIVERGENCE_LOSS:-0}" != "1" ]; then
    _pf_tmp="$(mktemp -d)"
    _pf_rc=0
    vlib_materialise "$TREE" "$_pf_tmp" >/dev/null 2>&1 || _pf_rc=$?
    if [ "$_pf_rc" = "0" ]; then
        vlib_apply_patch "$TREE" "$_pf_tmp" >/dev/null 2>&1 || _pf_rc=$?
    fi
    if [ "$_pf_rc" != "0" ]; then
        # Cannot build the comparison. That is CANNOT-RUN, never a pass: a
        # missing oracle must not read as "nothing would be lost".
        echo "REFUSING TO SYNC $TREE: could not reconstruct source@pinned_sha+patch (rc=$_pf_rc)." >&2
        echo "  Without that tree there is no way to know what the swap would delete." >&2
        echo "  Fix the pin or the patch first, or re-run with SYNC_ACCEPT_DIVERGENCE_LOSS=1" >&2
        echo "  if you have checked by hand that nothing is lost." >&2
        rm -rf "$_pf_tmp"
        exit 1
    fi
    _pf_diff="$(mktemp)"
    if ! vlib_shared_diff "$_pf_tmp" "$abs_vendor" "$_pf_diff"; then
        _pf_files="$(grep -c '^--- a/' "$_pf_diff" || true)"
        cat >&2 <<REFUSE
REFUSING TO SYNC $TREE.

The vendored tree contains content that vendor/divergences is NOT describing,
in ${_pf_files} file(s). The swap rebuilds the tree from source + that patch, so
every undescribed line would be DELETED -- and the patch would then be
regenerated from the result, making the gate green over the loss.

Undescribed divergence, by file:
$(grep '^--- a/' "$_pf_diff" | sed 's|^--- a/|    |')

DO THIS FIRST, then re-run the sync:

    scripts/sync_vendor.sh $TREE --regen-patch

That captures the current divergence at the CURRENT pin, which makes the tree
reconstructible; the sync afterwards preserves it instead of deleting it.

Do NOT reach for SYNC_ACCEPT_DIVERGENCE_LOSS=1 to make this go away. On
ostler_fda the undescribed lines were the kinship-word guard (v1018-D659) and
the display-name tier ladder, both shipped, both tracked launch fixes.
REFUSE
        rm -rf "$_pf_tmp" "$_pf_diff"
        exit 1
    fi
    rm -rf "$_pf_tmp" "$_pf_diff"
fi

_orig_pin="$(vlib_field "$TREE" pinned_sha)"
set_manifest_field "$TREE" pinned_sha "$TO_SHA"

# RESTORE THE PIN ON ANY EXIT THAT IS NOT A COMPLETED SYNC.
#
# The line above bumps pinned_sha BEFORE anything is validated, because the
# materialise helper reads the pin to know what to fetch. Fine as a mechanism,
# lethal as a default: every abort after this point leaves the manifest
# asserting a sha whose content was never vendored.
#
# Two abort paths restored it by hand. THREE DID NOT -- the VENDOR_ONLY refusal
# and the two stash failures. Measured 2026-08-12: `sync_vendor.sh doctor`
# refused at VENDOR_ONLY and left
#
#     - pinned_sha = "b0b383109e6e..."   (the deliberate hold)
#     + pinned_sha = "85621fb7a64b..."   (an UNMERGED local branch)
#
# while saying nothing about the manifest. A second run then aborted on the
# divergence patch and dutifully restored to the ALREADY-CORRUPTED value --
# which is how a leak like this quietly becomes the new baseline.
#
# The manifest's own hold_ack_reason names it: "pinning to a commit whose
# content you have not taken is the exact lie this ledger exists to prevent."
#
# A trap, not three more hand-written restores. The defect was never the
# missing lines; it was that adding an abort path silently opts out of the
# invariant. A new `exit` cannot forget this one.
_pin_committed=0
_restore_pin_on_exit() {
    [ "$_pin_committed" = "1" ] && return 0
    set_manifest_field "$TREE" pinned_sha "$_orig_pin"
}
trap _restore_pin_on_exit EXIT

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
_vo_root="$VLIB_REPO_ROOT/vendor"

# TWO DEFECTS FIXED HERE, 2026-08-11, BOTH FOUND BY RUNNING THE THING.
#
# 1. THE PATH JOIN DOUBLED THE TREE NAME, SO THIS GUARD HAD NEVER FIRED.
#    TSV paths are relative to vendor/ ("doctor/agent/daemon_cron.py"), and
#    abs_vendor is ALREADY .../vendor/doctor, so the old
#        _vo_src="$abs_vendor/$_vo_path"
#    resolved to .../vendor/doctor/doctor/agent/daemon_cron.py, which does not
#    exist. `[ -e ]` was therefore always false, every row was skipped,
#    _vo_kept stayed 0, and the restore block never ran. The two doctor files
#    it names survive only because nobody has run a full `sync_vendor.sh
#    doctor` since it was written. A guard that cannot find its own subject is
#    not a guard.
#
# 2. THE REGISTRY COULD SILENTLY MISS A FILE, AND DID.
#    `cm041/assistant_api/subscription_gate.py` is vendor-only and install.sh
#    imports it (`from subscription_gate import activate_first_month_free`, the
#    30-day free Pro month). It was never registered, so a re-pin of
#    cm041/assistant_api deleted it, and nothing downstream would have
#    objected: git shows a clean commit and the DMG ships an installer whose
#    import dangles.
#
#    So the registry is no longer TRUSTED to be complete. Vendor-only files are
#    COMPUTED (present in the vendored tree, absent from the freshly
#    materialised source) and any unregistered one is a HARD REFUSAL. You
#    cannot forget a row, because forgetting stops the sync. On the very first
#    run this found a second file I had missed by hand, test_vendor_import.sh,
#    because my manual sweep looked only at *.py.
#
# EXCLUDED PATHS ARE NOT UNREGISTERED, THEY ARE ALREADY DECIDED.
#
# The first version of this check REFUSED on six files. Five of them match the
# tree's own exclude globs -- cm041/assistant_api excludes "tests/" and
# "test_vendor_import.sh" -- so they are absent from the materialised source BY
# INSTRUCTION, not by accident. The exclude glob IS the recorded decision, and
# demanding a second record of the same decision would make this guard fire on
# every sync of every tree until someone silenced it. A guard that cries wolf
# gets disabled, and then the one real finding goes with it.
#
# So: excluded files do NOT need a row. They are still DROPPED by the swap --
# that is what an exclude glob means, and pretending otherwise would be the
# same lie in the other direction -- but the drop is now ANNOUNCED rather than
# silent. Only a file that is neither in the source nor covered by an exclude
# glob is genuinely vendor-only, and that one must be registered. Exactly one
# file in cm041/assistant_api qualifies: subscription_gate.py.
_vo_excluded_globs="$(vlib_field "$TREE" exclude 2>/dev/null | tr -d '[]"' | tr ',' ' ')"
_vo_is_excluded() {   # $1 = path relative to the vendored tree
    local _p="$1" _g
    for _g in $_vo_excluded_globs; do
        [ -n "$_g" ] || continue
        case "$_g" in
            */) case "$_p" in "${_g}"*|*"/${_g}"*) return 0 ;; esac ;;
            *)  case "$_p" in $_g|*"/$_g") return 0 ;; esac ;;
        esac
    done
    return 1
}

_vo_unregistered=""
_vo_preserve=""
_vo_via_patch=""
# Paths the CURRENT patch creates. Read before the swap, because the swap is
# what would lose them.
_vo_patch_new="$(vlib_patch_new_files "$TREE")"
while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    [ -e "$tmp/$_f" ] && continue                       # upstream has it -- not vendor-only
    # Absent from source. It WILL be deleted by the swap either way, so it is
    # preserved either way; the only question is whether it needed a decision.
    _vo_preserve="${_vo_preserve}${_f}
"
    _vo_is_excluded "$_f" && continue                   # the exclude glob is the decision
    # A file the divergence patch CREATES already has a durable home: the swap
    # deletes it, and source@pinned_sha + patch puts it back byte-for-byte. It
    # does not need a VENDOR_ONLY row, and forcing one would be a false
    # declaration -- that registry means "no upstream counterpart", and a file
    # grafted ahead of a held pin has one, just not at the pin.
    if printf '%s\n' "$_vo_patch_new" | grep -qxF "$_f"; then
        _vo_via_patch="${_vo_via_patch}${_f}
"
        continue
    fi
    _vo_rel_from_vendor="${abs_vendor#"$_vo_root"/}/$_f"
    if [ -f "$_vendor_only_tsv" ] && grep -qF "$_vo_rel_from_vendor" "$_vendor_only_tsv"; then
        continue
    fi
    _vo_unregistered="${_vo_unregistered}    ${_vo_rel_from_vendor}
"
done <<EOF
$(cd "$abs_vendor" 2>/dev/null && find . -type f -not -path '*/__pycache__/*' | sed 's|^\./||')
EOF

# Announce what the swap is about to drop. Five vendored test files under an
# excluded path went in the first run of this and nothing said a word; a
# defensible deletion is still a deletion, and the operator should read it.
if [ -n "$_vo_preserve" ]; then
    _vo_drop_n="$(printf '%s' "$_vo_preserve" | grep -c . || true)"
    if [ "${_vo_drop_n:-0}" -gt 0 ]; then
        echo "  note: the swap drops ${_vo_drop_n} file(s) absent from source@${TO_SHA} (excluded paths, or restored below if registered):"
        printf '%s' "$_vo_preserve" | sed 's/^/          /'
    fi
fi

if [ -n "$_vo_via_patch" ]; then
    echo "  note: $(printf '%s' "$_vo_via_patch" | grep -c . || true) vendor-only file(s) are carried by the divergence patch and will be reconstructed by source@sha + patch:"
    printf '%s' "$_vo_via_patch" | sed 's/^/          /'
fi

if [ -n "$_vo_unregistered" ]; then
    cat >&2 <<REFUSE
REFUSING TO SYNC $TREE.

The swap is a wholesale replace, so any file with no upstream counterpart is
DELETED. These files exist in the vendored tree and NOT in source@$TO_SHA, and
they are not declared in vendor/VENDOR_ONLY.tsv:

$_vo_unregistered
Each one is either
  (a) genuinely vendor-only  -> add a row to vendor/VENDOR_ONLY.tsv with the
      reason and the retirement plan, then re-run; or
  (b) upstream content this sync would legitimately drop -> say so in the
      manifest note, then add the row anyway so the decision is recorded.

Do NOT delete the row to make this pass. The one that started this was
cm041/assistant_api/subscription_gate.py, which install.sh imports; deleting it
ships an installer with a dangling import and a clean-looking commit.
REFUSE
    exit 1
fi

_vo_stash=""
_vo_kept=0
if [ -f "$_vendor_only_tsv" ]; then
    _vo_stash="$(mktemp -d)"
    while IFS=$'\t' read -r _vo_path _vo_repo _vo_why; do
        case "${_vo_path:-}" in ''|'#'*) continue ;; esac
        _vo_abs="$_vo_root/$_vo_path"
        # Only touch files inside the tree being synced. The swap rm -rf's
        # exactly abs_vendor, so a file outside it is neither at risk nor ours.
        case "$_vo_abs" in "$abs_vendor"/*) ;; *) continue ;; esac
        [ -e "$_vo_abs" ] || continue
        _vo_rel="${_vo_abs#"$abs_vendor"/}"
        mkdir -p "$_vo_stash/$(dirname "$_vo_rel")"
        cp -p "$_vo_abs" "$_vo_stash/$_vo_rel" || {
            echo "ERROR: could not stash vendor-only file: $_vo_path" >&2
            echo "       Refusing to sync -- the swap would delete it unrecoverably." >&2
            rm -rf "$_vo_stash"; exit 1; }
        _vo_kept=$((_vo_kept + 1))
    done < "$_vendor_only_tsv"
fi

# v1018-D684. Snapshot the tree we are about to destroy, so the symbol
# guard below has a "before" to compare against and so a refusal can roll
# back rather than leaving a half-vendored tree on disk.
#
# The swap is `rm -rf` + untar: it OVERWRITES, it does not merge. That is
# why a vendored tree which is AHEAD of upstream loses code silently, and
# why the guard has to run here rather than in review.
_symguard_before="$(mktemp -d)"
if [ -d "$abs_vendor" ]; then
    ( cd "$abs_vendor" && tar -cf - . ) | ( cd "$_symguard_before" && tar -xf - )
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

# ── v1018-D684 symbol-regression guard ───────────────────────────────
# Runs AFTER the vendor-only restore on purpose: files declared in
# VENDOR_ONLY.tsv are back by now, so they are not reported as losses and
# the guard only fires on symbols that genuinely vanished.
#
# Andy's ruling 2026-08-13: a re-vendor must FAIL if it would reduce the
# set of functions defined in the target file. Measured that day: the
# vendored doctor tree was a strict SUPERSET of HR015's -- 8 functions
# existed only in vendor, none only upstream -- so a re-vendor would have
# deleted three shipping Doctor cards. It had already happened once
# (HR015 12ac405 "restore iMessage chat.db FDA reminder card dropped in
# re-vendor"). This makes a third occurrence impossible.
#
# On refusal we ROLL BACK. Leaving a half-vendored tree behind would turn
# a caught defect into a worse one.
_symguard="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}/verify_no_symbol_regression.sh"
if [ -x "$_symguard" ]; then
    if ! "$_symguard" "$_symguard_before" "$abs_vendor"; then
        echo "" >&2
        echo "ROLLING BACK the vendored tree; nothing on disk has changed." >&2
        rm -rf "$abs_vendor"
        mkdir -p "$abs_vendor"
        ( cd "$_symguard_before" && tar -cf - . ) | ( cd "$abs_vendor" && tar -xf - )
        rm -rf "$_symguard_before"
        exit 1
    fi
else
    # Absent guard is a could-not-run, not a pass. Say so loudly rather
    # than vendoring unguarded and calling it clean.
    echo "WARNING: $_symguard not found or not executable --" >&2
    echo "         this re-vendor was NOT symbol-guarded (v1018-D684)." >&2
fi
rm -rf "$_symguard_before"

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

# The sync completed: the vendored tree now HOLDS this sha's content, so the
# pin is earned and the trap must not undo it.
_pin_committed=1

echo "synced $TREE -> pinned_sha ${TO_SHA:0:12}. Review 'git diff vendor/$vendor_path' and the regenerated patch, then commit."
