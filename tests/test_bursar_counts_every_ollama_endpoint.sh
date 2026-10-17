#!/usr/bin/env bash
# test_bursar_counts_every_ollama_endpoint.sh (walk #27, Archie)
#
# The Bursar arm compares the journal with the calls Ollama logged. The daemon
# journals every call it makes, including its memory embeds, which go to
# Ollama's OpenAI-compatible /v1/embeddings. A counter that sees only /api/*
# leaves those journal rows with no Ollama line behind them, and with the
# arm two-sided that reads as an over-count. So the counter must count the
# whole set Ollama serves:
#   /api/(embed|embeddings|generate|chat) and /v1/(embeddings|chat/completions|completions)
#
# Runs the EXACT snippet embedded in the probe (extracted, never copied) over
# a synthetic ollama.log, plus a MUTANT that restores the /api-only pattern:
# it must count fewer, or this test proves nothing.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${REPO_ROOT}/scripts/box_walk_probes/probes/hub_screens_customer_read.sh"
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; fail=$((fail+1)); }
[ -f "${PROBE}" ] || { echo "CANNOT-RUN: ${PROBE} absent"; exit 2; }

SNIPPET="$(sed -n '/python3 - <<.PY./,/^PY" >/p' "${PROBE}" | sed '1d;$d')"
[ -n "${SNIPPET}" ] || { echo "CANNOT-RUN: could not extract the embedded python snippet"; exit 2; }

TMPHOME="$(mktemp -d)"
trap 'rm -rf "${TMPHOME}"' EXIT
mkdir -p "${TMPHOME}/.ostler/logs" "${TMPHOME}/.ostler/assistant-config/workspace/state"
T="$(date +%Y/%m/%d' - '%H:%M:%S)"
{
  for ep in /api/chat /api/generate /api/embed /api/embeddings /v1/embeddings /v1/chat/completions /v1/completions; do
    echo "[GIN] ${T} |  200 |   1ms |       127.0.0.1 | POST     \"${ep}\""
  done
  # Not model calls: must NOT be counted.
  echo "[GIN] ${T} |  200 |   1ms |       127.0.0.1 | GET      \"/api/tags\""
  echo "[GIN] ${T} |  200 |   1ms |       127.0.0.1 | POST     \"/api/show\""
  echo "[GIN] ${T} |  200 |   1ms |       127.0.0.1 | GET      \"/v1/models\""
} > "${TMPHOME}/.ostler/logs/ollama.log"
: > "${TMPHOME}/.ostler/assistant-config/workspace/state/costs.jsonl"

count() { HOME="${TMPHOME}" /usr/bin/python3 - <<PYEOF | python3 -c "import json,sys; print(json.load(sys.stdin)['ollama_calls'])"
$1
PYEOF
}

real="$(count "${SNIPPET}")"
[ "${real}" = "7" ] && ok "all 7 model endpoints counted (4 under /api, 3 under /v1); tags/show/models not counted" \
                    || bad "expected ollama_calls=7, got '${real}'"

MUTANT="$(sed 's#POST +\\"/(api/(embed|embeddings|generate|chat)|v1/(embeddings|chat/completions|completions))\\"#POST +\\"/api/(embed|embeddings|generate|chat)\\"#' <<<"${SNIPPET}")"
if [ "${MUTANT}" = "${SNIPPET}" ]; then
  bad "the /api-only mutant did not apply, so this test proves nothing"
else
  mut="$(count "${MUTANT}")"
  [ "${mut}" = "4" ] && ok "MUTANT (/api only, the old pattern) counts 4: the /v1 lines are what it misses" \
                     || bad "mutant counted '${mut}', expected 4"
fi

echo "  passed ${pass}, failed ${fail}"
[ "${fail}" -eq 0 ] || exit 1
exit 0
