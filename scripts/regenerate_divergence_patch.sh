#!/usr/bin/env bash
# Record a vendored graft instead of deleting it.
#
# WHY THIS EXISTS
# ---------------
# Before this script, the repo had exactly two vendor-facing tools:
#
#     scripts/sync_vendor.sh          re-vendors from source. DESTRUCTIVE.
#     scripts/verify_vendor_fresh.sh  read-only. reports drift.
#
# So when the freshness gate said a tree diverged, the ONLY remedy the repo
# offered was the one that deletes grafts. That is not a discipline problem, it
# is a missing tool, and it is why "just re-sync from source" keeps suggesting
# itself under time pressure. On 2026-08-15 the gate reported eight divergent
# trees at once and one of them, cm041/identity_resolver, had a divergence patch
# whose last commit was the removal of real family names from a PUBLIC repo. A
# blind re-sync there re-publishes them.
#
# WHAT THIS DOES, precisely
# -------------------------
# A divergence patch is the recorded delta between upstream source at the
# pinned sha and the vendored copy that actually ships. When someone grafts a
# fix straight into vendor/ and does not regenerate the patch, the tree diverges
# -- not because the vendored tree is wrong, but because the RECORD of it is
# stale. This recomputes that record.
#
# IT CHANGES NO SHIPPED BYTES. The vendored tree is read, never written. Only
# vendor/divergences/<tree>.patch changes. That is the entire point: the graft
# becomes recorded rather than deleted.
#
# THE DANGER, stated plainly
# --------------------------
# Regenerating BLESSES whatever is in the vendored tree, including accidental
# drift and including anything an attacker or a bad merge put there. A tool that
# did this silently would be worse than no tool. So:
#
#   * it is DRY RUN by default and prints the full delta it would bless
#   * it refuses outright if the newly-blessed lines carry PII shapes
#   * it carries a positive control for that PII check EVERY RUN, and reports
#     CANNOT-RUN rather than success if the control does not fire
#   * after writing, it RE-RUNS THE GATE and reverts itself if the tree does
#     not then report OK. The proof is the gate's verdict, not this script's
#     confidence.
#
# EXIT CODES. Three states, never two.
#   0  dry run completed, or write completed AND the gate then reported OK
#   1  a real problem: PII in the blessed delta, or the gate still fails after
#      writing (in which case the old patch has been restored)
#   2  CANNOT RUN: unknown tree, unresolvable source repo, missing pinned sha,
#      or the PII positive control did not fire. NOT a pass and NOT a failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# HERE derives from THIS FILE's own path. Running a copy out of /tmp would
# resolve every target outside the repo and produce a clean-looking result off
# an artefact that is not the one under test. Run it in place.

# shellcheck source=/dev/null
. "$HERE/_vendor_lib.sh"
PII_LIB="$REPO_ROOT/.githooks/pii_patterns.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
die2() { printf '%sCANNOT RUN%s  %s\n' "$YEL" "$OFF" "$*" >&2; exit 2; }
die1() { printf '%sREFUSED%s  %s\n'    "$RED" "$OFF" "$*" >&2; exit 1; }

TREE=""; WRITE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --write) WRITE=1 ;;
        -h|--help)
            say "usage: $(basename "$0") <tree-name> [--write]"
            say ""
            say "Recomputes vendor/divergences/<tree>.patch as the delta between"
            say "source@pinned_sha and the vendored tree AS IT STANDS, so a graft"
            say "becomes recorded rather than deleted. Dry run unless --write."
            say ""
            say "Valid tree names:"
            vlib_tree_names | sed 's/^/    /'
            exit 0 ;;
        -*) die2 "unknown flag: $1" ;;
        *)  [ -n "$TREE" ] && die2 "more than one tree name given: '$TREE' and '$1'"; TREE="$1" ;;
    esac
    shift
done
[ -n "$TREE" ] || die2 "no tree name given. Try --help for the list."

# ---- the tree must exist, and say so with the list rather than a bare error --
if ! vlib_tree_names | grep -qxF "$TREE"; then
    say "${RED}CANNOT RUN${OFF}  no tree named '$TREE' in vendor/VENDOR_MANIFEST.toml." >&2
    say "Valid names:" >&2
    vlib_tree_names | sed 's/^/    /' >&2
    exit 2
fi

PINNED="$(vlib_field "$TREE" pinned_sha || true)"
VENDOR_PATH="$(vlib_field "$TREE" vendor_path || true)"
PATCH_REL="$(vlib_field "$TREE" divergence_patch || true)"
[ -n "$PINNED" ]      || die2 "$TREE has no pinned_sha in the manifest."
[ -n "$VENDOR_PATH" ] || die2 "$TREE has no vendor_path in the manifest."
ABS_VENDOR="$REPO_ROOT/$VENDOR_PATH"
[ -d "$ABS_VENDOR" ]  || die2 "$TREE vendor_path does not exist on disk: $VENDOR_PATH"

SRC_REPO="$(resolve_source_repo "$TREE" 2>/dev/null || true)"
if [ -z "$SRC_REPO" ] || [ ! -d "$SRC_REPO" ]; then
    die2 "$TREE source repo did not resolve (manifest says '$(vlib_field "$TREE" source_repo)'). \
The eight \$VAR placeholders are assigned nowhere in this repo; export the one this tree needs. \
Not resolving is UNVERIFIABLE, which is neither fresh nor stale."
fi

# ---- the PII positive control, run BEFORE any verdict is trusted ------------
# The canary is COMPOSED at runtime and never appears as a literal in this file,
# because this repo's own pre-commit hook scans this file and a gate must not
# carry the thing it hunts. OFCOM reserves 07700 900xxx for drama, so the shape
# is provably not a real subscriber while still being the shape the scan hunts.
#
# READ THE CONVENTION BEFORE TRUSTING THE ANSWER. `pii_scan_files` ALWAYS
# `return 0`; it signals findings by PRINTING them. It also returns 0 with no
# output when the pattern file fails to load. So exit code carries NO
# information here, and a predicate that tests it reads every run as clean.
# This function was written that way first and the control below is what caught
# it. Findings are judged by NON-EMPTY OUTPUT, never by rc.
control_fires() {
    [ -f "$PII_LIB" ] || return 2
    # shellcheck source=/dev/null
    . "$PII_LIB" || return 2
    local d canary out
    d="$(mktemp -d -t regen-control-XXXXXX)" || return 2
    canary="+44$(printf '%s%s' '77009000' '00')"
    printf 'phone = "%s"\n' "$canary" > "$d/canary.txt"
    out="$(pii_scan_files "$d/canary.txt" 2>&1)"
    rm -rf "$d"
    [ -n "$out" ]               # non-empty output == the scanner fired, as it must
}
if ! control_fires; then
    die2 "the PII positive control did NOT fire. Either .githooks/pii_patterns.sh is \
missing or its patterns no longer match a known-bad synthetic value. A PII check that \
cannot be shown to fire is not evidence of absence, so nothing is blessed."
fi

# ---- materialise source@pinned_sha ------------------------------------------
TMP="$(mktemp -d -t regen-XXXXXX)" || die2 "could not create a temp dir"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

if ! vlib_materialise "$TREE" "$TMP" 2>"$TMP.mat.err"; then
    say "${YEL}CANNOT RUN${OFF}  could not materialise $TREE at $PINNED:" >&2
    sed -n '1,10{s/^/    /;p;}' "$TMP.mat.err" >&2
    exit 2
fi

NEWPATCH="$TMP.new.patch"
if ! vlib_vendor_diff "$TREE" "$TMP" "$ABS_VENDOR" "$NEWPATCH"; then
    :   # non-zero simply means "there is drift", which is why we are here
fi
if [ ! -s "$NEWPATCH" ]; then
    say "${GRN}NOTHING TO DO${OFF}  $TREE already reconstructs from source@${PINNED:0:8} with no delta."
    say "If the gate calls this tree divergent, the cause is elsewhere: check the"
    say "'source advanced past pinned_sha' limb, which is a re-pin question, not a patch one."
    exit 0
fi

# ---- what is NEWLY blessed, relative to the patch already recorded ----------
OLDPATCH="$REPO_ROOT/$PATCH_REL"
DELTA="$TMP.delta"
if [ -f "$OLDPATCH" ]; then
    diff -u "$OLDPATCH" "$NEWPATCH" > "$DELTA" 2>/dev/null || true
else
    cp "$NEWPATCH" "$DELTA"
fi
ADDED="$TMP.added"
grep -E '^\+' "$DELTA" | sed 's/^\+//' > "$ADDED" 2>/dev/null || true

# ---- refuse if the newly-blessed lines carry PII shapes ---------------------
# Scanning the ADDED lines, not the whole patch: pre-existing recorded content
# is an audit question, and scanning it whole is how a two-line change goes red
# on strings that have been in the tree for months.
if [ -s "$ADDED" ]; then
    # Non-empty output means a hit. NOT the exit code: see control_fires above.
    pii_scan_files "$ADDED" > "$TMP.pii" 2>&1 || true
    if [ -s "$TMP.pii" ]; then
        say "${RED}REFUSED${OFF}  the delta this would bless carries PII-shaped content."
        say "Categories and locations only. The values are deliberately NOT printed:"
        sed -E 's/[[:print:]]*$//; s/^/    /' "$TMP.pii" | head -20
        say ""
        say "Locations, by pattern name only:"
        cut -d: -f1 "$TMP.pii" 2>/dev/null | sort -u | sed 's/^/    /' | head -20
        say ""
        say "This is the case the tool exists to prevent. Do NOT re-sync to clear it:"
        say "a re-sync deletes the vendored side, which is where scrubs live. Read the"
        say "delta, remove the PII from the VENDORED tree, then run this again."
        exit 1
    fi
fi

# ---- report ----------------------------------------------------------------
n_files="$(grep -cE '^(diff --git|--- )' "$NEWPATCH" 2>/dev/null || echo 0)"
n_add="$(grep -cE '^\+[^+]' "$NEWPATCH" 2>/dev/null || echo 0)"
n_del="$(grep -cE '^-[^-]' "$NEWPATCH" 2>/dev/null || echo 0)"
say "tree            $TREE"
say "source          $SRC_REPO @ ${PINNED:0:8}"
say "vendored        $VENDOR_PATH   (READ ONLY; this tool never writes here)"
say "patch file      $PATCH_REL"
say "new patch       ${n_files} file section(s), +${n_add}/-${n_del}"
say "PII control     fired on a synthetic known-bad value, so the clean result means something"
say ""
say "=== THE FULL DELTA THIS WOULD BLESS (old recorded patch -> new) ==="
cat "$DELTA"
say "=== END DELTA ==="
say ""

if [ "$WRITE" -eq 0 ]; then
    say "${YEL}DRY RUN. Nothing written.${OFF}"
    say "Read the delta above. Every line of it becomes an officially recorded"
    say "divergence, which means no future gate will ever question it again."
    say "If it is right: re-run with --write"
    exit 0
fi

# ---- write, then PROVE it with the gate, and revert if it did not work ------
BACKUP=""
if [ -f "$OLDPATCH" ]; then
    BACKUP="$TMP.backup.patch"
    cp "$OLDPATCH" "$BACKUP"
fi
mkdir -p "$(dirname "$OLDPATCH")"
cp "$NEWPATCH" "$OLDPATCH"
ensure_manifest_patch_ref "$TREE" 2>/dev/null || true

say "wrote $PATCH_REL. Now proving it with the gate rather than asserting it."
GATE_OUT="$TMP.gate"
bash "$HERE/verify_vendor_fresh.sh" > "$GATE_OUT" 2>&1
if grep -qE "^OK[[:space:]]+$TREE[[:space:]]" "$GATE_OUT"; then
    say "${GRN}PROVEN${OFF}  the gate now reports OK for $TREE:"
    grep -E "^OK[[:space:]]+$TREE[[:space:]]" "$GATE_OUT" | sed 's/^/    /'
    say ""
    say "Note: the gate's overall verdict may still be RED because of OTHER trees."
    say "That is correct and is not this tree's problem."
    exit 0
fi

say "${RED}REVERTING${OFF}  the gate does NOT report OK for $TREE after the write:"
grep -E "^(FAIL|WARN)[[:space:]]+$TREE[[:space:]]" "$GATE_OUT" | sed -n '1,6{s/^/    /;p;}'
if [ -n "$BACKUP" ]; then
    cp "$BACKUP" "$OLDPATCH"
    say "restored the previous $PATCH_REL"
else
    rm -f "$OLDPATCH"
    say "removed the patch file this run created (there was none before)"
fi
say ""
say "Regenerating did not reconcile this tree, which means the divergence is not"
say "merely an unrecorded graft. The likely cause is the 'source advanced past"
say "pinned_sha' limb: that is a RE-PIN plus a re-graft, not a patch regeneration."
exit 1
