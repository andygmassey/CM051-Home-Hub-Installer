#!/usr/bin/env bash
#
# test_oxigraph_proxy_credential.sh
#
# #550 -- OXIGRAPH IS THE ONLY STORE WITH NO NATIVE AUTH.
#
# Qdrant has an API key and Redis has requirepass. Oxigraph 0.4.6 has
# neither, so its credential can only live in the store-proxy. This test
# guards the mechanism that puts it there.
#
# THE INVARIANT THAT MATTERS MOST IS NOT "the check exists". It is:
#
#     THE TOKEN MUST NEVER ENTER THE WORLD-READABLE CONF.
#
# ostler-store-proxy.conf is 644 and bind-mounted as nginx.conf. Writing
# the shared secret into it would be the same defect class as a
# world-readable customer report under /tmp, with a credential as the
# payload -- readable by exactly the second local account #550 is about.
# So the secret lives in a 0600 include, and this test asserts the
# separation rather than trusting the author to have remembered it.
#
# Assertions are `grep -c` and NEVER `... | grep -q`: under pipefail a
# piped `grep -q` exits on first match, SIGPIPEs the producer, and the
# pipeline reports FAILURE for a needle that IS present -- inverting the
# assertion on exactly the input it exists to catch. Measured trigger is
# producer size against the pipe buffer.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

fails=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

[ -f "$INSTALL_SH" ] || { echo "FAIL: install.sh not found -- CANNOT-RUN" >&2; exit 1; }

# ── CONTROL: the block exists at all ─────────────────────────────────
# Without this, every assertion below could pass vacuously against a
# file that no longer generates the credential.
block_lines="$(awk '/^# ── Oxigraph store credential \(#550\)/,/^fi$/' "$INSTALL_SH" | wc -l | tr -d ' ')"
if [ "$block_lines" -lt 10 ]; then
    echo "FAIL: the Oxigraph credential block is absent or truncated" >&2
    echo "      (${block_lines} lines). Every assertion below would be" >&2
    echo "      vacuous, so this is CANNOT-RUN, not a pass." >&2
    exit 1
fi
pass "control: the credential block is present (${block_lines} lines)"

# ── 1. THE SEPARATION INVARIANT ──────────────────────────────────────
# The 644 conf must not carry the token, and must delegate to the include.
proxy_conf="$(awk "/^cat > .\\\$\{OSTLER_DIR\}\/ostler-store-proxy.conf. <<'NGINXEOF'/,/^NGINXEOF\$/" "$INSTALL_SH")"
if [ -z "$proxy_conf" ]; then
    echo "FAIL: could not extract the store-proxy conf heredoc -- CANNOT-RUN" >&2
    exit 1
fi
if [ "$(printf '%s\n' "$proxy_conf" | grep -c 'OXIGRAPH_TOKEN')" -gt 0 ]; then
    fail "the 644 store-proxy conf interpolates OXIGRAPH_TOKEN. A shared secret
      in a world-readable file is readable by the second local account
      that #550 is about."
else
    pass "the 644 conf carries NO token"
fi
if [ "$(printf '%s\n' "$proxy_conf" | grep -c 'include /etc/nginx/ostler-store-auth.conf;')" -gt 0 ]; then
    pass "the 644 conf includes the 0600 credential file"
else
    fail "the 644 conf does not include ostler-store-auth.conf, so the
      credential is never applied however well it is generated"
fi

# ── 2. THE BIND-MOUNT ────────────────────────────────────────────────
# An include with no mounted source is a container that will not start:
# Docker materialises a DIRECTORY at the path and nginx dies with "is a
# directory". Same trap the wiki gate already records.
if [ "$(grep -c 'ostler-store-auth.conf:/etc/nginx/ostler-store-auth.conf:ro' "$INSTALL_SH")" -gt 0 ]; then
    pass "the credential file is bind-mounted into store-proxy"
else
    fail "no bind-mount for ostler-store-auth.conf -- nginx would fail to
      start, or silently include nothing"
fi

# ── 3. BEHAVIOUR: render the generator in both flag states ───────────
# Assert on the FILE THE INSTALLER ACTUALLY WRITES, not on the source
# text that writes it. The instrument and the defect must share a surface.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/.ostler"
awk '/^# ── Oxigraph store credential \(#550\)/,/^fi$/' "$INSTALL_SH" > "$tmp/block.sh"

render() {  # $1 = enforce value; echoes nothing, writes the conf
    ( OSTLER_DIR="$tmp/.ostler"
      OXIGRAPH_TOKEN="SYNTHETIC-TOKEN-NOT-A-SECRET"
      OSTLER_STORE_AUTH_ENFORCE="$1"
      ok() { :; }
      . "$tmp/block.sh" )
}
conf="$tmp/.ostler/ostler-store-auth.conf"

for state in 0 1; do
    rm -f "$conf"
    render "$state"
    if [ ! -s "$conf" ]; then
        fail "enforce=${state}: no credential file was written at all"
        continue
    fi
    mode="$(stat -f '%Sp' "$conf")"
    if [ "$mode" = "-rw-------" ]; then
        pass "enforce=${state}: credential file is 0600 (${mode})"
    else
        fail "enforce=${state}: credential file is ${mode}, not 0600. Any
      local account can read the token."
    fi

    has_token="$(grep -c 'SYNTHETIC-TOKEN-NOT-A-SECRET' "$conf")"
    has_check="$(grep -c 'http_authorization' "$conf")"
    if [ "$state" = "1" ]; then
        [ "$has_check" -gt 0 ] && pass "enforce=1: the bearer check is present" \
            || fail "enforce=1: NO bearer check -- 7878 still answers anyone"
        [ "$has_token" -gt 0 ] && pass "enforce=1: the token is interpolated" \
            || fail "enforce=1: the token did not interpolate, so the check
      compares against an empty string"
    else
        [ "$has_token" -eq 0 ] && pass "enforce=0: no token is written" \
            || fail "enforce=0: a token was written despite auth being off"
    fi
done

# ── 4. HONESTY: default-OFF must SAY it is open ──────────────────────
# A staged control that reads as a fix is worse than no control. The
# off-state file has to name what is still exposed, so the next reader
# cannot mistake its presence for protection -- which is precisely how
# store-auth sat staged and default-OFF until #550 was demonstrated.
rm -f "$conf"; render 0
if [ "$(grep -ci 'OPEN' "$conf")" -gt 0 ]; then
    pass "enforce=0: the file states that #550's Oxigraph half is still open"
else
    fail "enforce=0: the placeholder does not say the hole is open. Someone
      will read 'store credential' and assume it is closed."
fi

echo ""
if [ "$fails" -eq 0 ]; then
    echo "oxigraph proxy credential: PASS"
    exit 0
fi
echo "oxigraph proxy credential: FAIL (${fails})" >&2
exit 1
