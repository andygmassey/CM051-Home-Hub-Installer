#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The AI_MODEL writer/reader contract must stay wired (#259 / v1018-D636).
#
# WHAT BREAKS IF THIS REGRESSES, which is why it is worth a gate:
#
# install.sh picks a model per RAM tier (AI_MODEL, ~line 4710) and pulls THAT
# model. The wiki-compiler container asks Ollama for whatever OLLAMA_MODEL says.
# Those two are joined by a three-link chain:
#
#   1. install.sh WRITES   AI_MODEL=<tier pick>        into the compose .env
#   2. docker-compose.yml  READS  OLLAMA_MODEL=${AI_MODEL:-qwen3.5:9b}
#   3. the heredoc that writes docker-compose.yml is QUOTED (<<'DCEOF'), so
#      that ${...} survives into the file for `docker compose` to interpolate
#      at run time, instead of being expanded (to empty) at write time.
#
# Break ANY link and the reference silently falls back to qwen3.5:9b. On a
# <=23GB Mac the RAM picker chose gemma4:e2b and qwen3.5:9b was never pulled,
# so CM044's compiler hits Ollama with a model that does not exist: roughly
# 2000 404s in a single compile, and Person / Org / Year pages render empty.
#
# Nothing fails loudly. The install succeeds, the compile "runs", the wiki is
# just blank. That is the ships-dark shape, so it gets a gate.
#
# WHY LINK 3 IS ASSERTED SEPARATELY. An UNQUOTED heredoc would expand
# ${AI_MODEL:-qwen3.5:9b} at write time using install.sh's shell var. That
# happens to look right on the operator's machine and bakes a literal into the
# customer's compose file, which then ignores the .env forever. Same visible
# output, completely different behaviour -- exactly the kind of difference a
# text-only check misses.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

PASSED=0
FAILED=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; PASSED=$((PASSED+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

[[ -f "$INSTALL_SH" ]] || { echo "install.sh not found at $INSTALL_SH" >&2; exit 2; }

echo "test_ai_model_env_contract"

# grep -F throughout. A BRE containing ${ parses the brace as an interval
# expression and matches NOTHING, which reads exactly like "the line is gone".
# That false zero cost real time on 2026-08-13; fixed strings cannot do it.

# --- link 1: install.sh writes AI_MODEL into the compose .env -------------
if grep -qF "printf 'AI_MODEL=%s" "$INSTALL_SH"; then
    ok "writer: install.sh writes AI_MODEL= into the compose .env"
else
    bad "writer MISSING: nothing writes AI_MODEL= to the compose .env, so
       OLLAMA_MODEL falls back to qwen3.5:9b, which is not pulled on
       <=23GB Macs -> the wiki compile 404s and renders empty pages."
fi

# --- link 2: the compose service reads it ---------------------------------
if grep -qF 'OLLAMA_MODEL=${AI_MODEL' "$INSTALL_SH"; then
    ok "reader: docker-compose.yml maps OLLAMA_MODEL from \${AI_MODEL}"
else
    bad "reader MISSING: the wiki-compiler service no longer references
       \${AI_MODEL}, so whatever install.sh writes to the .env is ignored."
fi

# --- link 3: the heredoc must be QUOTED so the ${...} survives ------------
HEREDOC_LINE="$(grep -nF 'docker-compose.yml' "$INSTALL_SH" | grep -F '<<' | head -1)"
if [[ -z "$HEREDOC_LINE" ]]; then
    bad "could not find the heredoc that writes docker-compose.yml -- the
       structure changed and link 3 is unverified. NOT a pass."
elif printf '%s' "$HEREDOC_LINE" | grep -qE "<<'[A-Za-z_]+'"; then
    ok "heredoc is QUOTED, so \${AI_MODEL:-...} reaches the compose file intact"
else
    bad "heredoc is UNQUOTED: $HEREDOC_LINE
       \${AI_MODEL:-qwen3.5:9b} would be expanded at WRITE time by install.sh's
       shell and baked as a literal, so the customer's compose file would
       ignore the .env permanently. Looks identical on the operator's machine."
fi

# --- link 2b: reader must sit INSIDE that heredoc, not somewhere else -----
# A reference outside the heredoc would satisfy link 2 while doing nothing.
HD_START="$(grep -nF 'docker-compose.yml' "$INSTALL_SH" | grep -F '<<' | head -1 | cut -d: -f1)"
RD_LINE="$(grep -nF 'OLLAMA_MODEL=${AI_MODEL' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -n "$HD_START" && -n "$RD_LINE" && "$RD_LINE" -gt "$HD_START" ]]; then
    ok "reader sits after the heredoc opener (line $RD_LINE > $HD_START)"
else
    bad "the OLLAMA_MODEL reference is not inside the compose heredoc
       (heredoc opens at ${HD_START:-?}, reference at ${RD_LINE:-none}).
       A reference outside it satisfies a text search and ships nothing."
fi

# --- NEGATIVE CONTROL ------------------------------------------------------
# Prove the checks above can actually fail. Without this the file cannot tell
# a working guard from a guard-shaped no-op.
CTL="$(mktemp)"
grep -vF "printf 'AI_MODEL=%s" "$INSTALL_SH" > "$CTL"
if grep -qF "printf 'AI_MODEL=%s" "$CTL"; then
    bad "CONTROL FAILED: stripping the writer did not remove it from the copy"
else
    ok "CONTROL: removing the writer line makes the writer check fail"
fi
rm -f "$CTL"

echo
if (( FAILED == 0 )); then
    printf '\033[32m%s passed, 0 failed\033[0m\n' "$PASSED"; exit 0
else
    printf '\033[31m%s passed, %s FAILED\033[0m\n' "$PASSED" "$FAILED" >&2; exit 1
fi
