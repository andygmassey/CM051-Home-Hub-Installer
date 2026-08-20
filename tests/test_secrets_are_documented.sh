#!/usr/bin/env bash
# EVERY SECRET A WORKFLOW REFERENCES MUST HAVE A ROW IN .github/SECRETS.md.
#
# WHY THIS EXISTS. Measured 2026-08-20: CM051_RELEASES_READ was wired at four
# sites and reading FROM ostler-ai releases, while the publish counterpart was
# never connected to anything at all. The read half worked. The write half did
# not exist. Nothing anywhere compared the two, so nothing ever said so. The
# result was 37 cut tags and ZERO release objects: every cut produced a signed,
# notarised artefact that no customer could obtain, and ostler.ai/install.dmg
# returned 404 to anyone who had paid.
#
# A register nobody is forced to update rots. This is the forcing function. It
# does not check that a secret's VALUE is set (it cannot, and must not: secrets
# are unreadable by design). It checks that a human wrote down what the wire is
# for and what breaks without it, which is the thing that was missing.
#
# TWO CONTROLS, BOTH REQUIRED, BOTH FATAL IF THEY FAIL.
#   POSITIVE: the extractor must find a secret KNOWN to be referenced. A
#     predicate that finds nothing may simply be blind, and this gate's whole
#     output is a set of absence claims.
#   NEGATIVE: a seeded undocumented secret must be FLAGGED. A gate that cannot
#     fail is green forever and proves nothing.
# Both were earned. The first draft of the extractor matched the substring
# `secrets.sh` inside `bin/require_signing_secrets.sh` and reported a phantom
# secret named `sh`. Hence the expression-context requirement below.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

WF_DIR=".github/workflows"
DOC=".github/SECRETS.md"

pass=0
fail=0
ok()   { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
info() { printf '        %s\n' "$*"; }

printf '\n=== secrets-are-documented ===\n\n'

# --- extractor ---------------------------------------------------------------
# A secret reference is only real inside a ${{ }} expression. Matching the bare
# substring `secrets.NAME` also matches filenames and prose, which is how the
# phantom `sh` above got in. Two greps: isolate expressions, then read names
# out of them.
extract_secrets() {
    grep -rhoE '\$\{\{[^}]*\}\}' "$1" 2>/dev/null \
        | grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' \
        | sed 's/^secrets\.//' \
        | sort -u
}

# GITHUB_TOKEN is minted per-run by Actions. It is not stored, cannot be
# rotated, and has no owner to document, so it is excluded BY NAME and for a
# stated reason rather than silently filtered.
is_exempt() { [ "$1" = "GITHUB_TOKEN" ]; }

# --- denominator -------------------------------------------------------------
# A gate that examined nothing reports clean. Print what was examined.
if [ ! -d "$WF_DIR" ]; then
    bad "workflow dir ${WF_DIR} does not exist. This gate examined NOTHING."
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
WF_COUNT="$(find "$WF_DIR" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) | wc -l | tr -d ' ')"
info "workflow files examined: ${WF_COUNT}"
if [ "$WF_COUNT" -eq 0 ]; then
    bad "zero workflow files found under ${WF_DIR}. A zero denominator reads as success; it is not one."
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
ok "denominator non-zero (${WF_COUNT} workflow files)"

[ -f "$DOC" ] || { bad "${DOC} is missing. Every secret is undocumented by definition."; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }

# --- what the doc documents --------------------------------------------------
# Rows are `### NAME`, and a row may cover a pair: `### NAME_A / NAME_B`.
documented() {
    grep -E '^### ' "$DOC" | sed 's/^### //' | tr '/' '\n' | tr -d ' ' | grep -v '^$' | sort -u
}
DOC_NAMES="$(documented)"
DOC_COUNT="$(printf '%s\n' "$DOC_NAMES" | grep -c . || true)"
info "documented rows: ${DOC_COUNT}"

# --- POSITIVE CONTROL --------------------------------------------------------
# CM051_RELEASES_READ is referenced by cut.yml at four sites. If the extractor
# cannot see it, the extractor is blind and every absence claim below is void.
FOUND="$(extract_secrets "$WF_DIR")"
CONTROL="CM051_RELEASES_READ"
if printf '%s\n' "$FOUND" | grep -qx "$CONTROL"; then
    ok "POSITIVE CONTROL: extractor found ${CONTROL}, which is known to be referenced"
else
    bad "POSITIVE CONTROL FAILED: extractor did not find ${CONTROL}, which IS referenced in cut.yml."
    info "The extractor is blind. Every result below is void. Fix the extractor, not the doc."
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi

# It must also not hallucinate. `sh` is the phantom the first draft produced.
if printf '%s\n' "$FOUND" | grep -qx 'sh'; then
    bad "extractor produced the phantom secret 'sh' (matched require_signing_secrets.sh). Expression-context guard has regressed."
else
    ok "extractor rejects the 'sh' phantom from require_signing_secrets.sh"
fi

# --- the actual check --------------------------------------------------------
REF_COUNT="$(printf '%s\n' "$FOUND" | grep -c . || true)"
info "secrets referenced by workflows: ${REF_COUNT}"
UNDOCUMENTED=""
for name in $FOUND; do
    is_exempt "$name" && continue
    printf '%s\n' "$DOC_NAMES" | grep -qx "$name" || UNDOCUMENTED="${UNDOCUMENTED}${name} "
done

if [ -z "$UNDOCUMENTED" ]; then
    ok "every referenced secret has a row in ${DOC}"
else
    bad "referenced but NOT documented: ${UNDOCUMENTED}"
    info "Add a row to ${DOC} saying what the wire is for and WHAT BREAKS without it."
    info "NO VALUES. Names and purpose only."
fi

# --- the other direction -----------------------------------------------------
# A row for a secret nothing references is a wire that was removed while the
# doc kept claiming it. Not fatal, because a row may deliberately describe a
# secret that is absent by design, but it must be said out loud.
STALE=""
for name in $DOC_NAMES; do
    printf '%s\n' "$FOUND" | grep -qx "$name" || STALE="${STALE}${name} "
done
if [ -z "$STALE" ]; then
    ok "no stale rows: every documented secret is still referenced"
else
    info "NOTE: documented but referenced by no workflow: ${STALE}"
    info "Either the wire was removed and the row should go, or the row names a secret held elsewhere."
fi

# --- NEGATIVE CONTROL --------------------------------------------------------
# Seed an undocumented secret and require that the logic above would flag it.
# Without this, a gate whose extractor silently returns empty passes forever.
SEED_FILE="${WF_DIR}/__negctl_$$.yml"
cleanup() { rm -f "$SEED_FILE"; }
trap cleanup EXIT
cat > "$SEED_FILE" <<'YAML'
name: negative-control-do-not-commit
on: workflow_dispatch
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ secrets.CM051_NEGATIVE_CONTROL_UNDOCUMENTED }}"
YAML
SEEDED="$(extract_secrets "$WF_DIR")"
if printf '%s\n' "$SEEDED" | grep -qx 'CM051_NEGATIVE_CONTROL_UNDOCUMENTED' \
   && ! printf '%s\n' "$DOC_NAMES" | grep -qx 'CM051_NEGATIVE_CONTROL_UNDOCUMENTED'; then
    ok "NEGATIVE CONTROL: a seeded undocumented secret IS detected, so this gate can fail"
else
    bad "NEGATIVE CONTROL FAILED: seeded undocumented secret was NOT flagged. This gate cannot fail and its green means nothing."
fi
cleanup
trap - EXIT

# The seed file must not survive. A stray workflow in .github/workflows is a
# real workflow to GitHub.
[ -f "$SEED_FILE" ] && bad "negative-control seed file survived at ${SEED_FILE}" || ok "negative-control seed file removed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
