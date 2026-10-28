#!/usr/bin/env bash
# tests/test_model_pull_labels.sh
#
# Copy/markers only. The "Downloading AI models" step pulls two models, each
# with its own 0-100% bar, so the bar visibly restarts. The v1.0.116 walk read
# that as "downloading twice". Each pull is now labelled "N of 2", the sizes
# match the pinned manifests, the time estimate is honest, and the stale
# Gemma Terms warning is gone (the pinned licence layer is Apache-2.0).
#
# rc 0 all hold, rc 1 one does not.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
rc=0
fail() { printf 'FAIL  %s\n' "$*"; rc=1; }
ok()   { printf 'ok    %s\n' "$*"; }

INSTALL="$ROOT/install.sh"
STR="$ROOT/install.sh.strings.en-GB.sh"
HINT="$ROOT/gui/OstlerInstaller/Resources/HintCopy.json"
PINS="$ROOT/docs/model-pins/ollama-0.34.0"
for f in "$INSTALL" "$STR" "$HINT" "$PINS/gemma4_e2b.json" "$PINS/nomic-embed-text_latest.json"; do
    [ -f "$f" ] || { printf 'CANNOT RUN  %s absent\n' "$f"; exit 2; }
done

# 1. The two labels appear, in order, in the ai_models section.
sect="$(awk '/^progress "Downloading AI models/{f=1} /^# ── 3\.10 /{f=0} f{print}' "$INSTALL")"
[ -n "$sect" ] || { echo "CANNOT RUN  ai_models section not found"; exit 2; }
l1="$(printf '%s\n' "$sect" | /usr/bin/grep -n 'MSG_INFO_PULLING_AI_MODEL_1_OF_2' | head -1 | cut -d: -f1)"
l2="$(printf '%s\n' "$sect" | /usr/bin/grep -n 'MSG_INFO_PULLING_AI_MODEL_2_OF_2' | head -1 | cut -d: -f1)"
if [ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ]; then ok "label 1 of 2 (line $l1) precedes 2 of 2 (line $l2)"
else fail "pull labels missing or out of order (1=$l1 2=$l2)"; fi

# Rendered text, with the real size variables.
. "$STR"
EMBED_MODEL_SIZE="$(sed -n 's/^EMBED_MODEL_SIZE="\(.*\)"$/\1/p' "$INSTALL" | head -1)"
t1="$(printf "$MSG_INFO_PULLING_AI_MODEL_1_OF_2" "$EMBED_MODEL_SIZE")"
. "$ROOT/lib/ostler-model-fit.sh" >/dev/null 2>&1
t2="$(printf "$MSG_INFO_PULLING_AI_MODEL_2_OF_2" "$(ostler_model_size_label gemma4:e2b)")"
[ "$t1" = "Downloading AI model 1 of 2 (embedding, ~0.3 GB)" ] && ok "$t1" || fail "label 1 renders '$t1'"
[ "$t2" = "Downloading AI model 2 of 2 (assistant, ~4.6 GB)" ] && ok "$t2" || fail "label 2 renders '$t2'"

# 2. Advertised sizes are not below the pinned manifests (weight layers).
gb() { python3 -I -c '
import json,sys
m=json.load(open(sys.argv[1]))
w=("model","projector","draft")
print("%.1f" % (sum(l["size"] for l in m["layers"] if l["mediaType"].split(".")[-1] in w)/1e9 + 0.04999))' "$1"; }
for pair in "gemma4_e2b.json:$(ostler_model_size_label gemma4:e2b)" "nomic-embed-text_latest.json:$EMBED_MODEL_SIZE"; do
    f="${pair%%:*}"; lbl="${pair#*:}"; need="$(gb "$PINS/$f")"; have="$(printf '%s' "$lbl" | tr -cd '0-9.')"
    # label rounds to 0.1: it must be >= the manifest size rounded half-down
    if awk -v h="$have" -v n="$need" 'BEGIN{exit !(h+0 >= n-0.1)}'; then ok "$f label $lbl vs manifest ~$need"
    else fail "$f label $lbl understates manifest ~$need"; fi
done
fb="$(/usr/bin/grep -A8 -F 'AI_MODEL="gemma4:e2b"' "$INSTALL" | /usr/bin/grep -m1 'AI_MODEL_SIZE=' | sed 's/.*="//;s/".*//')"
[ "$fb" = "$(ostler_model_size_label gemma4:e2b)" ] && ok "fallback ladder agrees ($fb)" || fail "fallback ladder '$fb' != catalogue"

# 3. Stale claims gone.
if /usr/bin/grep -qE '~7 ?GB|15-20 minutes' "$HINT"; then fail "HintCopy still has ~7GB / 15-20 minutes"; else ok "HintCopy has no ~7GB or 15-20 minutes"; fi
/usr/bin/grep -q 'an hour or more' "$HINT" && ok "HintCopy long_running_copy says an hour or more" || fail "HintCopy lacks 'an hour or more'"
if /usr/bin/grep -qE 'Gemma Terms|gemma/terms' "$INSTALL" "$STR"; then fail "Gemma Terms warning still present"; else ok "no Gemma Terms warning"; fi
if /usr/bin/grep -qE '7\.2 GB\)|~7\.2 GB' "$INSTALL" "$STR" "$ROOT/lib/ostler-model-fit.sh"; then fail "~7.2 GB still advertised"; else ok "no ~7.2 GB advertised"; fi

# 4. The pinned licence layer really is Apache (size of the Apache-2.0 text).
lsz="$(python3 -I -c '
import json,sys
m=json.load(open(sys.argv[1]))
print([l["size"] for l in m["layers"] if l["mediaType"].endswith("license")][0])' "$PINS/gemma4_e2b.json")"
[ "$lsz" = "11355" ] && ok "gemma4:e2b licence layer 11355 bytes (digest-verified Apache-2.0 text, 2026-10-22)" || fail "licence layer size changed ($lsz): re-verify Apache-2.0"
exit $rc
