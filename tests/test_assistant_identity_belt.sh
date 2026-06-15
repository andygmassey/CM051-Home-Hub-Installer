#!/usr/bin/env bash
# test_assistant_identity_belt.sh -- v1.0.0 LAST-CUT belts (B1 + B7).
#
# Covers two installer belt-and-braces additions:
#   B1: the installer seeds workspace/IDENTITY.md + SOUL.md from
#       ${ASSISTANT_NAME} (never an engine/product codeword), and
#       overwrites a stale workspace that still carries the codename.
#   B7: the installer writes ${OSTLER_DIR}/.setup-complete so the
#       Doctor opens its dashboard, not the first-run Setup Wizard.
#
# Structural checks assert the shipped install.sh carries the
# constructs; behavioural checks exercise the seed logic in isolation
# so a future edit that breaks the name-templating or the stale-file
# overwrite fails loudly.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== structural: install.sh carries the belts =="
grep -q 'ASSISTANT_WORKSPACE_DIR="${ASSISTANT_CONFIG_DIR}/workspace"' "$INSTALL_SH" \
    && ok "identity belt: workspace dir derived from assistant-config" \
    || bad "identity belt: workspace dir line missing"
grep -q '_identity_name="${ASSISTANT_NAME:-your assistant}"' "$INSTALL_SH" \
    && ok "identity belt: neutral fallback (never a codeword)" \
    || bad "identity belt: neutral fallback missing"
grep -q "grep -qi 'zeroclaw'" "$INSTALL_SH" \
    && ok "identity belt: overwrites a workspace still carrying the codename" \
    || bad "identity belt: stale-codename guard missing"
grep -q 'I am ${_identity_name}, your personal assistant.' "$INSTALL_SH" \
    && ok "identity belt: IDENTITY.md templated from name" \
    || bad "identity belt: IDENTITY.md template missing"
grep -q "printf 'completed\\\\n' > \"\${OSTLER_DIR}/.setup-complete\"" "$INSTALL_SH" \
    && ok "setup-complete belt: writes the Doctor first-run flag" \
    || bad "setup-complete belt: flag write missing"
# The seed text must never hardcode the codename.
if grep -E 'I am ZeroClaw|You are ZeroClaw' "$INSTALL_SH" >/dev/null 2>&1; then
    bad "identity belt: hardcoded ZeroClaw identity string present"
else
    ok "identity belt: no hardcoded ZeroClaw identity string"
fi

echo "== behavioural: seed loop templating + stale overwrite =="
# Faithful reproduction of the install.sh seed loop, run in a sandbox.
seed_identity() {
    local ASSISTANT_NAME="$1" ASSISTANT_WORKSPACE_DIR="$2"
    local _identity_name="${ASSISTANT_NAME:-your assistant}"
    mkdir -p "$ASSISTANT_WORKSPACE_DIR"
    local _idf _idf_path
    for _idf in IDENTITY.md SOUL.md; do
        _idf_path="${ASSISTANT_WORKSPACE_DIR}/${_idf}"
        if [[ -f "$_idf_path" ]] && ! grep -qi 'zeroclaw' "$_idf_path" 2>/dev/null; then
            continue
        fi
        if [[ "$_idf" == "IDENTITY.md" ]]; then
            printf 'I am %s, your personal assistant.\n' "$_identity_name" > "$_idf_path"
        else
            printf 'You are %s, the user'"'"'s personal assistant.\n' "$_identity_name" > "$_idf_path"
        fi
    done
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Named: files carry the name, never the codeword.
seed_identity "Samantha" "$TMP/ws1"
grep -q 'I am Samantha,' "$TMP/ws1/IDENTITY.md" && grep -q 'You are Samantha,' "$TMP/ws1/SOUL.md" \
    && ! grep -qi 'zeroclaw' "$TMP/ws1/IDENTITY.md" "$TMP/ws1/SOUL.md" \
    && ok "named: IDENTITY/SOUL templated from name, codename-free" \
    || bad "named: templating wrong"

# 2. Empty name: neutral fallback, never a codeword.
seed_identity "" "$TMP/ws2"
grep -q 'I am your assistant,' "$TMP/ws2/IDENTITY.md" \
    && ! grep -qi 'zeroclaw' "$TMP/ws2/IDENTITY.md" \
    && ok "empty name: neutral 'your assistant' fallback" \
    || bad "empty name: fallback wrong"

# 3. Stale codename file IS overwritten.
mkdir -p "$TMP/ws3"
printf 'I am ZeroClaw, an autonomous AI agent.\n' > "$TMP/ws3/IDENTITY.md"
seed_identity "Samantha" "$TMP/ws3"
grep -q 'I am Samantha,' "$TMP/ws3/IDENTITY.md" && ! grep -qi 'zeroclaw' "$TMP/ws3/IDENTITY.md" \
    && ok "stale codename file overwritten with the name" \
    || bad "stale codename file NOT overwritten (leak persists)"

# 4. Clean user-edited file is NOT clobbered.
mkdir -p "$TMP/ws4"
printf 'I am Alfred, butler to the family.\n' > "$TMP/ws4/IDENTITY.md"
printf 'You are Alfred.\n' > "$TMP/ws4/SOUL.md"
seed_identity "Samantha" "$TMP/ws4"
grep -q 'I am Alfred,' "$TMP/ws4/IDENTITY.md" \
    && ok "clean user-edited identity left untouched" \
    || bad "clean user-edited identity was clobbered"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
