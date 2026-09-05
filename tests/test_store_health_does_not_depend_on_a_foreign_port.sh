#!/usr/bin/env bash
# THE STORE HEALTH ARMS MUST NOT REPORT HEALTHY BECAUSE SOMEONE ELSE'S CONTAINER ANSWERED.
#
# WHY THIS EXISTS. The :11434 arm was measured doing exactly this on the v1.0.66
# artefact walk (#1471): another account on the same Mac served the port, the
# bare loopback curl got its 200, and health_check reported a component healthy
# for an install that did not have it.
#
#     curl http://127.0.0.1:11434/    -> 200
#     lsof -nP -iTCP:11434 (as us)    -> NOTHING
#     STEP_END id=health_check status=ok
#
# :6333 had the SAME SHAPE and could not be closed the same way:
#
#   - Ollama ships as com.ostler.ollama, a LaunchAgent this installer writes,
#     so #1471 could ask launchctl. Qdrant and Oxigraph are colima CONTAINERS
#     with no launchd identity, so that instrument would answer a confident
#     "absent" for a healthy store -- wrong in a NEW direction, which is worse
#     than the honest blindness it replaced.
#   - A credential cannot close :6333 either: Qdrant exempts /healthz from the
#     api-key by the vendor's own design, so a foreign Qdrant answers our probe
#     exactly as ours does. (:7878 IS credentialled, and that credential is a
#     real ownership signal while store auth is enforced. This adds the
#     container signal alongside it so both arms rest on the same evidence.)
#
# The instrument is `docker compose ps -q`, which resolves the service inside
# OUR compose project: a foreign holder yields an EMPTY id, not a container.
#
# THIS TEST DRIVES THE CONDITION, NOT THE FILE. It extracts the real helper and
# the real guard out of install.sh and executes them against stubbed docker/curl,
# so a reword that drops the ownership check fails here rather than passing a
# copy of itself.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── extract the REAL helper, from its definition to its closing brace ────────
HELPER="$(awk '/^_ostler_store_container_is_ours\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SUBJECT")"
case "$HELPER" in
    *"docker compose ps -q"*) : ;;
    *) echo "CANNOT-RUN: _ostler_store_container_is_ours was not found in install.sh," >&2
       echo "  or no longer uses 'docker compose ps -q' as its ownership signal." >&2
       echo "  It is extracted by name so a rename fails LOUDLY here rather than" >&2
       echo "  silently testing nothing." >&2
       exit 2 ;;
esac

# ── extract the REAL guards (two physical lines, joined by a backslash) ──────
_guard_for() {
    awk -v svc="$1" '
        $0 ~ ("_ostler_store_container_is_ours " svc) {print; got=1; next}
        got {print; exit}
    ' "$SUBJECT"
}
G_QDRANT="$(_guard_for qdrant)"
G_OXIGRAPH="$(_guard_for oxigraph)"
for pair in "qdrant:${G_QDRANT}" "oxigraph:${G_OXIGRAPH}"; do
    svc="${pair%%:*}"; g="${pair#*:}"
    case "$g" in
        *"curl"*"; then") : ;;
        *) echo "CANNOT-RUN: could not extract the ${svc} health guard from install.sh." >&2
           echo "  got: ${g:-<empty>}" >&2
           exit 2 ;;
    esac
done

# ── drive it ────────────────────────────────────────────────────────────────
# container: absent | stopped | running      port: 1 answering, 0 silent
_drive() {
    local container="$1" answering="$2" guard="$3"
    local proj="${WORK}/proj"; mkdir -p "$proj"
    cat > "${WORK}/run.sh" <<EOF
set -uo pipefail
OSTLER_DIR="${proj}"
_OSTLER_STORE_CURL_ARGS=()
docker() {
    case "\$1" in
        compose) [ "${container}" = absent ] || printf 'cid-ours-123\n'; return 0 ;;
        inspect) if [ "${container}" = running ]; then printf 'true\n'; else printf 'false\n'; fi; return 0 ;;
    esac
    return 0
}
curl() { return $(( answering == 1 ? 0 : 1 )); }
${HELPER}
${guard}
    echo HEALTHY
else
    echo UNHEALTHY
fi
EOF
    /bin/bash "${WORK}/run.sh" 2>/dev/null
}

printf '\n== :6333 qdrant -- the arm with NO credential to fall back on ==\n'
# THE ARM THAT MATTERS: a foreign holder answers the port, our container is absent.
r="$(_drive absent 1 "$G_QDRANT")"
[ "$r" = UNHEALTHY ] && ok "foreign holder answering + our container ABSENT -> ${r}" \
                     || bad "foreign holder answering + our container ABSENT -> ${r} (want UNHEALTHY)"
r="$(_drive stopped 1 "$G_QDRANT")"
[ "$r" = UNHEALTHY ] && ok "our container present but NOT running -> ${r}" \
                     || bad "our container present but NOT running -> ${r} (want UNHEALTHY)"
r="$(_drive running 1 "$G_QDRANT")"
[ "$r" = HEALTHY ]   && ok "our container running AND port answering -> ${r}" \
                     || bad "our container running AND port answering -> ${r} (want HEALTHY)"
r="$(_drive running 0 "$G_QDRANT")"
[ "$r" = UNHEALTHY ] && ok "our container running but port silent -> ${r}" \
                     || bad "our container running but port silent -> ${r} (want UNHEALTHY)"

printf '\n== :7878 oxigraph -- same four states ==\n'
for st in "absent 1 UNHEALTHY" "stopped 1 UNHEALTHY" "running 1 HEALTHY" "running 0 UNHEALTHY"; do
    set -- $st
    r="$(_drive "$1" "$2" "$G_OXIGRAPH")"
    [ "$r" = "$3" ] && ok "container=$1 answering=$2 -> ${r}" \
                    || bad "container=$1 answering=$2 -> ${r} (want $3)"
done

# ── MUTATION ARM: the test must FAIL on the pre-fix subject ──────────────────
# A gate that passes on the defect it exists for is decoration. Re-run the arm
# that matters against the BARE guard this change replaced; it must report
# HEALTHY, which is the defect, which is what this test refuses.
printf '\n== mutation control: the PRE-FIX bare guard must still show the defect ==\n'
r="$(_drive absent 1 'if curl -sf http://localhost:6333/healthz &>/dev/null; then')"
[ "$r" = HEALTHY ] && ok "bare guard, foreign holder, container absent -> ${r} (defect reproduced)" \
                   || bad "bare guard did NOT reproduce the defect -> ${r}; the harness proves nothing"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
