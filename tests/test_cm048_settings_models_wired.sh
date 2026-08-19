#!/usr/bin/env bash
#
# test_cm048_settings_models_wired.sh
#
# Byte-walking regression test for the CM048 RAM-aware model fix
# (recut 2026-06-03). Refuses the exact failure shape that left every
# conversation dead at step 02_enrich: CM048 defaults its enrich / fact /
# relationship / coach steps to qwen3.5:35b-a3b, which a 16-24GB box
# cannot run and the installer never pulled, so Ollama 404'd and no
# conversation ever reached its sinks.
#
# The fix writes ~/.ostler/settings.yaml (CM048's auto-loaded settings
# path) pointing every conversation model at the installer's RAM-selected
# model ($AI_MODEL: the one it actually pulled), reusing the existing
# picker rather than hardcoding a model no box can serve. CM048's code
# default stays at 35b-a3b as the large-RAM opt-in.
#
# What the failure looked like (PRE-FIX, must never recur):
#   1. install.sh never writes a CM048 settings.yaml
#   2. it does not pin all five ollama_*_model fields
#   3. it hardcodes a model instead of reusing $AI_MODEL (the RAM pick)
#   4. it clobbers an operator's existing settings.yaml
#
# All axes per locked memory feedback_silent_bail_regression_test_shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    failure "install.sh missing"
    echo "test_cm048_settings_models_wired: FAILED" >&2
    exit 1
fi

# Axis 1: install.sh must write a CM048 settings.yaml under OSTLER_DIR.
if ! grep -Eq '_cm048_settings=.*OSTLER_DIR.*settings\.yaml' "$INSTALL_SH"; then
    failure "install.sh never targets \${OSTLER_DIR}/settings.yaml — CM048 keeps its 35b-a3b defaults"
fi

# Axis 2: all five conversation model fields must be pinned.
for key in ollama_classify_model ollama_enrich_model ollama_fact_model \
           ollama_relationship_model ollama_coach_model; do
    if ! grep -q "$key" "$INSTALL_SH"; then
        failure "install.sh does not pin $key — that step falls back to 35b-a3b and 404s"
    fi
done

# Axis 3: the pinned model must come from the RAM picker ($AI_MODEL),
# not a hardcoded literal, so it always matches the model pulled.
if ! grep -Eq '_cm048_model=.*AI_MODEL' "$INSTALL_SH"; then
    failure "install.sh does not derive the conversation model from \$AI_MODEL — risks pinning a model the installer never pulled"
fi

# Axis 4: an existing settings.yaml must be preserved (operator edits win).
if ! grep -Eq 'if \[\[ -f "\$_cm048_settings" \]\]' "$INSTALL_SH"; then
    failure "install.sh does not guard against clobbering an existing settings.yaml"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_cm048_settings_models_wired: FAILED" >&2
    exit 1
fi
echo "test_cm048_settings_models_wired: RAM-aware conversation models wired (settings.yaml + 5 fields + \$AI_MODEL + no-clobber)"
