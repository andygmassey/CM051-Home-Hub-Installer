#!/usr/bin/env bash
#
# scripts/tests/test_ollama_contract_controls.sh
#
# PROVES every limb of tests/test_ollama_install_path_contract.sh can go red,
# and that the limb which used to be blind now discriminates.
#
# The rewritten test replaced one that asserted a RETIRED policy (formula-only)
# and whose cask predicate matched `--cask ollama-app` as a prefix of
# `--cask ollama`. Both halves of that mattered: it fired on a correct tree, and
# it could not have told the two casks apart if it had been right.
#
# A replacement with no evidence it can fail is the same non-instrument in a
# newer file, so each control mutates install.sh along the axis one limb reads:
#
#   0  unmodified                            PASS   (not vacuous)
#   1  bare `ollama` cask reintroduced       FAIL   limb 1, the CX-14 regression
#   2  cask install removed                  FAIL   limb 2
#   3  cask installed twice                  FAIL   limb 2, the divergence risk
#   4  de-quarantine removed                 FAIL   limb 3, THE load-bearing one
#   5  exists-check error code removed       FAIL   limb 4
#   6  OLLAMA_APP_BIN repointed at PATH      FAIL   limb 4
#   7  `open -a Ollama` reintroduced         FAIL   limb 5
#   8  port drifted to 11435                 FAIL   limb 6
#
# Control 1 is the one that would have been impossible before: it renames the
# cask from `ollama-app` to `ollama` and NOTHING ELSE. The old predicate scored
# both spellings identically, so it could not have distinguished the safe path
# from the unsafe one -- it just happened to be shouting at the safe one.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_REL="tests/test_ollama_install_path_contract.sh"
fails=0

pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# $1 label, $2 expected rc, $3.. sed/awk program applied to install.sh
run_control() {
    local label="$1" want="$2"; shift 2
    local dir="$WORK/c$$RANDOM"
    rm -rf "$dir"; mkdir -p "$dir/tests"
    cp "$REPO_ROOT/$TEST_REL" "$dir/tests/"
    if [ "$#" -eq 0 ]; then
        cp "$REPO_ROOT/install.sh" "$dir/install.sh"
    else
        "$@" < "$REPO_ROOT/install.sh" > "$dir/install.sh"
    fi
    # A mutation that did not land exercises nothing. Compare against the
    # original and say so rather than reporting the predicate's verdict on an
    # unmodified file as if it meant something.
    if [ "$#" -gt 0 ] && cmp -s "$REPO_ROOT/install.sh" "$dir/install.sh"; then
        fail "$label -- fixture mutation did not land; control exercised nothing"
        rm -rf "$dir"; return
    fi
    bash "$dir/tests/$(basename "$TEST_REL")" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" = "$want" ]; then
        pass "$label -> rc=$rc"
    else
        fail "$label -> rc=$rc, expected $want"
    fi
    rm -rf "$dir"
}

echo "ollama install path contract: can every limb go red?"

run_control "control 0: unmodified tree                 (expect PASS)" 0

run_control "control 1: bare 'ollama' cask reintroduced (expect FAIL)" 1 \
    sed -E 's#^([[:space:]]*)brew install --cask ollama-app$#\1brew install --cask ollama#'

run_control "control 2: cask install removed            (expect FAIL)" 1 \
    grep -v 'brew install --cask ollama-app'

run_control "control 3: cask installed twice            (expect FAIL)" 1 \
    sed -E 's#^([[:space:]]*)(brew install --cask ollama-app)$#\1\2\n\1\2#'

run_control "control 4: de-quarantine removed           (expect FAIL)" 1 \
    grep -v 'xattr -dr com.apple.quarantine /Applications/Ollama.app'

run_control "control 5: exists-check code removed       (expect FAIL)" 1 \
    sed 's/ERR-07-DMG48-OLLAMA-MISSING-AFTER-BREW/ERR-07-SOMETHING-ELSE/'

run_control "control 6: OLLAMA_APP_BIN repointed        (expect FAIL)" 1 \
    sed -E 's#^OLLAMA_APP_BIN="/Applications/Ollama\.app/Contents/Resources/ollama"#OLLAMA_APP_BIN="ollama"#'

run_control "control 7: 'open -a Ollama' reintroduced   (expect FAIL)" 1 \
    sed -E 's#^([[:space:]]*)(xattr -dr com\.apple\.quarantine.*)$#\1\2\n\1open -a Ollama#'

run_control "control 8: port drifted to 11435           (expect FAIL)" 1 \
    sed 's#localhost:11434/api/tags#localhost:11435/api/tags#g'

echo ""
if [ "$fails" -gt 0 ]; then
    printf '\033[0;31mollama contract controls: %d FAILED\033[0m\n' "$fails"
    exit 1
fi
printf '\033[0;32mollama contract controls: 9/9 -- every limb discriminates, including the two cask names\033[0m\n'
