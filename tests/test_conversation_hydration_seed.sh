#!/usr/bin/env bash
#
# test_conversation_hydration_seed.sh -- BUG-037 (Andy 2026-06-25).
#
# BUG-037: the installer's conversation/citation step ran the FULL
# per-conversation LLM enrichment (~6 qwen calls each, ~250 conversations)
# and looked hung for hours. The agreed fix: do NOT drain it synchronously
# in the installer. The four conversation-bundle LaunchAgents already do
# the heavy enrichment in the BACKGROUND; the installer just (a) seeds a
# small "queued + done per channel" progress signal in seconds and (b)
# stages the shared bump helper so the feeds report progress as they drain.
#
# This guards the SHIPPED install.sh + lib helper + the four vendored feed
# pipelines so a future re-vendor that drops the wiring fails the cut.
#
# Three layers:
#   - structural: install.sh carries the seed block + does NOT block on a
#     synchronous LLM drain in this region.
#   - behavioural: lib/conversation_hydration.py seeds, bumps, derives
#     status, is re-seed-idempotent on `done`, and validates inputs.
#   - wiring: each feed pipeline defines its channel + bumps `done` after a
#     successful dispatch.
#
# Network-free, dependency-free. British English.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_SH="${REPO_ROOT}/install.sh.strings.en-GB.sh"
HELPER="${REPO_ROOT}/lib/conversation_hydration.py"

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "== structural: install.sh seeds (not synchronously drains) =="

grep -q 'conversation_seed' "$INSTALL_SH" \
    && ok "install.sh emits a conversation_seed progress step" \
    || bad "conversation_seed progress step missing"

grep -q 'conversation_hydration.py' "$INSTALL_SH" \
    && ok "install.sh references the shared progress helper" \
    || bad "install.sh does not reference conversation_hydration.py"

# The helper must be STAGED to ~/.ostler/lib so the background feeds (which
# run from their own service dirs long after install) can load it.
grep -q 'cp -f "\$_conv_seed_helper" "\${HOME}/.ostler/lib/conversation_hydration.py"' "$INSTALL_SH" \
    && ok "install.sh stages the helper to ~/.ostler/lib for the feeds" \
    || bad "install.sh does not stage the helper to ~/.ostler/lib"

# All four channels must be seeded.
_seed_misses=0
for ch in imessage whatsapp email spoken; do
    grep -q "_conv_seed_channel ${ch} " "$INSTALL_SH" || _seed_misses=$((_seed_misses+1))
done
[[ "$_seed_misses" -eq 0 ]] \
    && ok "install.sh seeds all four channels (imessage/whatsapp/email/spoken)" \
    || bad "install.sh is missing ${_seed_misses} channel seed call(s)"

# The seed block writes the signal as a sibling of wiki_hydration.json.
grep -q 'conversation_hydration.json' "$INSTALL_SH" \
    && ok "install.sh names the conversation_hydration.json signal" \
    || bad "install.sh does not name conversation_hydration.json"

# Plain-English, benefit-led copy (BUG-039 principle) is locale-driven --
# assert the install.sh call site AND the en-GB catalogue string exist, and
# that the string itself carries no jargon.
grep -q 'MSG_INFO_CONV_SEED_DRAINS_BACKGROUND' "$INSTALL_SH" \
    && grep -q 'MSG_INFO_CONV_SEED_DRAINS_BACKGROUND=' "$STRINGS_SH" \
    && ok "background-drain reassurance is locale-driven" \
    || bad "background-drain reassurance string missing"

# Anti-regression: the seed region must NOT introduce a synchronous LLM
# enrichment loop. It must not call pwg-convo, ollama, or an enrich CLI
# inline in the seed block. Extract the block and grep it.
_seed_block="$(awk '/3.14c-seed/{f=1} f{print} /3.14a-probe Mail content probe/{if(f)exit}' "$INSTALL_SH")"
if printf '%s' "$_seed_block" | grep -Eq 'pwg-convo|ollama|enrich --|process <'; then
    bad "seed block contains a synchronous enrichment call (regression!)"
else
    ok "seed block stays light -- no synchronous pwg-convo/ollama/enrich"
fi
# And it must be cheap: the iMessage backlog probe is a sqlite COUNT, not a
# body read.
printf '%s' "$_seed_block" | grep -q 'sqlite3 -readonly' \
    && ok "iMessage backlog is a cheap sqlite COUNT (no body read)" \
    || bad "iMessage backlog probe is not the expected sqlite COUNT"

echo "== behavioural: helper seeds, bumps, derives status, validates =="

if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP  python3 not available; behavioural checks skipped"
else
    _t="$(mktemp -d)"
    _sig="${_t}/conversation_hydration.json"

    # seed imessage 120 -> draining, done 0
    python3 "$HELPER" --output "$_sig" seed --channel imessage --queued 120 >/dev/null 2>&1
    python3 - "$_sig" <<'PY' && ok "seed writes queued + done=0 + status draining" || bad "seed payload wrong"
import json, sys
d = json.load(open(sys.argv[1]))
c = d["channels"]["imessage"]
assert d["schema"] == 1, d
assert isinstance(d["install_ts"], int) and d["install_ts"] > 0
assert c == {"queued": 120, "done": 0, "status": "draining"}, c
PY

    # bump +3 -> done 3
    python3 "$HELPER" --output "$_sig" bump --channel imessage --done 3 >/dev/null 2>&1
    python3 - "$_sig" <<'PY' && ok "bump increments done" || bad "bump did not increment done"
import json, sys
assert json.load(open(sys.argv[1]))["channels"]["imessage"]["done"] == 3
PY

    # re-seed must NOT lower an existing done
    python3 "$HELPER" --output "$_sig" seed --channel imessage --queued 120 >/dev/null 2>&1
    python3 - "$_sig" <<'PY' && ok "re-seed preserves real progress (done stays 3)" || bad "re-seed clobbered done"
import json, sys
assert json.load(open(sys.argv[1]))["channels"]["imessage"]["done"] == 3
PY

    # done >= queued -> status ready, clamped to queued
    python3 "$HELPER" --output "$_sig" seed --channel email --queued 2 >/dev/null 2>&1
    python3 "$HELPER" --output "$_sig" bump --channel email --done 9 >/dev/null 2>&1
    python3 - "$_sig" <<'PY' && ok "done clamps to queued and status flips to ready" || bad "ready/clamp wrong"
import json, sys
c = json.load(open(sys.argv[1]))["channels"]["email"]
assert c == {"queued": 2, "done": 2, "status": "ready"}, c
PY

    # unknown channel -> rc 2, no write of a phantom channel
    python3 "$HELPER" --output "$_sig" seed --channel bogus --queued 5 >/dev/null 2>&1
    [[ $? -ne 0 ]] && ok "unknown channel rejected (rc != 0)" || bad "unknown channel was accepted"
    python3 - "$_sig" <<'PY' && ok "no phantom channel written" || bad "phantom channel leaked into signal"
import json, sys
assert "bogus" not in json.load(open(sys.argv[1]))["channels"]
PY

    # non-int -> rc 2
    python3 "$HELPER" --output "$_sig" bump --channel email --done abc >/dev/null 2>&1
    [[ $? -ne 0 ]] && ok "non-integer count rejected (rc != 0)" || bad "non-integer count accepted"

    # in-process bump_done_safe swallows a bad output path (feed hot path)
    python3 - <<PY && ok "bump_done_safe swallows write errors (never breaks a feed)" || bad "bump_done_safe raised"
import importlib.util
spec = importlib.util.spec_from_file_location("m", "${HELPER}")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.bump_done_safe("imessage", 1, output="/dev/null/nope/x.json")  # must not raise
PY

    rm -rf "$_t"
fi

echo "== wiring: every feed pipeline reports done after dispatch =="

for feed in imessage email whatsapp spoken; do
    PIPE="${REPO_ROOT}/vendor/${feed}_source/pipeline.py"
    if [[ ! -f "$PIPE" ]]; then
        bad "${feed}: pipeline.py missing"
        continue
    fi
    grep -q "_CONV_CHANNEL = \"${feed}\"" "$PIPE" \
        && ok "${feed}: declares its channel key" \
        || bad "${feed}: channel key not declared / wrong"
    grep -q '_bump_conversation_progress(1)' "$PIPE" \
        && ok "${feed}: bumps done after a successful dispatch" \
        || bad "${feed}: does not bump done after dispatch"
    # The bump must sit on the success path (rc == 0), guarded by not dry_run.
    python3 - "$PIPE" <<'PY' && ok "${feed}: bump is on the dispatch success path" || bad "${feed}: bump not on success path"
import sys, re
src = open(sys.argv[1]).read()
# crude but sufficient: the bump appears after a "dispatched += 1" line.
i = src.find("dispatched += 1")
j = src.find("_bump_conversation_progress(1)")
assert i != -1 and j != -1 and j > i, (i, j)
PY
done

echo
echo "== summary =="
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
