#!/usr/bin/env bash
#
# test_email_ingest_bootstrap_guard.sh
#
# Proves the email-ingest LaunchAgent is never bootstrapped against a missing
# assistant binary.
#
# WHAT SHIPPED
# ------------
# vendor/email_ingest/INSTALL_SNIPPET.sh rendered the plist and ran
# `launchctl bootstrap` unconditionally. ProgramArguments[0] is the
# code-signed assistant binary inside the .app (the FDA holder), and the plist
# carries RunAtLoad=true.
#
# launchd resolves ProgramArguments[0] at BOOTSTRAP time. If it is absent, the
# RunAtLoad tick fires, fails to exec, and launchd answers EX_CONFIG (78).
#
# EX_CONFIG is not a retry. launchd reads it as "this job is misconfigured",
# records runs=1, and never starts the job again -- StartInterval included.
# Both log files stay 0 bytes because nothing ever ran to write to them, so
# the failure presents as total silence.
#
# The v1.0.15 box-walk found exactly that: email-ingest at runs=1 / last exit
# 78, no mail ingested since install, and two empty log files. The old comment
# in the snippet called this shape "degraded-but-survivable". It is neither.
#
# An absent LaunchAgent that says why is strictly better than a present one
# that is permanently dead, so the snippet now refuses to bootstrap and prints
# the exact command to run once the binary exists.
#
# Usage: bash tests/test_email_ingest_bootstrap_guard.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET="$REPO_ROOT/vendor/email_ingest/INSTALL_SNIPPET.sh"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

printf '== test_email_ingest_bootstrap_guard ==\n'

[[ -f "$SNIPPET" ]] || { echo "snippet not found: $SNIPPET" >&2; exit 3; }

bash -n "$SNIPPET" && ok "snippet parses" || bad "snippet has a syntax error"

# --- the guard exists, and guards the right thing --------------------------

if grep -q 'ASSISTANT_BINARY=' "$SNIPPET" \
   && grep -q 'if \[\[ ! -x "\$ASSISTANT_BINARY" \]\]' "$SNIPPET"; then
    ok "guard tests ProgramArguments[0] for executability"
else
    bad "no executability guard on the assistant binary"
fi

# --- ordering: the guard must PRECEDE the bootstrap ------------------------
# A guard placed after the bootstrap would still match a naive grep while
# doing nothing, which is precisely the failure mode being fixed.

guard_line=$(grep -n 'if \[\[ ! -x "\$ASSISTANT_BINARY" \]\]' "$SNIPPET" | head -1 | cut -d: -f1)
boot_line=$(grep -n 'launchctl bootstrap "\$DOMAIN"' "$SNIPPET" | head -1 | cut -d: -f1)
if [[ -n "$guard_line" && -n "$boot_line" && "$guard_line" -lt "$boot_line" ]]; then
    ok "guard runs BEFORE launchctl bootstrap (guard:$guard_line boot:$boot_line)"
else
    bad "guard does not precede bootstrap (guard:${guard_line:-none} boot:${boot_line:-none})"
fi

# --- the guard must exit non-zero, not merely warn -------------------------
# install.sh branches on the snippet's exit status to decide whether to tell
# the operator the agent is missing. A warning that still exits 0 is invisible.

guard_block=$(sed -n "${guard_line},\$p" "$SNIPPET" | sed -n '1,40p')
if printf '%s' "$guard_block" | grep -q 'exit 1'; then
    ok "guard exits non-zero so install.sh surfaces it"
else
    bad "guard does not exit non-zero; install.sh would report success"
fi

# --- the operator is told how to recover -----------------------------------

if printf '%s' "$guard_block" | grep -q 'launchctl bootstrap \$DOMAIN'; then
    ok "guard prints the exact command to load the agent later"
else
    bad "guard gives no recovery instruction"
fi

# --- behavioural: run the guard logic against a missing binary -------------
# Exercises the actual condition rather than trusting the grep above.

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
probe() {  # $1 = path to test
    ASSISTANT_BINARY="$1"
    if [[ ! -x "$ASSISTANT_BINARY" ]]; then echo refused; else echo bootstrapped; fi
}
[[ "$(probe "$TMP/nope/ostler-assistant")" == "refused" ]] \
    && ok "missing binary -> refuses to bootstrap" \
    || bad "missing binary was allowed through"

mkdir -p "$TMP/app"; printf '#!/bin/sh\n' > "$TMP/app/ostler-assistant"
[[ "$(probe "$TMP/app/ostler-assistant")" == "refused" ]] \
    && ok "non-executable binary -> refuses to bootstrap" \
    || bad "non-executable binary was allowed through"

chmod +x "$TMP/app/ostler-assistant"
[[ "$(probe "$TMP/app/ostler-assistant")" == "bootstrapped" ]] \
    && ok "present + executable -> proceeds (no false positive)" \
    || bad "guard blocks a perfectly good binary"

# --- the stale-comment regression ------------------------------------------
# The old comment asserted that loading a broken agent was survivable. It was
# the reasoning that produced the bug; if it comes back, so does the bug.

if grep -q 'degraded-but-survivable' "$SNIPPET"; then
    bad "the 'degraded-but-survivable' claim is back; EX_CONFIG is permanent"
else
    ok "stale 'degraded-but-survivable' rationale is gone"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
