#!/usr/bin/env bash
#
# tests/test_v1010_ical_doctor_service_auth.sh
#
# FIX 6 (v1.0.10 security lockdown -- wire the #200 service token into
# ical-server, pairs with CM041 fix/v1010-ical-server-auth).
#
# The ical-server (127.0.0.1:8090) launchd plist previously omitted the
# #200 service token, and the Doctor proxy forwarded to :8090 with no
# bearer. Both plists must now carry PWG_SERVICE_TOKEN so the ical-server
# can require it and the Doctor can attach it as a bearer. Env-var name
# PWG_SERVICE_TOKEN is the agreed name both halves read.
#
# ── WHY THIS TEST WAS REWRITTEN, 2026-09-23 ────────────────────────────
#
# It used to grep the plist HEREDOC TEXT for two fixed strings:
#     <key>PWG_SERVICE_TOKEN</key>
#     <string>${PWG_SERVICE_TOKEN}</string>
# Both are satisfied by the text of the template. Neither says anything
# about the value that reaches the customer's plist.
#
# MEASURED against this repo's install.sh: replacing BOTH assignments
#     PWG_SERVICE_TOKEN=$(cat "$SERVICE_TOKEN_FILE")     -> PWG_SERVICE_TOKEN=""
#     PWG_SERVICE_TOKEN=$(openssl rand -hex 32)          -> PWG_SERVICE_TOKEN=""
# left the old test printing its single PASS line, rc=0. Every shipped
# plist would carry <string></string>, the ical-server would require a
# bearer nobody holds, and the Doctor would attach an empty one. The
# authentication is then off on both halves and the gate is green.
#
# WHAT IT DOES NOW: it runs the code and reads the artefact, in two
# places, because the defect can live in either and one cannot see the
# other.
#
#   1. THE GENERATOR. Executes the `if [[ -s "$SERVICE_TOKEN_FILE" ]]`
#      block against an empty secrets dir and asserts the token it
#      produces is 64 hex characters. `PWG_SERVICE_TOKEN=""` fails here.
#
#   2. THE PLISTS. Executes each `cat > ... <<EOF` heredoc with a CANARY
#      token, parses the result as a real property list, and asserts the
#      canary arrives as the VALUE of EnvironmentVariables.PWG_SERVICE_TOKEN.
#      A template that carries the key but never interpolates it -- the
#      literal string "${PWG_SERVICE_TOKEN}" reaching the plist -- fails
#      here, and the old text grep could not tell the two apart.
#
# The canary in (2) is supplied by this test, so (2) alone would MASK a
# blanked generator. That is exactly why (1) exists and why neither is
# sufficient on its own.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

pass=0
fail=0
ok()  { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }

[[ -f "$INSTALL_SCRIPT" ]] || { echo "CANNOT-RUN: install.sh not found" >&2; exit 2; }
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 to parse the plists" >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "CANNOT-RUN: no openssl; the generator cannot be exercised" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A line that is commented out is not code. Used for the chmod assertions
# below, which are still text checks because the chmod runs far from here.
live_lines() {
    awk '
    {
        line = $0
        probe = line
        sub(/^[[:space:]]+/, "", probe)
        if (substr(probe, 1, 1) == "#") next
        n = length(line); sq = 0; dq = 0; out = line
        for (k = 1; k <= n; k++) {
            ch = substr(line, k, 1)
            if (ch == "\\" && sq == 0) { k++; continue }
            if (ch == "\047" && dq == 0) { sq = 1 - sq; continue }
            if (ch == "\"" && sq == 0) { dq = 1 - dq; continue }
            if (ch == "#" && sq == 0 && dq == 0) {
                prev = (k == 1) ? " " : substr(line, k - 1, 1)
                if (prev == " " || prev == "\t") { out = substr(line, 1, k - 1); break }
            }
        }
        print out
    }
' "$1"
}

# ── 1. THE GENERATOR ──────────────────────────────────────────────────
GS="$(/usr/bin/grep -n '^if \[\[ -s "\$SERVICE_TOKEN_FILE" \]\]; then$' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
if [ -z "$GS" ]; then
    echo "CANNOT-RUN: could not find the service-token generator block in install.sh" >&2
    exit 2
fi
GE="$(awk -v s="$GS" 'NR > s && /^fi$/ { print NR; exit }' "$INSTALL_SCRIPT")"
sed -n "${GS},${GE}p" "$INSTALL_SCRIPT" > "${WORK}/gen.sh"

mkdir -p "${WORK}/secrets"
{
    echo 'set +u'
    echo "SERVICE_TOKEN_FILE=\"${WORK}/secrets/service_token\""
    echo 'info() { :; }; ok() { :; }'
    echo ". \"${WORK}/gen.sh\""
    echo 'printf "%s" "$PWG_SERVICE_TOKEN" > "'"${WORK}"'/generated.txt"'
} > "${WORK}/rungen.sh"
bash "${WORK}/rungen.sh" >/dev/null 2>"${WORK}/gen.err"

GENERATED="$(cat "${WORK}/generated.txt" 2>/dev/null || true)"
if [ -z "$GENERATED" ]; then
    bad "the service-token generator produced an EMPTY token -- every plist would ship <string></string> and both halves of the #200 auth would be off"
elif [[ "$GENERATED" =~ ^[0-9a-f]{64}$ ]]; then
    ok "generator produces a 64-hex service token (${#GENERATED} chars)"
else
    bad "generator produced a token that is not 64 hex characters: ${#GENERATED} chars"
fi

# ── 2. THE PLISTS ─────────────────────────────────────────────────────
CANARY="CANARY0000SERVICE0000TOKEN0000feedface"

CHECKER="${WORK}/plistcheck.py"
cat > "$CHECKER" <<'PYEOF'
import plistlib, sys

path, want = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    raw = fh.read()
if not raw.strip():
    print("plist is empty; refusing to call that clean", file=sys.stderr)
    sys.exit(3)
try:
    data = plistlib.loads(raw)
except Exception as exc:                                     # noqa: BLE001
    print(f"not a parseable property list: {exc}", file=sys.stderr)
    sys.exit(1)

env = data.get("EnvironmentVariables")
if not isinstance(env, dict):
    print("plist has no EnvironmentVariables dict", file=sys.stderr)
    sys.exit(1)
if "PWG_SERVICE_TOKEN" not in env:
    print("EnvironmentVariables carries no PWG_SERVICE_TOKEN key", file=sys.stderr)
    sys.exit(1)
got = env["PWG_SERVICE_TOKEN"]
if got != want:
    print(
        "PWG_SERVICE_TOKEN did not reach the plist as a value: "
        f"expected {want!r}, got {got!r}",
        file=sys.stderr,
    )
    sys.exit(1)
sys.exit(0)
PYEOF

render_plist() {   # $1 = start-line regex, $2 = terminator, $3 = var name, $4 = token, $5 = out
    local s e
    s="$(/usr/bin/grep -n "$1" "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
    [ -n "$s" ] || return 1
    e="$(awk -v s="$s" -v t="$2" 'NR > s && $0 == t { print NR; exit }' "$INSTALL_SCRIPT")"
    [ -n "$e" ] || return 1
    sed -n "${s},${e}p" "$INSTALL_SCRIPT" > "${WORK}/hd.sh"
    {
        echo 'set +u'
        echo "${3}=\"${5}\""
        echo "PWG_SERVICE_TOKEN=\"${4}\""
        echo ". \"${WORK}/hd.sh\""
    } > "${WORK}/runhd.sh"
    bash "${WORK}/runhd.sh" >/dev/null 2>&1
    [ -s "$5" ]
}

assert_plist() {   # $1 = label, $2 = start regex, $3 = terminator, $4 = var
    local out="${WORK}/$(echo "$1" | tr -c 'A-Za-z0-9' '_').plist"
    if ! render_plist "$2" "$3" "$4" "$CANARY" "$out"; then
        echo "CANNOT-RUN: could not render the $1 plist from install.sh -- the heredoc anchors moved." >&2
        exit 2
    fi
    if "$PY" "$CHECKER" "$out" "$CANARY" 2>"${WORK}/err"; then
        ok "$1 plist: PWG_SERVICE_TOKEN reaches the plist as a value"
    else
        bad "$1 plist: $(cat "${WORK}/err")"
    fi

    # NEGATIVE CONTROL, and it is the exact defect this file was blind to:
    # render the SAME heredoc with an empty token and require a red.
    local blank="${out}.blank"
    if render_plist "$2" "$3" "$4" "" "$blank"; then
        if "$PY" "$CHECKER" "$blank" "$CANARY" 2>/dev/null; then
            bad "$1 plist: CONTROL DID NOT FIRE -- an EMPTY PWG_SERVICE_TOKEN passed"
        else
            ok "$1 plist: control fires on an empty PWG_SERVICE_TOKEN"
        fi
    else
        bad "$1 plist: could not render the empty-token control"
    fi
}

assert_plist "ical-server" 'cat > "\$ICAL_PLIST" <<ICALPLISTEOF'   'ICALPLISTEOF' 'ICAL_PLIST'
assert_plist "Doctor"      'cat > "\$DOCTOR_PLIST" <<DOCEOF'       'DOCEOF'       'DOCTOR_PLIST'

# ── 3. Both plists carry a secret, so both must be chmod 0600 ─────────
# Default umask leaves them 0644 world-readable -> token leak on a
# multi-user Mac. Comment-stripped: a commented-out chmod is not a chmod.
live_lines "$INSTALL_SCRIPT" > "${WORK}/install.live"
for pair in 'ICAL_PLIST:ical-server' 'DOCTOR_PLIST:Doctor'; do
    var="${pair%%:*}"; label="${pair#*:}"
    if [ "$(/usr/bin/grep -cF "chmod 0600 \"\$${var}\"" "${WORK}/install.live")" -gt 0 ]; then
        ok "${label} plist is chmod 0600"
    else
        bad "${label} plist not chmod 0600 (PWG_SERVICE_TOKEN would be world-readable)"
    fi
done

echo
echo "== ical/Doctor service auth: ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
