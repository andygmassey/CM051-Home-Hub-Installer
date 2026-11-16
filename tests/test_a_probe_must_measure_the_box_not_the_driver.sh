#!/bin/bash
# tests/test_a_probe_must_measure_the_box_not_the_driver.sh
#
# A PROBE THAT MEASURES THE WALK DRIVER RECORDS A VERDICT ABOUT THE WRONG
# MACHINE, AND NOTHING IN ITS OUTPUT SAYS SO.
#
# doctor_page_renders_for_a_customer reported CANNOT-RUN on the v1.0.100 and
# v1.0.101 walks with "the Doctor is not serving: /api/v1/sources answered 000".
# The Doctor was serving. Measured on the walk box: ~/.ostler/logs/doctor.log
# carries `GET /api/v1/sources HTTP/1.1" 200 OK` written inside the probe
# window, under `Uvicorn running on http://127.0.0.1:8089`; and
# source_status_artefact_is_served, which GETs THAT SAME URL on that same box
# through box_run, PASSED in the walk that recorded this probe as not measured.
#
# run_box_walk.sh:519 executes each probe LOCALLY and hands it OSTLER_BOX_HOST.
# Reaching the box is the probe's job, via box_run / box_run_v. This probe used
# bare curl against 127.0.0.1, which is the DRIVER's loopback. Two walks of
# coverage were lost to a connection the driver refused to itself.
#
# Pointing the probe at the box's LAN address does not fix it: the Doctor binds
# 127.0.0.1 on the box deliberately. The request must be ISSUED ON the box.
#
# WHAT THIS TEST ASSERTS, and why each arm exists.
#
#   ARM 1  Every HTTP read the probe makes crosses the box transport. Proved by
#          replacing ssh with a stub that RECORDS what was sent through it. On
#          the pre-fix probe the stub records nothing, because ssh was never
#          invoked.
#   ARM 2  When nothing answers, the probe refuses WITHOUT asserting a cause it
#          has no instrument to see. 000 is curl saying it got no status line;
#          refused, timed out, proxied and never-issued are indistinguishable
#          there, and only one of them is "the Doctor is not serving".
#   ARM 3  MUTATION. A copy of the probe with the transport reverted to a bare
#          local curl must FAIL arm 1. Without this, arm 1 passing proves
#          nothing: a stub that never ran, a log path that was never written,
#          or a predicate that matches anything all look identical to a pass.
#   ARM 4  PREDICATE CONTROL for arm 2. The reason-checker is run against the
#          exact sentence the two walks recorded, and must judge it bad; and
#          against the replacement, and must judge it good. A checker that
#          cannot go red cannot defend anything.
#
# NOTHING HERE OPENS A NETWORK CONNECTION BEYOND 127.0.0.1, and no real ssh
# runs: the stub is on PATH ahead of it.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
PROBE_REL="scripts/box_walk_probes/probes/doctor_page_renders_for_a_customer.sh"
PROBE="${REPO}/${PROBE_REL}"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; printf '  NOTHING was checked. This is not a pass.\n' >&2; exit 2; }

[ -r "${PROBE}" ] || cant "cannot read ${PROBE}"
[ -s "${PROBE}" ] || cant "${PROBE} is empty; every arm below would report on nothing"
command -v python3 >/dev/null 2>&1 || cant "no python3; the fixture server cannot be stood up"
command -v curl    >/dev/null 2>&1 || cant "no curl; the readiness check cannot be made"

WORK="$(mktemp -d)" || cant "no working directory"
SERVER_PID=""
cleanup() {
    if [ -n "${SERVER_PID}" ]; then kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The ssh stub. box_run_v calls:  ssh -o ... -o ... <host> "<command>"
# so the command is the LAST argument. The stub records it and runs it here.
# Recording is the whole point: an empty log is the pre-fix probe's signature.
# ---------------------------------------------------------------------------
STUB_DIR="${WORK}/stub"
mkdir -p "${STUB_DIR}"
cat > "${STUB_DIR}/ssh" <<'STUB'
#!/bin/bash
cmd=""
for a in "$@"; do cmd="$a"; done
printf '%s\n' "${cmd}" >> "${SSH_STUB_LOG}"
exec /bin/bash -c "${cmd}"
STUB
chmod +x "${STUB_DIR}/ssh"

# Prove the stub is the ssh that will be found, before any arm depends on it.
_probe_stub_check="${WORK}/stubcheck.log"
SSH_STUB_LOG="${_probe_stub_check}" PATH="${STUB_DIR}:${PATH}" \
    ssh -o BatchMode=yes stub-box 'echo stub-alive' > "${WORK}/stubcheck.out" 2>&1
if ! /usr/bin/grep -q 'stub-alive' "${WORK}/stubcheck.out"; then
    cant "the ssh stub did not execute its command; every arm below would measure a transport that is not there"
fi
if [ ! -s "${_probe_stub_check}" ]; then
    cant "the ssh stub ran but recorded nothing, so an empty log could not be read as evidence of anything"
fi

# ---------------------------------------------------------------------------
# A fixture Doctor: 200 on /api/v1/sources, 200 with a table on /doctor.
# ---------------------------------------------------------------------------
start_fixture() { # $1 = port
    python3 -c '
import sys, http.server
port = int(sys.argv[1])
PAGE = b"<html><body><table><tr><td>a source</td></tr></table></body></html>"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/api/v1/sources"):
            payload = b"{\"sources\":[]}"
        elif self.path.startswith("/doctor"):
            payload = PAGE
        else:
            self.send_response(404); self.send_header("Content-Length","0"); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
' "$1" &
    SERVER_PID=$!
    # 🔴 A POLL LOOP WITH NO DELAY IS NOT A WAIT.
    #
    # MEASURED 2026-09-24 on macos-latest, twice, after this test went red on
    # a PR that touches only SwiftUI glyph code and could not possibly affect
    # it. Both runs reported the honest thing:
    #
    #   CANNOT-RUN: the fixture Doctor never came up on 127.0.0.1:18921
    #   NOTHING was checked. This is not a pass.
    #
    # There was no `sleep` in this loop. Against a port with nothing
    # listening, curl fails IMMEDIATELY -- connection refused, long before
    # --max-time 1 is relevant -- so all 60 attempts burned through in well
    # under a second while python3's http.server was still starting. On this
    # developer's Mac the server wins that race and the test passes; on a cold
    # CI runner it does not. MEASURE ON THE HOST THAT RUNS IT.
    #
    # The identical defect was fixed in
    # scripts/box_walk_probes/probes/doctor_page_renders_for_a_customer.sh
    # earlier the same night, where its readiness loop took a self-test from
    # 105s to 2s. Same shape, different file, and the ratchet that catches
    # pipefail constructs does not look for this one.
    #
    # 60 attempts at 0.25s is up to 15 seconds of real waiting, which is
    # generous for a local http.server and still fails fast when it genuinely
    # cannot bind.
    local i=0
    while [ $i -lt 60 ]; do
        if curl -s -o /dev/null --noproxy '*' --max-time 1 "http://127.0.0.1:$1/api/v1/sources"; then return 0; fi
        sleep 0.25
        i=$((i+1))
    done
    return 1
}

port_is_closed() { # $1 = port
    if curl -s -o /dev/null --noproxy '*' --max-time 1 "http://127.0.0.1:$1/api/v1/sources"; then
        return 1
    fi
    return 0
}

count_of() { # $1 = file, $2 = fixed string. Prints a number, never an exit code.
    local n
    n="$(/usr/bin/grep -c -F -- "$2" "$1" 2>/dev/null)"
    case "${n}" in
        ''|*[!0-9]*) printf '0' ;;
        *)           printf '%s' "${n}" ;;
    esac
}

# run_one <probe-path> <port> <ssh-log> <out-file>  -> RETURNS the probe's exit
# code and writes its output to a file.
#
# It returns rather than printing because the first draft of this test printed
# the output and set a global RC, and the caller read that global through a
# command substitution -- which runs in a SUBSHELL, so the assignment never
# reached the caller. Arm 2 then compared a stale 0 against 78 and reported the
# fixed probe as broken. A test that reads the wrong exit code is the same
# defect class as the probe it is policing.
run_one() {
    : > "$3"
    SSH_STUB_LOG="$3" PATH="${STUB_DIR}:${PATH}" \
        OSTLER_BOX_HOST=stub-box OSTLER_PROBE_DOCTOR_HOST=127.0.0.1 \
        DOCTOR_PORT="$2" /bin/bash "$1" > "$4" 2>&1
    return $?
}

# transport_carried_the_reads <log> -> 0 when BOTH HTTP reads crossed the stub
transport_carried_the_reads() {
    local n_src n_doc
    n_src="$(count_of "$1" 'api/v1/sources')"
    n_doc="$(count_of "$1" '/doctor')"
    if [ "${n_src}" -ge 1 ] && [ "${n_doc}" -ge 1 ]; then return 0; fi
    return 1
}

# reason_is_honest <text> -> 0 when the refusal reports a transport fact and
# does NOT assert the service is down.
FALSE_SENTENCE='the Doctor is not serving'
reason_is_honest() {
    case "$1" in
        *"${FALSE_SENTENCE}"*) return 1 ;;
    esac
    case "$1" in
        *'NO HTTP RESPONSE'*) return 0 ;;
    esac
    return 1
}

printf 'test_a_probe_must_measure_the_box_not_the_driver\n'
printf '  probe under test: %s\n' "${PROBE_REL}"

# ---------------------------------------------------------------------------
# ARM 1. Every HTTP read crosses the box transport.
# ---------------------------------------------------------------------------
PORT_LIVE=18921
if ! start_fixture "${PORT_LIVE}"; then
    cant "the fixture Doctor never came up on 127.0.0.1:${PORT_LIVE}; arms 1 and 3 would report on nothing"
fi
LOG1="${WORK}/arm1.ssh.log"
OUTF1="${WORK}/arm1.out"
run_one "${PROBE}" "${PORT_LIVE}" "${LOG1}" "${OUTF1}"; RC1=$?
OUT1="$(cat "${OUTF1}")"
if [ "${RC1}" -ne 0 ]; then
    bad "arm 1: against a fixture serving 200 and a table the probe returned ${RC1}, not PASS. Output: ${OUT1}"
elif transport_carried_the_reads "${LOG1}"; then
    ok "arm 1: both HTTP reads crossed the box transport (stub recorded $(count_of "${LOG1}" 'curl') curl invocation(s))"
else
    bad "arm 1: the probe returned PASS without sending its HTTP reads to the box. The stub ssh log holds $(count_of "${LOG1}" 'curl') curl line(s), $(count_of "${LOG1}" 'api/v1/sources') naming /api/v1/sources and $(count_of "${LOG1}" '/doctor') naming /doctor. A verdict reached over the driver's own loopback is a verdict about the wrong machine."
fi
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""

# ---------------------------------------------------------------------------
# ARM 2. Nothing listening: refuse, and do not invent a cause.
# ---------------------------------------------------------------------------
PORT_DEAD=18922
if ! port_is_closed "${PORT_DEAD}"; then
    cant "something is already listening on 127.0.0.1:${PORT_DEAD}; the absence arm cannot be constructed"
fi
LOG2="${WORK}/arm2.ssh.log"
OUTF2="${WORK}/arm2.out"
run_one "${PROBE}" "${PORT_DEAD}" "${LOG2}" "${OUTF2}"; RC2=$?
OUT2="$(cat "${OUTF2}")"
if [ "${RC2}" -ne 78 ]; then
    bad "arm 2: with nothing listening the probe returned ${RC2}, not 78 CANNOT-RUN. Output: ${OUT2}"
elif reason_is_honest "${OUT2}"; then
    ok "arm 2: refused as CANNOT-RUN and reported a transport fact rather than a verdict on the service"
else
    bad "arm 2: refused as CANNOT-RUN but named a cause it cannot see. The probe has no instrument that separates refused, timed out, proxied and never-issued, so it must not pick one. Output: ${OUT2}"
fi

# ---------------------------------------------------------------------------
# ARM 3. MUTATION. Revert only the transport and require arm 1 to catch it.
# ---------------------------------------------------------------------------
# If the probe makes no call through the box transport at all there is nothing
# to revert: it IS the mutant. That is the pre-fix state, and it is a FAILURE of
# this arm, not a reason to stop measuring -- an abort here would report the
# defective tree as CANNOT-RUN, which reads as "unknown" when it is known.
TRANSPORT_CALLS="$(count_of "${PROBE}" 'box_run_v ')"
if [ "${TRANSPORT_CALLS}" -lt 2 ]; then
    bad "arm 3: the probe makes ${TRANSPORT_CALLS} call(s) through the box transport, so there is no transport to revert and the mutation arm cannot add anything. The probe under test already reads the driver."
    printf '\n  %s passed, %s failed\n' "${pass}" "${fail}"
    exit 1
fi

MUT_ROOT="${WORK}/bwp"
cp -R "${REPO}/scripts/box_walk_probes" "${MUT_ROOT}" 2>/dev/null \
    || cant "could not copy the probe suite for the mutation arm"
MUTANT="${MUT_ROOT}/probes/mutant_local_curl.sh"
awk '
    { line = $0
      gsub(/box_run_v /, "_driver_local_run ", line)
      print line
      if (line ~ /lib\/probe\.sh"$/) print "_driver_local_run() { bash -lc \"$1\"; }"
    }
' "${PROBE}" > "${MUTANT}" || cant "could not build the mutant"
chmod +x "${MUTANT}"

MUT_APPLIED="$(count_of "${MUTANT}" '_driver_local_run')"
if [ "${MUT_APPLIED}" -lt 2 ]; then
    cant "the mutation did not apply (${MUT_APPLIED} occurrence(s) of the local runner). A mutant that did not apply looks exactly like one that was not caught, so arm 3 would pass for the wrong reason."
fi
if ! /bin/bash -n "${MUTANT}"; then
    cant "the mutant does not parse, so it cannot demonstrate anything"
fi

if ! start_fixture "${PORT_LIVE}"; then
    cant "the fixture Doctor never came up for the mutation arm"
fi
LOG3="${WORK}/arm3.ssh.log"
OUTF3="${WORK}/arm3.out"
run_one "${MUTANT}" "${PORT_LIVE}" "${LOG3}" "${OUTF3}"; RC3=$?
if transport_carried_the_reads "${LOG3}"; then
    bad "arm 3: the mutant reads the driver's own loopback, yet arm 1's predicate scored its transport as correct. The predicate cannot see the defect it exists for, so arm 1 proves nothing. Mutant exit ${RC3}."
else
    ok "arm 3: the predicate went red on a probe that reads the driver instead of the box (mutant exit ${RC3}, stub log holds $(count_of "${LOG3}" 'curl') curl line(s))"
fi
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""

# ---------------------------------------------------------------------------
# ARM 4. PREDICATE CONTROL for arm 2, against the sentence two walks recorded.
# ---------------------------------------------------------------------------
HISTORICAL="the Doctor is not serving: /api/v1/sources answered 000, not 200. Nothing about the PAGE is measurable while the service is down."
REPLACEMENT="NO HTTP RESPONSE from http://127.0.0.1:8089/api/v1/sources, issued from the box walkbox, where curl ran over ssh: curl exit 7, connection refused"
if reason_is_honest "${HISTORICAL}"; then
    bad "arm 4: the reason-checker accepted the exact sentence the v1.0.100 and v1.0.101 walks recorded. It cannot go red, so arm 2 is decoration."
elif reason_is_honest "${REPLACEMENT}"; then
    ok "arm 4: the reason-checker rejects the historical sentence and accepts an honest transport report, so it discriminates in both directions"
else
    bad "arm 4: the reason-checker rejects an honest transport report as well as the historical sentence. It refuses everything, which is not a working predicate."
fi

# ---------------------------------------------------------------------------
# ARM 5. WIDENED: no probe evaluates the DRIVER's ~/.ostler on this machine.
#
# v1.0.130: setup_progress_advancing tested and read $HOME/.ostler on the DRIVER
# while OSTLER_BOX_HOST named the box. This arm is the gate for that shape.
#
# THE RULE, bash-aware (python3 -I, stdlib only). A finding is a $HOME, ${HOME} or
# ~ reference that the shell running the probe would EXPAND on this machine:
#   NOT a finding: inside single quotes (a string for the box); escaped (\$ \~);
#   inside a quoted heredoc body (a payload, expanded wherever it is sent); after
#   a probe_* verdict call (a message that prints a path); a tilde inside double
#   quotes (not expanded); a box_run argument written in single quotes.
#   A finding: an unquoted or double-quoted $HOME / ${HOME} / ~ that the local shell
#   expands, including inside a $( ... ) substitution.
# The predicate is "a path the local shell builds or uses", which covers file
# tests, reads, cd, find, and the expression that builds a path a read then uses.
#
# LIMITS, stated because they are real: a path assigned in one line and read on
# another is seen only at the assignment; a local python heredoc that is run by
# the driver (not sent to the box) is a payload here, so it is not seen. Those
# were checked by hand for the four directive-blocking probes (arm 7).
#
# NO ALLOWLIST. A finding in another probe is a finding, reported by name.
# ---------------------------------------------------------------------------
cat > "${WORK}/scan_driver_home.py" <<'PYSCAN'
# Bash-aware scanner. A finding is a $HOME, ${HOME} or ~ reference that the
# DRIVER's shell would expand locally. Not a finding: inside single quotes; escaped
# (\$ \~); inside a quoted heredoc body (payload, expanded wherever it is sent);
# after a probe_* verdict call (a message); a tilde inside double quotes.
# Frames: 'dq' for a double-quoted region, 'cmd' for a $( ... ) substitution (which
# re-enters full shell quoting). Quote state carries across lines.
import os, re, sys
PROBE_CALL = re.compile(r'\bprobe_(fail_or_advisory|fail|cannot_run|note|pass|advisory)\b')
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
FUNC = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
GUARD = "_refuse_driver_local_if_walk"
def excluded_lines(lines):
    # STRUCTURAL exclusion. A function body is excluded when it is self_test (a
    # synthetic fixture, judges no box) or when its first statement is the walk
    # guard (it refuses a host walk that reaches the driver). A name alone earns
    # nothing: a function named like a local arm with no guard is scanned.
    ex = set()
    i = 0
    while i < len(lines):
        m = FUNC.match(lines[i])
        if not m:
            i += 1; continue
        name = m.group(1)
        j = i + 1
        first = None
        while j < len(lines) and lines[j] != "}":
            st = lines[j].strip()
            if first is None and st and not st.startswith("#"):
                first = st
            j += 1
        if name == "self_test" or first == GUARD:
            ex.update(range(i + 1, j + 2))
        i = j + 1
    return ex
def scan(path):
    name = os.path.basename(path)
    stack = []; sq = False
    delim = None; strip = False
    out = []
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    skip = excluded_lines(lines)
    for n, raw in enumerate(lines, 1):
        if delim is not None:
            if (raw.lstrip("\t") if strip else raw) == delim:
                delim = None
            continue
        pc = PROBE_CALL.search(raw)
        limit = pc.start() if pc else len(raw)
        i = 0; L = len(raw); hit = False
        while i < L:
            c = raw[i]
            nxt = raw[i+1] if i + 1 < L else ""
            if sq:
                if c == "'":
                    sq = False
                i += 1; continue
            top = stack[-1][0] if stack else None
            if c == "\\":
                i += 2; continue
            live_here = raw.startswith("${HOME}/.ostler", i) or raw.startswith("$HOME/.ostler", i)
            if top == "dq":
                if c == '"':
                    stack.pop(); i += 1; continue
                if c == "$" and nxt == "(":
                    stack.append(["cmd", 0]); i += 2; continue
                if live_here and i < limit:
                    hit = True
                i += 1; continue
            # unquoted (top-level or inside a $( ) frame)
            if c == "'":
                sq = True; i += 1; continue
            if c == '"':
                stack.append(["dq", 0]); i += 1; continue
            if c == "$" and nxt == "(":
                stack.append(["cmd", 0]); i += 2; continue
            if top == "cmd":
                if c == "(":
                    stack[-1][1] += 1
                elif c == ")":
                    if stack[-1][1] > 0:
                        stack[-1][1] -= 1
                    else:
                        stack.pop()
                i += 1; continue
            if c == "#" and (i == 0 or raw[i-1] in " \t;"):
                break
            if raw.startswith("<<", i):
                m = HEREDOC.match(raw, i)
                if m:
                    delim = m.group(3); strip = (m.group(1) == "-")
                    i = m.end(); continue
            if live_here:
                if i < limit: hit = True
            elif c == "~" and raw.startswith("~/.ostler", i) and (i == 0 or raw[i-1] in " \t=:(;|&<>"):
                if i < limit: hit = True
            i += 1
        if hit and n not in skip:
            out.append("%s:%d: %s" % (name, n, raw.strip()))
    return out
hits = []
for f in sorted(os.listdir(sys.argv[1])):
    if f.endswith(".sh"):
        hits += scan(os.path.join(sys.argv[1], f))
print("\n".join(hits))
PYSCAN

scan_driver_home_reads() { # <probes dir> -> prints "file:line: text" per finding
    python3 -I "${WORK}/scan_driver_home.py" "$1"
}

PROBES_DIR="${REPO}/scripts/box_walk_probes/probes"
[ -d "${PROBES_DIR}" ] || cant "no probes directory at ${PROBES_DIR}; the widened scan would report on nothing"
ARM5_FINDINGS="$(scan_driver_home_reads "${PROBES_DIR}")"
ARM5_N="$(printf '%s\n' "${ARM5_FINDINGS}" | /usr/bin/grep -c . || true)"
if [ "${ARM5_N}" -eq 0 ]; then
    ok "arm 5: no probe evaluates the driver's ~/.ostler on this machine (scanned $(ls "${PROBES_DIR}"/*.sh | wc -l | tr -d ' ') probes)"
else
    bad "arm 5: ${ARM5_N} line(s) in probes evaluate the driver's ~/.ostler on this machine. Each is a finding to triage; none is allowlisted:"
    printf '%s\n' "${ARM5_FINDINGS}" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# ARM 6. The scanner can go RED and can go GREEN. Positive controls: the v1.0.130
# line (#3456 probe line 80) and the two synthetic mutants (a bare file test, a
# bare read), and a function that is NOT excused merely by its name. Negative
# controls: one case per exclusion class. Without the positive, arm 5's green is
# decoration.
# ---------------------------------------------------------------------------
ARM6_DIR="${WORK}/scan6"
mkdir -p "${ARM6_DIR}"
cat > "${ARM6_DIR}/positive_3456.sh" <<'FIX'
_settling_dir() {
    printf '%s/settling_progress.d' "${OSTLER_STATE_DIR:-$HOME/.ostler/state}"
}
FIX
cat > "${ARM6_DIR}/mutant_bare_test.sh" <<'FIX'
check() {
    [ -f "$HOME/.ostler/x" ] && echo y
}
FIX
cat > "${ARM6_DIR}/mutant_bare_read.sh" <<'FIX'
cat ~/.ostler/x
FIX
cat > "${ARM6_DIR}/positive_named_no_guard.sh" <<'FIX'
_box_local_verify() {
    cat ~/.ostler/x
}
FIX
cat > "${ARM6_DIR}/negative_controls.sh" <<'FIX'
# A comment naming ~/.ostler and $HOME/.ostler is not code.
raw="$(box_run 'f="$HOME/.ostler/x"; [ -r "$f" ] && cat "$f"')"
box_run "cat \$HOME/.ostler/x"
MODEL='$HOME/.ostler/.env'
TOKEN="${OSTLER_T:-~/.ostler/secrets/token}"
probe_cannot_run "no admin token at ~/.ostler/secrets/token; nothing was read"
python3 - <<'PYX'
import os
p = os.path.expanduser("~/.ostler/state")
PYX
self_test() {
    cat ~/.ostler/fixture
}
_box_local_verify() {
    _refuse_driver_local_if_walk
    cat ~/.ostler/x
}
FIX
ARM6_POS_3456="$(scan_driver_home_reads "${ARM6_DIR}" | /usr/bin/grep -c 'positive_3456.sh:2:' || true)"
ARM6_POS_TEST="$(scan_driver_home_reads "${ARM6_DIR}" | /usr/bin/grep -c 'mutant_bare_test.sh:2:' || true)"
ARM6_POS_READ="$(scan_driver_home_reads "${ARM6_DIR}" | /usr/bin/grep -c 'mutant_bare_read.sh:1:' || true)"
ARM6_POS_NAME="$(scan_driver_home_reads "${ARM6_DIR}" | /usr/bin/grep -c 'positive_named_no_guard.sh:2:' || true)"
ARM6_NEG="$(scan_driver_home_reads "${ARM6_DIR}" | /usr/bin/grep -c 'negative_controls.sh' || true)"
if [ "${ARM6_POS_3456}" -eq 1 ] && [ "${ARM6_POS_TEST}" -eq 1 ] && [ "${ARM6_POS_READ}" -eq 1 ] && [ "${ARM6_POS_NAME}" -eq 1 ] && [ "${ARM6_NEG}" -eq 0 ]; then
    ok "arm 6: the scanner flags the v1.0.130 line, both synthetic mutants, and an unguarded function named like a local arm; passes every exclusion class (self_test body, guarded body, quoting, heredoc, message)"
else
    bad "arm 6: scanner predicate wrong: v1.0.130=${ARM6_POS_3456} (want 1), bare test=${ARM6_POS_TEST} (want 1), bare read=${ARM6_POS_READ} (want 1), unguarded named=${ARM6_POS_NAME} (want 1), negatives=${ARM6_NEG} (want 0). Arm 5 is not evidence until this is right."
fi

# ---------------------------------------------------------------------------
# ARM 7. The four directive-BLOCKING probes evaluate no driver home at all. Each
# was hand-checked (people_stores_reconcile: 3 hits, all inside payloads sent by
# box_run; the other three read through box_run or a box-built path). This arm
# holds that verdict on every run.
# ---------------------------------------------------------------------------
ARM7_BAD=""
for _bp in people_stores_reconcile no_person_holds_two_contact_cards assistant_answers_grounded no_store_port_is_tcp_reachable; do
    _n="$(scan_driver_home_reads "${PROBES_DIR}" | /usr/bin/grep -c "^${_bp}.sh:" || true)"
    if [ "${_n}" -ne 0 ]; then
        ARM7_BAD="${ARM7_BAD} ${_bp}(${_n})"
    fi
done
if [ -z "${ARM7_BAD}" ]; then
    ok "arm 7: the four directive-blocking probes evaluate no driver ~/.ostler (hand-checked, held here)"
else
    bad "arm 7: a directive-blocking probe evaluates the driver's ~/.ostler:${ARM7_BAD}"
fi

# ---------------------------------------------------------------------------
# ARM 8. THE WALK GUARD. install_manifest_complete's box-local arm reads THIS
# machine's home. A host walk exports OSTLER_WALK_REMOTE_HOST next to
# OSTLER_BOX_HOST (post_walk_qa.sh:359). If the marker is present and the box
# variable was dropped, the probe must REFUSE with rc 78, never read the driver.
# Driven through the real probe with a stale driver home that would be read.
# ---------------------------------------------------------------------------
ARM8_PROBE="${REPO}/scripts/box_walk_probes/probes/install_manifest_complete.sh"
ARM8_HOME="${WORK}/arm8_driver_home"
mkdir -p "${ARM8_HOME}/.ostler/state"
out8="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="${ARM8_HOME}" OSTLER_WALK_REMOTE_HOST=walk-host /bin/bash "${ARM8_PROBE}" 2>&1)"; rc8=$?
if [ "${rc8}" -eq 78 ] && [[ "${out8}" == *"VERDICT: CANNOT-RUN"* ]] && [[ "${out8}" == *"a --host walk is in progress"* ]]; then
    ok "arm 8: a host walk with OSTLER_BOX_HOST dropped is REFUSED (rc 78, CANNOT-RUN) and the driver home is not read"
else
    bad "arm 8: the walk guard did not refuse a dropped OSTLER_BOX_HOST on a host walk: rc=${rc8}, output: $(printf '%s' "${out8}" | tr '\n' ' ' | cut -c1-300)"
fi
out8b="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="${ARM8_HOME}" /bin/bash "${ARM8_PROBE}" 2>&1)"; rc8b=$?
if [[ "${out8b}" == *"a --host walk is in progress"* ]]; then
    bad "arm 8 control: with no host-walk marker the guard refused, so the box-local run would be blocked for a legitimate on-box run"
else
    ok "arm 8 control: with no host-walk marker the guard does not refuse (rc ${rc8b}), so an on-box run is not blocked"
fi

printf '\n  %s passed, %s failed\n' "${pass}" "${fail}"
if [ "${fail}" -gt 0 ]; then exit 1; fi
if [ "${pass}" -lt 9 ]; then
    printf 'CANNOT-RUN: only %s arms reported. A partial run is not a pass.\n' "${pass}" >&2
    exit 2
fi
exit 0
