#!/usr/bin/env bash
# lib/daemon_memory.sh -- read, and forget from, the assistant daemon's OWN
# memory, for the walk's synthetic seed person only.
#
# Sourced by assistant_grounds_the_opening_turn.sh (precondition 1) and by
# grounding_seed.sh (after seeding, before any probe asks). Callers set
# GATEWAY, TOKEN_PATH and KNOWN_PERSON; the defaults below match the probes.
#
# WHY THE SEED PURGES. The daemon files every conversation in memory, so on a
# box the grounded battery has already run on, "Who is <seed person>?" is
# answered from memory with NO tool call. Measured on the v1.0.102 candidate 4
# box, fourth battery on the same install: the seeded question read
# no_tool_call, and /api/memory held "User: Who is <seed person> ... Assistant:
# ... submarine cable engineer at example.com" from an earlier run. The first
# walk on a fresh box never sees this, which is why it passed there. A re-run
# of the probe phase (after an ssh drop, or to re-adjudicate) is routine, so
# the walk must not grade its own leftovers. Only memory naming the SYNTHETIC
# person is touched, and only when grounding_seed_apply seeded that person.
# The runner sources this without lib/probe.sh, so box_run may not exist yet.
# The fallback is the same transport probe.sh defines, stderr kept out of the
# reading exactly as there.
if ! declare -F box_run >/dev/null 2>&1; then
    box_run() {
        if [ -n "${OSTLER_BOX_HOST:-}" ]; then
            ssh -o ConnectTimeout="${OSTLER_SSH_TIMEOUT:-8}" -o BatchMode=yes -o ServerAliveInterval="${OSTLER_SSH_ALIVE_S:-15}" -o ServerAliveCountMax="${OSTLER_SSH_ALIVE_N:-4}" \
                "$OSTLER_BOX_HOST" "$1" 2>/dev/null
        else
            bash -lc "$1" 2>/dev/null
        fi
    }
fi
GATEWAY="${GATEWAY:-${OSTLER_PROBE_GATEWAY:-http://127.0.0.1:8000}}"
TOKEN_PATH="${TOKEN_PATH:-${OSTLER_PROBE_TOKEN_PATH:-~/.ostler/secrets/zeroclaw_admin_token}}"

# THE ROUTE THIS USED TO READ DOES NOT EXIST. It asked
# /api/v1/memory/search, unauthenticated, through curl -f. The daemon has no
# such route (measured on the v1.0.102 walk-4 box: 404 "unknown endpoint", with
# or without the admin token), so the reading was empty on every box and this
# probe was CANNOT-RUN on every walk it has ever been in, reported as "could
# not read daemon memory" and never as "the instrument asks a route nobody
# serves". The daemon's memory API is GET /api/memory?query= (recall, top 50)
# and DELETE /api/memory/{key}, both behind the admin bearer token
# (ostler-assistant crates/zeroclaw-gateway/src/lib.rs, the /api/memory
# routes). python on the box, not curl, so the token never rides on a command
# line and a refused read names its HTTP status instead of printing nothing.
read -r -d '' MEMORY_PY <<'PYMEMORY'
import json, os, sys, urllib.error, urllib.parse, urllib.request
gw, tok_path, person, action = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
try:
    tok = open(os.path.expanduser(tok_path), encoding="utf-8").read().strip()
except Exception as exc:
    print("UNREADABLE token " + type(exc).__name__); sys.exit(0)
H = {"Authorization": "Bearer " + tok}
def call(method, path):
    req = urllib.request.Request(gw + path, headers=H, method=method)
    return urllib.request.urlopen(req, timeout=15)
try:
    if action == "read":
        d = json.load(call("GET", "/api/memory?query=" + urllib.parse.quote(person)))
        entries = d.get("entries") if isinstance(d, dict) else None
        if not isinstance(entries, list):
            print("UNREADABLE shape " + type(d).__name__); sys.exit(0)
        hits = [e.get("key", "") for e in entries
                if person.lower() in str(e.get("content") or "").lower()]
        print("READ %d %d" % (len(entries), len(hits)))
        for k in hits:
            print("KEY " + k)
    else:
        ok = bad = 0
        for k in sys.argv[5:]:
            try:
                call("DELETE", "/api/memory/" + urllib.parse.quote(k, safe=""))
                ok += 1
            except Exception:
                bad += 1
        print("FORGOT %d %d" % (ok, bad))
except urllib.error.HTTPError as exc:
    print("UNREADABLE http %d" % exc.code)
except Exception as exc:
    print("UNREADABLE " + type(exc).__name__)
PYMEMORY

_memory_mentions_person() {
    # ${GATEWAY}, not a second hard-coded 127.0.0.1:8000. The refusal this
    # feeds NAMES the URL it could not read, and a message that names one
    # address while the reader used another is the shape that makes a probe's
    # reason untrustworthy even when its verdict is right.
    box_run "python3 - '${GATEWAY}' '${TOKEN_PATH}' '${KNOWN_PERSON}' read <<'PYMEMORY'
${MEMORY_PY}
PYMEMORY"
}

_memory_forget_keys() {
    box_run "python3 - '${GATEWAY}' '${TOKEN_PATH}' '${KNOWN_PERSON}' forget $* <<'PYMEMORY'
${MEMORY_PY}
PYMEMORY"
}

# _read_memory_answer <reader output> -> UNREADABLE | ABSENT | PRESENT
# One copy, driven by run_probe and by the self-test.
_read_memory_answer() {
    case "$1" in
        "READ "*)
            local n
            n="$(printf '%s\n' "$1" | awk 'NR==1 {print $3}')"
            case "$n" in ''|*[!0-9]*) printf 'UNREADABLE'; return ;; esac
            if [ "$n" -gt 0 ]; then printf 'PRESENT'; else printf 'ABSENT'; fi ;;
        *) printf 'UNREADABLE' ;;
    esac
}
