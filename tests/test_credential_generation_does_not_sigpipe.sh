#!/usr/bin/env bash
# Regression test for #1754 (second instance): generating the wiki/vane
# credential must not abort the install on SIGPIPE.
#
# ROOT CAUSE (measured, v1.0.73 box walk, archie account, step config_save):
#
#     _raw="$(LC_ALL=C tr -dc '<alphabet>' < /dev/urandom | head -c 20)"
#
#   `head -c 20` takes its bytes and exits, closing the pipe under `tr`, which
#   dies on SIGPIPE. `pipefail` promotes the pipeline to 141 and the ERR trap
#   aborts. The install reported rc=141, ERR-99-INSTALL-ABORT-L13022.
#
# WHY THE EXISTING GUARD DID NOT SAVE IT: the function already has a loud,
# correct failure path immediately below --
#
#     if [[ "${#_raw}" -ne 20 ]]; then fail_with_code "ERR-14-STORE-WIKI-CREDENTIAL" ...
#
#   -- and it was UNREACHABLE, because the assignment aborted the script first.
#   That is the same shape as the Ollama agent poll at :12403: the handling for
#   a failure sits downstream of the construct that kills the script. Both were
#   found on the same artefact.
#
# This test asserts the pipeline survives AND that the loud length check is
# still reachable, because removing the abort is only half the property.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "${INSTALL_SH}" ]] || { printf 'FAIL: install.sh not found\n' >&2; exit 1; }

fails=0
check() {
    local label="$1" got="$2" want="$3"
    if [[ "${got}" == "${want}" ]]; then
        printf 'ok   %s -- %s\n' "${label}" "${got}"
    else
        printf 'FAIL %s -- got %-24s want %s\n' "${label}" "${got}" "${want}" >&2
        fails=$((fails + 1))
    fi
}

# ── The SHIPPED lines, extracted so this tracks the real code ────────────
POOL_LINE="$(grep -F '_pool="$(LC_ALL=C /usr/bin/head -c 4096 /dev/urandom' "${INSTALL_SH}" || true)"
[[ -n "${POOL_LINE}" ]] || {
    printf 'FAIL: could not find the bounded-pool credential line in install.sh\n' >&2
    printf '      (has the SIGPIPE fix been reverted?)\n' >&2
    exit 1
}
SLICE_LINE='    _raw="${_pool:0:20}"'
grep -qF "${SLICE_LINE}" "${INSTALL_SH}" || {
    printf 'FAIL: bounded pool present but the shell slice is missing\n' >&2
    exit 1
}

run_snippet() {
    printf '%s\n' "set -Eeuo pipefail" "trap 'echo ABORTED; exit 99' ERR" "$1" \
        'printf "LEN=%s\n" "${#_raw}"' > "${WORK}/c.sh"
    bash "${WORK}/c.sh" 2>/dev/null || true
}

printf '== shipped construct ==\n'
GOT="$(run_snippet "${POOL_LINE}
${SLICE_LINE}")"
check "generates 20 chars without aborting" "${GOT}" "LEN=20"

# Ten runs: SIGPIPE is a race, and a single green run proves very little about
# a race. The pre-fix construct lost that race on a real box.
RUNS=10; ok_runs=0
for _ in $(seq "${RUNS}"); do
    [[ "$(run_snippet "${POOL_LINE}
${SLICE_LINE}")" == "LEN=20" ]] && ok_runs=$((ok_runs + 1))
done
check "survives ${RUNS} consecutive runs" "${ok_runs}/${RUNS}" "${RUNS}/${RUNS}"

printf '== RED control (pre-fix pipeline must abort) ==\n'
RED='_raw="$(LC_ALL=C /usr/bin/tr -dc '"'"'abcdefghjkmnpqrstuvwxyz23456789'"'"' < /dev/urandom | /usr/bin/head -c 20)"'
red_aborts=0
for _ in $(seq "${RUNS}"); do
    [[ "$(run_snippet "${RED}")" == "ABORTED" ]] && red_aborts=$((red_aborts + 1))
done
# Not asserted as 10/10: SIGPIPE depends on whether tr is still writing when
# head exits. Asserting a race is deterministic is how a flaky gate is born.
# One abort in ten is proof the construct can kill the install; zero would mean
# this control never demonstrated the defect and the test proves nothing.
if [[ "${red_aborts}" -ge 1 ]]; then
    printf 'ok   pre-fix construct aborted %s/%s runs (>=1 required)\n' "${red_aborts}" "${RUNS}"
else
    printf 'FAIL RED control never aborted in %s runs -- it does not reproduce the defect\n' "${RUNS}" >&2
    fails=$((fails + 1))
fi

printf '== the loud failure path must still be reachable ==\n'
# Removing the abort is only half of it. If the pool comes back short, the
# existing ERR-14 check has to be the thing that fires.
GOT="$(run_snippet '_pool="abc"
    _raw="${_pool:0:20}"')"
check "short pool yields a short _raw for the guard" "${GOT}" "LEN=3"
grep -qF 'ERR-14-STORE-WIKI-CREDENTIAL' "${INSTALL_SH}" \
    && printf 'ok   ERR-14 length guard still present in install.sh\n' \
    || { printf 'FAIL ERR-14 length guard has gone missing\n' >&2; fails=$((fails + 1)); }

if [[ ${fails} -ne 0 ]]; then
    printf '\n%d assertion(s) failed\n' "${fails}" >&2
    exit 1
fi
printf '\nall assertions passed\n'
