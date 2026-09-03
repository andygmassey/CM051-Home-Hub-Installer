#!/usr/bin/env bash
#
# test_import_wire_membership.sh -- #617 gate hardening (#616-class, same shape as #1376)
#
# =============================================================================
# THE DEFECT THIS FAILS ON
# =============================================================================
# The install-manifest import_wire rows for #617 used ONE glob over a directory:
#
#     vendor/cm041/contact_syncer/*.py|is_relationship_label   (present in ANY file?)
#
# That is a CARDINALITY test, and A CARDINALITY TEST CANNOT SEE A MISSING MEMBER.
# In the vendored tree it goes GREEN the moment relationship_labels.py -- which
# DEFINES the guard -- is vendored, so every direct name-WRITER (syncer,
# facebook_friends, ...) could lose the guard and the row would still pass.
# A2 mutation-proved that 2026-09-03: strip the guard from every writer and the
# old row stays green via a non-writer that merely names the symbol.
#
# The fix is one row per VENDORED file that WRITES a person pwg:displayName
# literal, each REQUIRING the guard, so a RED names WHICH writer regressed, and
# a renamed/removed writer is CANNOT-RUN, never a silent pass.
#
# =============================================================================
# WHAT THIS TEST DOES
# =============================================================================
# It drives the SHIPPING verifier (scripts/verify_install_manifest.py) against
# FIXTURE source trees via --source-root, so the arms are independent of whether
# the real vendored tree currently carries the guard (it does not, until the
# CM041 #136 re-vendor). Each arm builds a tree, mutates ONE thing, and asserts
# the verifier's exit code AND that a RED names the right file.
#
# Exit codes (from the verifier): 0 clean, 1 a real difference, 2 CANNOT-RUN.
# A difference DOMINATES a CANNOT-RUN, by the verifier's own rule.
#
#   A  baseline: every required writer guarded            -> 0  (the gate CAN pass)
#   B  each writer in turn loses the guard                -> 1, naming THAT writer
#   C  owner_node loses the guard (it is not a contact)   -> 0  (not over-broadened)
#   D  a required writer file is removed (renamed)        -> 2  (empty != satisfied)
#   E  writers unguarded, only relationship_labels has it -> 1  (the OLD false-green,
#                                                                 now caught)
#   F  the positive control (identifier_quality) checked  -> 1 when only it loses it
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$HERE/scripts/verify_install_manifest.py"

# The 7 vendored person-displayName writers the manifest requires (kept in step
# with scripts/install_manifest.tsv; a drift here or there is caught by arm A,
# which fails the moment a required row points at a file this fixture omits).
REQUIRED_WRITERS=(
  vendor/cm041/contact_syncer/syncer.py
  vendor/cm041/contact_syncer/facebook_friends.py
  vendor/cm041/contact_syncer/instagram_social.py
  vendor/cm041/contact_syncer/linkedin_connections.py
  vendor/cm041/contact_syncer/linkedin_career.py
  vendor/cm041/identity_resolver/resolver.py
  vendor/cm041/identity_resolver/batch_resolver.py
)
CONTROL=vendor/ostler_fda/identifier_quality.py
NONWRITER=vendor/cm041/contact_syncer/relationship_labels.py   # DEFINES the guard
OWNER=vendor/cm041/contact_syncer/owner_node.py                # owner's own name

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A file that USES the shared guard in code (regex (?<!\w)is_relationship_label\b).
guarded() {
  mkdir -p "$(dirname "$1")"
  {
    printf '%s\n' "from contact_syncer.relationship_labels import is_relationship_label"
    printf '%s\n' "def build(fn):"
    printf '%s\n' "    if is_relationship_label(fn):"
    printf '%s\n' "        return []"
    printf '%s\n' '    return [f"<uri> pwg:displayName \"{fn}\""]'
  } > "$1"
}
# A file that WRITES a displayName but does NOT use the shared guard. It even
# NAMES the guard in a comment, to prove the comment-stripping enumerator does
# not count a mention as a wiring.
unguarded() {
  mkdir -p "$(dirname "$1")"
  {
    printf '%s\n' "# a displayName writer that forgot is_relationship_label"
    printf '%s\n' "def build(fn):"
    printf '%s\n' '    return [f"<uri> pwg:displayName \"{fn}\""]'
  } > "$1"
}

build_tree() {   # $1 = root; every file guarded to start
  local root="$1" f
  for f in "${REQUIRED_WRITERS[@]}" "$CONTROL" "$NONWRITER" "$OWNER"; do
    guarded "$root/$f"
  done
}

RC=0; OUT=""
run() {   # $1 = root
  RC=0
  OUT="$(python3 "$VERIFY" --only-type import_wire --source-root "$1" 2>&1)" || RC=$?
}

# ---- arm A: baseline GREEN -------------------------------------------------
A="$(mktemp -d)"; build_tree "$A"; run "$A"
if [ "$RC" = "0" ]; then pass "A baseline: every writer guarded -> clean (rc=0)"
else fail "A baseline expected rc=0, got rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
rm -rf "$A"

# ---- arm B: each writer in turn loses the guard -> RED naming it ------------
for w in "${REQUIRED_WRITERS[@]}"; do
  B="$(mktemp -d)"; build_tree "$B"; unguarded "$B/$w"; run "$B"
  base="$(basename "$w")"
  named=0; case "$OUT" in *"$w"*) named=1 ;; esac
  if [ "$RC" = "1" ] && [ "$named" = "1" ]; then pass "B $base unguarded -> RED naming it (rc=1)"
  else fail "B $base expected rc=1 naming $w, got rc=$RC named=$named"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
  rm -rf "$B"
done

# ---- arm C: owner_node unguarded is still GREEN (not in the required set) ---
C="$(mktemp -d)"; build_tree "$C"; unguarded "$C/$OWNER"; run "$C"
if [ "$RC" = "0" ]; then pass "C owner_node unguarded -> still clean (owner is not a contact writer)"
else fail "C expected rc=0 (owner_node not required), got rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
rm -rf "$C"

# ---- arm D: a required writer removed -> CANNOT-RUN, not a silent pass ------
D="$(mktemp -d)"; build_tree "$D"; rm -f "$D/${REQUIRED_WRITERS[0]}"; run "$D"
moved=0; case "$OUT" in *"matched no files"*) moved=1 ;; esac
if [ "$RC" = "2" ] && [ "$moved" = "1" ]; then pass "D writer removed -> CANNOT-RUN (rc=2), the write path moved"
else fail "D expected rc=2 CANNOT-RUN, got rc=$RC moved=$moved"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
rm -rf "$D"

# ---- arm E: the OLD false-green -- writers unguarded, only the definition has
#             the guard. The old *.py glob passed here; membership must RED. ---
E="$(mktemp -d)"; build_tree "$E"
for w in "${REQUIRED_WRITERS[@]}"; do unguarded "$E/$w"; done   # relationship_labels stays guarded
run "$E"
allnamed=1; for w in "${REQUIRED_WRITERS[@]}"; do case "$OUT" in *"$w"*) : ;; *) allnamed=0 ;; esac; done
if [ "$RC" = "1" ] && [ "$allnamed" = "1" ]; then pass "E only the guard-DEFINITION carries it -> RED naming all 7 (old glob's exact false-green, now caught)"
else fail "E expected rc=1 naming all 7 writers, got rc=$RC allnamed=$allnamed"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
rm -rf "$E"

# ---- arm F: the positive control is actually checked -----------------------
F="$(mktemp -d)"; build_tree "$F"; unguarded "$F/$CONTROL"; run "$F"
cnamed=0; case "$OUT" in *"$CONTROL"*) cnamed=1 ;; esac
if [ "$RC" = "1" ] && [ "$cnamed" = "1" ]; then pass "F control identifier_quality unguarded -> RED (the enumerator really checks it)"
else fail "F expected rc=1 naming the control, got rc=$RC cnamed=$cnamed"; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
rm -rf "$F"

echo
if [ "$fails" = "0" ]; then echo "OK -- import_wire membership gate: all arms passed"; exit 0
else echo "FAILED -- $fails arm(s) failed"; exit 1; fi
