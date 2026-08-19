#!/usr/bin/env bash
#
# tests/test_gen_patch_new_files.sh
#
# THE RECONSTRUCTION PROOF for vendor-only new files.
#
# WHY THIS EXISTS
#
#   The vendored tree is meant to be reproducible as source@pinned_sha plus a
#   divergence patch. That was true only for files present in BOTH trees.
#   `vlib_shared_diff` iterated the vendored tree and skipped anything the
#   source lacked, so a file grafted ahead of a held pin had NO durable home:
#
#     * the swap (rm -rf + untar) deletes it, every sync;
#     * --regen-patch would not describe it, so the patch could not put it back;
#     * VENDOR_ONLY.tsv cannot honestly take it either, because that registry
#       means "no upstream counterpart" and a graft-ahead-of-pin file HAS one,
#       just not at the pin. A row there is a false declaration that masks real
#       drift.
#
#   That is why the old daemon_cron.py hunks are gone, and it is what blocked
#   the WhatsApp pair-code reader from reaching a customer.
#
#   `vlib_vendor_diff` now emits git new-file hunks for vendor-only files. This
#   test proves the round trip: source@sha + patch reconstructs the tree
#   BYTE-FOR-BYTE including the new file.
#
# WHAT IS ASSERTED, and each one has a demonstrated failure mode:
#   1. a vendor-only file produces a new-file hunk
#   2. `git apply` of that patch CREATES the file with identical bytes
#   3. an EXCLUDED file does NOT get a hunk (or the exclude glob is defeated
#      and every materialise resurrects content the tree deliberately drops)
#   4. modified shared files still produce ordinary hunks (no regression)
#   5. an identical tree still reports "no divergence" (no false patch)
#   6. vlib_patch_new_files names only files the patch CREATES, not every file
#      it touches

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
VLIB_REPO_ROOT="$REPO_ROOT"
. "$REPO_ROOT/scripts/_vendor_lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL [$1]: $2" >&2; exit 1; }

# ── Fixture: a source tree and a vendored tree that diverges from it ──
SRC="$TMP/src"; VEN="$TMP/ven"
mkdir -p "$SRC/agent" "$VEN/agent" "$SRC/tests" "$VEN/tests"

printf 'shared, unchanged\n'            > "$SRC/agent/same.py"
cp "$SRC/agent/same.py"                   "$VEN/agent/same.py"

printf 'line one\nline two\n'           > "$SRC/agent/modified.py"
printf 'line one\nline two CHANGED\n'   > "$VEN/agent/modified.py"

# The subject: present in vendor, absent from source. Contents deliberately
# include a quote, a tab and a trailing-newline-less final line, because a
# byte-for-byte claim that only ever sees plain ASCII is a weak claim.
printf 'def f():\n\treturn "vendor only"\n' > "$VEN/agent/grafted.py"

# An excluded file present in vendor. Must NOT be resurrected by the patch.
printf 'excluded content\n'             > "$VEN/tests/test_thing.py"

# vlib_excludes reads the manifest; stub it for the fixture tree.
vlib_excludes() { printf 'tests/\n'; }

OUT="$TMP/doctor.patch"
rc=0
vlib_vendor_diff "fixture" "$SRC" "$VEN" "$OUT" || rc=$?
[ "$rc" = "1" ] || fail drift-rc "expected drift rc=1, got rc=$rc"
echo "PASS: divergence detected"

# ── 1. the vendor-only file produced a new-file hunk ─────────────────
grep -q '^--- /dev/null$' "$OUT" \
    || fail new-file-hunk "no new-file hunk in the patch; a grafted file has no durable home"
grep -q '^+++ b/agent/grafted.py$' "$OUT" \
    || fail new-file-target "the new-file hunk does not name agent/grafted.py"
echo "PASS: vendor-only file emitted a new-file hunk"

# ── 3. the excluded file did NOT ─────────────────────────────────────
# Checked before the apply, because if it IS in the patch the apply below
# would "succeed" and the reconstruction would still compare equal, hiding it.
if grep -q 'tests/test_thing.py' "$OUT"; then
    fail excluded-resurrected \
        "an excluded file got a hunk; every materialise would resurrect content the tree deliberately drops"
fi
echo "PASS: excluded file was not given a hunk"

# ── 4. shared modified file still produces an ordinary hunk ──────────
grep -q '^--- a/agent/modified.py$' "$OUT" \
    || fail shared-hunk "the ordinary modified-file hunk regressed"
echo "PASS: modified shared file still produces an ordinary hunk"

# ── 6. vlib_patch_new_files names creations only ─────────────────────
vlib_field() { [ "$2" = "divergence_patch" ] && printf 'rel.patch\n'; }
VLIB_REPO_ROOT="$TMP"; cp "$OUT" "$TMP/rel.patch"
NEWFILES="$(vlib_patch_new_files fixture)"
VLIB_REPO_ROOT="$REPO_ROOT"

[ "$NEWFILES" = "agent/grafted.py" ] \
    || fail patch-new-files "expected exactly 'agent/grafted.py', got: [${NEWFILES}]"
echo "PASS: vlib_patch_new_files names the created file and only it"

# ── 2. THE RECONSTRUCTION: source + patch == vendor, byte for byte ───
# This is the acceptance criterion. Everything above is a component check.
RECON="$TMP/recon"
cp -R "$SRC" "$RECON"
( cd "$RECON" && git init -q . && git apply --whitespace=nowarn "$OUT" ) \
    || fail apply "git apply of the divergence patch failed"

[ -f "$RECON/agent/grafted.py" ] \
    || fail recon-missing "the patch did not create agent/grafted.py"
cmp -s "$RECON/agent/grafted.py" "$VEN/agent/grafted.py" \
    || fail recon-bytes "reconstructed agent/grafted.py differs from the vendored copy"
cmp -s "$RECON/agent/modified.py" "$VEN/agent/modified.py" \
    || fail recon-modified "reconstructed agent/modified.py differs from the vendored copy"
echo "PASS: source@sha + patch reconstructs the new file byte-for-byte"

# Whole-tree comparison, minus the excluded path and git's own metadata. A
# per-file cmp can pass while the tree has extra or missing files.
rm -rf "$RECON/.git"
DIFF_OUT="$(diff -r --exclude=tests "$RECON" "$VEN" 2>&1 || true)"
[ -z "$DIFF_OUT" ] || fail recon-tree "reconstructed tree differs from the vendored tree:
$DIFF_OUT"
echo "PASS: the whole reconstructed tree matches (excluded path aside)"

# ── 5. an identical tree still reports no divergence ─────────────────
# CONTROL. Without this the new-file logic could report drift on every tree
# forever, and a patch would be written where none is needed.
IDENT="$TMP/ident"
cp -R "$SRC" "$IDENT"
OUT2="$TMP/none.patch"
rc2=0
vlib_vendor_diff "fixture" "$SRC" "$IDENT" "$OUT2" || rc2=$?
[ "$rc2" = "0" ] || fail no-false-drift "identical trees reported drift (rc=$rc2)"
[ ! -s "$OUT2" ] || fail no-false-patch "identical trees produced a non-empty patch"
echo "PASS: identical trees still report no divergence"

echo
echo "ALL GEN_PATCH NEW-FILE TESTS PASSED"
