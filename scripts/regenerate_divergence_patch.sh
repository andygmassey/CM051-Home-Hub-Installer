#!/usr/bin/env bash
# regenerate_divergence_patch.sh -- RECORD a vendored graft instead of deleting it.
# =================================================================================
#
# THE GAP THIS FILLS
# ------------------
# Before this existed, CM051 had exactly two vendor tools:
#
#     scripts/sync_vendor.sh            re-vendors. DESTRUCTIVE. deletes grafts.
#     scripts/verify_vendor_fresh.sh    read-only. reports.
#
# So when the freshness gate said a tree DIFFERS, the only remedy the repo
# offered was the one that throws the divergence away. Under time pressure,
# during a cut, "just re-sync it" is the obvious move and it is the wrong one.
# On 2026-08-15 that nearly happened to cm041/identity_resolver, whose most
# recent graft was the removal of real family names from a PUBLIC repo. The
# tree turned out to be fresh, so nothing was lost -- but the tool gap was
# real, and a gap that only bites under pressure bites at the worst moment.
#
# The safe operation is the opposite of a re-sync and it changes NO SHIPPED
# BYTES: leave the vendored tree exactly as it is, and recompute the divergence
# patch to describe it. The graft stops being undeclared drift and becomes a
# recorded, reproducible difference. Nothing that ships moves.
#
# WHY IT REFUSES TO BE QUIET
# --------------------------
# Regenerating blindly blesses ACCIDENTAL drift with the same stroke as a
# deliberate graft. The patch file is the only record of which is which, so a
# tool that rewrites it without showing you what it is about to record just
# moves the silent failure one level up: the gate goes green and nobody ever
# learns what it went green over.
#
# Hence: dry-run by default, the full proposed change printed, and writing
# requires naming the tree a second time in the environment. You cannot loop
# this over every divergent tree without typing each name, which is the point.
#
# WHAT IT REFUSES OUTRIGHT
#   - a tree that is already fresh                 nothing to record
#   - a source repo that cannot be resolved        CANNOT-RUN, exit 2
#   - a pinned_sha absent from the checkout        CANNOT-RUN, exit 2
#   - a source that has ADVANCED past the pin      that is a RE-PIN, not a
#                                                  graft; blessing it here
#                                                  would record upstream
#                                                  commits as local edits
#
# AND IT VERIFIES ITSELF. After writing, it reconstructs the tree from
# source@pinned_sha + the NEW patch and diffs against the vendored tree. If
# they do not match, the previous patch is restored and the run fails. The tool
# is not allowed to leave the repo in a state where the patch cannot rebuild
# the thing it describes.
#
# USAGE
#   scripts/regenerate_divergence_patch.sh <tree>              # dry run, prints
#   VENDOR_PATCH_REGEN_CONFIRM=<tree> \
#     scripts/regenerate_divergence_patch.sh <tree> --write    # writes
#
# EXIT
#   0  dry run completed, or patch written and verified
#   1  refused, or the written patch failed to reconstruct the tree
#   2  could not run (unknown tree, source absent, sha absent, no git)
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_vendor_lib.sh
. "$SCRIPT_DIR/_vendor_lib.sh"

TREE="${1:-}"
MODE="${2:-}"

die_cannot_run() { echo "regenerate_divergence_patch: CANNOT RUN -- $1" >&2; exit 2; }
refuse()         { echo "" >&2; echo "REFUSED: $1" >&2; exit 1; }

if [ -z "$TREE" ]; then
    echo "usage: scripts/regenerate_divergence_patch.sh <tree> [--write]" >&2
    echo "" >&2
    echo "Records the vendored tree's current content as its divergence patch." >&2
    echo "Changes no vendored bytes. Dry run unless --write AND" >&2
    echo "VENDOR_PATCH_REGEN_CONFIRM=<tree> are both given." >&2
    echo "" >&2
    echo "Declared trees:" >&2
    vlib_tree_names | sed 's/^/  /' >&2
    exit 2
fi

command -v git >/dev/null 2>&1 || die_cannot_run "git unavailable"

if ! vlib_tree_names | grep -qx "$TREE"; then
    echo "regenerate_divergence_patch: CANNOT RUN -- '$TREE' is not a declared tree." >&2
    echo "Declared trees:" >&2
    vlib_tree_names | sed 's/^/  /' >&2
    exit 2
fi

VENDOR_PATH="$(vlib_field "$TREE" vendor_path)"
PATCH_REL="$(vlib_field "$TREE" divergence_patch)"
PINNED_SHA="$(vlib_field "$TREE" pinned_sha)"
ABS_VENDOR="$VLIB_REPO_ROOT/$VENDOR_PATH"

[ -n "$PATCH_REL" ]   || die_cannot_run "$TREE declares no divergence_patch path in the manifest"
[ -d "$ABS_VENDOR" ]  || die_cannot_run "vendored tree missing on disk: $VENDOR_PATH"

ABS_PATCH="$VLIB_REPO_ROOT/$PATCH_REL"

echo "regenerate divergence patch -- $TREE"
echo "  vendored tree : $VENDOR_PATH   (NOT MODIFIED by this tool)"
echo "  patch file    : $PATCH_REL"
echo "  pinned sha    : $PINNED_SHA"
echo ""

# --- materialise source@pinned_sha, WITHOUT the existing patch ---------------
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC" "$SRC.new" "$SRC.chk" "$SRC.diff"' EXIT
rc=0
vlib_materialise "$TREE" "$SRC" || rc=$?
case "$rc" in
    0) ;;
    2) die_cannot_run "source repo for $TREE is not available (see above)" ;;
    3) die_cannot_run "pinned_sha $PINNED_SHA is not in the source checkout (see above)" ;;
    *) die_cannot_run "could not materialise $TREE (rc=$rc)" ;;
esac

# --- REFUSE if the source has advanced past the pin --------------------------
# Recording a graft and moving a pin are different operations. If upstream has
# commits the vendor has not taken, some of the difference between them is
# UPSTREAM WORK, and folding that into a divergence patch would record another
# team's commits as this repo's local edits -- permanently, and invisibly.
SRC_REPO="$(resolve_source_repo "$TREE")"
SUBPATH="$(vlib_field "$TREE" source_path)"
if [ "$PINNED_SHA" != "WORKING_TREE" ] && [ -d "$SRC_REPO" ] \
   && git -C "$SRC_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    _spec="."; [ -n "$SUBPATH" ] && [ "$SUBPATH" != "." ] && _spec="$SUBPATH"
    AHEAD="$(git -C "$SRC_REPO" log --oneline "${PINNED_SHA}..HEAD" -- "$_spec" 2>/dev/null || true)"
    if [ -n "$AHEAD" ]; then
        echo "The SOURCE has advanced past the pin. Unshipped commits touching this tree:" >&2
        printf '%s\n' "$AHEAD" | sed 's/^/    /' >&2
        refuse "this is a RE-PIN, not a graft to record.
         Regenerating here would fold those upstream commits into the
         divergence patch and record them as local edits to this repo.
         Move the pin first (scripts/sync_vendor.sh), re-apply the graft on
         the new base, then run this tool if a divergence remains."
    fi
fi

# --- is there anything to record? --------------------------------------------
if vlib_vendor_diff "$TREE" "$SRC" "$ABS_VENDOR" "$SRC.diff"; then
    echo "The vendored tree already reconstructs from source@${PINNED_SHA} alone."
    refuse "nothing to record -- this tree is not divergent.
         If the freshness gate disagrees, it is reading a different pin or a
         different checkout; resolve that rather than writing a patch."
fi

# --- build the proposed patch ------------------------------------------------
# The patch is simply the diff from source@pinned_sha to the vendored tree AS
# IT STANDS. That is the definition of "record what is there", and it is why
# this operation cannot change shipped bytes: the vendored side of the diff is
# the input, never the output.
NEW_PATCH="$SRC.new"
( cd "$VLIB_REPO_ROOT" && git diff --no-index --no-color -- "$SRC" "$ABS_VENDOR" ) > "$NEW_PATCH" 2>/dev/null || true
# Rewrite the temp-dir prefixes to stable a/ b/ paths so the patch is portable
# and does not embed this run's mktemp path.
sed -i.bak -e "s#${SRC}/#a/#g" -e "s#${ABS_VENDOR}/#b/#g" -e "s#${SRC}#a#g" -e "s#${ABS_VENDOR}#b#g" "$NEW_PATCH" 2>/dev/null
rm -f "$NEW_PATCH.bak"

if [ ! -s "$NEW_PATCH" ]; then
    refuse "computed an EMPTY patch while vlib_vendor_diff reported drift.
         Those two cannot both be right. Do not write. Investigate:
           $SRC.diff  holds the drift the gate saw."
fi

# --- SHOW what is about to be blessed ----------------------------------------
echo "PROPOSED PATCH -- this is what would be RECORDED as a deliberate graft:"
echo ""
printf '  files touched : %s\n' "$(grep -c '^diff --git' "$NEW_PATCH" || echo 0)"
printf '  lines added   : %s\n' "$(grep -c '^+[^+]' "$NEW_PATCH" || echo 0)"
printf '  lines removed : %s\n' "$(grep -c '^-[^-]' "$NEW_PATCH" || echo 0)"
echo ""
echo "  per-file:"
grep '^diff --git' "$NEW_PATCH" | sed 's#^diff --git a/##; s# b/.*##' | sed 's/^/    /'
echo ""

if [ -f "$ABS_PATCH" ]; then
    echo "CHANGE AGAINST THE PATCH ALREADY ON DISK (a diff of diffs):"
    if diff -q "$ABS_PATCH" "$NEW_PATCH" >/dev/null 2>&1; then
        echo "  none -- the recorded patch already describes the tree."
        refuse "nothing would change. The patch on disk is already correct."
    fi
    diff -u "$ABS_PATCH" "$NEW_PATCH" 2>/dev/null | sed -n '1,60p' | sed 's/^/    /'
    _dl="$(diff -u "$ABS_PATCH" "$NEW_PATCH" 2>/dev/null | wc -l | tr -d ' ')"
    [ "${_dl:-0}" -gt 60 ] && echo "    ... ($_dl lines total, truncated)"
else
    echo "  (no patch on disk yet -- this would create $PATCH_REL)"
fi
echo ""

# --- write, or stop here ------------------------------------------------------
if [ "$MODE" != "--write" ]; then
    echo "DRY RUN. Nothing written."
    echo ""
    echo "Read the change above. Every line of it becomes a permanent claim that"
    echo "this difference is DELIBERATE. If any of it is accidental drift, fix the"
    echo "vendored tree first -- do not record it."
    echo ""
    echo "To write:"
    echo "  VENDOR_PATCH_REGEN_CONFIRM=$TREE \\"
    echo "    scripts/regenerate_divergence_patch.sh $TREE --write"
    exit 0
fi

if [ "${VENDOR_PATCH_REGEN_CONFIRM:-}" != "$TREE" ]; then
    refuse "--write requires VENDOR_PATCH_REGEN_CONFIRM=$TREE.
         Naming the tree twice is deliberate: it stops this being looped over
         every divergent tree in one go, which is how accidental drift gets
         blessed in bulk."
fi

BACKUP=""
if [ -f "$ABS_PATCH" ]; then
    BACKUP="$(mktemp)"
    cp "$ABS_PATCH" "$BACKUP"
fi
mkdir -p "$(dirname "$ABS_PATCH")"
cp "$NEW_PATCH" "$ABS_PATCH"
echo "wrote $PATCH_REL"

# --- VERIFY THE THING WE JUST WROTE ------------------------------------------
# A patch that cannot rebuild the tree it describes is worse than no patch: the
# gate will fail on it forever and the next person will reach for sync_vendor.
echo ""
echo "verifying: does source@${PINNED_SHA} + the NEW patch reconstruct the tree?"
CHK="$SRC.chk"
mkdir -p "$CHK"
vrc=0
vlib_materialise "$TREE" "$CHK" >/dev/null 2>&1 || vrc=$?
if [ "$vrc" -ne 0 ]; then
    echo "  could not re-materialise to verify (rc=$vrc)" >&2
    vok=1
elif ! vlib_apply_patch "$TREE" "$CHK" >/dev/null 2>&1; then
    echo "  the new patch does not APPLY to source@${PINNED_SHA}" >&2
    vok=1
elif vlib_vendor_diff "$TREE" "$CHK" "$ABS_VENDOR" "$SRC.diff"; then
    vok=0
else
    echo "  applied, but the result still DIFFERS from the vendored tree:" >&2
    sed 's/^/    /' "$SRC.diff" | head -20 >&2
    vok=1
fi

if [ "$vok" -ne 0 ]; then
    if [ -n "$BACKUP" ]; then
        cp "$BACKUP" "$ABS_PATCH"
        echo "  RESTORED the previous $PATCH_REL -- nothing was left broken." >&2
    else
        rm -f "$ABS_PATCH"
        echo "  REMOVED the patch this run created -- nothing was left broken." >&2
    fi
    refuse "the written patch does not reconstruct the vendored tree.
         The repo is back as it was. This usually means the tree contains
         something the materialiser excludes, or a file mode / symlink the
         patch format does not carry."
fi

echo "  OK -- source@${PINNED_SHA} + $PATCH_REL == $VENDOR_PATH"
echo ""
echo "The graft is now RECORDED. No vendored bytes changed."
echo "Commit $PATCH_REL with a message saying WHY the divergence exists --"
echo "the patch records what differs; only you can record why."
exit 0
