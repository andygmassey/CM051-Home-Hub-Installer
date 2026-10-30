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
# emergency numbers: a sourced row (official URL + date in cols 9, 10) ships its number; a row still marked * never does
grep -qF -- "$(row_col GB 4)" "$F" && [[ -n "$(row_col GB 9)" && -n "$(row_col GB 10)" ]] && ok "GB: sourced emergency number ships ($(row_col GB 4), ${tab}source $(row_col GB 9))" || bad "GB: sourced emergency number missing"
em_bad=0; em_sourced=0; em_star=0
for iso in $(awk -F'\t' '$1 !~ /^#/ && $1 != "" && $1 != "ZZ" && $7 == "CONFIRMED" { print $1 }' "${CARE}/helplines.tsv"); do
    em="$(row_col "$iso" 4)"; g="${TMP}/w_${iso}/AGENTS.md"
    case "$em" in
        *'*') em_star=$((em_star+1)); grep -qF -- "${em%\*}" "$g" && { bad "${iso}: unsourced (*) emergency line shipped"; em_bad=1; } ;;
        *) if [[ -n "$(row_col "$iso" 9)" && -n "$(row_col "$iso" 10)" ]]; then
               em_sourced=$((em_sourced+1)); grep -qF -- "${em}." "$g" || { bad "${iso}: sourced emergency line missing"; em_bad=1; }
           fi ;;
    esac
done
[[ $em_bad -eq 0 && $em_sourced -ge 5 && $em_star -ge 1 ]] && ok "emergency lines: ${em_sourced} sourced rows ship, ${em_star} unsourced (*) rows do not" || bad "emergency lines wrong (sourced ${em_sourced}, star ${em_star})"
for iso in AU CH BE KR; do
    { [[ "$(row_col $iso 7)" == "CONFIRMED" ]] && [[ -n "$(row_col $iso 8)" ]]; } && ok "${iso}: flag is exactly CONFIRMED, caveat in note column" || bad "${iso}: flag/note wrong"
done
for iso in MX PT CN AE EG; do
    [[ "$(row_col $iso 7)" != "CONFIRMED" ]] && ok "${iso}: stays generic (flag $(row_col $iso 7))" || bad "${iso}: unexpectedly CONFIRMED"
done

echo "== writer: unknown / unconfirmed regions fall back to the number-free line =="
zz="$(row_col ZZ 2)"
for r in ZZ XX "" SA MX PT CN AE EG 99; do
    bash "$WRITER" "$CARE" "$r" "${TMP}/fb_${r:-empty}" >/dev/null 2>&1
    g="${TMP}/fb_${r:-empty}/AGENTS.md"
    if grep -qF -- "$zz" "$g" && ! grep -Eq 'Samaritans|988|13 11 14|800 911' "$g"; then ok "region '${r:-empty}' -> generic fallback"; else bad "region '${r:-empty}' did not fall back"; fi
done

echo "== writer: foreign AGENTS.md content is preserved, care block never duplicated =="
PW="${TMP}/pres"; blocks() { grep -c '^# Care rules' "$1"; }
# 1. no file
bash "$WRITER" "$CARE" GB "${PW}/none" >/dev/null 2>&1; N="${PW}/none/AGENTS.md"
{ [[ "$(blocks "$N")" == 1 ]] && [[ "$(head -1 "$N")" == "<!-- OSTLER-CARE-BEGIN -->" ]]; } && ok "preserve 1: no file -> one care block at the top" || bad "preserve 1: no-file case wrong"
# 2. foreign content only
mkdir -p "${PW}/f"; printf '# AGENTS.md -- Wizard Personal Assistant\n\nMY OWN RULE: call me Captain.\n' > "${PW}/f/AGENTS.md"
bash "$WRITER" "$CARE" GB "${PW}/f" >/dev/null 2>&1; FF="${PW}/f/AGENTS.md"
{ [[ "$(blocks "$FF")" == 1 ]] && grep -q 'MY OWN RULE: call me Captain' "$FF" && grep -q 'Wizard Personal Assistant' "$FF"; } && ok "preserve 2: foreign content kept below one care block" || bad "preserve 2: foreign content lost or block count wrong"
care_line="$(grep -n '^# Care rules' "$FF" | cut -d: -f1)"; own_line="$(grep -n 'MY OWN RULE' "$FF" | cut -d: -f1)"
[[ "$care_line" -lt "$own_line" ]] && ok "preserve 2: care block comes first (survives the per-file truncation)" || bad "preserve 2: care block is not first"
# 3. already contains our block: rerun is byte-identical
bash "$WRITER" "$CARE" GB "${PW}/f" >/dev/null 2>&1; a="$(cksum < "$FF")"; bash "$WRITER" "$CARE" GB "${PW}/f" >/dev/null 2>&1; b="$(cksum < "$FF")"
{ [[ "$a" == "$b" ]] && [[ "$(blocks "$FF")" == 1 ]]; } && ok "preserve 3: rerun is idempotent (byte-identical, one block)" || bad "preserve 3: rerun changed the file or duplicated the block"
bash "$WRITER" "$CARE" GB "${PW}/none" >/dev/null 2>&1; c="$(cksum < "$N")"; bash "$WRITER" "$CARE" GB "${PW}/none" >/dev/null 2>&1
[[ "$c" == "$(cksum < "$N")" && "$(blocks "$N")" == 1 ]] && ok "preserve 3: care-only file rerun is byte-identical" || bad "preserve 3: care-only rerun not idempotent"
# 4. our OLD block (other text, other region) plus foreign content, foreign above and below
mkdir -p "${PW}/old"
printf 'ABOVE FOREIGN\n<!-- OSTLER-CARE-BEGIN -->\n# Care rules\nOLD TEXT old helpline 000\n<!-- OSTLER-CARE-END -->\n\nBELOW FOREIGN\n' > "${PW}/old/AGENTS.md"
bash "$WRITER" "$CARE" US "${PW}/old" >/dev/null 2>&1; FO="${PW}/old/AGENTS.md"
{ [[ "$(blocks "$FO")" == 1 ]] && ! grep -q 'OLD TEXT' "$FO" && grep -q 'ABOVE FOREIGN' "$FO" && grep -q 'BELOW FOREIGN' "$FO" && grep -qF -- "$(row_col US 2)" "$FO"; } \
    && ok "preserve 4: old block replaced, foreign content above and below kept" || bad "preserve 4: old block / foreign content wrong"
# 5. damaged file: BEGIN with no END loses nothing foreign
mkdir -p "${PW}/dmg"; printf '<!-- OSTLER-CARE-BEGIN -->\nKEEP ME\n' > "${PW}/dmg/AGENTS.md"
bash "$WRITER" "$CARE" GB "${PW}/dmg" >/dev/null 2>&1
{ grep -q 'KEEP ME' "${PW}/dmg/AGENTS.md" && [[ "$(grep -c 'OSTLER-CARE-BEGIN' "${PW}/dmg/AGENTS.md")" == 1 ]]; } && ok "preserve 5: unterminated marker keeps foreign text" || bad "preserve 5: damaged file lost content"

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
[[ -n "$up_blk" ]] || bad "upgrade block not found in install.sh"
PAY="${TMP}/payload"; mkdir -p "${PAY}/services"; cp -R "$CARE" "${PAY}/services/care"
UOH="${TMP}/uhome/.ostler"; mkdir -p "${UOH}/posture" "${UOH}/assistant-config/workspace"
printf '{\n  "region": "uk",\n  "iso_country": "GB",\n  "source": "manual"\n}\n' > "${UOH}/posture/region.json"
printf 'FOREIGN WIZARD FILE\n' > "${UOH}/assistant-config/workspace/AGENTS.md"
run_upgrade_blk() {  # $1 = payload dir
    ( _UPG_PAYLOAD="$1"; _UPG_OSTLER_DIR="$UOH"; _UPG_ASSISTANT_CONFIG_DIR="${UOH}/assistant-config"
      OSTLER_UPGRADE_LOG_PATH="${TMP}/upg.log"
      _upg_payload_dir() { local c; for c in "$@"; do [[ -d "${_UPG_PAYLOAD}/${c}" ]] && { printf '%s' "${_UPG_PAYLOAD}/${c}"; return 0; }; done; return 1; }
      _upg_log() { echo "LOG: $*" >> "${TMP}/upg.log"; }
      eval "$up_blk" )
}
: > "${TMP}/upg.log"; run_upgrade_blk "$PAY"
UF="${UOH}/assistant-config/workspace/AGENTS.md"
{ grep -qF -- "$(row_col GB 2)" "$UF" && grep -q 'FOREIGN WIZARD FILE' "$UF"; } \
    && ok "upgrade: care block written, foreign file content kept, region GB read from posture/region.json" || bad "upgrade: AGENTS.md not rewritten ($(cat "${TMP}/upg.log"))"
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
