#!/usr/bin/env bash
# hub_screens_customer_read -- read every Hub screen and every wiki section the
# way a picky customer does, and fail on what they would see (#2534-#2558).
#
# The v1.0.106 QA pass (2026-10-01) found ISO dates, em dashes, internal ids,
# four different people counts, WhatsApp ids shown as phone numbers, a Governor
# that billed Ostler's own VM to "Other apps", three disagreeing copies of
# source status and half-width wiki tables, while hub_screens_render_for_a_customer
# read PASS. That probe asks whether the screens RENDER; this one asks whether
# what they SAY is true and customer-ready. The judge is lib/customer_read.py.
#
# READ-ONLY by construction: every non-GET from the page is aborted and recorded,
# never sent; the Front Page is reached through a shim that answers only
# get_front_page; the box is asked only GETs and file reads. Safe on a box a
# customer is using.
#
# Runs on the WALK DRIVER (Playwright WebKit), forwarding the box's gateway
# (:8000) and Doctor (:8089) over ssh.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="hub_screens_customer_read"
PROBE_QUESTION="read as a customer, is every Hub screen and wiki page free of ISO dates, em dashes and internal values, do counts and source statuses agree across screens, are wiki boxes full width, and do the app's own reads succeed?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_PY="${OSTLER_SCREENS_PYTHON:-${HOME}/walkdriver/pwvenv/bin/python}"

self_test() {
    if python3 "${_HERE}/lib/customer_read.py" --self-test; then
        probe_examined 32 "mutated customer-read facts"
        probe_fail "negative control behaved: every known-bad fixture went red by its own assertion, an empty read is CANNOT-RUN, and a silent declared assertion FAILS"
    fi
    probe_examined 32 "mutated customer-read facts"
    probe_pass "SELF-TEST BROKEN: the customer-read judge let a known-bad fixture through (see above)"
}

run_probe() {
    [ -n "${OSTLER_BOX_HOST:-}" ] || probe_cannot_run "OSTLER_BOX_HOST is unset: this probe runs on the walk driver against a box"
    [ -x "${_PY}" ] || probe_cannot_run "no Playwright python at ${_PY} (set OSTLER_SCREENS_PYTHON)"

    local out tokfile feed boxf port dport fwd_pid rc n
    out="${OSTLER_WALK_SCREENS_DIR:-$PWD/walk-screens/$(date -u +%Y%m%dT%H%M%SZ)}/customer-read"
    mkdir -p "${out}" || probe_cannot_run "cannot create ${out}"
    tokfile="$(mktemp)"; feed="$(mktemp)"; boxf="$(mktemp)"
    trap 'rm -f "${tokfile}" "${feed}" "${boxf}"; [ -n "${fwd_pid:-}" ] && kill "${fwd_pid}" 2>/dev/null' EXIT

    box_run "cat \$HOME/.ostler/secrets/zeroclaw_admin_token" > "${tokfile}" 2>/dev/null
    [ -s "${tokfile}" ] || probe_cannot_run "could not read the box's Hub token over ssh"
    box_run "cat \$HOME/.ostler/editor/front_page.json" > "${feed}" 2>/dev/null
    [ -s "${feed}" ] || probe_note "no front_page.json on the box: the Front Page arms will be CANNOT-RUN"
    # Ollama's logged model calls vs the Bursar's journal rows over the last hour.
    box_run "/usr/bin/python3 - <<'PY'
import json,re,os,datetime as dt
now=dt.datetime.now(dt.timezone.utc); start=now-dt.timedelta(minutes=60)
off=dt.datetime.now().astimezone().utcoffset(); n=0; j=0
try:
    for l in open(os.path.expanduser('~/.ostler/logs/ollama.log'),errors='replace'):
        m=re.match(r'\[GIN\] (\d{4}/\d\d/\d\d - \d\d:\d\d:\d\d) \| *\d+ \|.*POST +\"/api/(embed|embeddings|generate|chat)\"',l)
        if m and dt.datetime.strptime(m.group(1),'%Y/%m/%d - %H:%M:%S').replace(tzinfo=dt.timezone(off))>=start: n+=1
except FileNotFoundError: n=None
for p in [os.path.expanduser('~/.ostler/assistant-config/workspace/state/costs.jsonl')]:
    try:
        for l in open(p):
            try:
                row=json.loads(l); u=row['usage']; ts=u['timestamp']
            except Exception: continue
            if dt.datetime.fromisoformat(ts.replace('Z','+00:00'))>=start:
                # SUM calls, not rows (#2603 follow-up): a rollup row
                # carries usage.calls = the real number of Ollama calls it
                # folded in. An old row with no calls field is one call,
                # the same default the Rust reader uses.
                j+=int(u.get('calls',1) or 1)
    except FileNotFoundError: j=None
print(json.dumps({'ollama_calls':n,'journal_calls':j,'window_min':60}))
PY" > "${boxf}" 2>/dev/null
    [ -s "${boxf}" ] || probe_note "could not count Ollama calls on the box: the Bursar arm will be CANNOT-RUN"

    port="$(( 20000 + RANDOM % 20000 ))"; dport="$(( port + 1 ))"
    ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
        -N -L "${port}:127.0.0.1:8000" -L "${dport}:127.0.0.1:8089" "${OSTLER_BOX_HOST}" &
    fwd_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        /usr/bin/curl -s -o /dev/null --noproxy '*' --max-time 2 "http://127.0.0.1:${port}/" && break
        sleep 1
    done

    set -- collect --base "http://127.0.0.1:${port}" --doctor-base "http://127.0.0.1:${dport}" \
        --token-file "${tokfile}" --out "${out}"
    [ -s "${feed}" ] && set -- "$@" --front-page-json "${feed}"
    [ -s "${boxf}" ] && set -- "$@" --box-facts "${boxf}"
    "${_PY}" "${_HERE}/lib/customer_read.py" "$@" | tee "${out}/verdict.txt"
    rc=${PIPESTATUS[0]}
    # A run that printed no assertion row is a FAIL, never a quiet pass.
    n="$(/usr/bin/grep -cE '^  (ok|FAIL|CANNOT|N/A) ' "${out}/verdict.txt" 2>/dev/null || echo 0)"
    probe_examined "${n}" "customer-read assertions"
    [ "${n}" -gt 0 ] || probe_fail "the customer read printed no assertion at all (rc=${rc}); a silent probe is not a pass"
    probe_note "screens and facts: ${out}"
    case "${rc}" in
        0)  probe_pass "every screen reads as customer-ready and every cross-screen fact agrees" ;;
        78) probe_cannot_run "a customer-read assertion could not be measured (see CANNOT lines above)" ;;
        *)  probe_fail "a customer would see something wrong (see FAIL lines above; screenshots in ${out})" ;;
    esac
}

probe_main "$@"
