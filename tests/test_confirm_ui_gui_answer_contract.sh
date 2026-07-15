#!/usr/bin/env bash
#
# tests/test_confirm_ui_gui_answer_contract.sh
#
# Cross-layer contract for the end-of-install "Confirm what we learned"
# GUI screen (gui/OstlerInstaller/Views/ConfirmLearnedView.swift).
#
# The screen answers the four confirmation PROMPTs emitted by
# install.sh's end-of-install block over the gui_read FIFO. Its card
# wire values must therefore stay in lockstep with:
#
#   (a) the gui_read prompt ids install.sh emits,
#   (b) the case arms install.sh matches the answers against, and
#   (c) the decision writer (lib/ostler-confirm-identity.py record)
#       those case arms drive.
#
# Three parts:
#
#   A. STATIC (Swift side) -- the dedicated view exists, is dispatched
#      from OnboardingQuestionView, covers exactly the four prompt ids,
#      carries the pinned wire values, and has its strings in
#      ViewCopy.json (Rule 0.9 -- no hardcoded customer copy).
#
#   B. STATIC (bash side) -- install.sh emits those prompt ids and its
#      case arms accept the GUI's wire values ("y" accepts a collapse,
#      "different" writes the namesake veto, "me" does not).
#
#   C. BEHAVIOURAL (accept/correct -> decision-write) -- replay the
#      exact answer sequence the GUI produces through the same
#      shell-side logic install.sh runs, into the real
#      ostler-confirm-identity.py recorder, and assert what lands in
#      duplicates.yaml:
#        - accept collapse ("y")        -> merge decision written
#        - correct collapse ("n")       -> NO merge decision written
#        - namesake "different"         -> distinct veto written
#        - namesake corrected to "me"   -> NO distinct veto written
#
# All fixtures are SYNTHETIC. No real personal data.
# Exit 0 on clean, 1 on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
ID_PY="$REPO_ROOT/lib/ostler-confirm-identity.py"
VIEW="$REPO_ROOT/gui/OstlerInstaller/Views/ConfirmLearnedView.swift"
DISPATCH="$REPO_ROOT/gui/OstlerInstaller/Views/OnboardingQuestionView.swift"
VIEWCOPY="$REPO_ROOT/gui/OstlerInstaller/Resources/ViewCopy.json"

PY="$(command -v python3)"
fails=0
check() {  # check <desc> <cmd...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf 'ok   %s\n' "$desc"
    else
        printf 'FAIL %s\n' "$desc" >&2
        fails=$((fails + 1))
    fi
}

PROMPT_IDS=(calendar_owner calendar_type identity_collapse identity_namesake)

echo "== A. static (Swift side) =="

check "dedicated view exists" test -f "$VIEW"
check "dispatched from OnboardingQuestionView" \
    grep -q "confirmLearnedPromptIds.contains" "$DISPATCH"

for id in "${PROMPT_IDS[@]}"; do
    check "view covers prompt id: $id" grep -q "\"$id\"" "$VIEW"
done

# The pinned wire values the cards post back over the FIFO.
check "collapse accept card posts 'y'" \
    grep -q 'value: "y"' "$VIEW"
check "collapse reject card posts 'n'" \
    grep -q 'value: "n"' "$VIEW"

# Rule 0.9: the view's customer copy lives in ViewCopy.json.
check "ViewCopy.json has a confirm_learned section" \
    "$PY" -c "import json;d=json.load(open('$VIEWCOPY'));assert isinstance(d['confirm_learned'],dict)"
check "confirm_learned card labels present for every wire value" \
    "$PY" -c "
import json
d = json.load(open('$VIEWCOPY'))['confirm_learned']
need = ['header_label', 'evidence_heading', 'calendar_owner_hint']
need += ['calendar_type_%s_%s' % (t, p)
         for t in ('personal', 'work', 'family', 'shared', 'other')
         for p in ('title', 'subtitle')]
need += ['identity_collapse_%s_%s' % (v, p)
         for v in ('y', 'n') for p in ('title', 'subtitle')]
need += ['identity_namesake_%s_%s' % (v, p)
         for v in ('different', 'me') for p in ('title', 'subtitle')]
missing = [k for k in need if not isinstance(d.get(k), str) or not d[k]]
assert not missing, missing
"

echo "== B. static (bash side) =="

for id in "${PROMPT_IDS[@]}"; do
    check "install.sh emits gui_read prompt id: $id" \
        grep -q "\"$id\"" "$INSTALL_SH"
done

# The case arms the GUI answers land in. Pinned as literal patterns so
# a bash-side rewrite that stops accepting the GUI's wire values fails
# here before it fails on a customer's install.
check "collapse accept arm matches the GUI's 'y'" \
    grep -q 'yes|true|y|Y)' "$INSTALL_SH"
check "namesake veto arm matches the GUI's 'different'" \
    grep -Eq 'different\|no\|n\|N' "$INSTALL_SH"

echo "== C. behavioural: GUI answers -> decision write =="

TMP="$(mktemp -d -t ostler-gui-confirm.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Proposals as install.sh receives them from `propose` (TSV):
#   COLLAPSE  <sids>  <evidence>
#   NAMESAKE  <sids>  <evidence>
# Synthetic short-ids only.
PROPS_TSV="$(printf 'COLLAPSE\taaaa1111,bbbb2222\tshared email domain example.com\nNAMESAKE\taaaa1111,cccc3333\tdifferent LinkedIn profile\n')"

# Replays install.sh's answer-handling loop (the case arms in the
# "Identity collapse / namesake-split confirmation" block) against a
# fixed sequence of GUI answers, then drives the real recorder exactly
# as install.sh does. $1 = collapse answer, $2 = namesake answer,
# $3 = corrections dir.
replay_gui_answers() {
    local collapse_answer="$1" namesake_answer="$2" corrections="$3"
    local merge_args=() distinct_args=()
    local kind ids evidence
    while IFS=$'\t' read -r kind ids evidence; do
        [[ -z "${kind:-}" ]] && continue
        case "$kind" in
            COLLAPSE)
                case "$collapse_answer" in
                    yes|true|y|Y) merge_args+=("--merge" "$ids") ;;
                esac
                ;;
            NAMESAKE)
                case "$namesake_answer" in
                    different|no|n|N|"") distinct_args+=("--distinct" "$ids") ;;
                esac
                ;;
        esac
    done <<< "$PROPS_TSV"
    mkdir -p "$corrections"
    if [[ ${#merge_args[@]} -gt 0 || ${#distinct_args[@]} -gt 0 ]]; then
        "$PY" "$ID_PY" record --corrections-dir "$corrections" \
            ${merge_args[@]+"${merge_args[@]}"} \
            ${distinct_args[@]+"${distinct_args[@]}"} >/dev/null
    fi
}

# --- accept path: GUI cards post "y" (combine) + "different" (veto) ---
replay_gui_answers "y" "different" "$TMP/accept"
check "accept: duplicates.yaml written" test -f "$TMP/accept/duplicates.yaml"
check "accept: collapse 'y' recorded a merge decision" \
    "$PY" -c "
import yaml
d = yaml.safe_load(open('$TMP/accept/duplicates.yaml'))
merges = [e['merge'] for e in d['decisions'] if isinstance(e, dict) and 'merge' in e]
assert any(sorted(m) == ['aaaa1111', 'bbbb2222'] for m in merges), merges
"
check "accept: namesake 'different' recorded a distinct veto" \
    "$PY" -c "
import yaml
d = yaml.safe_load(open('$TMP/accept/duplicates.yaml'))
vetos = [e['distinct'] for e in d['decisions'] if isinstance(e, dict) and 'distinct' in e]
assert any(sorted(v) == ['aaaa1111', 'cccc3333'] for v in vetos), vetos
"

# --- correct path: GUI cards post "n" (keep separate) + "me" ---
replay_gui_answers "n" "me" "$TMP/correct"
check "correct: 'n' + 'me' writes NO merge and NO veto" \
    "$PY" -c "
import os, yaml
path = '$TMP/correct/duplicates.yaml'
if os.path.exists(path):
    d = yaml.safe_load(open(path)) or {}
    assert not (d.get('decisions') or []), d
"

# --- mixed path: reject the collapse, keep the veto ---
replay_gui_answers "n" "different" "$TMP/mixed"
check "mixed: 'n' + 'different' writes the veto only" \
    "$PY" -c "
import yaml
d = yaml.safe_load(open('$TMP/mixed/duplicates.yaml'))
kinds = sorted(k for e in d['decisions'] if isinstance(e, dict) for k in e if k in ('merge', 'distinct'))
assert kinds == ['distinct'], kinds
"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "PASS: GUI confirm-screen answer contract verified end to end"
    exit 0
fi
echo "FAIL: $fails check(s) failed" >&2
exit 1
