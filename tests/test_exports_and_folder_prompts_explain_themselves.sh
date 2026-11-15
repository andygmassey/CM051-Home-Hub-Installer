#!/usr/bin/env bash
# F&F tester report (2026-11-05), items 1 and 2.
#  1. The exports screen ("Have you requested your data exports?") came out of
#     the blue. Its HELP must now open by saying WHAT exports are and that the
#     step can be skipped.
#  2. A line said "macOS is asking permission for X. Click OK." with no button on
#     the installer's own screen, and vanished. macOS draws that dialog, only on
#     the first ask; the installer may not promise a button. The folder pre-warm
#     lines and the Documents pre-prompt must say "if macOS asks".
# Usage: tests/test_exports_and_folder_prompts_explain_themselves.sh [repo_root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FAIL=0; N=0
chk() { N=$((N+1)); if ! "$@"; then FAIL=$((FAIL+1)); fi; }
val() { ( set +u; . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2}\"" ); }
for loc in en-GB en-US; do
  f="${ROOT}/install.sh.strings.${loc}.sh"
  [ -f "$f" ] || { echo "CANNOT-RUN: $f missing"; exit 2; }
  h="$(val "$f" MSG_PROMPT_EXPORTS_ACK_HELP)"
  first="${h%%$'\n'*}"
  [ -n "$h" ] || { echo "CANNOT-RUN: could not read EXPORTS_ACK_HELP from $f"; exit 2; }
  case "$first" in *Google*Meta*) ;; *) echo "FAIL ${loc}: first line of EXPORTS_ACK_HELP does not say what exports are"; FAIL=$((FAIL+1));; esac
  case "$first" in *skip*) ;; *) echo "FAIL ${loc}: first line does not say it can be skipped"; FAIL=$((FAIL+1));; esac
  N=$((N+2))
  for k in DOWNLOADS DESKTOP DOCUMENTS; do
    v="$(val "$f" MSG_INFO_FOLDER_PREWARM_$k)"
    [ -n "$v" ] || { echo "CANNOT-RUN: MSG_INFO_FOLDER_PREWARM_$k empty in $f"; exit 2; }
    case "$v" in *"If macOS asks"*) ;; *) echo "FAIL ${loc}: PREWARM_$k does not say 'If macOS asks': $v"; FAIL=$((FAIL+1));; esac
    case "$v" in *"asking permission"*|*"Click OK"*) echo "FAIL ${loc}: PREWARM_$k still promises a button: $v"; FAIL=$((FAIL+1));; esac
    N=$((N+2))
  done
  d="$(val "$f" MSG_INFO_DOCUMENTS_TCC_PRE_PROMPT)"
  case "$d" in *"click Allow"*) echo "FAIL ${loc}: Documents pre-prompt names a button macOS does not draw (Allow)"; FAIL=$((FAIL+1));; esac
  N=$((N+1))
done
# Every other installer locale must carry its OWN translation of the new
# explainer and the folder lines (owner ruling: everything but legal is translated).
en="${ROOT}/install.sh.strings.en-GB.sh"
enfirst="$(val "$en" MSG_PROMPT_EXPORTS_ACK_HELP)"; enfirst="${enfirst%%$'\n'*}"
enfold="$(val "$en" MSG_INFO_FOLDER_PREWARM_DOWNLOADS)"
for f in "${ROOT}"/install.sh.strings.*.sh; do
  loc="${f##*strings.}"; loc="${loc%.sh}"
  case "$loc" in en-GB|en-US) continue;; esac
  h="$(val "$f" MSG_PROMPT_EXPORTS_ACK_HELP)"; first="${h%%$'\n'*}"
  case "$first" in *Spotify*LinkedIn*) ;; *) echo "FAIL ${loc}: exports help does not open with the translated explainer"; FAIL=$((FAIL+1));; esac
  [ "$first" != "$enfirst" ] || { echo "FAIL ${loc}: exports explainer is still English"; FAIL=$((FAIL+1)); }
  [ "$(val "$f" MSG_INFO_FOLDER_PREWARM_DOWNLOADS)" != "$enfold" ] || { echo "FAIL ${loc}: folder pre-warm line is still English"; FAIL=$((FAIL+1)); }
  N=$((N+2))
done
echo "checks=${N} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
