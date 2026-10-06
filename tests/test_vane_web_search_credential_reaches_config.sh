#!/usr/bin/env bash
#
# tests/test_vane_web_search_credential_reaches_config.sh
#
# v1.0.107 console walk (Andy, candidate #9, BLOCKING): web_search 401s on
# a FRESH install. Andy asked the assistant "What's on at the cinema that
# I may like?" and it replied that the search tool "returned an
# authorization error".
#
# MEASURED on the walk box (macmini16-walk, read-only):
#   - curl --noproxy '*' http://127.0.0.1:3000/  -> 401, WWW-Authenticate:
#     Basic realm="Ostler assistant" (Vane's nginx front door, #1660/#1672,
#     now demands a credential).
#   - ~/.ostler/assistant-config/config.toml carried a (correctly-named)
#     [web_search] section with vane_url = "http://localhost:3000" -- no
#     credential.
#   - install.sh's own comment at the web_search emission block already
#     described the #1660/#1672 fix (embed ostler:$VANE_PASSWORD@ in the
#     URL's userinfo so reqwest sends Basic auth automatically) -- but
#     wrote it under "[tools.web_search]", a table NOTHING in the schema
#     reads. `Config.web_search` (ostler-assistant crates/zeroclaw-config/
#     src/schema.rs:289) is a TOP-LEVEL field; the only correct header is
#     "[web_search]". Under the wrong header the credentialed line still
#     gets written to disk, but the daemon's parser never looks at that
#     table, so WebSearchConfig::default() (uncredentialed) wins -- and the
#     daemon's own Config::save() round-trip then overwrites the file with
#     a CORRECTLY-named "[web_search]" section carrying that same default,
#     which is why the live file on the walk box showed the right header
#     with the wrong value: the credential had been landing nowhere both
#     before and after that round-trip.
#
# WHY THIS TEST DOES NOT JUST GREP FOR THE STRING "[web_search]" ─────────
#
# The old block had the text "web_search" in it too (inside
# "[tools.web_search]"), so a plain string grep for "web_search" would
# have passed on the broken block. The defect is about which TABLE the
# key lands in, which only a real TOML parse can see. This test executes
# the actual `echo` statements install.sh runs, with a canary password,
# and parses the result with Python's stdlib tomllib -- the same
# generator-then-parse shape as test_v1010_ical_doctor_service_auth.sh,
# applied to a TOML fragment instead of a plist.
#
# British English throughout.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

pass=0
fail=0
ok()  { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$INSTALL_SCRIPT" ] || { echo "CANNOT-RUN: install.sh not found" >&2; exit 2; }
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 to parse the TOML" >&2; exit 2; }
"$PY" -c 'import tomllib' >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 has no tomllib (needs 3.11+)" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Locate the real emission block by its CODE lines, not a comment ────
# Matches EITHER table name on purpose: the anchor must still find the
# block if some future edit regresses the header back to the wrong
# "[tools.web_search]" table, so that regression is a genuine FAIL from
# the checker below rather than a CANNOT-RUN from a vanished anchor.
START_LN="$(/usr/bin/grep -n '^    echo "\[\(tools\.\)\?web_search\]"$' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
if [ -z "$START_LN" ]; then
    echo "CANNOT-RUN: could not find the web_search table emission ('echo \"[web_search]\"' or 'echo \"[tools.web_search]\"') in install.sh -- has it moved to a different shape entirely?" >&2
    exit 2
fi
END_LN="$(awk -v s="$START_LN" 'NR > s && /echo "vane_url = /{print NR; exit}' "$INSTALL_SCRIPT")"
if [ -z "$END_LN" ]; then
    echo "CANNOT-RUN: found the [web_search] header but not the following vane_url emission" >&2
    exit 2
fi
sed -n "${START_LN},${END_LN}p" "$INSTALL_SCRIPT" > "${WORK}/emit.sh"

CANARY="canary-vane-pw-7f3a9c"

render() {
    # $1: the emission source to run (so the negative control below can
    # swap in a deliberately-wrong header). $2: output path.
    local src="$1" out="$2"
    {
        echo 'set -u'
        echo "VANE_PASSWORD=\"${CANARY}\""
        echo ". \"${src}\""
    } > "${WORK}/run.sh"
    bash "${WORK}/run.sh" > "$out" 2>"${WORK}/run.err"
}

CHECKER="${WORK}/tomlcheck.py"
cat > "$CHECKER" <<'PYEOF'
import sys, tomllib

path, canary = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    raw = fh.read()
if not raw.strip():
    print("rendered TOML fragment is empty", file=sys.stderr)
    sys.exit(3)
try:
    data = tomllib.loads(raw.decode("utf-8"))
except Exception as exc:                                     # noqa: BLE001
    print(f"not a parseable TOML document: {exc}", file=sys.stderr)
    sys.exit(1)

web_search = data.get("web_search")
if not isinstance(web_search, dict):
    # The exact shape of the bug this test exists to catch: present under
    # the wrong table (e.g. tools.web_search) instead of top-level.
    nested = isinstance(data.get("tools"), dict) and "web_search" in data.get("tools", {})
    where = "under [tools.web_search] instead of top-level [web_search]" if nested else "missing entirely"
    print(f"no top-level [web_search] table ({where})", file=sys.stderr)
    sys.exit(1)

if web_search.get("provider") != "vane":
    print(f"web_search.provider = {web_search.get('provider')!r}, want 'vane'", file=sys.stderr)
    sys.exit(1)

vane_url = web_search.get("vane_url") or ""
want = f"ostler:{canary}@localhost:3000"
if want not in vane_url:
    print(f"web_search.vane_url = {vane_url!r} does not carry the credentialed userinfo {want!r}", file=sys.stderr)
    sys.exit(1)

print("ok")
PYEOF

# ── 1. THE REAL EMISSION, AS SHIPPED ────────────────────────────────────
OUT="${WORK}/real.toml"
render "${WORK}/emit.sh" "$OUT"
if "$PY" "$CHECKER" "$OUT" "$CANARY" >"${WORK}/real.out" 2>"${WORK}/real.err"; then
    ok "install.sh's web_search emission lands [web_search].vane_url with the credentialed userinfo"
else
    bad "install.sh's web_search emission: $(cat "${WORK}/real.err")"
fi

# ── 2. NEGATIVE CONTROL: the exact regression this test exists to catch ─
# Reproduce the shape of the original defect (right-looking text, wrong
# table) and require the SAME checker to red on it. If this control does
# not fire, assertion 1 above is not actually discriminating anything.
cat > "${WORK}/wrong.sh" <<'WRONGEOF'
    echo "[tools.web_search]"
    echo "provider = \"vane\""
    echo "vane_url = \"http://ostler:${VANE_PASSWORD}@localhost:3000\""
WRONGEOF
WRONG_OUT="${WORK}/wrong.toml"
render "${WORK}/wrong.sh" "$WRONG_OUT"
if "$PY" "$CHECKER" "$WRONG_OUT" "$CANARY" >/dev/null 2>"${WORK}/wrong.err"; then
    bad "CONTROL DID NOT FIRE -- a [tools.web_search] (wrong table) fragment passed the checker"
else
    ok "control fires on the [tools.web_search] (wrong-table) shape: $(cat "${WORK}/wrong.err")"
fi

echo
echo "== vane web_search credential reaches config: ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
