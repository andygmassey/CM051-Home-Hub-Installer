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
#   - a tree marked regenerate_forbidden           a NAMED, per-tree ban that
#                                                  does not depend on the
#                                                  operator's environment
#   - a tree that is already fresh                 nothing to record
#   - a source repo that cannot be resolved        CANNOT-RUN, exit 2
#   - a pinned_sha absent from the checkout        CANNOT-RUN, exit 2
#   - a source that has ADVANCED past the pin      that is a RE-PIN, not a
#                                                  graft; blessing it here
#                                                  would record upstream
#                                                  commits as local edits
#
# WHY regenerate_forbidden EXISTS, AND WHY THE ADVANCE CHECK IS NOT ENOUGH.
# Measured 2026-08-15 on cm041/contact_syncer. With CM041 resolving to a
# checkout AHEAD of the pin, the advance check refuses and the tree is safe.
# Point CM041 at a checkout sitting EXACTLY AT the pin -- a fresh clone checked
# out at the pinned sha, or a clone predating the four held commits -- and the
# advance limb is discharged, the run reaches a verdict, and it returns 0 and
# offers to write. The delta it would write carries TWO PERSON-NAME-SHAPED
# tokens on its MINUS side, i.e. the SOURCE side, so writing would export them
# from a private repo into this public one.
#
# The PII scan does not catch it, and cannot: .githooks/pii_patterns.sh carries
# five NUMERIC shapes (UK mobile x2, US/intl phone, SSN, long numeric id) and
# no person-name shape at all. The instrument and the defect sit on different
# surfaces, so the scan reads clean forever while the defect is fully present.
# Its positive control fires, so the clean result is a real measurement of the
# wrong thing -- which is the most misleading kind.
#
# The advance limb also cannot be relied on here for a second reason, recorded
# in VENDOR_MANIFEST.toml: it reads HEAD of whatever checkout source_repo
# resolves to, so it is NOT PORTABLE. Two "canonical" exports were measured
# wrong for it on the same day, one of them four commits behind origin/main --
# which for this tree is precisely the state that discharges the limb.
#
# So the ban is DECLARED, per tree, in the manifest, and is checked before the
# environment is consulted at all. Same shape as the manifest's other
# declare-it-with-a-reason pairs: a ban without a reason is still a refusal.
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

# RE-ASSERT OUR OWN SHELL OPTIONS. _vendor_lib.sh runs `set -euo pipefail` at
# file scope, so SOURCING it silently turns -e back on in this shell and
# overrides the `set -uo pipefail` chosen above. Confirmed by measurement:
#   bash -c 'set -uo pipefail; . scripts/_vendor_lib.sh; case "$-" in *e*) ...'
#   -> -e IS SET after sourcing.
#
# -e is wrong for this tool. Several library calls signal by EXIT CODE rather
# than by failing: vlib_vendor_diff returns non-zero to mean "there is drift",
# which is the normal case here and the whole reason the tool was invoked. The
# paths in use today happen to be -e-exempt because they sit in `if` or `||`
# constructs, so nothing is currently broken -- but a bare call added later
# would abort the run mid-write with no message, and the arm most likely to
# contain one is the revert, which only executes when something has already
# gone wrong. A latent -e in the recovery path is the worst place for it.
set +e
PII_LIB="$VLIB_REPO_ROOT/.githooks/pii_patterns.sh"

# ---------------------------------------------------------------------------
# THE PII POSITIVE CONTROL. Runs EVERY invocation, before any verdict is trusted.
#
# READ THE SCANNER'S CONVENTION BEFORE TRUSTING ITS ANSWER. `pii_scan_files`
# ALWAYS returns 0 and signals findings by PRINTING them. It also returns 0
# with NO OUTPUT when the pattern file fails to load. So the exit code carries
# no information, and a predicate written as `if pii_scan_files ...; then`
# reads every run as clean -- including the run where the patterns never
# loaded. Findings are judged by NON-EMPTY OUTPUT, never by rc.
#
# The canaries are COMPOSED at runtime and never appear as literals here,
# because this repo's own pre-commit hook scans this file and a gate must not
# carry the thing it hunts. Both are STRUCTURALLY NON-ASSIGNABLE, so neither
# can be a real person's identifier no matter who reads it:
#   - a NANP number whose area code begins with a zero, which the numbering
#     plan forbids, so it belongs to nobody. Exercises the US/intl PHONE limb.
#   - an SSN in the all-zero area, which the SSA has never issued. Exercises
#     the SSN limb.
# The composition below is the specification; read it there. The values are
# written as printf ARGUMENTS, which is exactly what keeps the assembled shape
# out of this file. CI caught the first version of this comment doing the
# opposite -- it spelled both numbers out longhand in the prose, and a gate's
# own source is the last place the shape it hunts should appear. The local
# pre-commit hook passed and CI did not, so do not read a clean pre-commit run
# as permission to write a shape out in full.
#
# WHY NOT THE OFCOM DRAMA RANGE, WHICH THIS CONTROL USED TO USE. Because the
# scanner now deliberately IGNORES it. #729 taught pii_scan_files to drop
# standards-reserved placeholders (OFCOM 07700 900xxx, NANP 555-01xx) so that
# following the hook's own advice stops tripping the hook. Correct change --
# but it silently turned this control's canary into a value the scanner is
# CONTRACTUALLY REQUIRED to ignore, so the control stopped firing and the tool
# reported CANNOT-RUN on every invocation. Measured on this branch against
# origin/main f14715a6: 8 of 24 controls red, every one of them rc=2.
#
# That is the failure mode this control exists to produce rather than hide, and
# it is why a reserved-for-fiction value can never again serve as the canary
# here: the property that makes it safe to write down is now exactly the
# property that makes it invisible. A positive control must be a value the
# scanner is required to FIND, not one it is required to FORGIVE.
#
# ALL canaries must fire. A partial fire means some limb of the scanner went
# quiet, and a scanner that is half-awake cannot clear a patch. On failure the
# NAME of the limb that stayed silent is left in _PII_CONTROL_SILENT so the
# CANNOT-RUN message can say which one, rather than just "something".
_PII_CONTROL_SILENT=""
_pii_control_fires() {
    [ -f "$PII_LIB" ] || return 2
    # shellcheck source=/dev/null
    . "$PII_LIB" || return 2
    local d out
    d="$(mktemp -d)" || return 2
    _PII_CONTROL_SILENT=""

    printf 'phone = "%s"\n' "$(printf '+1 (%s) %s-%s' '000' '000' '0000')" > "$d/nanp.txt"
    out="$(pii_scan_files "$d/nanp.txt" 2>&1)"
    [ -n "$out" ] || _PII_CONTROL_SILENT="US/intl phone"

    printf 'ref = "%s"\n' "$(printf '%s-%s-%s' '000' '00' '0000')" > "$d/ssn.txt"
    out="$(pii_scan_files "$d/ssn.txt" 2>&1)"
    [ -n "$out" ] || _PII_CONTROL_SILENT="${_PII_CONTROL_SILENT:+$_PII_CONTROL_SILENT, }SSN"

    rm -rf "$d"
    [ -z "$_PII_CONTROL_SILENT" ]
}

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

# --- REFUSE a tree the manifest bans outright --------------------------------
# FIRST, before the source repo, the pin or the operator's environment is
# consulted, because every one of those is a thing an operator can change and
# this ban must not be escapable by changing them. See the header for the
# measurement that forced this.
FORBID="$(vlib_field "$TREE" regenerate_forbidden)"
if [ "$FORBID" = "true" ]; then
    FORBID_WHY="$(vlib_field "$TREE" regenerate_forbidden_reason)"
    echo "" >&2
    echo "REFUSED: $TREE is marked regenerate_forbidden in VENDOR_MANIFEST.toml." >&2
    echo "" >&2
    if [ -n "$FORBID_WHY" ]; then
        echo "  Declared reason:" >&2
        printf '%s\n' "$FORBID_WHY" | fold -s -w 72 | sed 's/^/    /' >&2
    else
        # Fail closed. A ban with no reason is malformed, and the safe reading
        # of a malformed ban is that it still bans.
        echo "  NO regenerate_forbidden_reason IS DECLARED. That is malformed, and it" >&2
        echo "  is still a refusal: an undocumented ban is not a licence to proceed." >&2
        echo "  Add the reason, or remove the ban deliberately." >&2
    fi
    echo "" >&2
    echo "  This ban is checked BEFORE the source checkout, so it cannot be cleared" >&2
    echo "  by re-pointing an env placeholder or moving a checkout. Do not route" >&2
    echo "  around it with sync_vendor.sh either: that re-syncs FROM source and" >&2
    echo "  deletes the vendored side, which is where scrubs live." >&2
    exit 1
fi

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
trap 'rm -rf "$SRC" "$SRC.new" "$SRC.chk" "$SRC.diff" "$SRC.changed" "$SRC.pii"' EXIT
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

# --- REFUSE if the patch would record PII ------------------------------------
# THE `-` LINES ARE THE DANGEROUS ONES, AND THAT IS THE WHOLE POINT.
#
# A divergence patch's `-` lines are the SOURCE content, and its `+` lines are
# the vendored content. In this repo the commonest graft is a SCRUB: upstream
# still carries a real name or mailbox, the vendored side has it removed. So
# the PII lands on the MINUS side, and writing the patch republishes into a
# public repo exactly what was removed from the tree.
#
# A scan of only the added lines misses that entirely whenever there is no
# patch on disk yet -- because then the "delta" is the raw patch and its `+`
# lines are the SCRUBBED side. Verified by construction 2026-08-15 against a
# patch whose source side held a synthetic UK mobile: the added-lines-only
# predicate scanned it and found 0 occurrences. That is precisely the case for
# the trees whose divergences are unrecorded today, which are the ones a
# regenerate run would touch first.
#
# So: scan EVERY changed line, both signs, marker stripped.
#
# WHAT THIS SCAN DOES NOT COVER, stated so a clean run is not over-read.
#
# (a) SCOPE. It scans the patch this run would WRITE. PII already recorded in an
#     existing patch, unchanged by this run, is not in that set and is never
#     rescanned. A clean result here means "this run adds no new PII", NOT "this
#     patch contains no PII". Auditing what is already recorded is a separate
#     sweep against the committed vendor/divergences/ tree, not this tool's job.
#
# (b) SURFACE, and this is the one that has actually bitten. The patterns in
#     .githooks/pii_patterns.sh are FIVE NUMERIC SHAPES: UK mobile in two
#     forms, US/intl phone, US SSN, and a long numeric id. There is NO
#     person-name shape among them. So this scan cannot see a name, and on
#     cm041/contact_syncer it returns a clean, positive-control-backed zero over
#     a delta carrying two person-name-shaped tokens on its minus side.
#     A green line below therefore means "no numeric-shaped PII", never "no
#     PII". Names are hunted by tests/vendor_person_name_sweep.py, a separate
#     instrument this tool does not call, and adjudicated in
#     vendor/PERSON_NAMES_REVIEWED.tsv, which does not exist yet -- so for names
#     the answer is UNKNOWN, not clean. Where that gap is known to be live for a
#     specific tree, ban the tree with regenerate_forbidden rather than trusting
#     this scan to catch it.
if ! _pii_control_fires; then
    echo "regenerate_divergence_patch: CANNOT RUN -- the PII positive control did NOT fire." >&2
    if [ -n "$_PII_CONTROL_SILENT" ]; then
        echo "  Silent limb(s): $_PII_CONTROL_SILENT" >&2
    fi
    echo "  Either $PII_LIB is missing, or its patterns no longer match a known-bad" >&2
    echo "  synthetic value. A PII check that cannot be shown to fire is not evidence" >&2
    echo "  of absence, so nothing is blessed." >&2
    echo "" >&2
    echo "  IF A LIMB IS NAMED ABOVE, check first whether the scanner was taught to" >&2
    echo "  IGNORE the canary rather than losing the ability to see it -- that is how" >&2
    echo "  this broke once already. A canary must be a value the scanner is required" >&2
    echo "  to FIND, never one it is required to FORGIVE, so a reserved-for-fiction" >&2
    echo "  range cannot serve here. Use a structurally non-assignable value instead." >&2
    exit 2
fi

CHANGED="$SRC.changed"
grep -E '^[+-]' "$NEW_PATCH" | grep -vE '^(\+\+\+|---)' | sed -E 's/^[+-]//' > "$CHANGED" 2>/dev/null || true
if [ -s "$CHANGED" ]; then
    pii_scan_files "$CHANGED" > "$SRC.pii" 2>&1 || true
    if [ -s "$SRC.pii" ]; then
        echo "" >&2
        echo "REFUSED: the patch this would record carries PII-shaped content." >&2
        echo "" >&2
        echo "  Pattern names only -- the values are deliberately NOT printed:" >&2
        cut -d: -f1 "$SRC.pii" 2>/dev/null | sort -u | sed 's/^/    /' | head -20 >&2
        echo "" >&2
        echo "  This is the case the tool exists to prevent, and the likely location is" >&2
        echo "  the MINUS side: upstream still carries the value, the vendored tree has" >&2
        echo "  it scrubbed. Recording that publishes it back into a public repo." >&2
        echo "" >&2
        echo "  Do NOT re-sync to clear this. A re-sync deletes the vendored side, which" >&2
        echo "  is where the scrub lives. Remove the PII from the SOURCE, re-pin, and" >&2
        echo "  bring the graft forward; or keep the divergence unrecorded until you can." >&2
        exit 1
    fi
fi

# --- SHOW what is about to be blessed ----------------------------------------
echo "PII control   : fired on a synthetic known-bad value, so the clean result means something"
echo "PII scan      : $(wc -l < "$CHANGED" | tr -d ' ') changed line(s) scanned, both signs, no hits"
echo "                SURFACE: numeric shapes only (phone / SSN / long numeric id)."
echo "                This scan CANNOT see a person name. For names the answer is"
echo "                UNKNOWN, not clean -- see tests/vendor_person_name_sweep.py."
echo ""
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
