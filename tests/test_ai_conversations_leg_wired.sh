#!/usr/bin/env bash
# AI-Conversations install-leg wiring guard (#553 / #613)
# =======================================================
#
# The AI Conversations hydrate leg only helps the customer if the
# shipped install.sh actually wires it -- and only ships SAFELY if it
# stays dark by default on v1.0.x. This guard fails if either
# invariant is lost in a future edit or a stale re-vendor:
#
#   1. ENABLE flag exists and defaults to false (section ships dark).
#   2. The producer run is gated on the flag being exactly "true".
#   3. install.sh invokes the vendored pwg-ai-convo producer with the
#      v1.0.3 contract flags (--source all / --since-days / --json).
#   4. Ordering: the leg runs AFTER the first-month-free subscription
#      activation (CM052's wire.post() PAUSES with no episodic write
#      when subscription_state.json is absent -- gotcha 1).
#   5. The pip install is NON-editable (editable does not expose the
#      `src` package on every setuptools version -- gotcha 2).
#   6. Every MSG_HYDRATE_AICONV_* key referenced in install.sh is
#      defined in the en-GB strings catalogue.
#   7. No new GUI progress step id is introduced (the leg is dark on
#      v1.0.x, so it must NOT drift the StepCatalog sidebar contract).
#   8. install.sh still parses (bash -n).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
STRINGS="install.sh.strings.en-GB.sh"

# 1. ENABLE flag defaults OFF.
if ! grep -q 'OSTLER_AI_CONVERSATIONS_ENABLED="${OSTLER_AI_CONVERSATIONS_ENABLED:-false}"' "$INSTALL"; then
    echo "FAIL: OSTLER_AI_CONVERSATIONS_ENABLED missing or no longer defaults to false (v1.0.x must ship dark)" >&2
    exit 1
fi
echo "flag check: OSTLER_AI_CONVERSATIONS_ENABLED defaults to false"

# 2. The leg is gated on the flag being exactly "true".
if ! grep -q 'if \[\[ "$OSTLER_AI_CONVERSATIONS_ENABLED" == "true" \]\]' "$INSTALL"; then
    echo "FAIL: AI-Conversations leg is not gated on OSTLER_AI_CONVERSATIONS_ENABLED == true" >&2
    exit 1
fi
echo "gate check: leg only runs when the flag is exactly \"true\""

# 3. The producer is invoked per the v1.0.3 contract.
if ! grep -q 'pwg-ai-convo' "$INSTALL"; then
    echo "FAIL: $INSTALL never references the pwg-ai-convo producer (ship-dark forever)" >&2
    exit 1
fi
if ! grep -q -- '--source all --since-days 365 --json' "$INSTALL"; then
    echo "FAIL: producer invocation drifted from the v1.0.3 contract (--source all --since-days 365 --json)" >&2
    exit 1
fi
echo "wiring check: install.sh invokes pwg-ai-convo with the v1.0.3 contract flags"

# 4. Ordering: leg AFTER first-month-free activation (subscription gate).
aiconv_line="$(grep -n 'if \[\[ "$OSTLER_AI_CONVERSATIONS_ENABLED" == "true" \]\]' "$INSTALL" | head -1 | cut -d: -f1)"
fmf_line="$(grep -n 'from subscription_gate import activate_first_month_free' "$INSTALL" | head -1 | cut -d: -f1)"
if [ -z "$aiconv_line" ] || [ -z "$fmf_line" ]; then
    echo "FAIL: could not locate the AI-Conversations gate and/or the first-month-free activation callsite" >&2
    exit 1
fi
if [ "$aiconv_line" -le "$fmf_line" ]; then
    echo "FAIL: AI-Conversations leg (line $aiconv_line) must run AFTER first-month-free activation (line $fmf_line)" >&2
    echo "      CM052's wire.post() pauses with no episodic write until subscription_state.json exists." >&2
    exit 1
fi
echo "ordering check: AI-Conversations leg (line $aiconv_line) runs after first-month-free activation (line $fmf_line)"

# 5. NON-editable pip install of the vendored package.
if grep -E 'pip" install [^|]*-e[[:space:]]+"\$_AICONV_SRC"' "$INSTALL" >/dev/null; then
    echo "FAIL: the CM052 package is pip-installed EDITABLE; it must be non-editable (src package not exposed on every setuptools version)" >&2
    exit 1
fi
if ! grep -q 'pip" install --quiet "\$_AICONV_SRC"' "$INSTALL"; then
    echo "FAIL: could not find the non-editable pip install of \$_AICONV_SRC" >&2
    exit 1
fi
echo "pip check: vendored CM052 package installed non-editable"

# 6. Every referenced MSG_HYDRATE_AICONV_* key is defined in the catalogue.
missing=0
for key in $(grep -o 'MSG_HYDRATE_AICONV_[A-Z_]*' "$INSTALL" | sort -u); do
    if ! grep -q "^${key}=" "$STRINGS"; then
        echo "FAIL: $key referenced in $INSTALL but not defined in $STRINGS" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1
if ! grep -q '^MSG_HYDRATE_AICONV_STARTED=' "$STRINGS"; then
    echo "FAIL: MSG_HYDRATE_AICONV_STARTED not defined in $STRINGS" >&2
    exit 1
fi
echo "strings check: all MSG_HYDRATE_AICONV_* keys defined in en-GB catalogue"

# 7. No new GUI progress step id (sidebar contract untouched while dark).
if grep -q 'progress ".*" "hydrate_ai' "$INSTALL"; then
    echo "FAIL: AI-Conversations leg added a GUI progress step id; the leg is dark on v1.0.x and must not drift StepCatalog" >&2
    exit 1
fi
echo "catalog check: no new progress step id introduced (leg stays dark)"

# 8. install.sh parses.
if ! bash -n "$INSTALL"; then
    echo "FAIL: bash -n $INSTALL failed" >&2
    exit 1
fi
echo "syntax check: bash -n $INSTALL clean"

echo "ai_conversations leg wiring guard: PASS"
