#!/usr/bin/env bash
# test_encryption_hardening.sh -- T16 at-rest encryption hardening.
#
# Covers the three buildable pieces added on dc/encryption-hardening:
#   1. --allow-plaintext is guarded: on a normal (non-dev, non-CI) host
#      the installer REFUSES the flag and exits, instead of merely
#      warning. An explicit OSTLER_DEV=1 / OSTLER_ALLOW_PLAINTEXT_OK=1 /
#      CI=true signal is required to proceed.
#   2. The DEK is delivered to headless services: passphrase setup writes
#      a mode-0600 key file, and the ical-server LaunchAgent plist points
#      at it via OSTLER_DB_KEY_FILE (raw key kept out of the plist).
#   3. In --allow-plaintext dev runs the plist instead carries
#      OSTLER_ALLOW_PLAINTEXT=1 so the service's fail-closed gate permits
#      an unencrypted run.
#
# The guard runs early (before any install work), so cases 1 are exercised
# against the REAL install.sh. Cases 2/3 are asserted structurally plus a
# plist-validity check on the injected fragment.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${HERE}/../install.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# Run install.sh far enough to resolve the --allow-plaintext guard, then
# stop. Returns via globals: GUARD_RC (exit code if it exited on its own,
# else empty) and GUARD_OUT (captured output path).
run_guard() {
    local out; out="$(mktemp)"
    ( env "$@" OSTLER_GUI=1 HOME="$(mktemp -d)" bash "$INSTALL" --allow-plaintext </dev/null >"$out" 2>&1 ) &
    local pid=$!
    local i
    for i in $(seq 1 25); do
        if grep -qE "REFUSING --allow-plaintext|RUNNING WITH --allow-plaintext" "$out"; then
            break
        fi
        kill -0 "$pid" 2>/dev/null || break
        python3 -c "import time; time.sleep(0.2)"
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    GUARD_OUT="$out"
}

echo "== syntax =="
bash -n "$INSTALL" && ok "install.sh parses (bash -n)" || bad "install.sh syntax error"

echo "== 1. --allow-plaintext guard =="
run_guard
if grep -q "REFUSING --allow-plaintext" "$GUARD_OUT"; then
    ok "refuses --allow-plaintext with no dev/CI signal"
else
    bad "did NOT refuse --allow-plaintext on a plain host"
fi

for sig in "OSTLER_DEV=1" "OSTLER_ALLOW_PLAINTEXT_OK=1" "CI=true"; do
    run_guard "$sig"
    if grep -q "REFUSING --allow-plaintext" "$GUARD_OUT"; then
        bad "$sig should permit --allow-plaintext but it was refused"
    elif grep -q "RUNNING WITH --allow-plaintext" "$GUARD_OUT"; then
        ok "$sig permits --allow-plaintext (guard passed)"
    else
        bad "$sig: guard outcome indeterminate"
    fi
done

echo "== 2. key delivery: DEK unwrap + 0600 key file =="
grep -q "from ostler_security.passphrase import unlock as _unlock" "$INSTALL" \
    && ok "installer unwraps the DEK at passphrase setup" \
    || bad "DEK unwrap step missing"
grep -q "service_db.key" "$INSTALL" \
    && ok "installer references the service_db.key key file" \
    || bad "service_db.key key file not referenced"
grep -qE "os.open\(str\(_key_path\), os.O_WRONLY \| os.O_CREAT \| os.O_TRUNC, 0o600\)" "$INSTALL" \
    && ok "key file is created mode 0600" \
    || bad "key file not created 0600"

echo "== 2/3. ical-server plist carries the key env =="
grep -q 'OSTLER_DB_KEY_FILE' "$INSTALL" \
    && ok "plist can carry OSTLER_DB_KEY_FILE" \
    || bad "OSTLER_DB_KEY_FILE not delivered to plist"
grep -q '${ICAL_DB_KEY_ENV_XML}' "$INSTALL" \
    && ok "ical plist heredoc injects the key-env fragment" \
    || bad "ical plist heredoc does not reference ICAL_DB_KEY_ENV_XML"
# Prefer the key file; fall back to the plaintext marker only in dev.
if grep -q 'elif \[\[ "$ALLOW_PLAINTEXT" == "1" \]\]; then' "$INSTALL" \
   && grep -q 'OSTLER_ALLOW_PLAINTEXT' "$INSTALL"; then
    ok "dev --allow-plaintext path sets OSTLER_ALLOW_PLAINTEXT in the plist"
else
    bad "dev plaintext fallback marker missing"
fi

echo "== 3. injected key-env fragment is plist-valid =="
# Reproduce the exact fragment the installer injects for the key-file case
# and confirm it yields a valid plist (a malformed fragment would break
# every launchd boot).
FRAG=$(printf '        <key>OSTLER_DB_KEY_FILE</key>\n        <string>%s</string>' "/Users/x/.ostler/security/service_db.key")
RENDERED="$(mktemp)"; trap 'rm -f "$RENDERED"' EXIT
cat > "$RENDERED" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OSTLER_API_PORT</key>
        <string>8090</string>
${FRAG}
    </dict>
</dict>
</plist>
PLISTEOF
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$RENDERED" >/dev/null 2>&1 \
        && ok "injected OSTLER_DB_KEY_FILE fragment produces a valid plist" \
        || bad "injected fragment breaks plist validity"
else
    ok "plutil unavailable; skipped plist lint (non-macOS runner)"
fi

echo
echo "==> ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
