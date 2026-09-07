#!/usr/bin/env bash
# scripts/tests/test_no_store_port_probe_reads_the_credential.sh
# ============================================================================
# Proves the no_store_port_is_tcp_reachable box-walk probe asks the RIGHT
# question of a published surface, on BOTH arms, and can go RED either way.
#
# THE PROBE IT GUARDS. Until #1618 the probe asked `nc -z` of every store
# port: TCP reachability. That was the right question while the stores had no
# auth. Once every surface was published on purpose behind a credential, a
# connect could no longer tell a protected surface from an unprotected one --
# 8044 serving the whole wiki bare and 6333 refusing with 401 produced the
# same output line. Named in 7 walk records, passed in none.
#
# The rewrite asks two questions per surface:
#   arm 1  an UNCREDENTIALLED request must be refused      2xx is #550
#   arm 2  the install's OWN credential must be served     401 is a lock-out
# The second arm is what gives the first any meaning: a dead upstream answers
# 401 to everyone exactly as a healthy gate does.
#
# THIS TEST drives the real probe against a fake surface on a free port, in
# every state the two arms can disagree about, and asserts the verdict:
#
#   1  bare 200 to everything             -> FAIL, names the port with (200)
#   2  401 bare, 200 with the fixture pw  -> PASS
#   3  401 to everything                  -> FAIL, a lock-out, not a pass
#   4  401 bare, and the fixture pw is    -> FAIL, the same lock-out: the
#      WRONG                                 credential on disk is not honoured
#   5  api-key via the -K store config    -> PASS  (the store kind, not basic)
#   6  nothing listening on the surface   -> CANNOT-RUN, never PASS
#   7  the positive-control port is down  -> CANNOT-RUN, never PASS
#   8  --self-test                        -> rc 1, no BROKEN (runner contract)
#   9  the same PASS through a stub ssh   -> PASS under `zsh -c`, because the
#      that runs `zsh -c`                    walk box's login shell is zsh and a
#                                            bare ? aborts a command there (#1737)
#
# And one mutant per arm, each proved LANDED by diff before its verdict:
#   M1  arm 1 stops recording a served bare request   -> arm 1 must go green
#   M2  arm 2 stops recording a refused credential    -> arm 3 must go green
# A mutant the arm still catches has survived, and the arm was decoration.
#
# Arm 1 is the mutation control the launch directive item 5 asked for in so
# many words: "point it at a port that answers bare and it must FAIL".
#
# THE FAKE BINDS RAW SOCKETS ON PURPOSE. http.server's constructor calls
# getfqdn() and on a CI runner that is a 35-second reverse-DNS stall
# (scripts/tests/test_people_seed_and_retrieval_probe.sh, task #348). Two
# listening sockets, a select loop, hand-parsed request lines, and the ports
# written to a file only after both binds have succeeded.
#
# NO REAL DATA. The password and api-key are fixtures minted here.
#
# Exit: 0 every arm behaved and every mutant was killed
#       1 an arm failed or a mutant survived
#       2 could not run (a prerequisite is missing, the fake never bound,
#         or a mutant did not land)
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/box_walk_probes/probes/no_store_port_is_tcp_reachable.sh"
LIB_DIR="$REPO_ROOT/scripts/box_walk_probes/lib"

for need in python3 curl nc diff sed; do
    command -v "$need" >/dev/null 2>&1 || { echo "CANNOT-RUN: $need not on PATH" >&2; exit 2; }
done
[[ -f "$PROBE" ]] || { echo "CANNOT-RUN: no probe at $PROBE" >&2; exit 2; }
[[ -f "$LIB_DIR/probe.sh" ]] || { echo "CANNOT-RUN: no probe lib at $LIB_DIR/probe.sh" >&2; exit 2; }

pass=0; fail=0; cannot=0
LAST_OUT=""
TMP="$(mktemp -d)"
SERVER_PIDS=""
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
    for p in $SERVER_PIDS; do kill "$p" 2>/dev/null; done
    rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The fake surface. One process, two listeners: a control port that accepts
# and closes (the probe's positive control is `nc -z`), and an HTTP port whose
# answer is decided by --mode:
#   bare    200 to everything
#   refuse  401 to everything
#   auth    200 iff the request carries the expected Basic credential or the
#           expected api-key header, else 401
# ---------------------------------------------------------------------------
cat > "$TMP/fake.py" <<'PY'
import argparse, base64, os, select, socket
ap = argparse.ArgumentParser()
ap.add_argument('--mode', required=True)
ap.add_argument('--basic', default='')
ap.add_argument('--apikey', default='')
ap.add_argument('--portfile', required=True)
a = ap.parse_args()

def listen():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', 0))
    s.listen(8)
    return s

ctrl = listen()
http = listen()
with open(a.portfile + '.tmp', 'w') as f:
    f.write('%d\n%d\n' % (ctrl.getsockname()[1], http.getsockname()[1]))
os.rename(a.portfile + '.tmp', a.portfile)
want_basic = base64.b64encode(a.basic.encode()).decode() if a.basic else None

def respond(c, code):
    body = b'fake\n'
    reason = {200: 'OK', 401: 'Unauthorized'}[code]
    hdr = 'HTTP/1.1 %d %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n' % (code, reason, len(body))
    if code == 401:
        hdr += 'WWW-Authenticate: Basic realm="fake"\r\n'
    c.sendall(hdr.encode() + b'\r\n' + body)

while True:
    ready, _, _ = select.select([ctrl, http], [], [], 1.0)
    for s in ready:
        c, _ = s.accept()
        if s is ctrl:
            c.close()
            continue
        c.settimeout(3)
        data = b''
        try:
            while b'\r\n\r\n' not in data:
                chunk = c.recv(4096)
                if not chunk:
                    break
                data += chunk
        except Exception:
            pass
        headers = {}
        for line in data.decode('latin-1').split('\r\n')[1:]:
            if ':' in line:
                k, v = line.split(':', 1)
                headers[k.strip().lower()] = v.strip()
        if a.mode == 'bare':
            code = 200
        elif a.mode == 'refuse':
            code = 401
        else:
            ok = False
            if want_basic and headers.get('authorization') == 'Basic ' + want_basic:
                ok = True
            if a.apikey and headers.get('api-key') == a.apikey:
                ok = True
            code = 200 if ok else 401
        try:
            respond(c, code)
        except Exception:
            pass
        c.close()
PY

CTRL=""; HTTP=""
start_server() {   # $1 mode, $2 basic "user:pw" or "", $3 apikey or ""
    local pf="$TMP/ports.$$.$RANDOM"
    rm -f "$pf"
    python3 "$TMP/fake.py" --mode "$1" --basic "$2" --apikey "$3" --portfile "$pf" &
    local pid=$!
    SERVER_PIDS="$SERVER_PIDS $pid"
    for _ in $(seq 1 100); do
        [[ -s "$pf" ]] && break
        sleep 0.1
    done
    if [[ ! -s "$pf" ]]; then
        echo "CANNOT-RUN: the fake surface never bound a port (mode $1)" >&2
        exit 2
    fi
    CTRL="$(/usr/bin/sed -n '1p' "$pf")"
    HTTP="$(/usr/bin/sed -n '2p' "$pf")"
    LAST_SERVER_PID="$pid"
}
stop_server() {
    kill "$LAST_SERVER_PID" 2>/dev/null
    wait "$LAST_SERVER_PID" 2>/dev/null
}

# A port nothing listens on: bind 0, read it, close. TIME_WAIT does not apply
# to a socket that never connected, so the probe's connect gets ECONNREFUSED.
closed_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# Fixtures. The password file mirrors the installer: no trailing newline.
GOOD_PW="tst-pw-2k9q-mn7r"
printf '%s' "$GOOD_PW" > "$TMP/wiki_password";  chmod 600 "$TMP/wiki_password"
printf '%s' "wrong-pw-0000"  > "$TMP/wiki_password.wrong"; chmod 600 "$TMP/wiki_password.wrong"
API_KEY="fixture-api-key-7f3a"
printf 'header = "api-key: %s"\n' "$API_KEY" > "$TMP/store-curl.conf"; chmod 600 "$TMP/store-curl.conf"

count() {   # $1 fixed string, $2 text -> how many lines contain it
    printf '%s\n' "$2" | grep -cF -- "$1"
}

# Runs the probe at $1 against one surface.  $2 ctrl port, $3 surfaces spec,
# $4 wiki password file, $5 store curl conf. OSTLER_BOX_HOST is cleared so the
# transport is local (`bash -lc`), unless the caller exports a fake host to
# exercise the ssh path.
run_probe() {
    local probe="$1" ctrl="$2" surfaces="$3" pwfile="$4" conf="$5"
    env -u OSTLER_BOX_HOST \
        OSTLER_GATEWAY_PORT="$ctrl" \
        OSTLER_PROBE_MUST_NOT_LISTEN="" \
        OSTLER_PROBE_SURFACES="$surfaces" \
        OSTLER_PROBE_WIKI_PASSWORD_FILE="$pwfile" \
        OSTLER_PROBE_STORE_CURL_CONF="$conf" \
        bash "$probe" 2>&1
}

# Each arm returns 0 when the probe behaved and leaves its output in LAST_OUT.
arm_bare_is_fail() {          # 1
    local out rc
    start_server bare "" ""
    out="$(run_probe "$1" "$CTRL" "$HTTP:wiki:/" "$TMP/wiki_password" "$TMP/store-curl.conf")"; rc=$?; LAST_OUT="$out"
    stop_server
    [[ "$rc" -eq 1 ]] || return 1
    [[ "$(count 'VERDICT: FAIL' "$out")" -eq 1 ]] || return 1
    [[ "$(count "${HTTP}(200)" "$out")" -ge 1 ]] || return 1
    [[ "$(count 'served by these Ostler surfaces' "$out")" -eq 1 ]] || return 1
    return 0
}
arm_gated_is_pass() {         # 2
    local out rc
    start_server auth "ostler:${GOOD_PW}" ""
    out="$(run_probe "$1" "$CTRL" "$HTTP:wiki:/" "$TMP/wiki_password" "$TMP/store-curl.conf")"; rc=$?; LAST_OUT="$out"
    stop_server
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$(count 'VERDICT: PASS' "$out")" -eq 1 ]] || return 1
    [[ "$(count "served by: ${HTTP}" "$out")" -eq 1 ]] || return 1
    return 0
}
arm_refuse_all_is_fail() {    # 3
    local out rc
    start_server refuse "" ""
    out="$(run_probe "$1" "$CTRL" "$HTTP:wiki:/" "$TMP/wiki_password" "$TMP/store-curl.conf")"; rc=$?; LAST_OUT="$out"
    stop_server
    [[ "$rc" -eq 1 ]] || return 1
    [[ "$(count 'VERDICT: FAIL' "$out")" -eq 1 ]] || return 1
    [[ "$(count "refused the install's OWN credential" "$out")" -eq 1 ]] || return 1
    [[ "$(count "${HTTP}(401)" "$out")" -ge 1 ]] || return 1
    return 0
}
arm_wrong_password_is_fail() { # 4
    local out rc
    start_server auth "ostler:${GOOD_PW}" ""
    out="$(run_probe "$1" "$CTRL" "$HTTP:wiki:/" "$TMP/wiki_password.wrong" "$TMP/store-curl.conf")"; rc=$?; LAST_OUT="$out"
    stop_server
    [[ "$rc" -eq 1 ]] || return 1
    [[ "$(count "refused the install's OWN credential" "$out")" -eq 1 ]] || return 1
    return 0
}
arm_store_kind_is_pass() {    # 5
    local out rc
    start_server auth "" "$API_KEY"
    out="$(run_probe "$1" "$CTRL" "$HTTP:store:/collections" "$TMP/wiki_password" "$TMP/store-curl.conf")"; rc=$?; LAST_OUT="$out"
    stop_server
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$(count 'VERDICT: PASS' "$out")" -eq 1 ]] || return 1
    return 0
}
arm_nothing_listening_is_cannot_run() {   # 6
    local out rc dead
    start_server auth "ostler:${GOOD_PW}" ""
    dead="$(closed_port)"
    out="$(run_probe "$1" "$CTRL" "$dead:wiki:/" "$TMP/wiki_password" "$TMP/store-curl.conf")"; rc=$?; LAST_OUT="$out"
    stop_server
    [[ "$rc" -eq 78 ]] || return 1
    [[ "$(count 'VERDICT: CANNOT-RUN' "$out")" -eq 1 ]] || return 1
    [[ "$(count "${dead}(000)" "$out")" -ge 1 ]] || return 1
    return 0
}
arm_control_down_is_cannot_run() {        # 7
    local out rc dead
    start_server auth "ostler:${GOOD_PW}" ""
    dead="$(closed_port)"
    out="$(run_probe "$1" "$dead" "$HTTP:wiki:/" "$TMP/wiki_password" "$TMP/store-curl.conf")"; rc=$?; LAST_OUT="$out"
    stop_server
    [[ "$rc" -eq 78 ]] || return 1
    [[ "$(count 'VERDICT: CANNOT-RUN' "$out")" -eq 1 ]] || return 1
    [[ "$(count "control port ${dead}" "$out")" -eq 1 ]] || return 1
    return 0
}
arm_self_test_contract() {                # 8
    local out rc
    out="$(bash "$1" --self-test 2>&1)"; rc=$?; LAST_OUT="$out"
    [[ "$rc" -eq 1 ]] || return 1
    [[ "$(count 'VERDICT: BROKEN' "$out")" -eq 0 ]] || return 1
    [[ "$(count 'NEGATIVE CONTROL DEMONSTRATED' "$out")" -eq 1 ]] || return 1
    return 0
}
arm_pass_survives_zsh() {                 # 9
    local out rc
    mkdir -p "$TMP/bin"
    # A stub ssh: the walk box's login shell is zsh, so run the command the
    # probe would have sent over the wire under `zsh -c` right here. Options
    # (-o ..., the host) are dropped; the last argument is the command.
    cat > "$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd=""
for a in "$@"; do cmd="$a"; done
exec zsh -c "$cmd"
STUB
    chmod +x "$TMP/bin/ssh"
    start_server auth "ostler:${GOOD_PW}" ""
    # The path carries a QUERY STRING on purpose: under zsh a bare ? is a glob
    # that matches nothing and aborts the command before curl runs (#1737).
    # The probe single-quotes every URL it sends; this is the arm that proves
    # it, on the shell that bit.
    out="$(PATH="$TMP/bin:$PATH" OSTLER_BOX_HOST=fakebox \
           OSTLER_GATEWAY_PORT="$CTRL" OSTLER_PROBE_MUST_NOT_LISTEN="" \
           OSTLER_PROBE_SURFACES="$HTTP:wiki:/query?query=ASK%7B%7D" \
           OSTLER_PROBE_WIKI_PASSWORD_FILE="$TMP/wiki_password" \
           OSTLER_PROBE_STORE_CURL_CONF="$TMP/store-curl.conf" \
           bash "$1" 2>&1)"; rc=$?; LAST_OUT="$out"
    stop_server
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$(count 'VERDICT: PASS' "$out")" -eq 1 ]] || return 1
    return 0
}

report() {   # $1 name, $2 rc of the arm
    if [[ "$2" -eq 0 ]]; then
        printf '  [pass] %s\n' "$1"; pass=$((pass + 1))
    else
        printf '  [FAIL] %s\n' "$1"; fail=$((fail + 1))
        printf '%s\n' "$LAST_OUT" | sed 's/^/         | /' | head -40
    fi
}

echo "== the store-port probe asks whether a surface SERVES, on both arms (#1618) =="
echo "-- the real probe: $PROBE"
arm_bare_is_fail "$PROBE";                  report "1 a surface that answers bare -> FAIL, naming the port with (200)" $?
arm_gated_is_pass "$PROBE";                 report "2 refuses bare, serves the install's credential -> PASS" $?
arm_refuse_all_is_fail "$PROBE";            report "3 refuses everyone -> FAIL, a lock-out, never a pass" $?
arm_wrong_password_is_fail "$PROBE";        report "4 the credential on disk is not honoured -> the same lock-out FAIL" $?
arm_store_kind_is_pass "$PROBE";            report "5 the store kind presents the -K config (api-key) -> PASS" $?
arm_nothing_listening_is_cannot_run "$PROBE"; report "6 nothing listening on the surface -> CANNOT-RUN, never PASS" $?
arm_control_down_is_cannot_run "$PROBE";    report "7 the positive control is down -> CANNOT-RUN, never PASS" $?
arm_self_test_contract "$PROBE";            report "8 --self-test exits 1 without BROKEN (the runner's contract)" $?
if command -v zsh >/dev/null 2>&1; then
    arm_pass_survives_zsh "$PROBE";         report "9 the same PASS through a stub ssh running zsh -c, with a ? in the URL (#1737)" $?
else
    printf '  [not run] 9 zsh is not on this host, so the remote-shell arm was NOT measured\n'
fi

# ---------------------------------------------------------------------------
# Mutants. The probe sources ../lib/probe.sh relative to its own directory, so
# each mutant lives in a probes/ dir beside a lib/ that points at the real one.
# ---------------------------------------------------------------------------
mutate() {   # $1 name, $2 sed expression -> prints the mutant probe path, rc 2 if it did not land
    local dir="$TMP/mut-$1" changed
    mkdir -p "$dir/probes"
    ln -sfn "$LIB_DIR" "$dir/lib"
    sed -e "$2" "$PROBE" > "$dir/probes/no_store_port_is_tcp_reachable.sh"
    changed="$(diff "$PROBE" "$dir/probes/no_store_port_is_tcp_reachable.sh" | grep -c '^>')"
    if [[ "$changed" -ne 1 ]]; then
        printf '  [CANNOT-RUN] mutant %s did not land: %s changed line(s), wanted 1\n' "$1" "$changed" >&2
        return 2
    fi
    printf '%s' "$dir/probes/no_store_port_is_tcp_reachable.sh"
}

# The counter is moved HERE, in the shell that reads it at exit: mutate() runs
# inside a command substitution, so a counter it moved would move in a
# subshell and the summary would print zero.
run_mutant() {   # $1 name, $2 arm fn, $3 sed expression
    local m mrc
    m="$(mutate "$1" "$3")"; mrc=$?
    if [[ "$mrc" -ne 0 ]]; then cannot=$((cannot + 1)); return; fi
    if "$2" "$m"; then
        printf '  [FAIL] mutant %s SURVIVED: %s still passes against the mutated probe\n' "$1" "$2"
        fail=$((fail + 1))
        printf '%s\n' "$LAST_OUT" | sed 's/^/         | /' | head -40
    else
        printf '  [pass] mutant %s killed by %s\n' "$1" "$2"; pass=$((pass + 1))
    fi
}

echo "-- mutants, one per arm"
# shellcheck disable=SC2016
run_mutant M1-arm1-stops-recording-a-bare-200 arm_bare_is_fail \
    's/^            readable)     readable_list="${readable_list} ${p}(${r1})"; continue ;;$/            readable)     continue ;;/'
# shellcheck disable=SC2016
run_mutant M2-arm2-stops-recording-a-refused-credential arm_refuse_all_is_fail \
    's/^            refused)  locked_list="${locked_list} ${p}(${r2})" ;;$/            refused)  : ;;/'

echo ""
echo "== ${pass} passed, ${fail} failed, ${cannot} cannot-run =="
[[ "$cannot" -eq 0 ]] || exit 2
[[ "$fail" -eq 0 ]] || exit 1
exit 0
