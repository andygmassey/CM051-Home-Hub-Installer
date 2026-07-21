#!/usr/bin/env bash
#
# tests/test_v1010_ical_doctor_service_token.sh
#
# FIX 6 (v1.0.10 security lockdown -- wire the #200 service token into
# ical-server, pairs with CM041 fix/v1010-ical-server-auth).
#
# The ical-server (127.0.0.1:8090) launchd plist previously omitted
# the #200 service token, and the Doctor proxy forwarded to :8090 with
# no bearer. Both plists must now carry PWG_SERVICE_TOKEN so the
# ical-server can require it and the Doctor can attach it as a bearer.
# Env-var name PWG_SERVICE_TOKEN is the agreed name both halves read.
#
# Pure shell + grep / awk. No launchd.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install.sh not found"

extract_heredoc() { # $1 = delimiter
    awk -v d="$1" '
        $0 ~ ("<<" d "$") { cap = 1; next }
        $0 == d           { cap = 0 }
        cap               { print }
    ' "$INSTALL_SCRIPT"
}

ICAL="$(extract_heredoc "ICALPLISTEOF")"
DOC="$(extract_heredoc "DOCEOF")"

[[ -n "$ICAL" ]] || fail "ical-server plist heredoc (ICALPLISTEOF) not found"
[[ -n "$DOC"  ]] || fail "Doctor plist heredoc (DOCEOF) not found"

echo "$ICAL" | grep -q '<key>PWG_SERVICE_TOKEN</key>' \
    || fail "ical-server plist does not carry PWG_SERVICE_TOKEN"
echo "$ICAL" | grep -q '<string>${PWG_SERVICE_TOKEN}</string>' \
    || fail "ical-server plist PWG_SERVICE_TOKEN value not wired to the generated token"

echo "$DOC" | grep -q '<key>PWG_SERVICE_TOKEN</key>' \
    || fail "Doctor plist does not carry PWG_SERVICE_TOKEN (proxy cannot attach the bearer to :8090)"
echo "$DOC" | grep -q '<string>${PWG_SERVICE_TOKEN}</string>' \
    || fail "Doctor plist PWG_SERVICE_TOKEN value not wired to the generated token"

# Both plists now carry the token, so they must be chmod 0600 (default
# umask leaves them 0644 world-readable -> token leak on a multi-user Mac).
grep -q 'chmod 0600 "\$ICAL_PLIST"' "$INSTALL_SCRIPT" \
    || fail "ical-server plist not chmod 0600 (PWG_SERVICE_TOKEN would be world-readable)"
grep -q 'chmod 0600 "\$DOCTOR_PLIST"' "$INSTALL_SCRIPT" \
    || fail "Doctor plist not chmod 0600 (PWG_SERVICE_TOKEN would be world-readable)"

echo "PASS: ical-server + Doctor plists both carry PWG_SERVICE_TOKEN (the #200 service token) and are chmod 0600."
