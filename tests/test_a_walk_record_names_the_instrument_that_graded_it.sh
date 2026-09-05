#!/usr/bin/env bash
# A walk record names its SUBJECT six ways and named its INSTRUMENT not at all.
#
# MEASURED on walks/v1.0.68.tsv before this fix. The record carries 18 fields:
#
#   the subject   version, version_source, artefact_sha256,
#                 artefact_sha256_source, box_fp, walked_at
#   the verdict   verdict, qa_exit, pass, fail, cannot_run, broken, measured, ...
#   the instrument   NOTHING.  0 matches for probe_rev|instrument|probes_sha|repo_rev
#
# AND THE PROBES DO NOT COME FROM THE ARTEFACT. In --from-dmg mode ttywalk.sh
# copies the .app Resources VERBATIM ("the box receives what the customer
# receives"), and gui/project.yml mentions box_walk_probes ZERO times. So the
# suite that runs is the one in the operator's checkout: a walk is artefact X
# judged by instrument Y, and only X was ever recorded.
#
# THE CASE THAT FORCED IT. no_person_holds_two_contact_cards gained a
# collision-opportunity measure in #1549. Before it a clean graph printed a bare
# pass; after it the same graph prints EARNED or UNEXERCISED. Both write the same
# `pass` into this record. Reading the file later nobody could tell an earned
# zero from a vacuous one, which is the exact distinction that probe exists to
# make and the one #1543 is closed on.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. British English throughout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
QA="${REPO}/scripts/post_walk_qa.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
cant() { echo "CANNOT-RUN: $*" >&2; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

[ -f "$QA" ] || cant "no post_walk_qa.sh at ${QA}"
command -v git >/dev/null 2>&1 || cant "git is not on PATH; every arm below drives a git-backed resolver"

WORK="$(mktemp -d)" || cant "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

SRC="${WORK}/resolver.sh"
/usr/bin/sed -n '/^_resolve_instrument_rev() {/,/^}/p' "$QA" > "$SRC"
[ -s "$SRC" ] || cant "extracted an empty resolver from post_walk_qa.sh; the anchors moved"

# Drive the REAL resolver against a chosen REPO_ROOT and PATH.
drive() {
    local root="$1" path="${2:-$PATH}"
    PATH="$path" /bin/bash -c "
        REPO_ROOT='${root}'
        . '${SRC}'
        _resolve_instrument_rev
        printf '%s\t%s' \"\$INSTRUMENT_REV\" \"\$INSTRUMENT_SOURCE\"
    " 2>/dev/null
}

# ── 1. this checkout: a real sha, and the source says it is measured ──────────
r="$(drive "$REPO")"; rev="${r%%$'\t'*}"; src="${r#*$'\t'}"
case "$rev" in
    [0-9a-f]*) [ "${#rev}" = "40" ] \
        && ok "this checkout yields a 40-character sha (${rev:0:12}...)" \
        || bad "expected a 40-character sha, got ${#rev} characters: '${rev}'" ;;
    *) bad "this checkout yielded '${rev}', which is not a sha" ;;
esac
case "$src" in
    measured*) ok "and its source says measured: ${src:0:52}..." ;;
    *) bad "source was '${src}', expected it to begin with measured(" ;;
esac

# ── 2. a git repo with UNCOMMITTED probe edits: the sha must be qualified ─────
# A commit id that does not describe the probes that ran is worse than none,
# because it looks authoritative.
FAKE="${WORK}/fake"
mkdir -p "${FAKE}/scripts/box_walk_probes/probes"
git -C "$FAKE" init -q 2>/dev/null || cant "git init failed in the fixture"
git -C "$FAKE" config user.email t@example.invalid
git -C "$FAKE" config user.name  T
printf 'x\n' > "${FAKE}/scripts/box_walk_probes/probes/a.sh"
git -C "$FAKE" add -A >/dev/null 2>&1
git -C "$FAKE" commit -qm init >/dev/null 2>&1 || cant "fixture commit failed"

r="$(drive "$FAKE")"; src_clean="${r#*$'\t'}"
case "$src_clean" in
    *clean*) ok "a clean fixture repo reports the probes clean" ;;
    *) bad "a clean fixture reported '${src_clean}'" ;;
esac

printf 'edited\n' >> "${FAKE}/scripts/box_walk_probes/probes/a.sh"
r="$(drive "$FAKE")"; rev_d="${r%%$'\t'*}"; src_d="${r#*$'\t'}"
case "$src_d" in
    *UNCOMMITTED*) ok "an edited probe tree is NAMED as uncommitted, not hidden behind a clean-looking sha" ;;
    *) bad "an edited probe tree reported '${src_d}' -- the sha would look authoritative while describing a tree that did not run" ;;
esac
# CONTROL: the two sources must DIFFER, or the qualification is decoration.
[ "$src_clean" != "$src_d" ] \
    && ok "CONTROL: clean and dirty produce different sources, so the qualification is load-bearing" \
    || bad "CONTROL: clean and dirty produced the SAME source '${src_d}'"
# and the sha itself is unchanged by a working-tree edit, which is the point
[ -n "$rev_d" ] && ok "CONTROL: the sha is still reported alongside the warning (${rev_d:0:12}...)" \
                || bad "CONTROL: no sha reported for the dirty tree"

# ── 3. not a git checkout at all: unavailable, never a blank ──────────────────
NOGIT="${WORK}/nogit"; mkdir -p "$NOGIT"
r="$(drive "$NOGIT")"; rev_n="${r%%$'\t'*}"; src_n="${r#*$'\t'}"
[ "$rev_n" = "unavailable" ] \
    && ok "a non-repository yields the literal 'unavailable', not an empty field" \
    || bad "a non-repository yielded '${rev_n}'; an absent field leaves a reader inferring"
case "$src_n" in
    unavailable*) ok "and its source explains why: ${src_n:0:46}..." ;;
    *) bad "source was '${src_n}'" ;;
esac

# ── 4. the record must actually CARRY the fields ─────────────────────────────
for f in instrument_rev instrument_source; do
    n="$(/usr/bin/grep -c "printf '${f}" "$QA")"
    [ "${n:-0}" -gt 0 ] \
        && ok "post_walk_qa.sh writes ${f} into the record" \
        || bad "${f} is resolved but never written; the value would exist and no record would carry it"
done

# CONTROL ON THAT: a field known to be written must be found by the same probe,
# or the check above passes for everyone.
n="$(/usr/bin/grep -c "printf 'box_fp" "$QA")"
[ "${n:-0}" -gt 0 ] \
    && ok "CONTROL: the same predicate finds box_fp, a field that has always been written" \
    || bad "CONTROL: the predicate cannot even find box_fp, so its verdicts above mean nothing"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
