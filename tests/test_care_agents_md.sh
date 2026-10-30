#!/usr/bin/env bash
# test_care_agents_md.sh -- care rules (AGENTS.md) + offline local helpline.
#
# Runs the REAL care/write_agents_md.sh against the REAL template and table,
# and runs the REAL install.sh fresh-install and upgrade blocks (extracted by
# marker, not re-typed) in a sandbox with HOME=$(mktemp -d). No network, no
# keychain, no launchctl.
#
# CAN FAIL: removing the helpline line from the written file, a placeholder
# left unrendered, a VERIFY row shipping, or the write landing after the
# daemon start all turn this red (see the mutation runs in the PR).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/.."
CARE="${ROOT}/care"
INSTALL_SH="${ROOT}/install.sh"
WRITER="${CARE}/write_agents_md.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="${TMP}/home"; mkdir -p "$HOME"

tab="$(printf '\t')"
# helpline text for an ISO row, read straight from the shipped table
row_col() { awk -F'\t' -v iso="$1" -v col="$2" '$1 == iso { print $col; exit }' "${CARE}/helplines.tsv"; }

echo "== writer: every CONFIRMED region gets its own line, nothing else does =="
confirmed=0; shipped_wrong=0
for iso in $(awk -F'\t' '$1 !~ /^#/ && $1 != "" && $1 != "ZZ" { print $1 }' "${CARE}/helplines.tsv"); do
    flag="$(row_col "$iso" 7)"; line="$(row_col "$iso" 2)"
    out="${TMP}/w_${iso}"
    bash "$WRITER" "$CARE" "$iso" "$out" >/dev/null 2>&1 || { bad "writer failed for ${iso}"; continue; }
    if [[ "$flag" == "CONFIRMED" ]]; then
        confirmed=$((confirmed+1))
        grep -qF -- "$line" "${out}/AGENTS.md" || { bad "${iso}: helpline line missing from AGENTS.md"; shipped_wrong=1; }
    else
        grep -qF -- "$line" "${out}/AGENTS.md" && { bad "${iso}: unconfirmed row (${flag}) shipped"; shipped_wrong=1; }
    fi
done
[[ $confirmed -ge 10 ]] && ok "confirmed regions exercised: ${confirmed}" || bad "too few confirmed regions exercised: ${confirmed}"
[[ $shipped_wrong -eq 0 ]] && ok "CONFIRMED rows ship, others do not (denominator ${confirmed} confirmed)"

echo "== writer: content contract =="
bash "$WRITER" "$CARE" gb "${TMP}/gb" >/dev/null 2>&1
F="${TMP}/gb/AGENTS.md"
grep -qF -- "$(row_col GB 2)" "$F" && ok "GB: Samaritans line present (lowercase region accepted)" || bad "GB: helpline line missing"
grep -q '^# Care rules' "$F" && ok "capability pattern '# Care rules' present" || bad "'# Care rules' heading missing"
grep -q '{{' "$F" && bad "unrendered placeholder" || ok "no unrendered placeholder"
grep -qi 'hurt themselves' "$F" && grep -qi 'specific real person' "$F" && grep -qi 'Never give operational help\|Never give methods' "$F" \
    && ok "refuses operational help to self-harm and to hurting a real person" || bad "operational-help refusal missing"
grep -qi 'Talk them down' "$F" && ok "talk-down rule present" || bad "talk-down rule missing"
grep -qi 'Never report venting' "$F" && ok "venting never reported" || bad "venting rule missing"
grep -qi 'leaves this Mac' "$F" && ok "nothing leaves the Mac" || bad "nothing-leaves-the-Mac missing"
# emergency numbers marked * in the table were not seen on a source page: never shipped
grep -q '999' "$F" && bad "unverified emergency number 999 shipped" || ok "unverified (*) emergency number not shipped; generic line used"

echo "== writer: unknown / unconfirmed regions fall back to the number-free line =="
zz="$(row_col ZZ 2)"
for r in ZZ XX "" AU MX CN 99; do
    bash "$WRITER" "$CARE" "$r" "${TMP}/fb_${r:-empty}" >/dev/null 2>&1
    g="${TMP}/fb_${r:-empty}/AGENTS.md"
    if grep -qF -- "$zz" "$g" && ! grep -Eq 'Samaritans|988|13 11 14|800 911' "$g"; then ok "region '${r:-empty}' -> generic fallback"; else bad "region '${r:-empty}' did not fall back"; fi
done

echo "== writer: no third-party directory reference anywhere in care/ =="
if grep -rqi 'findahelpline' "$CARE"; then bad "findahelpline reference in care/"; else ok "no findahelpline reference in care/"; fi

echo "== writer: fail closed =="
mkdir -p "${TMP}/ws_keep"; printf 'previous\n' > "${TMP}/ws_keep/AGENTS.md"
bash "$WRITER" "${TMP}/nonexistent" GB "${TMP}/ws_keep" >/dev/null 2>&1; rc=$?
{ [[ $rc -eq 2 ]] && [[ "$(cat "${TMP}/ws_keep/AGENTS.md")" == "previous" ]]; } && ok "missing inputs: rc 2, existing file untouched" || bad "missing inputs: rc=${rc} or file clobbered"

# Extract a block from the real install.sh: from the line matching $1 through
# the first later line matching $2.
extract() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f&&index($0,e){exit}' "$INSTALL_SH"; }

echo "== fresh install: the real install.sh block writes AGENTS.md =="
fresh_blk="$(extract 'bash "${SCRIPT_DIR}/care/write_agents_md.sh"' 'Could not write the care rules')"
[[ -n "$fresh_blk" ]] || bad "fresh block not found in install.sh"
SD="${TMP}/script_dir"; mkdir -p "$SD"; cp -R "$CARE" "${SD}/care"
FWS="${TMP}/fresh/assistant-config/workspace"
( ok(){ echo "OKCALLED"; }; warn(){ echo "WARNCALLED"; }
  SCRIPT_DIR="$SD"; OSTLER_REGION_ISO="US"; ASSISTANT_WORKSPACE_DIR="$FWS"
  eval "$fresh_blk" ) > "${TMP}/fresh.out" 2>&1
grep -q OKCALLED "${TMP}/fresh.out" && grep -qF -- "$(row_col US 2)" "${FWS}/AGENTS.md" \
    && ok "fresh: US box has the 988 line in AGENTS.md" || bad "fresh: AGENTS.md missing or wrong ($(cat "${TMP}/fresh.out"))"
( ok(){ echo "OKCALLED"; }; warn(){ echo "WARNCALLED"; }
  SCRIPT_DIR="${TMP}/no_care_here"; OSTLER_REGION_ISO="US"; ASSISTANT_WORKSPACE_DIR="${TMP}/fresh2"
  eval "$fresh_blk" ) > "${TMP}/fresh2.out" 2>&1
grep -q WARNCALLED "${TMP}/fresh2.out" && ! grep -q OKCALLED "${TMP}/fresh2.out" && [[ ! -e "${TMP}/fresh2/AGENTS.md" ]] \
    && ok "fresh: missing care/ warns loudly, no silent ok" || bad "fresh: missing care/ not surfaced"

echo "== upgrade: the real install.sh block rewrites AGENTS.md from the payload =="
up_blk="$(extract '(2b) Care rules' '_upg_log "ERROR: care rules')"
up_blk="${up_blk}"$'\n'"        fi"
[[ -n "$up_blk" ]] || bad "upgrade block not found in install.sh"
PAY="${TMP}/payload"; mkdir -p "${PAY}/services"; cp -R "$CARE" "${PAY}/services/care"
UOH="${TMP}/uhome/.ostler"; mkdir -p "${UOH}/posture" "${UOH}/assistant-config/workspace"
printf '{\n  "region": "uk",\n  "iso_country": "GB",\n  "source": "manual"\n}\n' > "${UOH}/posture/region.json"
printf 'STALE PRE-CARE FILE\n' > "${UOH}/assistant-config/workspace/AGENTS.md"
run_upgrade_blk() {  # $1 = payload dir
    ( _UPG_PAYLOAD="$1"; _UPG_OSTLER_DIR="$UOH"; _UPG_ASSISTANT_CONFIG_DIR="${UOH}/assistant-config"
      OSTLER_UPGRADE_LOG_PATH="${TMP}/upg.log"
      _upg_payload_dir() { local c; for c in "$@"; do [[ -d "${_UPG_PAYLOAD}/${c}" ]] && { printf '%s' "${_UPG_PAYLOAD}/${c}"; return 0; }; done; return 1; }
      _upg_log() { echo "LOG: $*" >> "${TMP}/upg.log"; }
      eval "$up_blk" )
}
: > "${TMP}/upg.log"; run_upgrade_blk "$PAY"
UF="${UOH}/assistant-config/workspace/AGENTS.md"
{ grep -qF -- "$(row_col GB 2)" "$UF" && ! grep -q STALE "$UF"; } \
    && ok "upgrade: stale file replaced, region GB read from posture/region.json" || bad "upgrade: AGENTS.md not rewritten ($(cat "${TMP}/upg.log"))"
rm -f "${UOH}/posture/region.json"; run_upgrade_blk "$PAY"
grep -qF -- "$zz" "$UF" && ok "upgrade: no region.json -> generic fallback" || bad "upgrade: no-region case wrong"
: > "${TMP}/upg.log"; run_upgrade_blk "${TMP}/empty_payload"
grep -q 'ERROR: care rules' "${TMP}/upg.log" && ok "upgrade: payload without care/ logs ERROR" || bad "upgrade: missing payload care/ not surfaced"

echo "== ordering: written BEFORE the daemon starts =="
f_line="$(grep -n 'bash "${SCRIPT_DIR}/care/write_agents_md.sh"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
f_start="$(grep -n 'OSTLER_ASSISTANT_DEFER_START="true"' "$INSTALL_SH" | awk -F: -v w="$f_line" '$1>w{print $1; exit}')"
{ [[ -n "$f_line" && -n "$f_start" && "$f_line" -lt "$f_start" ]]; } && ok "fresh: write (L${f_line}) precedes daemon snippet (L${f_start})" || bad "fresh: ordering (write L${f_line:-?}, start L${f_start:-?})"
u_line="$(grep -n '(2b) Care rules' "$INSTALL_SH" | head -1 | cut -d: -f1)"
u_boot="$(grep -n 'booting out running daemon before swap' "$INSTALL_SH" | head -1 | cut -d: -f1)"
u_plist="$(grep -n '^        _upg_rerender_plists$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
{ [[ -n "$u_line" && "$u_line" -lt "$u_boot" && "$u_boot" -lt "$u_plist" ]]; } && ok "upgrade: write (L${u_line}) precedes bootout (L${u_boot}) and restart (L${u_plist})" || bad "upgrade: ordering wrong"

echo "== shipping: care/ reaches the DMG payload, GUI bundle and tarball =="
grep -q 'cp -R "\$\$CARE_SRC" "\$\$PAYLOAD/services/care"' "${ROOT}/gui/Makefile" && ok "Makefile: payload carries services/care" || bad "Makefile: payload copy missing"
grep -q 'services/care/helplines.tsv' "${ROOT}/gui/Makefile" && ok "Makefile: payload completeness check names care files" || bad "Makefile: completeness check missing"
grep -q 'Bundle care rules' "${ROOT}/gui/project.yml" && ok "project.yml: GUI bundle phase for care/" || bad "project.yml: bundle phase missing"
grep -q '^    "care"$' "${ROOT}/release.sh" && ok "release.sh: tarball includes care/" || bad "release.sh: care/ missing"

echo "== bash 3.2 / syntax =="
bash -n "$WRITER" && ok "writer parses" || bad "writer syntax error"
if [[ -x /bin/bash ]]; then /bin/bash -n "$WRITER" && ok "/bin/bash -n writer" || bad "/bin/bash parse failed"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
