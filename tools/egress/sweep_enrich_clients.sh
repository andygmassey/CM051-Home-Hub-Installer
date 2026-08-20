#!/bin/bash
# The enrichment clients SHIP and install.sh:13217 RUNS them.
# For each: which host, and is it gated behind an API key (inert without one)
# or does it call unconditionally?
#
# "Ships" and "runs" are different claims and so are "runs" and "reaches the
# network". This measures the third.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
D=vendor/cm019_preferences/services/enrich/src/clients

printf '%-22s %-42s %s\n' CLIENT HOST KEY-GATED
printf '%-22s %-42s %s\n' ------ ---- ---------
for f in $(git ls-files "$D" | grep -vE '__init__|base\.py'); do
    name="$(basename "$f" .py)"
    hosts="$(grep -ohE 'https?://[a-zA-Z0-9._-]+' "$f" | sed -E 's|https?://||' | sort -u | tr '\n' ',' | sed 's/,$//')"
    # An env-var read whose name looks like a credential is the gate.
    key="$(grep -ohE 'getenv\("[A-Z0-9_]*(KEY|TOKEN|SECRET|APP_ID)[A-Z0-9_]*"|environ\[?"[A-Z0-9_]*(KEY|TOKEN|SECRET)[A-Z0-9_]*"' "$f" | head -1)"
    printf '%-22s %-42s %s\n' "$name" "${hosts:-<none in source>}" "${key:+YES}"
done
echo
echo "=== CONTROL: does any of these files import an HTTP client at all? ==="
printf '  files importing httpx/requests/aiohttp: %s of %s\n' \
  "$(git grep -lE '^\s*(import|from)\s+(httpx|requests|aiohttp)' -- "$D" | grep -c .)" \
  "$(git ls-files "$D" | grep -c .)"
echo "=== CONTROL: a string that must be absent ==="
printf '  files matching notarealclient: %s\n' "$(git grep -lE 'notarealclient' -- "$D" | grep -c .)"
echo
echo "=== is the enrich CLI reachable from install.sh, and under what condition? ==="
git grep -nE 'services.enrich.src.cli' -- install.sh | sed 's/^/  /'
echo
echo "  --- the surrounding guard ---"
sed -n '13200,13225p' install.sh | sed 's/^/  /'
