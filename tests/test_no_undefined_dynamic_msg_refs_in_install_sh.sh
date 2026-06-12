#!/usr/bin/env bash
# Regression guard — the DYNAMIC half of test_no_undefined_msg_refs_in_install_sh.sh.
#
# The literal-ref guard greps $MSG_* / ${MSG_*} names. It is blind to the
# INDIRECT family install.sh builds at runtime in `_install_conversation_feed`:
#
#   _install_conversation_feed whatsapp ...        # feed_key = $1
#       local uc; uc="$(... | tr to upper)"        # WHATSAPP
#       local k_ok_src="MSG_OK_${uc}_SOURCE_INSTALLED"
#       ok "${!k_ok_src}"                          # indirect expansion
#
# These MSG_* names never appear as a literal $MSG_ token, so the literal
# guard cannot see them. If a new feed_key is wired up but its
# MSG_*_<UC>_* family is not added to install.sh.strings.en-GB.sh, the first
# `${!k}` detonates the install under `set -u` mid-step — the exact CX-18
# silent-bail shape, through a path the literal guard misses.
#
# This test expands every (feed_key x dynamic-template) pair and asserts the
# en-GB catalogue defines the resulting MSG_* key. Both halves together close
# the "referenced but undefined" class for install.sh strings.
#
# Exit 0 on clean. Exit 1 on any undefined dynamic reference.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_SH="$REPO_ROOT/install.sh"
CATALOGUE="$REPO_ROOT/install.sh.strings.en-GB.sh"

for f in "$INSTALL_SH" "$CATALOGUE"; do
    if [[ ! -f "$f" ]]; then
        echo "FAIL: required file not found: $f" >&2
        exit 1
    fi
done

# 1. feed_key values = the literal first arg at each _install_conversation_feed
#    call site (the def line `_install_conversation_feed() {` has a `(` so the
#    `[a-z]` arg pattern below skips it). `while read` keeps this bash-3.2
#    compatible (macOS default; no `mapfile`).
#    Anchor to ^[[:space:]]* so only real invocation lines match -- not prose
#    comments that mention the function name, and not the `() {` def line.
FEED_KEYS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && FEED_KEYS+=("$line")
done < <(
    grep -E '^[[:space:]]*_install_conversation_feed[[:space:]]+[a-z][a-z0-9_]*' "$INSTALL_SH" \
        | awk '{print $2}' | sort -u
)

# 2. dynamic MSG name templates, e.g. MSG_OK_${uc}_SOURCE_INSTALLED
TEMPLATES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && TEMPLATES+=("$line")
done < <(
    grep -oE '"MSG_[A-Z0-9_]*\$\{[a-z_]+\}[A-Z0-9_]*"' "$INSTALL_SH" \
        | tr -d '"' | sort -u
)

# Guard against silent parser rot: if either set is empty the function was
# probably renamed/refactored -- fail loudly rather than vacuously pass.
if [[ "${#FEED_KEYS[@]}" -eq 0 ]]; then
    echo "FAIL: no _install_conversation_feed <feed_key> call sites found." >&2
    echo "      The parser may be stale (function renamed?). Refusing to pass vacuously." >&2
    exit 1
fi
if [[ "${#TEMPLATES[@]}" -eq 0 ]]; then
    echo "FAIL: no dynamic MSG_* \${...} templates found in install.sh." >&2
    echo "      The parser may be stale. Refusing to pass vacuously." >&2
    exit 1
fi

MISSING=()
CHECKED=0
for fk in "${FEED_KEYS[@]}"; do
    uc="$(printf '%s' "$fk" | tr '[:lower:]' '[:upper:]')"
    for tmpl in "${TEMPLATES[@]}"; do
        # Replace the ${...} placeholder with the uppercased feed_key.
        name="$(printf '%s' "$tmpl" | sed -E "s/\\\$\{[a-z_]+\}/${uc}/")"
        CHECKED=$((CHECKED + 1))
        if ! grep -qE "^${name}=" "$CATALOGUE"; then
            MISSING+=("$name  (feed_key=${fk})")
        fi
    done
done

if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "FAIL: _install_conversation_feed builds these MSG_* keys by indirect" >&2
    echo "      expansion, but install.sh.strings.en-GB.sh does not define them." >&2
    echo "      At runtime the first \${!k} reference detonates the install under" >&2
    echo "      set -u (the CX-18 silent-bail shape)." >&2
    echo "" >&2
    echo "Missing dynamic keys:" >&2
    printf '    %s\n' "${MISSING[@]}" >&2
    echo "" >&2
    echo "Fix: add each MSG_NAME=\"...\" line to install.sh.strings.en-GB.sh." >&2
    exit 1
fi

echo "PASS: all $CHECKED dynamic MSG_* keys (${#FEED_KEYS[@]} feed_keys x ${#TEMPLATES[@]} templates) resolve to a catalogue definition."
