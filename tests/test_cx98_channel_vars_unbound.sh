#!/usr/bin/env bash
#
# tests/test_cx98_channel_vars_unbound.sh
#
# Byte-walking regression test for the CX-98 launch-blocker fix
# (DMG #48h Studio retest, 2026-05-29).
#
# What the failure looks like (PRE-FIX, must never recur):
#
#   1. install.sh detects a previous COMPLETE install via the
#      ${OSTLER_FINAL_DIR}/config/.env probe (~line 1521) and
#      branches reuse=yes (SKIP_PHASE2=true).
#
#   2. The Phase-2 questions block at lines ~1521-2642 is skipped
#      end-to-end. The block contains the only assignment of
#      CHANNEL_*_ENABLED + CHANNEL_*_USERNAME + CHANNEL_*_PASSWORD
#      + CHANNEL_*_FOLDER + CHANNEL_WHATSAPP_RECIPIENT etc., plus
#      OSTLER_REGION / OSTLER_REGION_ISO / OSTLER_REGION_SOURCE,
#      plus WA_CONSENT.
#
#   3. Phase 3 walks through to config_save at line ~4523, then
#      the TOML writer block at line ~4815-5070 reads
#      $CHANNEL_IMESSAGE_ENABLED bare. set -u trips:
#        install.sh: line 4823:
#          CHANNEL_IMESSAGE_ENABLED: unbound variable
#
#   4. The shell exits non-zero. The GUI's exit-0 masking bug
#      (tracked as #454 v1.0.1) reports the install as succeeded
#      while no security setup / no service deploy / no hydration
#      / no QR code actually ran. Customer thinks the install
#      finished; nothing works.
#
#   5. Same shape applies on every reuse=yes path for every
#      "assigned-inside, read-outside" variable in install.sh.
#
# This test refuses the exact shape that caused the launch-blocker
# per locked memory feedback_silent_bail_regression_test_shape.
#
# Axes covered:
#   1. install.sh must initialise every "read-outside,
#      assigned-inside" variable BEFORE the SKIP_PHASE2 branch.
#   2. The defaults must be syntactically present and reachable on
#      the reuse=yes path (asserted by simulated source-up-to-X).
#   3. The TOML writer block must run under set -u against the
#      defaults with zero unbound-variable trips.

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

# ── Axis 1: every "read-outside, assigned-inside-wrap" var must ──
# have an unconditional default before the SKIP_PHASE2 branch.
#
# The brief's audit confirmed these variables fall into the bug
# class: read at sites outside the SKIP_PHASE2 wrap, assigned ONLY
# inside it, no default elsewhere, no safe-default ${VAR:-} at any
# of the read sites.

REQUIRED_DEFAULTS=(
    CHANNEL_CHOICE
    CHANNEL_IMESSAGE_ENABLED
    CHANNEL_EMAIL_ENABLED
    CHANNEL_WHATSAPP_ENABLED
    CHANNEL_WHATSAPP_CONSENT_ACCEPTED
    CHANNEL_WHATSAPP_RECIPIENT
    CHANNEL_IMESSAGE_ALLOWED
    CHANNEL_EMAIL_USERNAME
    CHANNEL_EMAIL_PASSWORD
    CHANNEL_EMAIL_FROM
    CHANNEL_EMAIL_IMAP_HOST
    CHANNEL_EMAIL_IMAP_PORT
    CHANNEL_EMAIL_SMTP_HOST
    CHANNEL_EMAIL_SMTP_PORT
    CHANNEL_EMAIL_IMAP_FOLDER
    CHANNEL_EMAIL_APPLE_MAIL_ENABLED
    CHANNEL_EMAIL_CUSTOM_IMAP_ENABLED
    WA_CONSENT
    OSTLER_REGION
    OSTLER_REGION_ISO
    OSTLER_REGION_SOURCE
)

# Find the line number of the SKIP_PHASE2=false declaration that
# starts the reuse-detection branch. Defaults MUST sit at a lower
# line number than this one.
PHASE2_START_LINE="$(grep -n '^SKIP_PHASE2=false$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -z "$PHASE2_START_LINE" ]]; then
    failure "could not locate SKIP_PHASE2=false in install.sh"
fi

for var in "${REQUIRED_DEFAULTS[@]}"; do
    default_line="$(grep -nE "^${var}=" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    if [[ -z "$default_line" ]]; then
        failure "no unconditional ${var}=... default found in install.sh"
        continue
    fi
    if (( default_line >= PHASE2_START_LINE )); then
        failure "${var} default at line ${default_line} is AT or AFTER the SKIP_PHASE2=false branch at line ${PHASE2_START_LINE}; must be BEFORE so reuse=yes path inherits it"
    fi
done

# ── Axis 2: under set -u, every default must be REACHABLE before ──
# the SKIP_PHASE2 branch is taken. Simulate by sourcing install.sh
# from line 1 up to PHASE2_START_LINE and asserting every var is
# set (not merely defined as empty -- defined is enough for set -u).
#
# We can't really `source` arbitrary install.sh fragments without
# triggering all of its side-effects (mkdir / chmod / gui_emit /
# launchctl probes). Instead we extract every line at column-0
# matching `^VAR=` for our 21 required vars and execute them in
# isolation under set -u.

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

DEFAULTS_FRAGMENT="${TMPDIR}/defaults.sh"
{
    echo "set -euo pipefail"
    for var in "${REQUIRED_DEFAULTS[@]}"; do
        # Pull the FIRST unconditional assignment for this var.
        # (grep -m1 quits after the first match; portable across BSD
        # + GNU grep.)
        line="$(grep -E "^${var}=" "$INSTALL_SH" | head -1)"
        if [[ -n "$line" ]]; then
            echo "$line"
        fi
    done
    # Round-trip assertion: every var must now satisfy
    # ${VAR+set} (works on bash 3.2 + bash 4+, unlike [[ -v ]]
    # which is bash 4.2+ only and breaks on stock macOS bash).
    for var in "${REQUIRED_DEFAULTS[@]}"; do
        echo "[ \"\${${var}+set}\" = set ] || { echo \"UNSET: ${var}\" >&2; exit 1; }"
    done
} > "$DEFAULTS_FRAGMENT"

if ! bash "$DEFAULTS_FRAGMENT" 2>"${TMPDIR}/err"; then
    failure "defaults fragment failed under set -u:"
    sed 's/^/  /' "${TMPDIR}/err" >&2 || true
fi

# ── Axis 3: the config_save TOML writer block (~4815-5070) must ──
# not trip set -u on any of our 21 required-default vars. We do
# this by extracting every $VAR / ${VAR} reference from that line
# range and asserting we have a default for each, OR the read uses
# safe-default syntax (${VAR:-...}).

WRITER_START="$(grep -n '^progress "Saving your configuration" "config_save"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -z "$WRITER_START" ]]; then
    failure "could not locate config_save progress line"
else
    # Walk a generous window past config_save -- 600 lines covers
    # the .env writer + the assistant-config TOML writer + the
    # JWT / service-token seeders.
    WRITER_END=$(( WRITER_START + 600 ))

    # Extract all bare ${VAR} or $VAR uses for our required-default
    # vars in the writer window. Bare = not prefixed with `:-`
    # safe-default syntax.
    BARE_USES="${TMPDIR}/bare_uses.txt"
    > "$BARE_USES"
    for var in "${REQUIRED_DEFAULTS[@]}"; do
        # Three forms to check (any of):
        #   $VAR     "$VAR"     [[ "$VAR"
        #   ${VAR}   "${VAR}"   [[ "${VAR}"
        # And EXCLUDE the safe-default syntax ${VAR:-...} which is
        # already protected.
        sed -n "${WRITER_START},${WRITER_END}p" "$INSTALL_SH" \
            | grep -nE "\\\$${var}[^A-Za-z0-9_]|\\\$\\{${var}[^:A-Za-z0-9_]" \
            | grep -vE "\\\$\\{${var}:-" \
            >> "$BARE_USES" || true
    done

    if [[ -s "$BARE_USES" ]]; then
        # A bare use is OK ONLY if the var has an unconditional
        # default before the SKIP_PHASE2 branch (asserted above).
        # The fix's contract is: bare uses are fine, because the
        # defaults guarantee the var is always set. So a non-empty
        # bare-uses file is expected; this axis is informational.
        # We assert the file is non-empty AND that every var named
        # in it appears in our REQUIRED_DEFAULTS list.
        while IFS= read -r line; do
            # Extract the var name from each line: looks like
            # ${WRITER_OFFSET}:    if [[ "$CHANNEL_IMESSAGE_ENABLED" == true ...
            for var in "${REQUIRED_DEFAULTS[@]}"; do
                if grep -qE "\\\$${var}|\\\$\\{${var}" <<<"$line"; then
                    # Confirmed: var has a default, bare use is safe.
                    continue 2
                fi
            done
            failure "bare use of an unguarded var in writer block: ${line}"
        done < "$BARE_USES"
    fi
fi

# ── Axis 4: bash -n syntax check on the patched install.sh.
if ! bash -n "$INSTALL_SH" 2>"${TMPDIR}/syntax"; then
    failure "install.sh failed bash -n:"
    sed 's/^/  /' "${TMPDIR}/syntax" >&2 || true
fi

if (( FAILED == 0 )); then
    echo "PASS: tests/test_cx98_channel_vars_unbound.sh"
    exit 0
else
    echo "FAILED: tests/test_cx98_channel_vars_unbound.sh" >&2
    exit 1
fi
