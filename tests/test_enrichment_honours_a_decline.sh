#!/usr/bin/env bash
#
# tests/test_enrichment_honours_a_decline.sh
#
# PRIVACY, walk #28. Setup asks consent_enrichment ("look things up in public
# reference sources?", default no) and records the answer in
# ~/.ostler/config/.env as OSTLER_CONSENT_ENRICHMENT_DECISION. Before this
# test, ostler-import ran `services.enrich.src.cli enrich --all` on every
# import whatever the answer, and ostler-scan-exports runs ostler-import every
# time an export lands in Downloads. So: say no, drop a data export, and the
# titles and artists in it went to Wikidata and MusicBrainz anyway.
#
# Three launchers, each RUN, not grepped, under four recorded answers
# (accepted / declined / key absent / no .env at all):
#
#   A  the REAL generated ostler-import (IMPORTEOF heredoc from install.sh),
#      its CM019 python stubbed to COUNT enrich invocations.
#   B  the REAL enrich tick wrapper (ENRTICKEOF heredoc), same stub.
#   C  the REAL vendored enrich CLI (`enrich --all`), the backstop, with a
#      socket guard installed by sitecustomize: every connect() and every
#      DNS lookup is recorded and refused. Declined or unknown must record
#      ZERO attempts; accepted must record at least one, which is the control
#      proving the guard can see traffic at all.
#
# Only "accepted" may reach enrichment. Synthetic data only. Exit 2 is
# CANNOT-RUN (the vendored CLI is not importable), never a pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
CM019_SRC="${REPO}/vendor/cm019_preferences"
PY="${PYTHON:-python3}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cannot() { echo "CANNOT RUN: $*" >&2; exit 2; }
status=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; status=1; }

[[ -f "$INSTALL_SH" ]] || cannot "install.sh not found"

awk '/cat > "\$IMPORT_SCRIPT" <<.IMPORTEOF./{f=1;next} f&&/^IMPORTEOF$/{exit} f{print}' "$INSTALL_SH" > "$WORK/ostler-import"
grep -q 'services.enrich.src.cli enrich' "$WORK/ostler-import" || cannot "could not extract ostler-import from install.sh"
awk "/<<'ENRTICKEOF'/{f=1;next} /^ENRTICKEOF\$/{f=0} f" "$INSTALL_SH" > "$WORK/enrich-tick"
grep -q 'services.enrich.src.cli enrich' "$WORK/enrich-tick" || cannot "could not extract the enrich tick from install.sh"
chmod +x "$WORK/ostler-import" "$WORK/enrich-tick"

# launchctl / curl must not touch the real session or the network.
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin/launchctl"
printf '#!/usr/bin/env bash\necho "curl reached: $*" >> "%s/curl.calls"\nexit 7\n' "$WORK" > "$WORK/bin/curl"
chmod +x "$WORK/bin/launchctl" "$WORK/bin/curl"

# home <name> <answer>: answer is accepted|declined|absent-key|no-env
home() {
    local h="$WORK/$1" a="$2"
    mkdir -p "$h/.ostler/config" "$h/.ostler/services/cm019/.venv/bin" "$h/exports/synthetic"
    : > "$h/exports/synthetic/placeholder.json"
    case "$a" in
        accepted|declined) printf 'USER_ID="jane"\nOSTLER_CONSENT_ENRICHMENT_DECISION="%s"\n' "$a" > "$h/.ostler/config/.env" ;;
        absent-key)        printf 'USER_ID="jane"\n' > "$h/.ostler/config/.env" ;;
        no-env)            rm -f "$h/.ostler/config/.env" ;;
    esac
    # Stub CM019 python (both names the launchers use): ingest is local and
    # succeeds; every enrich invocation is COUNTED.
    local stub="$h/.ostler/services/cm019/.venv/bin/python"
    printf '#!/usr/bin/env bash\ncase " $* " in *" services.enrich.src.cli "*) echo enrich >> "%s/enrich.calls" ;; esac\nexit 0\n' "$h" > "$stub"
    chmod +x "$stub"; cp "$stub" "${stub}3"
    : > "$h/enrich.calls"
    echo "$h"
}
calls() { wc -l < "$1/enrich.calls" | tr -d ' '; }

ANSWERS=(accepted declined absent-key no-env)

# ── A: ostler-import ──────────────────────────────────────────────────────
for a in "${ANSWERS[@]}"; do
    h="$(home "imp-$a" "$a")"
    # A caller's leftover variable must NOT count as the customer's answer.
    HOME="$h" PATH="$WORK/bin:$PATH" OSTLER_CONSENT_ENRICHMENT_DECISION=accepted \
        "$WORK/ostler-import" "$h/exports" --user-name "Jane Doe" --user-id jane >"$h/out" 2>&1
    rc=$?
    n="$(calls "$h")"
    if [[ "$a" == accepted ]]; then
        [[ "$n" -ge 1 ]] && pass "A ostler-import, answer=$a: enrich ran ($n), rc=$rc" \
                         || fail "A ostler-import, answer=$a: enrich did NOT run; the yes path is broken"
    else
        [[ "$n" -eq 0 ]] && pass "A ostler-import, answer=$a: 0 enrich invocations, rc=$rc" \
                         || fail "A ostler-import, answer=$a: enrich ran $n time(s) after the customer did not say yes"
    fi
done

# ── B: the recurring enrich tick ──────────────────────────────────────────
for a in "${ANSWERS[@]}"; do
    h="$(home "tick-$a" "$a")"
    HOME="$h" PATH="$WORK/bin:$PATH" OSTLER_DIR="$h/.ostler" OXIGRAPH_URL="http://127.0.0.1:1" \
        OSTLER_CONSENT_ENRICHMENT_DECISION=accepted \
        bash "$WORK/enrich-tick" >"$h/out" 2>&1
    rc=$?
    n="$(calls "$h")"
    if [[ "$a" == accepted ]]; then
        [[ "$n" -ge 1 ]] && pass "B enrich tick, answer=$a: enrich ran ($n), rc=$rc" \
                         || fail "B enrich tick, answer=$a: enrich did NOT run; the yes path is broken"
    else
        if [[ "$n" -eq 0 ]] && grep -q 'not agreed' "$h/.ostler/logs/enrich.log"; then
            pass "B enrich tick, answer=$a: 0 enrich invocations, and the log says why"
        else
            fail "B enrich tick, answer=$a: enrich ran $n time(s) (or stood down silently)"
        fi
    fi
done

# ── C: the vendored enrich CLI backstop, network guarded ─────────────────
#
# THE SCRATCH HOME MUST NOT HIDE THE DEPENDENCIES. Arm C runs under HOME=<a
# scratch home>, and on the CI runner `pip install` lands in the USER site,
# which Python derives from HOME. The first CI run of this test died in all
# four C arms on "No module named pydantic_settings" while the import check
# (run under the REAL home) passed, and that read as four guard FAILs. So the
# interpreter keeps its ORIGINAL user base, the way a venv keeps its packages,
# and the import check runs in the C arms' exact environment. A missing
# dependency is CANNOT-RUN (exit 2), never a guard verdict.
PY_USERBASE="$("$PY" -c 'import site; print(site.getuserbase())' 2>/dev/null)"
mkdir -p "$WORK/importcheck-home"
( cd "$CM019_SRC" && HOME="$WORK/importcheck-home" PYTHONUSERBASE="$PY_USERBASE" \
    "$PY" -c "import services.enrich.src.cli" ) 2>"$WORK/imp.err" \
    || cannot "the vendored enrich CLI is not importable by ${PY} in arm C's environment: $(tail -1 "$WORK/imp.err") (pip install -r vendor/cm019_preferences/requirements.txt)"

mkdir -p "$WORK/guard"
cat > "$WORK/guard/sitecustomize.py" <<'PYEOF'
import os, socket
_log = os.environ["NET_GUARD_LOG"]
def _record(what):
    with open(_log, "a") as fh:
        fh.write(what + "\n")
def _connect(self, addr, *a, **k):
    _record("connect %r" % (addr,)); raise OSError("network guarded by test")
def _getaddrinfo(host, *a, **k):
    _record("dns %r" % (host,)); raise socket.gaierror("network guarded by test")
socket.socket.connect = _connect
socket.socket.connect_ex = _connect
socket.getaddrinfo = _getaddrinfo
PYEOF

for a in "${ANSWERS[@]}"; do
    h="$(home "cli-$a" "$a")"
    : > "$h/net.log"
    # Proxy variables are cleared so the guard sees the real destination,
    # not a local proxy that would answer for every host.
    ( cd "$CM019_SRC" && unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy && \
        HOME="$h" PYTHONUSERBASE="$PY_USERBASE" NET_GUARD_LOG="$h/net.log" PYTHONPATH="$WORK/guard" \
        OSTLER_CONSENT_ENRICHMENT_DECISION=accepted QDRANT_COLLECTION=preferences \
        "$PY" -m services.enrich.src.cli enrich --all --budget-seconds 5 --limit 5 -u jane ) >"$h/out" 2>&1
    rc=$?
    if grep -qE '(ModuleNotFoundError|ImportError)' "$h/out"; then
        cannot "arm C, answer=$a: the enrich CLI could not import its dependencies, so the guard measured nothing: $(grep -E '(ModuleNotFoundError|ImportError)' "$h/out" | tail -1)"
    fi
    n="$(wc -l < "$h/net.log" | tr -d ' ')"
    case "$a" in
        accepted)
            [[ "$n" -ge 1 ]] && pass "C enrich CLI, answer=$a: reached the network layer ($n attempt(s) seen by the guard, e.g. $(head -1 "$h/net.log")), rc=$rc" \
                             || { fail "C enrich CLI, answer=$a: the guard saw nothing, so it cannot vouch for the other arms"; tail -5 "$h/out" | sed 's/^/  | /'; } ;;
        declined)
            [[ "$n" -eq 0 && "$rc" -eq 0 ]] && pass "C enrich CLI, answer=$a: 0 network attempts, rc=0" \
                                            || { fail "C enrich CLI, answer=$a: $n network attempt(s), rc=$rc"; head -3 "$h/net.log" | sed 's/^/  | /'; } ;;
        *)
            [[ "$n" -eq 0 && "$rc" -eq 3 ]] && pass "C enrich CLI, answer=$a: 0 network attempts, rc=3 (could not read an answer)" \
                                            || { fail "C enrich CLI, answer=$a: $n network attempt(s), rc=$rc (want 0 and rc=3)"; head -3 "$h/net.log" | sed 's/^/  | /'; } ;;
    esac
done

[[ ! -s "$WORK/curl.calls" ]] || echo "note: curl stub was reached by: $(sort -u "$WORK/curl.calls" | head -3)"
echo "denominator: 3 launchers x 4 recorded answers = 12 runs; only answer=accepted may enrich"
exit "$status"
