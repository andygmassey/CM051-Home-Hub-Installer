# scripts/box_walk_probes/lib/walk134_common.sh
# Shared plumbing for the four 134 thin-walk probes. Sourced after lib/probe.sh.
#
# The decision lives in lib/walk134_judges.py. These helpers only move evidence
# from the box to that judge and map its exit code onto the probe contract:
# 0 -> probe_pass, 1 -> probe_fail, 78 -> probe_cannot_run. Nothing here turns a
# CANNOT into a PASS, and a judge that printed no reason is reported as such.

WALK134_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WALK134_JUDGE="${WALK134_HERE}/walk134_judges.py"
DOCTOR_URL="${OSTLER_DOCTOR_URL:-http://127.0.0.1:8089}"

# walk134_judge <verb> [args...] : run the judge, print its non-EXAMINED lines,
# and call the matching probe verdict. Never returns.
walk134_judge_and_report() {
    local out rc reason nm ex
    out="$(mktemp)"
    python3 "${WALK134_JUDGE}" "$@" > "${out}" 2>&1
    rc=$?
    ex="$(sed -n 's/^EXAMINED: //p' "${out}" | head -1)"
    reason="$(sed -n 's/^JUDGE: [A-Z-]* -- //p' "${out}" | head -1)"
    nm="$(sed -n 's/^NOT MEASURED: //p' "${out}" | head -1)"
    grep -v -e '^EXAMINED: ' -e '^NOT MEASURED: ' "${out}" | sed 's/^/  judge: /'
    rm -f "${out}"
    if [ -z "${reason}" ]; then
        probe_examined "${ex:-0}" "${PROBE_UNIT:-items}"
        probe_cannot_run "the judge printed no verdict (rc=${rc}); nothing can be claimed"
    fi
    probe_examined "${ex:-0}" "${PROBE_UNIT:-items}"
    [ -n "${nm}" ] && printf 'NOT MEASURED: %s\n' "${nm}"
    case "${rc}" in
        0)  probe_pass "${reason}" ;;
        1)  probe_fail "${reason}" ;;
        78) probe_cannot_run "${reason}" ;;
        *)  probe_cannot_run "the judge exited ${rc} (not 0, 1 or 78): nothing can be claimed. ${reason}" ;;
    esac
}

# walk134_self_red <verb> [args...] : the negative control. The judge MUST
# return 1 on the known-bad input the caller planted. Anything else is BROKEN,
# which the runner reads as "could not demonstrate a FAIL".
walk134_self_red() {
    local out rc
    out="$(python3 "${WALK134_JUDGE}" "$@" 2>&1)"
    rc=$?
    if [ "${rc}" -ne 1 ]; then
        printf 'VERDICT: BROKEN -- %s self-test: the judge returned %s on the known-bad input, not 1\n' "${PROBE_NAME}" "${rc}"
        printf '%s\n' "${out}" | sed 's/^/  judge: /'
        exit 2
    fi
    printf '%s\n' "${out}" | sed 's/^/  judge: /'
    return 0
}

# walk134_self_judge_selftest : the judge module's own cases, all of them. Its
# negative controls must go red and its positive controls must hold.
walk134_self_judge_selftest() {
    local out rc
    out="$(python3 "${WALK134_JUDGE}" --self-test 2>&1)"
    rc=$?
    if [ "${rc}" -ne 1 ] || ! printf '%s' "${out}" | grep -q 'negative controls behaved'; then
        printf 'VERDICT: BROKEN -- %s self-test: the judge module failed its own cases (rc=%s)\n' "${PROBE_NAME}" "${rc}"
        printf '%s\n' "${out}" | sed 's/^/  /'
        exit 2
    fi
}
