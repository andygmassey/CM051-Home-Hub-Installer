#!/usr/bin/env bash
# test_locale_overlay_fallback.sh
#
# Localisation pilot regression guard (v1.0.1). Locks in three
# guarantees of the install.sh strings-catalogue loader:
#
#   1. English is byte-identical. Sourcing en-GB through the new
#      base+overlay loader (with locale en-GB) produces exactly the
#      same MSG_* values as sourcing en-GB alone. English must never
#      regress because localisation landed.
#   2. The selected locale overlays on top of English. With a Spanish
#      catalogue present, MSG_* keys defined in it render in Spanish.
#   3. Per-key English fallback. A key NOT present in the selected
#      locale keeps its English value (no blank strings, no crash),
#      and a wholly-missing locale file falls back to English without
#      aborting.
#
# This mirrors the loader logic in install.sh ("Strings catalogue
# (Rule 0.9)" block). If you change that block, change it here too.
#
# Exit 0 on clean. Exit 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EN="$REPO_ROOT/install.sh.strings.en-GB.sh"
ES="$REPO_ROOT/install.sh.strings.es.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[[ -f "$EN" ]] || fail "en-GB catalogue not found at $EN"
[[ -f "$ES" ]] || fail "es catalogue not found at $ES"

# Replicates the install.sh loader: source en-GB base, then overlay
# the requested locale on top (per-key). Dumps every MSG_* var.
_render() {
    local lang="$1"
    bash -c '
        set -uo pipefail
        REPO_ROOT="$1"; LANG_REQ="$2"
        source "$REPO_ROOT/install.sh.strings.en-GB.sh"
        if [[ "$LANG_REQ" != "en-GB" ]]; then
            overlay="$REPO_ROOT/install.sh.strings.${LANG_REQ}.sh"
            if [[ -f "$overlay" ]]; then source "$overlay"; fi
        fi
        for v in $(compgen -v | grep "^MSG_" | sort); do
            printf "%s=%s\n" "$v" "${!v}"
        done
    ' _ "$REPO_ROOT" "$lang"
}

# Baseline: source ONLY en-GB (today's shipping behaviour).
_render_en_only() {
    bash -c '
        set -uo pipefail
        REPO_ROOT="$1"
        source "$REPO_ROOT/install.sh.strings.en-GB.sh"
        for v in $(compgen -v | grep "^MSG_" | sort); do
            printf "%s=%s\n" "$v" "${!v}"
        done
    ' _ "$REPO_ROOT"
}

base_en="$(_render_en_only)"
loader_en="$(_render en-GB)"
loader_es="$(_render es)"
loader_missing="$(_render zz-ZZ)"   # no such catalogue -> must fall back to English

# 1. English byte-identical.
if [[ "$base_en" != "$loader_en" ]]; then
    diff <(printf '%s\n' "$base_en") <(printf '%s\n' "$loader_en") | head >&2
    fail "English output is NOT byte-identical through the overlay loader."
fi
en_keys="$(printf '%s\n' "$base_en" | grep -c '^MSG_')"
printf 'OK: English byte-identical through loader (%s keys).\n' "$en_keys"

# 2. Spanish overlay applied. Pick a key we know is translated.
es_step="$(printf '%s\n' "$loader_es" | grep '^MSG_STEP_CHECKING_PREREQUISITES=')"
en_step="$(printf '%s\n' "$base_en"   | grep '^MSG_STEP_CHECKING_PREREQUISITES=')"
[[ "$es_step" != "$en_step" ]] || fail "Spanish overlay not applied (MSG_STEP_CHECKING_PREREQUISITES unchanged)."
printf 'OK: Spanish overlay applied.\n'

# 3a. Per-key fallback: a key NOT in the es catalogue keeps English.
fb_key="MSG_INFO_CLONING_DOCTOR_AGENT"
if grep -q "^${fb_key}=" "$ES"; then
    fail "test assumption broken: $fb_key is now translated in es; pick another untranslated key."
fi
es_fb="$(printf '%s\n' "$loader_es" | grep "^${fb_key}=")"
en_fb="$(printf '%s\n' "$base_en"   | grep "^${fb_key}=")"
[[ "$es_fb" == "$en_fb" ]] || fail "Per-key English fallback failed for $fb_key."
printf 'OK: per-key English fallback works for untranslated keys.\n'

# 3b. Wholly-missing locale file falls back to English, no abort.
if [[ "$loader_missing" != "$base_en" ]]; then
    fail "Missing locale catalogue did not fall back byte-identically to English."
fi
printf 'OK: missing locale catalogue falls back to English without aborting.\n'

# Key count is preserved across locales (no keys dropped).
es_keys="$(printf '%s\n' "$loader_es" | grep -c '^MSG_')"
[[ "$es_keys" == "$en_keys" ]] || fail "Key count changed under es ($es_keys vs $en_keys)."
printf 'OK: key count preserved across locales (%s).\n' "$es_keys"

# %s placeholder parity between es values and their English source.
mismatch=0
while IFS= read -r line; do
    key="${line%%=*}"
    [[ "$key" == MSG_* ]] || continue
    es_val="${line#*=}"
    en_line="$(grep -m1 "^${key}=" "$EN" || true)"
    [[ -n "$en_line" ]] || continue
    en_val="${en_line#*=}"
    es_n="$(grep -o '%s' <<<"$es_val" | wc -l | tr -d ' ')"
    en_n="$(grep -o '%s' <<<"$en_val" | wc -l | tr -d ' ')"
    if [[ "$es_n" != "$en_n" ]]; then
        printf 'FAIL: %s placeholder mismatch (es=%s en=%s)\n' "$key" "$es_n" "$en_n" >&2
        mismatch=1
    fi
done < "$ES"
[[ "$mismatch" == 0 ]] || fail "placeholder parity check failed."
printf 'OK: %%s placeholder parity holds between es and en-GB.\n'

printf '\nAll localisation overlay/fallback guarantees hold.\n'
exit 0
