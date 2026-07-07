#!/usr/bin/env bash
#
# tests/test_i18n_strings_perkey_fallback.sh
#
# Behavioural regression test for the W7 per-key i18n fallback fix
# (2026-07-07).
#
# What the failure looks like (PRE-FIX, must never recur):
#
#   1. install.sh runs under `set -Eeuo pipefail`.
#   2. The strings loader sourced exactly ONE catalogue file, with
#      only FILE-level fallback to en-GB (used only when the whole
#      locale file was absent).
#   3. The translated catalogues (de/fr/es/it) lag en-GB (861 keys
#      vs 952 at the time of the fix), so an OSTLER_LANG=de-DE
#      install hard-aborted with "unbound variable" on the FIRST
#      reference to any of the ~91 missing MSG_* keys -- including
#      inside failure paths, where the customer saw a raw bash
#      error instead of the intended failure message.
#
# The fix: the loader sources en-GB FIRST as the base layer (full
# key set), then sources the selected locale on top so translated
# keys override and missing ones keep their en-GB value.
#
# This test exercises the ACTUAL loader block extracted from
# install.sh (not a reimplementation), under the same
# `set -Eeuo pipefail` regime, on four axes:
#
#   1. Synthetic fixture: a 3-key en-GB base + 1-key de-DE overlay
#      proves the mechanism (override + fallback) independent of
#      catalogue drift, forever.
#   2. Real catalogues: OSTLER_LANG=de-DE, reference keys known to
#      be missing from de-DE (MSG_INFO_DEDUPE_STILL_MERGING and the
#      graph-db failure-path key MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY)
#      => must resolve to the en-GB value, not abort. Guarded: if a
#      key has since been translated, another missing key is picked
#      dynamically; if parity is ever reached this axis is a no-op.
#   3. Every-key sweep: for EVERY locale shipped, after loading
#      through the loader, every MSG_* key defined in en-GB must be
#      set (no unbound variable anywhere in the catalogue surface).
#   4. Overlay actually overrides: a key present in both catalogues
#      resolves to the de-DE value, and a stale OSTLER_LANG=xx-XX
#      falls back to a complete en-GB set without aborting.
#
# References:
#   - feedback_silent_bail_regression_test_shape (refuse the exact
#     failure shape)
#   - scripts/check_strings_key_parity.sh (informational drift list)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 2
fi

# ── Extract the real loader block from install.sh ────────────────
# The block lives between the "Strings catalogue (Rule 0.9)" section
# header and the "GUI progress emitter" section header.
LOADER_SNIPPET="$(awk '
    /^# ── Strings catalogue \(Rule 0\.9\)/ { grab=1 }
    /^# ── GUI progress emitter/            { grab=0 }
    grab { print }
' "$INSTALL_SH")"

if [[ -z "$LOADER_SNIPPET" ]]; then
    echo "FATAL: could not extract the strings-loader block from install.sh (section headers moved?)" >&2
    exit 2
fi
if ! grep -q '_STRINGS_BASE' <<<"$LOADER_SNIPPET"; then
    failure "extracted loader block has no _STRINGS_BASE layer -- per-key fallback fix missing?"
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

LOADER_FILE="${TMPDIR_TEST}/loader_snippet.sh"
printf '%s\n' "$LOADER_SNIPPET" > "$LOADER_FILE"

# Runs the extracted loader under install.sh's exact shell regime,
# then evaluates the caller-supplied probe script.
#   $1 = SCRIPT_DIR to point the loader at
#   $2 = OSTLER_LANG value
#   $3 = probe script (bash source text, run after the loader)
run_loader_probe() {
    local script_dir="$1" lang="$2" probe="$3"
    env -i HOME="$HOME" PATH="$PATH" \
        bash -c '
            set -Eeuo pipefail
            SCRIPT_DIR="$1"
            OSTLER_LANG="$2"
            source "$3"
            eval "$4"
        ' probe-shell "$script_dir" "$lang" "$LOADER_FILE" "$probe"
}

# ── Axis 1: synthetic fixture proves the mechanism forever ───────
SYNTH_DIR="${TMPDIR_TEST}/synth"
mkdir -p "$SYNTH_DIR"
cat > "${SYNTH_DIR}/install.sh.strings.en-GB.sh" <<'EOF'
MSG_TEST_TRANSLATED="english translated value"
MSG_TEST_UNTRANSLATED="english fallback value"
MSG_TEST_FAILURE_PATH="english failure-path value"
EOF
cat > "${SYNTH_DIR}/install.sh.strings.de-DE.sh" <<'EOF'
MSG_TEST_TRANSLATED="deutscher uebersetzter Wert"
EOF

if out="$(run_loader_probe "$SYNTH_DIR" "de-DE" '
        printf "%s|%s|%s" "$MSG_TEST_TRANSLATED" "$MSG_TEST_UNTRANSLATED" "$MSG_TEST_FAILURE_PATH"
    ' 2>&1)"; then
    [[ "$out" == "deutscher uebersetzter Wert|english fallback value|english failure-path value" ]] \
        || failure "synthetic fixture: wrong values after overlay load: ${out}"
else
    failure "synthetic fixture: loader aborted under set -Eeuo pipefail: ${out}"
fi

# Synthetic negative control: the PRE-FIX single-file behaviour must
# be what we think it is -- referencing the untranslated key after
# sourcing ONLY the de-DE fixture aborts with unbound variable. This
# proves the test would have caught the original bug.
if out="$(env -i HOME="$HOME" PATH="$PATH" bash -c '
        set -Eeuo pipefail
        source "$1/install.sh.strings.de-DE.sh"
        printf "%s" "$MSG_TEST_UNTRANSLATED"
    ' negctl "$SYNTH_DIR" 2>&1)"; then
    failure "negative control: single-file sourcing did NOT abort on a missing key -- test premise broken"
else
    grep -q "unbound variable" <<<"$out" \
        || failure "negative control aborted for an unexpected reason: ${out}"
fi

# ── Axis 2: real catalogues, known-missing de-DE keys ────────────
EN_GB="${REPO_ROOT}/install.sh.strings.en-GB.sh"
DE_DE="${REPO_ROOT}/install.sh.strings.de-DE.sh"
if [[ ! -f "$EN_GB" || ! -f "$DE_DE" ]]; then
    echo "FATAL: shipped catalogues not found at repo root" >&2
    exit 2
fi

list_keys() { grep -oE '^MSG_[A-Z0-9_]+' "$1" | sort -u; }

MISSING_IN_DE="$(comm -23 <(list_keys "$EN_GB") <(list_keys "$DE_DE"))"

# Preferred named candidates (documented in the fix); fall back to
# whatever is actually missing today so translation top-ups cannot
# make this test fail spuriously.
CANDIDATES=()
for key in MSG_INFO_DEDUPE_STILL_MERGING MSG_FAIL_GRAPH_DB_DOCKER_NOT_READY; do
    if grep -qx "$key" <<<"$MISSING_IN_DE"; then
        CANDIDATES+=("$key")
    fi
done
if [[ ${#CANDIDATES[@]} -eq 0 && -n "$MISSING_IN_DE" ]]; then
    CANDIDATES+=("$(head -n1 <<<"$MISSING_IN_DE")")
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "NOTE: de-DE has full key parity with en-GB; real-catalogue missing-key axis is vacuous (mechanism still proven by axis 1)."
else
    for key in "${CANDIDATES[@]}"; do
        expected="$(env -i HOME="$HOME" PATH="$PATH" bash -c '
            set -Eeuo pipefail
            source "$1"
            eval "printf \"%s\" \"\${$2}\""
        ' expected-shell "$EN_GB" "$key")"
        if out="$(run_loader_probe "$REPO_ROOT" "de-DE" "eval \"printf '%s' \\\"\\\${$key}\\\"\"" 2>&1)"; then
            [[ "$out" == "$expected" ]] \
                || failure "de-DE load: $key resolved to something other than the en-GB value"
        else
            failure "de-DE load aborted referencing missing key $key (unbound-variable crash is back): ${out}"
        fi
    done
    echo "OK: de-DE missing keys fall back to en-GB values (${CANDIDATES[*]})"
fi

# ── Axis 3: every en-GB key must be set after loading EVERY locale ─
ALL_KEYS_FILE="${TMPDIR_TEST}/all_keys"
list_keys "$EN_GB" > "$ALL_KEYS_FILE"

for catalogue in "$REPO_ROOT"/install.sh.strings.*.sh; do
    lang="$(basename "$catalogue")"
    lang="${lang#install.sh.strings.}"
    lang="${lang%.sh}"
    if out="$(run_loader_probe "$REPO_ROOT" "$lang" "
            missing=0
            while IFS= read -r k; do
                # bash-3.2-safe set-check (no [[ -v ]] on macOS bash)
                if eval \"test -z \\\"\\\${\$k+x}\\\"\"; then
                    printf 'UNSET:%s\n' \"\$k\"
                    missing=1
                fi
            done < '${ALL_KEYS_FILE}'
            exit \$missing
        " 2>&1)"; then
        echo "OK: ${lang}: all $(wc -l < "$ALL_KEYS_FILE" | tr -d ' ') en-GB keys defined after load"
    else
        failure "${lang}: keys unbound after loader run: $(head -n5 <<<"$out")"
    fi
done

# ── Axis 4: overlay overrides + stale-lang fallback ──────────────
# Find a key present in both en-GB and de-DE whose values differ,
# and confirm the de-DE value wins through the loader.
OVERRIDE_KEY=""
while IFS= read -r k; do
    en_val="$(env -i HOME="$HOME" PATH="$PATH" bash -c 'set -eu; source "$1"; eval "printf \"%s\" \"\${$2}\""' x "$EN_GB" "$k")"
    de_val="$(env -i HOME="$HOME" PATH="$PATH" bash -c 'set -eu; source "$1"; eval "printf \"%s\" \"\${$2}\""' x "$DE_DE" "$k")"
    if [[ "$en_val" != "$de_val" ]]; then
        OVERRIDE_KEY="$k"
        OVERRIDE_EXPECTED="$de_val"
        break
    fi
done < <(comm -12 <(list_keys "$EN_GB") <(list_keys "$DE_DE"))

if [[ -z "$OVERRIDE_KEY" ]]; then
    failure "could not find any key whose de-DE value differs from en-GB -- override axis cannot run"
else
    if out="$(run_loader_probe "$REPO_ROOT" "de-DE" "eval \"printf '%s' \\\"\\\${$OVERRIDE_KEY}\\\"\"" 2>&1)"; then
        [[ "$out" == "$OVERRIDE_EXPECTED" ]] \
            || failure "de-DE overlay did not override $OVERRIDE_KEY (got en-GB value back?)"
    else
        failure "de-DE overlay probe aborted: ${out}"
    fi
fi

# Stale OSTLER_LANG must fall back to a complete en-GB set, not abort.
if out="$(run_loader_probe "$REPO_ROOT" "xx-XX" '
        printf "%s" "$MSG_INFO_DEDUPE_STILL_MERGING" >/dev/null
        printf "loaded"
    ' 2>&1)"; then
    [[ "$out" == "loaded" ]] || failure "stale-lang fallback: unexpected output: ${out}"
else
    failure "stale OSTLER_LANG=xx-XX aborted the loader: ${out}"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_i18n_strings_perkey_fallback: FAILED" >&2
    exit 1
fi
echo "test_i18n_strings_perkey_fallback: PASS"
