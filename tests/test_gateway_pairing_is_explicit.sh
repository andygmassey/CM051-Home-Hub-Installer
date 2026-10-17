#!/usr/bin/env bash
# RED TEAM DMG #27 F4-4 (walk #27 item 6c): the companion listener binds
# 0.0.0.0:8443 and the shipped [gateway] config never stated require_pairing
# or a pair rate limit, so both rested on the binary's defaults. This renders
# the REAL [gateway] emission out of install.sh (from `echo "[gateway]"` to the
# companion_enabled line) and parses it as TOML:
#   require_pairing = true, pair_rate_limit_per_minute > 0, and an override
#   that is not a positive integer falls back to 10 (never 0, never text).
# Runs under bash 3.2.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
echo "test_gateway_pairing_is_explicit"
BLOCK="$(awk '/^    echo "\[gateway\]"$/{f=1} f{print} f&&/echo "companion_enabled = /{exit}' "$INSTALL")"
[ -n "$BLOCK" ] || { bad "no [gateway] emission found in install.sh"; echo "  $pass passed, $fail failed"; exit 1; }
render() { _paired_tokens_toml='"synthetic-token"' OSTLER_PAIR_RATE_LIMIT_PER_MINUTE="${1:-}" /bin/bash -c "$BLOCK" 2>/dev/null; }
parse() { python3 -c '
import sys
try:
    import tomllib
except ImportError:
    import re
    t = sys.stdin.read()
    rp = re.search(r"(?m)^require_pairing\s*=\s*(\S+)", t); rl = re.search(r"(?m)^pair_rate_limit_per_minute\s*=\s*(\S+)", t)
    print(rp.group(1) if rp else None, rl.group(1) if rl else None); sys.exit(0)
g = tomllib.loads(sys.stdin.read())["gateway"]
print(str(g.get("require_pairing")).lower(), g.get("pair_rate_limit_per_minute"))
'; }
read -r rp rl <<<"$(render "" | parse)"
[ "$rp" = "true" ] && ok "the shipped [gateway] states require_pairing = true" || bad "require_pairing is not stated true (found $rp)"
[ "${rl:-0}" -gt 0 ] 2>/dev/null && ok "the shipped [gateway] states pair_rate_limit_per_minute = $rl" || bad "no positive pair rate limit (found $rl)"
for v in 0 abc "-5"; do
    read -r _ rl2 <<<"$(render "$v" | parse)"
    [ "$rl2" = "10" ] && ok "an override of '$v' falls back to 10" || bad "an override of '$v' rendered $rl2"
done
read -r _ rl3 <<<"$(render 30 | parse)"
[ "$rl3" = "30" ] && ok "a positive override is honoured (30)" || bad "override 30 rendered $rl3"
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
