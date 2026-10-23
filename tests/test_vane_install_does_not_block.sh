#!/bin/bash
# THE INSTALL DOES NOT WAIT FOR WEB SEARCH, AND SAYS SO HONESTLY (v1.0.118 W5).
#
# v1.0.117 walks: `vane_install` blocked the install for 6515 s on a slow link
# (a 3.43 GB pull), and on a console install it died part-way while the step
# closed `unmeasured` and the install said DONE with 0 failed steps.
#
# This runs the REAL vane_install step, the REAL health-check lines and the
# REAL closing-summary lines, cut out of install.sh, with the REAL progress
# emitter, against a fake docker whose `compose up -d vane` / `pull vane`
# would sit for 10 minutes the way a cold pull does:
#
#   1. cold box -> the step returns in seconds, never pulls, loads the
#      com.ostler.vane-fetch LaunchAgent (RunAtLoad + StartInterval), closes
#      `pending` (NOT ok, NOT unmeasured), DONE carries pending_steps=1 and
#      failed_steps=0, and the health check and summary say
#      "Web search: getting ready (downloading in the background)".
#   2. warm box (image already local, credential answers) -> ready, step ok,
#      the summary shows the local web search address.
#   3. the agent cannot be loaded -> the step is an ERROR (counted failed) and
#      the summary says "not installed". Never ok, never silent.
#
# Exit: 0 pass, 1 fail, 2 cannot-run. Runs under /bin/bash 3.2.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

[ -r "$INSTALL" ] && [ -r "${REPO}/lib/progress_emitter.sh" ] || { echo "CANNOT-RUN: install.sh or lib/progress_emitter.sh missing"; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# The step: from its progress call to the next section header.
awk '/^progress "Starting local web search \(Vane\)" "vane_install"$/{on=1} /^# ── 3\.9 AI models/{on=0} on' "$INSTALL" > "${T}/step.sh"
# The health-check lines and the summary lines, by the anchors they carry.
awk '/^if \[\[ -x "\$\{OSTLER_DIR\}\/bin\/ostler-vane-fetch" \]\] \\$/{on=1} on{print} on && /^fi$/{exit}' "$INSTALL" > "${T}/health.sh"
awk '/^case "\$\{VANE_STATE:-failed\}" in$/{on=1} on{print} on && /^esac$/{exit}' "$INSTALL" > "${T}/summary.sh"
[ -s "${T}/step.sh" ] || { echo "CANNOT-RUN: no vane_install step found in install.sh"; exit 2; }
# A missing health or summary block is a FAIL, but the step still runs so
# the run shows WHAT the old code does (it blocks), not just that a line moved.
for f in health summary; do
    if [ ! -s "${T}/${f}.sh" ]; then
        bad "install.sh has no background-aware ${f} block for web search"
        echo ':' > "${T}/${f}.sh"
    fi
done
grep -q 'ostler-vane-fetch' "${T}/step.sh" || bad "the vane_install step does not hand the download to a background fetcher"

mkdir -p "${T}/bin"
cat > "${T}/bin/docker" <<'EOF'
#!/bin/bash
F="${FAKE:?}"
echo "$*" >> "${F}/calls"
case "$1" in
    image) [ -f "${F}/image_present" ] && exit 0; exit 1 ;;
    inspect) [ -f "${F}/running" ] && { echo true; exit 0; }; exit 1 ;;
    compose)
        case " $* " in
            *" pull vane "*|*" up -d vane "*)
                if [ ! -f "${F}/image_present" ]; then sleep 600; exit 1; fi
                : > "${F}/running"; exit 0 ;;
        esac ;;
esac
exit 0
EOF
cat > "${T}/bin/curl" <<'EOF'
#!/bin/bash
cfg="$(cat)"
if [ -f "${FAKE:?}/running" ] && [ "$cfg" = 'user = "ostler:synthetic-pass-word"' ]; then printf 200; else printf 401; fi
EOF
chmod 755 "${T}/bin/"*

# run_case <name> <warm:0|1> <load_rc>
run_case() {
    FAKE="${T}/$1"; mkdir -p "${FAKE}/hm/.ostler/secrets"
    printf 'synthetic-pass-word\n' > "${FAKE}/hm/.ostler/secrets/vane_password"
    printf 'services:\n  vane:\n    image: example.invalid/vane@sha256:2222\n' > "${FAKE}/hm/.ostler/docker-compose.yml"
    [ "$2" = 1 ] && : > "${FAKE}/image_present"
    cat > "${FAKE}/harness.sh" <<EOF
set -Eeuo pipefail
trap 'echo "ERR trap fired at line \$LINENO" >&2; exit 99' ERR
export FAKE='${FAKE}'
export HOME='${FAKE}/hm'
export PATH='${T}/bin':"\$PATH"
export OSTLER_GUI=1
export OSTLER_VANE_DOCKER='${T}/bin/docker' OSTLER_VANE_CURL='${T}/bin/curl' OSTLER_VANE_HEALTH_WAIT_S=0
OSTLER_DIR='${FAKE}/hm/.ostler'; OSTLER_FINAL_DIR="\$OSTLER_DIR"
BOLD=''; NC=''
source '${REPO}/lib/progress_emitter.sh'
source '${REPO}/install.sh.strings.en-GB.sh'
progress() { if [[ -n "\${__OSTLER_STEP_ID:-}" ]]; then gui_step_end; fi; gui_step_begin "\$2" "\$1"; }
info() { echo "[info] \$*"; }
ok()   { echo "[ok] \$*"; }
warn() { echo "[warn] \$*"; }
_ostler_launchagent_load_verified() { echo "\$1" >> '${FAKE}/loads'; return $3; }
source '${T}/step.sh'
gui_step_end
echo "VANE_STATE=\$VANE_STATE"
source '${T}/health.sh'
source '${T}/summary.sh'
gui_done ok
EOF
    /bin/bash "${FAKE}/harness.sh" > "${FAKE}/out" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        BLOCKED=1
    else
        wait "$pid"; RC=$?; BLOCKED=0
    fi
    ELAPSED=$waited
}

echo "== 1. cold box: the install does not wait for the 3.4 GB download =="
run_case cold 0 0
[ "$BLOCKED" = 0 ] && ok "vane_install returned in ${ELAPSED}s with the pull still to do" || bad "the install BLOCKED on the Vane download (killed after 30 s)"
[ "${RC:-1}" = 0 ] && ok "no abort" || bad "harness exit ${RC:-?}: $(tail -3 "${FAKE}/out")"
grep -q 'pull vane\|up -d vane' "${FAKE}/calls" 2>/dev/null && bad "the install itself pulled or started vane" || ok "the install never pulled"
grep -q 'VANE_STATE=pending' "${FAKE}/out" && ok "VANE_STATE=pending" || bad "VANE_STATE was not pending: $(grep VANE_STATE "${FAKE}/out")"
grep -q $'STEP_END\tid=vane_install\tstatus=pending' "${FAKE}/out" && ok "STEP_END vane_install status=pending" \
    || bad "vane_install closed as: $(grep 'id=vane_install' "${FAKE}/out" | tr '\t' ' ')"
grep $'\tDONE\t' "${FAKE}/out" | grep -q $'failed_steps=0\tunmeasured_steps=0\tpending_steps=1' && ok "DONE carries pending_steps=1, failed_steps=0, unmeasured_steps=0" \
    || bad "DONE line: $(grep 'DONE' "${FAKE}/out" | tr '\t' ' ')"
grep -q '^\[info\] Web search: getting ready (downloading in the background)$' "${FAKE}/out" && ok "health check: getting ready" || bad "health check did not say getting ready"
grep -q '^  Web search: getting ready (downloading in the background)$' "${FAKE}/out" && ok "final summary: Web search: getting ready (downloading in the background)" \
    || bad "summary did not say getting ready"
grep -q 'Vane healthy' "${FAKE}/out" && bad "claimed Vane healthy while it was downloading" || ok "never claimed healthy"
PLIST="${FAKE}/hm/Library/LaunchAgents/com.ostler.vane-fetch.plist"
[ "$(cat "${FAKE}/loads" 2>/dev/null)" = "$PLIST" ] && ok "loaded the LaunchAgent" || bad "agent not loaded: $(cat "${FAKE}/loads" 2>/dev/null)"
if [ -f "$PLIST" ]; then
    grep -q '<string>com.ostler.vane-fetch</string>' "$PLIST" && grep -A1 'RunAtLoad' "$PLIST" | grep -q '<true/>' \
        && grep -q '<key>StartInterval</key>' "$PLIST" && grep -q "<string>${FAKE}/hm/.ostler/bin/ostler-vane-fetch</string>" "$PLIST" \
        && ok "plist: label, RunAtLoad, StartInterval, the staged fetcher" || bad "plist is missing a key: $(cat "$PLIST")"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$PLIST" >/dev/null && ok "plutil -lint OK" || bad "plutil rejects the plist"
    else
        echo "  CANNOT-RUN plutil absent on this host; plist lint not run"
    fi
else
    bad "no plist written"
fi
[ -x "${FAKE}/hm/.ostler/bin/ostler-vane-fetch" ] && ok "fetcher staged executable" || bad "fetcher not staged"

echo "== 2. warm box: image already local =="
run_case warm 1 0
[ "$BLOCKED" = 0 ] && [ "${RC:-1}" = 0 ] && ok "returned, no abort" || bad "blocked=${BLOCKED} rc=${RC:-?}"
grep -q $'STEP_END\tid=vane_install\tstatus=ok\telapsed_s=[0-9]*\tmeasured=rc' "${FAKE}/out" && ok "STEP_END vane_install status=ok measured=rc" \
    || bad "vane_install closed as: $(grep 'id=vane_install' "${FAKE}/out" | tr '\t' ' ')"
grep -q 'Local web search: http://localhost:3000' "${FAKE}/out" && ok "summary shows the local web search address" || bad "summary did not show web search as ready"
grep -q 'getting ready' "${FAKE}/out" && bad "said getting ready on a ready box" || ok "no getting-ready claim on a ready box"

echo "== 3. the agent cannot be loaded =="
run_case noagent 0 1
[ "$BLOCKED" = 0 ] && [ "${RC:-1}" = 0 ] && ok "returned, no abort" || bad "blocked=${BLOCKED} rc=${RC:-?}"
grep -q $'STEP_END\tid=vane_install\tstatus=error' "${FAKE}/out" && ok "STEP_END vane_install status=error (not ok, not unmeasured)" \
    || bad "vane_install closed as: $(grep 'id=vane_install' "${FAKE}/out" | tr '\t' ' ')"
grep $'\tDONE\t' "${FAKE}/out" | grep -q $'failed_steps=1' && ok "DONE counts it failed" || bad "DONE: $(grep DONE "${FAKE}/out" | tr '\t' ' ')"
grep -q '^  Web search: not installed$' "${FAKE}/out" && ok "summary: Web search: not installed" || bad "summary did not say not installed"

echo
echo "== ${pass} pass / ${fail} fail =="
[ "$fail" -eq 0 ]
