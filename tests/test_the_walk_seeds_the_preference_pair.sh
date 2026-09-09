#!/usr/bin/env bash
# tests/test_the_walk_seeds_the_preference_pair.sh
# ============================================================================
# grounding_seed.sh puts a PERSON in the graph before the grounded probe asks
# about one. Nothing put a PREFERENCE there, so an empty preference wiki, an
# ingest that never ran and a broken write route were three faults wearing one
# face. On v1.0.81 the root cause was the first: cm019_setup logged "already
# set up" with elapsed_s=0 and install.log holds no ingest-dir and no "Files
# processed".
#
# scripts/box_walk_probes/lib/preference_seed.sh closes that. This test pins
# the things that make it worth having:
#
#   1. IT IS WIRED. The runner sources the lib and calls it ABOVE the phase-2
#      measurement loop, with the forget step below. A lib nothing invokes is
#      the "unwired" case the directive names.
#   2. THE STAGED TREE IS CHECKED BY CONTENT. A box running different cm019
#      code is a CANNOT-RUN, because the seed counts would not mean what the
#      fixture says. Measured against the REAL vendor tree, not a stub, and
#      the stale arm mutates one staged byte.
#   3. BOTH FLOOR ARMS ARE LOAD-BEARING. interests >= 1 AND suppressed >= 1.
#      A profile with interests and no suppressions cannot tell a working
#      screen from an absent one, so the suppressed arm has its own MUST-FAIL.
#   4. WHAT WE COULD NOT LOOK AT IS NOT A FAIL. Every path prints a named
#      CANNOT-RUN or a named FINDING, never a bare red.
#   5. THE ARTEFACT THE TOOL READS IS RECOMPILED AND READ BACK. On the
#      v1.0.82 walk the first four all held and the grounded probe still
#      reported [tool_found_nothing:pwg_preferences], because the tool reads
#      a compiled file the install's RunAtLoad tick had written EMPTY before
#      the seed existed. So the seed must trigger the installer's own tick
#      (launchctl kickstart, or the rendered tick directly when kickstart is
#      refused), wait for generated_at to ADVANCE (not merely exist: an equal
#      value after a rewrite is a CANNOT-RUN), then GET /api/v1/preferences
#      with the box's own token and find the fixture subject. Its MUST-FAIL
#      runs the pre-change lib against the same stub box and requires that
#      it reported seeded without a single API request.
#   6. EVERY REMOTE PATH EXPANDS $HOME ON THE BOX. The generated remote text
#      is captured and grepped: no single-quoted literal $HOME reaches it,
#      and a box whose only root is $HOME/.ostler is found.
#
# The loader, the compiler, launchctl and the API are stubbed. This test is
# about the WIRING, the currency check, the three-outcome discipline and the
# read-back route. Whether OS003's loader can talk to a store is
# load_preference_seed.py's own --self-test.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/preference_seed.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
VENDOR="$REPO/vendor/cm019_preferences"
LABEL="com.creativemachines.ostler.editor-frontpage"
PRE_CHANGE_SHA="ae5707d4"   # the last main without the compile-and-serve step

PASS=0
FAIL=0
arm() { # $1 = label, $2 = condition already evaluated (0/1), $3 = detail on failure
    if [ "$2" -eq 0 ]; then
        printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$1"; printf '%s\n' "$3" | sed 's/^/         /'; FAIL=$((FAIL + 1))
    fi
}

WORK="$(mktemp -d)"
API_PID=""
cleanup() {
    [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

[ -f "$LIB" ] || { printf 'CANNOT-RUN: no lib at %s\n' "$LIB"; exit 78; }
[ -f "$RUNNER" ] || { printf 'CANNOT-RUN: no runner at %s\n' "$RUNNER"; exit 78; }
[ -d "$VENDOR" ] || { printf 'CANNOT-RUN: no vendor tree at %s\n' "$VENDOR"; exit 78; }
PY3="$(command -v python3 || true)"
[ -n "$PY3" ] || { printf 'CANNOT-RUN: no python3 on PATH\n'; exit 78; }
UID_NOW="$(id -u)"

# The four files the lib hashes. Kept in the test as a LITERAL rather than
# read out of the lib, so a PR that quietly narrows the currency check to one
# file has to change this list too and be seen doing it.
CURRENCY="services/ingest/src/pipeline.py
services/ingest/src/filters.py
services/ingest/src/parsers/spotify.py
services/ingest/src/parsers/twitter.py"

# The fixture's clearing subject and floor, as the stub fixture below states
# them. Synthetic, lower-case on purpose (bin/pii_name_guard.py reads any
# capitalised word pair as a name), and never a person, place, handle or message.
STUB_SUBJECT="stub seed ensemble - loopback nocturne"
STUB_FLOOR="0.28"
STUB_TOKEN="stub-service-token-$$"
printf '%s\n' "$STUB_TOKEN" > "$WORK/token"

# ---------------------------------------------------------------------------
# THE STUB API. One process for the whole suite. It reads the artefact named
# by a POINTER FILE (rewritten per arm by run_apply), filters it the way
# api_preferences does (ical-server.py:6650-6710: exact-case domain,
# confidence >= min_confidence, score-sorted, limit), and answers 401 to any
# request that does not carry the stub token. Every request path is appended
# to a log, which is what the MUST-FAIL arm reads.
# ---------------------------------------------------------------------------
API_POINTER="$WORK/api.pointer"
API_REQLOG="$WORK/api.requests"
: > "$API_REQLOG"
cat > "$WORK/api.py" <<'PY'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
pointer, token_file, reqlog = sys.argv[1:4]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with open(reqlog, "a", encoding="utf-8") as fh:
            fh.write(self.path + "\n")
        u = urllib.parse.urlparse(self.path)
        if u.path != "/api/v1/preferences":
            self._send(404, {"error": "Not found"})
            return
        expected = open(token_file, encoding="utf-8").read().strip()
        if self.headers.get("Authorization", "") != "Bearer " + expected:
            self._send(401, {"error": "Unauthorized: missing or invalid service token"})
            return
        try:
            path = open(pointer, encoding="utf-8").read().strip()
            doc = json.load(open(path, encoding="utf-8"))
        except FileNotFoundError:
            self._send(200, {"interests": [], "count": 0})
            return
        items = doc.get("interests", [])
        q = urllib.parse.parse_qs(u.query)
        dom = (q.get("domain") or [None])[0]
        mc = float((q.get("min_confidence") or ["0"])[0])
        lim = int((q.get("limit") or ["0"])[0])
        if dom:
            items = [i for i in items if i.get("domain") == dom]
        if mc > 0.0:
            items = [i for i in items if float(i.get("confidence") or 0.0) >= mc]
        items.sort(key=lambda i: float(i.get("score") or 0.0), reverse=True)
        if lim > 0:
            items = items[:lim]
        self._send(200, {"interests": items, "count": len(items),
                         "generated_at": doc.get("generated_at")})

srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PY
"$PY3" "$WORK/api.py" "$API_POINTER" "$WORK/token" "$API_REQLOG" > "$WORK/api.port" 2> "$WORK/api.err" &
API_PID=$!
for _i in $(seq 1 100); do [ -s "$WORK/api.port" ] && break; sleep 0.1; done
API_PORT="$(cat "$WORK/api.port" 2>/dev/null)"
[ -n "$API_PORT" ] || { printf 'CANNOT-RUN: the stub API did not start: %s\n' "$(cat "$WORK/api.err")"; exit 78; }
API_BASE="http://127.0.0.1:$API_PORT"

# ---------------------------------------------------------------------------
# THE STUB launchctl. Answers 113 for a label that is not loaded (the real
# code, measured 2026-09-10), and on kickstart starts the root's rendered
# tick in the background after a two-second delay, which is what launchd
# does: kickstart returns at once and the tick runs later. The delay is what
# lets arm 9 see the OLD value polled before the new one. Logs every call.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/launchctl" <<'SH'
#!/bin/bash
root="${OSTLER_DIR:-$HOME/.ostler}"
printf '%s\n' "$*" >> "$root/launchctl.log"
if [ ! -f "$root/agent-loaded" ]; then
    echo "Could not find service in domain for user gui: $(id -u)" >&2
    exit 113
fi
case "$1" in
    print) exit 0 ;;
    kickstart)
        ( STUB_TICK_DELAY="${STUB_TICK_DELAY:-2}" /bin/bash "$root/bin/editor-frontpage-tick.sh" >/dev/null 2>&1 & )
        exit 0 ;;
    *) exit 1 ;;
esac
SH
chmod 0755 "$WORK/bin/launchctl"

# A stand-in for the cm019 bundle INSIDE THE ARTEFACT. Real vendor files are
# used as its content only because they are convenient bytes; nothing in the
# lib may read the checkout, and arm 4 is what proves that.
make_bundle() { # $1 = bundle dir to build
    local b="$1"
    for f in $CURRENCY; do
        mkdir -p "$b/$(dirname "$f")"
        cp "$VENDOR/$f" "$b/$f"
    done
}

# A fake ~/.ostler whose staged cm019 tree is a copy of a given bundle, which
# is what install.sh does: cp -R "${CM019_BUNDLE}/" "$CM019_DIR/".
make_staged_tree() { # $1 = OSTLER_DIR to build, $2 = bundle to copy from
    local root="$1" b="$2"
    for f in $CURRENCY; do
        mkdir -p "$root/services/cm019/$(dirname "$f")"
        cp "$b/$f" "$root/services/cm019/$f"
    done
}

# A fake staged interest-profile compiler, the rendered tick that names the
# interpreter, the LaunchAgent plist (under $root/boxhome, which run_apply hands
# the lib as HOME), the service token, an agent-loaded marker for the stub
# launchctl, and the artefact the install's RunAtLoad tick leaves behind:
# EMPTY, and older than anything this run writes.
#   $2/$3  the numbers build_from_live() reports in-process
#   $4     what the tick writes when run: serve (the subject at 0.2991),
#          empty (a fresh generated_at and no interests), frozen (rewrites
#          the file with the SAME generated_at)
make_stub_compiler() { # $1 = OSTLER_DIR, $2 = interests, $3 = suppressed, $4 = tick mode
    local root="$1" mode="${4:-serve}"
    mkdir -p "$root/bin" "$root/services/cm059-editor/compiler" "$root/secrets" \
        "$root/preferences" "$root/boxhome/Library/LaunchAgents"
    : > "$root/services/cm059-editor/compiler/__init__.py"
    cat > "$root/services/cm059-editor/compiler/interest_profile.py" <<PY
def build_from_live(*a, **k):
    return {"stats": {"interests": $2, "suppressed_low_confidence": $3,
                      "dislikes": 0, "domains": 1, "raw_rows": 2},
            "domains": [{"domain": "Music", "count": $2,
                         "interests": [{"subject": "stub row", "confidence": 0.2991}][:$2]}]}
PY
    printf '%s\n' "$STUB_TOKEN" > "$root/secrets/service_token"
    : > "$root/boxhome/Library/LaunchAgents/$LABEL.plist"
    : > "$root/agent-loaded"
    printf '{"schema_version": "0.1", "generated_at": "2026-09-09T18:17:09Z", "count": 0, "interests": []}\n' \
        > "$root/preferences/interest_profile.json"
    cat > "$root/bin/editor-frontpage-tick.sh" <<EOF
#!/bin/bash
PYTHON_BIN="$PY3"
sleep "\${STUB_TICK_DELAY:-0}"
"$PY3" - "$root/preferences/interest_profile.json" "$mode" <<'PY'
import json, sys
from datetime import datetime, timezone
p, mode = sys.argv[1], sys.argv[2]
if mode == "frozen":
    doc = json.load(open(p, encoding="utf-8"))
    json.dump(doc, open(p, "w", encoding="utf-8"))
    sys.exit(0)
items = []
if mode == "serve":
    items = [{"subject": "$STUB_SUBJECT", "domain": "Music", "polarity": "like",
              "confidence": 0.2991, "score": 0.2897, "privacy": "L1"}]
json.dump({"schema_version": "0.1", "generated_at": datetime.now(timezone.utc).isoformat(),
           "count": len(items), "interests": items}, open(p, "w", encoding="utf-8"))
PY
EOF
    chmod 0755 "$root/bin/editor-frontpage-tick.sh"
}

# A stand-in for OS003 gates/seed. $2 is the loader's exit code; the marker is
# what _ps_loader_is_current looks for, so --stale produces exactly the
# pre-read-back shape the guard exists to refuse. The fixture carries the two
# fields the read-back needs, in the real fixture's shape.
make_seed_dir() { # $1 dir, $2 rc, $3 optional --stale
    mkdir -p "$1/preferences/exports"
    cat > "$1/preferences/preference_fixture.json" <<JSON
{"expect_rows": [
   {"subject": "$STUB_SUBJECT", "category": "music", "clears_floor": true},
   {"subject": "loopback cartography", "category": "interest", "clears_floor": false}],
 "compiler": {"min_confidence": $STUB_FLOOR}}
JSON
    printf '[]\n' > "$1/preferences/exports/StreamingHistory0.json"
    printf 'window.YTD.personalization.part0 = []\n' > "$1/preferences/exports/personalization.js"
    if [ "${3:-}" = "--stale" ]; then
        cat > "$1/load_preference_seed.py" <<PY
import sys
# pre-read-back loader: reports the ingest exit code and calls that a pass
sys.exit($2)
PY
    else
        cat > "$1/load_preference_seed.py" <<PY
import os, sys
# current loader marker: the graph read-back is SELECT (COUNT(DISTINCT ?s) ...)
if "--digest" in sys.argv:
    # stdout is the digest ALONE, as the real one guarantees
    print("stubdigest-" + os.path.basename(sys.argv[sys.argv.index("--digest") + 1]))
    sys.exit(0)
with open("$1/RAN", "a") as fh:
    fh.write("ARGS " + " ".join(sys.argv[1:]) + "\n")
    fh.write("DIGEST " + os.environ.get("OSTLER_PREF_SEED_CM019_DIGEST", "") + "\n")
    fh.write("SOURCE " + os.environ.get("OSTLER_PREF_SEED_CM019_DIGEST_SOURCE", "") + "\n")
sys.stderr.write("stub loader says: rc=$2\n")
sys.exit($2)
PY
    fi
}

# Source the lib in a child shell, call the step, report what it decided.
# When an OSTLER_DIR=<root> assignment is among the args, HOME becomes
# <root>/boxhome (where make_stub_compiler put the plist) and the stub API is
# pointed at <root>'s artefact. PS_CAPTURE=<file> records every remote
# program the lib generated; PS_FORGET=1 also calls the forget step.
run_apply() { # $1 = lib, rest = env assignments
    local lib="$1"; shift
    local home_override="" kv
    for kv in "$@"; do
        case "$kv" in
            OSTLER_DIR=*)
                home_override="${kv#OSTLER_DIR=}/boxhome"
                printf '%s/preferences/interest_profile.json\n' "${kv#OSTLER_DIR=}" > "$API_POINTER" ;;
        esac
    done
    env -u OSTLER_PREF_SEED_SKIP -u OSTLER_SEED_DIR \
        -u OSTLER_ALLOW_INSTALLED_APP_BUNDLE -u OSTLER_PREF_COMPILE_SKIP \
        OSTLER_BOX_HOST= OSTLER_CM019_BUNDLE="${BUNDLE:-}" \
        OSTLER_PREF_SEED_VOLUMES_DIR="${EMPTY_VOLUMES:-/nonexistent-volumes}" \
        OSTLER_PREF_LAUNCHCTL="$WORK/bin/launchctl" OSTLER_PREF_API_BASE="$API_BASE" \
        OSTLER_PREF_COMPILE_BUDGET_S="${BUDGET:-10}" OSTLER_PREF_COMPILE_POLL_S=1 \
        ${home_override:+HOME="$home_override"} "$@" \
        bash -c '
            . "$1"
            if [ -n "${PS_CAPTURE:-}" ]; then
                _ps_box_exec() { printf "%s\n----\n" "$1" >> "$PS_CAPTURE"; /bin/sh -c "$1"; }
                _ps_box_exec_stdin() { printf "%s\n----\n" "$1" >> "$PS_CAPTURE"; /bin/sh -c "$1"; }
            fi
            preference_seed_apply
            printf "RC=%s\n" "$?"
            printf "STATE=%s\n" "${PREFERENCE_SEED_STATE}"
            if [ "${PS_FORGET:-0}" = "1" ]; then
                preference_seed_forget
                printf "FRC=%s\n" "$?"
            fi
        ' _ "$lib" 2>&1
}

printf 'THE WALK SEEDS THE PREFERENCE PAIR\n\n'

# ---------------------------------------------------------------------------
printf -- '-- 1. it is wired into the runner, in the right order --\n'
# ---------------------------------------------------------------------------
src_line="$(grep -n 'lib/preference_seed.sh' "$RUNNER" | head -1 | cut -d: -f1)"
apply_line="$(grep -n '^preference_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)"
forget_line="$(grep -n '^preference_seed_forget' "$RUNNER" | head -1 | cut -d: -f1)"
loop_line="$(grep -n '^    out="$(bash "$p" 2>&1)"' "$RUNNER" | head -1 | cut -d: -f1)"

[ -n "$src_line" ] && [ -n "$apply_line" ]
arm "the runner sources the lib and calls preference_seed_apply" $? \
    "source line='$src_line' apply line='$apply_line'"

[ -n "$loop_line" ] && [ -n "$apply_line" ] && [ "$apply_line" -lt "$loop_line" ]
arm "the seed runs BEFORE the phase-2 probe loop (a seed after it seeds nothing)" $? \
    "apply at $apply_line, probe loop at $loop_line"

[ -n "$forget_line" ] && [ -n "$loop_line" ] && [ "$forget_line" -gt "$loop_line" ]
arm "the forget step runs AFTER the loop, so it cannot change a verdict" $? \
    "forget at $forget_line, probe loop at $loop_line"

# The three line citations at the top of the runner must survive this wiring.
[ "$(sed -n '42p' "$RUNNER")" = 'PROBE_DIR="$HERE/probes"' ] \
    && [ "$(sed -n '44p' "$RUNNER")" = 'EX_CANNOT_RUN=78' ] \
    && [ "$(sed -n '83p' "$RUNNER")" = 'for f in "$PROBE_DIR"/*.sh; do' ]
arm "the runner's three cited lines (:42 :44 :83) still say what is cited" $? \
    "42=[$(sed -n '42p' "$RUNNER")] 44=[$(sed -n '44p' "$RUNNER")] 83=[$(sed -n '83p' "$RUNNER")]"

# ---------------------------------------------------------------------------
printf -- '\n-- 2. both floor arms, on a staged tree that matches --\n'
# ---------------------------------------------------------------------------
BUNDLE="$WORK/bundle"; make_bundle "$BUNDLE"
OK_ROOT="$WORK/ok-root"; make_staged_tree "$OK_ROOT" "$BUNDLE"; make_stub_compiler "$OK_ROOT" 1 1
D0="$WORK/seed-ok"; make_seed_dir "$D0" 0
out="$(run_apply "$LIB" OSTLER_SEED_DIR="$D0" OSTLER_DIR="$OK_ROOT")"
grep -q 'RC=0' <<< "$out" && grep -q 'STATE=seeded' <<< "$out"
arm "one interest cleared and one row screened is a pass" $? "$out"

[ -f "$D0/RAN" ]
arm "the loader actually ran" $? "no RAN sentinel in $D0"

grep -q 'DOES NOT CLEAR #1872' <<< "$out"
arm "and a pass says in words that it does not clear #1872" $? "$out"

# ---------------------------------------------------------------------------
printf -- '\n-- 3. each floor arm is load-bearing on its own --\n'
# ---------------------------------------------------------------------------
NO_INT="$WORK/no-int"; make_staged_tree "$NO_INT" "$BUNDLE"; make_stub_compiler "$NO_INT" 0 1
D1="$WORK/seed-noint"; make_seed_dir "$D1" 0
out1="$(run_apply "$LIB" OSTLER_SEED_DIR="$D1" OSTLER_DIR="$NO_INT")"
grep -q 'STATE=screen-moved' <<< "$out1" && grep -q 'FINDING: interests=0' <<< "$out1"
arm "interests=0 is a named FINDING, not a pass" $? "$out1"

NO_SUP="$WORK/no-sup"; make_staged_tree "$NO_SUP" "$BUNDLE"; make_stub_compiler "$NO_SUP" 1 0
D2="$WORK/seed-nosup"; make_seed_dir "$D2" 0
out2="$(run_apply "$LIB" OSTLER_SEED_DIR="$D2" OSTLER_DIR="$NO_SUP")"
grep -q 'STATE=screen-moved' <<< "$out2" && grep -q 'FINDING: suppressed=0' <<< "$out2"
arm "suppressed=0 is a named FINDING: a screen that never screens is not a screen" $? "$out2"

# ---------------------------------------------------------------------------
mkdir -p "$WORK/empty-volumes"
R5x="$WORK/r5x"; make_staged_tree "$R5x" "$BUNDLE"; make_stub_compiler "$R5x" 1 1
printf -- '\n-- 4. the staged tree is checked BY CONTENT, against the ARTEFACT --\n'
# ---------------------------------------------------------------------------
STALE="$WORK/stale-root"; make_staged_tree "$STALE" "$BUNDLE"; make_stub_compiler "$STALE" 1 1
# One byte, in one of the four measured files. An mtime check would not see it
# at all; that is the #1874 shape this arm exists for.
printf '\n# drifted\n' >> "$STALE/services/cm019/services/ingest/src/filters.py"
# ...and make the venv look FRESH, so a mtime-based check would call it current.
mkdir -p "$STALE/services/cm019/.venv/bin"; : > "$STALE/services/cm019/.venv/bin/python"
D3="$WORK/seed-stale"; make_seed_dir "$D3" 0
out3="$(run_apply "$LIB" OSTLER_SEED_DIR="$D3" OSTLER_DIR="$STALE")"
grep -q 'STATE=stale' <<< "$out3" && grep -q 'CANNOT-RUN' <<< "$out3"
arm "a drifted staged file is CANNOT-RUN, not a product FAIL" $? "$out3"
grep -q 'filters.py' <<< "$out3"
arm "and the report NAMES the file that drifted" $? "$out3"
[ ! -f "$D3/RAN" ]
arm "nothing is seeded onto a box running different code" $? "the loader ran anyway"

MISS="$WORK/missing-root"; make_staged_tree "$MISS" "$BUNDLE"; make_stub_compiler "$MISS" 1 1
rm -f "$MISS/services/cm019/services/ingest/src/parsers/twitter.py"
D4="$WORK/seed-missing"; make_seed_dir "$D4" 0
out4="$(run_apply "$LIB" OSTLER_SEED_DIR="$D4" OSTLER_DIR="$MISS")"
grep -q 'STATE=stale' <<< "$out4" && grep -q 'twitter.py' <<< "$out4"
arm "a staged file that is absent is caught too, and named" $? "$out4"

# THE SHARP ONE. The comparison must be BUNDLE vs BOX, never CHECKOUT vs BOX.
# Here the bundle and the staged tree agree with each other and BOTH differ
# from vendor/. A lib that reads the checkout goes red; the right one passes.
OTHER="$WORK/other-bundle"; make_bundle "$OTHER"
printf '\n# this artefact is not this checkout\n' >> "$OTHER/services/ingest/src/filters.py"
OTHER_ROOT="$WORK/other-root"; make_staged_tree "$OTHER_ROOT" "$OTHER"; make_stub_compiler "$OTHER_ROOT" 1 1
D4b="$WORK/seed-other"; make_seed_dir "$D4b" 0
out4b="$(run_apply "$LIB" OSTLER_SEED_DIR="$D4b" OSTLER_DIR="$OTHER_ROOT" OSTLER_CM019_BUNDLE="$OTHER")"
grep -q 'STATE=seeded' <<< "$out4b"
arm "a bundle that differs from vendor/ but matches the box PASSES (no checkout is read)" $? "$out4b"

# ...and the digest that reached the loader is the BUNDLE's, computed by the
# loader's own --digest, not invented here.
grep -q "^DIGEST stubdigest-$(basename "$OTHER")\$" "$D4b/RAN"
arm "the loader was handed the digest of THAT bundle, and its source" $? \
    "RAN says: $(cat "$D4b/RAN" 2>/dev/null)"
grep -q '^SOURCE OSTLER_CM019_BUNDLE$' "$D4b/RAN"
arm "and the source string travels with it, so a mismatch can say which side" $? \
    "RAN says: $(cat "$D4b/RAN" 2>/dev/null)"

# No bundle anywhere: refuse, and name the variable. EMPTY_VOLUMES points the
# mount scan at a directory with nothing in it, so this arm cannot depend on
# whether the machine running the test happens to have a DMG mounted.
D4c="$WORK/seed-nobundle"; make_seed_dir "$D4c" 0
out4c="$(env -u OSTLER_CM019_BUNDLE -u OSTLER_ALLOW_INSTALLED_APP_BUNDLE \
    OSTLER_BOX_HOST= OSTLER_SEED_DIR="$D4c" OSTLER_DIR="$R5x" \
    OSTLER_PREF_SEED_VOLUMES_DIR="$WORK/empty-volumes" \
    bash -c '. "$1"; preference_seed_apply; printf "RC=%s\n" "$?"; printf "STATE=%s\n" "${PREFERENCE_SEED_STATE}"' _ "$LIB" 2>&1)"
grep -q 'STATE=absent' <<< "$out4c" && grep -q 'OSTLER_CM019_BUNDLE' <<< "$out4c"
arm "no artefact bundle is CANNOT-RUN and names the variable that fixes it" $? "$out4c"
grep -q 'OSTLER_ALLOW_INSTALLED_APP_BUNDLE' <<< "$out4c"
arm "and it says /Applications is not used unless asked for by name" $? "$out4c"
[ ! -f "$D4c/RAN" ]
arm "nothing is seeded when there is no artefact to compare against" $? "the loader ran anyway"

# ---------------------------------------------------------------------------
printf -- '\n-- 5. a seed that did not work asserts NOTHING --\n'
# ---------------------------------------------------------------------------
R5="$WORK/r5"; make_staged_tree "$R5" "$BUNDLE"; make_stub_compiler "$R5" 1 1
D5="$WORK/seed-rc1"; make_seed_dir "$D5" 1
out5="$(run_apply "$LIB" OSTLER_SEED_DIR="$D5" OSTLER_DIR="$R5")"
grep -q 'STATE=failed' <<< "$out5" && grep -q 'FINDING (loader exit 1)' <<< "$out5"
arm "loader exit 1 is a FINDING about the write route" $? "$out5"

D6="$WORK/seed-rc2"; make_seed_dir "$D6" 2
out6="$(run_apply "$LIB" OSTLER_SEED_DIR="$D6" OSTLER_DIR="$R5")"
grep -q 'STATE=failed' <<< "$out6" && grep -q 'CANNOT-RUN (loader exit 2)' <<< "$out6"
arm "loader exit 2 is a named CANNOT-RUN, never a FAIL" $? "$out6"

# ---------------------------------------------------------------------------
printf -- '\n-- 6. the oracle is missing, pre-read-back, or waived --\n'
# ---------------------------------------------------------------------------
out7="$(run_apply "$LIB" OSTLER_SEED_DIR="$WORK/nothing-here" OSTLER_DIR="$R5")"
grep -q 'STATE=absent' <<< "$out7" && grep -q 'OSTLER_SEED_DIR' <<< "$out7"
arm "a missing oracle names the variable that fixes it" $? "$out7"

D8="$WORK/seed-preread"; make_seed_dir "$D8" 0 --stale
out8="$(run_apply "$LIB" OSTLER_SEED_DIR="$D8" OSTLER_DIR="$R5")"
grep -q 'STATE=absent' <<< "$out8" && grep -q 'PRE-READ-BACK' <<< "$out8"
arm "a loader with no graph read-back is refused, not run" $? "$out8"

out9="$(run_apply "$LIB" OSTLER_SEED_DIR="$D0" OSTLER_DIR="$R5" OSTLER_PREF_SEED_SKIP=1)"
grep -q 'STATE=skipped' <<< "$out9" && grep -q 'not a pass' <<< "$out9"
arm "OSTLER_PREF_SEED_SKIP=1 seeds nothing and says it is not a pass" $? "$out9"

# ---------------------------------------------------------------------------
printf -- '\n-- 7. the compiler itself cannot be reached --\n'
# ---------------------------------------------------------------------------
NOCOMP="$WORK/nocomp"; make_staged_tree "$NOCOMP" "$BUNDLE"; make_stub_compiler "$NOCOMP" 1 1
rm -rf "$NOCOMP/services/cm059-editor/compiler"
D10="$WORK/seed-nocomp"; make_seed_dir "$D10" 0
out10="$(run_apply "$LIB" OSTLER_SEED_DIR="$D10" OSTLER_DIR="$NOCOMP")"
grep -q 'STATE=failed' <<< "$out10" && grep -q 'CANNOT-RUN' <<< "$out10" \
    && grep -q 'NO-COMPILER' <<< "$out10"
arm "no staged compiler is CANNOT-RUN, and the rows are still reported written" $? "$out10"

NOTICK="$WORK/notick"; make_staged_tree "$NOTICK" "$BUNDLE"; make_stub_compiler "$NOTICK" 1 1
rm -f "$NOTICK/bin/editor-frontpage-tick.sh"
D11="$WORK/seed-notick"; make_seed_dir "$D11" 0
out11="$(run_apply "$LIB" OSTLER_SEED_DIR="$D11" OSTLER_DIR="$NOTICK")"
grep -q 'STATE=failed' <<< "$out11" && grep -q 'NO-TICK' <<< "$out11"
arm "no rendered tick means no interpreter, and that is CANNOT-RUN" $? "$out11"

# ---------------------------------------------------------------------------
printf -- '\n-- 8. MUTATION: with the suppressed arm removed, arm 3 must fail --\n'
# ---------------------------------------------------------------------------
# The suppressed arm is the one a future edit is most likely to drop, because
# it is the counter-intuitive half: it asserts that something was THROWN AWAY.
MUT="$WORK/mutant.sh"
sed 's/^    if \[ "${_ps_suppressed}" -lt 1 \]; then$/    if false; then/' "$LIB" > "$MUT"
mut_left="$(grep -c '_ps_suppressed}" -lt 1' "$MUT" || true)"
[ "$mut_left" = "0" ]
arm "the mutant really has the suppressed arm disabled (the injection landed)" $? \
    "still present: $mut_left line(s)"

MR="$WORK/mutroot"; make_staged_tree "$MR" "$BUNDLE"; make_stub_compiler "$MR" 1 0
D12="$WORK/seed-mut"; make_seed_dir "$D12" 0
outm="$(run_apply "$MUT" OSTLER_SEED_DIR="$D12" OSTLER_DIR="$MR")"
grep -q 'STATE=seeded' <<< "$outm"
if [ $? -eq 0 ]; then mut_rc=0; else mut_rc=1; fi
arm "MUST-FAIL: the mutant passes suppressed=0, so arm 3 is a real assertion" "$mut_rc" \
    "the mutant did not pass suppressed=0: $outm"

# ---------------------------------------------------------------------------
printf -- '\n-- 9. the compile is TRIGGERED, and generated_at must ADVANCE --\n'
# ---------------------------------------------------------------------------
# The pass in arm 2 went through the whole route. Read its evidence: the
# kickstart text, the poll that saw the OLD value before the new one, and
# which trigger the report says it used.
grep -q "^print gui/$UID_NOW/$LABEL\$" "$OK_ROOT/launchctl.log" \
    && grep -q "^kickstart -k gui/$UID_NOW/$LABEL\$" "$OK_ROOT/launchctl.log"
arm "the trigger is launchctl kickstart -k gui/<uid>/$LABEL, after a print" $? \
    "launchctl.log: $(cat "$OK_ROOT/launchctl.log" 2>/dev/null)"

grep -q 'trigger     : launchctl kickstart -k' <<< "$out"
arm "and the report says kickstart was the trigger used" $? "$out"

grep -q 'before      : generated_at 2026-09-09T18:17:09Z' <<< "$out" \
    && grep -q 'POLL generated_at=2026-09-09T18:17:09Z' <<< "$out" \
    && grep -q 'ADVANCED before=2026-09-09T18:17:09Z now=20' <<< "$out"
arm "the poll read the OLD generated_at first, then saw it ADVANCE (it polled, it did not assume)" $? "$out"

# Kickstart REFUSED: the agent is not loaded (no GUI domain over ssh, or never
# bootstrapped). The rendered tick is run directly, and the report says so.
REF="$WORK/refused"; make_staged_tree "$REF" "$BUNDLE"; make_stub_compiler "$REF" 1 1
rm -f "$REF/agent-loaded"
D13="$WORK/seed-refused"; make_seed_dir "$D13" 0
out13="$(run_apply "$LIB" OSTLER_SEED_DIR="$D13" OSTLER_DIR="$REF")"
grep -q 'STATE=seeded' <<< "$out13" && grep -q 'LABEL not-loaded' <<< "$out13" \
    && grep -q 'TRIGGER tick' <<< "$out13" \
    && grep -q 'kickstart was refused, so the installed tick was run directly' <<< "$out13"
arm "kickstart refused falls back to the installed tick, and the report says which was used" $? "$out13"

# The plist is ABSENT: the installer never left an agent, so there is nothing
# to trigger and no hourly compile to stand in for. CANNOT-RUN, named.
NOPL="$WORK/noplist"; make_staged_tree "$NOPL" "$BUNDLE"; make_stub_compiler "$NOPL" 1 1
rm -f "$NOPL/boxhome/Library/LaunchAgents/$LABEL.plist"
D14="$WORK/seed-noplist"; make_seed_dir "$D14" 0
out14="$(run_apply "$LIB" OSTLER_SEED_DIR="$D14" OSTLER_DIR="$NOPL")"
grep -q 'STATE=uncompiled' <<< "$out14" && grep -q 'CANNOT-RUN: label absent' <<< "$out14" \
    && grep -q 'RC=1' <<< "$out14"
arm "no LaunchAgent plist is CANNOT-RUN: label absent, and not a pass" $? "$out14"
[ ! -f "$NOPL/launchctl.log" ]
arm "and nothing was kickstarted or run for it" $? "launchctl.log exists: $(cat "$NOPL/launchctl.log" 2>/dev/null)"

# FROZEN: the tick runs and REWRITES the file (mtime moves) with the SAME
# generated_at. That is not an advance and must not be read as one.
FRZ="$WORK/frozen"; make_staged_tree "$FRZ" "$BUNDLE"; make_stub_compiler "$FRZ" 1 1 frozen
D15="$WORK/seed-frozen"; make_seed_dir "$D15" 0
out15="$(BUDGET=3 run_apply "$LIB" OSTLER_SEED_DIR="$D15" OSTLER_DIR="$FRZ")"
grep -q 'STATE=uncompiled' <<< "$out15" \
    && grep -q 'NOT-ADVANCED before=2026-09-09T18:17:09Z now=2026-09-09T18:17:09Z' <<< "$out15" \
    && grep -q 'CANNOT-RUN: budget of 3s exhausted and generated_at did not ADVANCE' <<< "$out15" \
    && grep -q 'RC=1' <<< "$out15"
arm "an old generated_at EQUAL to the new one is CANNOT-RUN, not an advance" $? "$out15"
: > "$API_REQLOG"
grep -q 'URL1 ' <<< "$out15"
if [ $? -eq 0 ]; then frz_api=1; else frz_api=0; fi
arm "and the API is never asked about an artefact that did not advance" "$frz_api" "$out15"

# ---------------------------------------------------------------------------
printf -- '\n-- 10. the read-back goes through the API the tool reads --\n'
# ---------------------------------------------------------------------------
# PASS (arm 2 again): the two GETs the tool's route needs, with the subject
# found at or above the floor and the domain read off the compiled row.
grep -q 'URL1 .*/api/v1/preferences?limit=200$' <<< "$out" \
    && grep -q 'HTTP1 200' <<< "$out" \
    && grep -q "MATCH1 yes subject=$STUB_SUBJECT confidence=0.2991 .*domain=Music" <<< "$out"
arm "GET ?limit=200 with the token finds the fixture subject at 0.2991 in domain Music" $? "$out"
grep -q 'URL2 .*/api/v1/preferences?domain=Music&min_confidence=0.28&limit=200$' <<< "$out" \
    && grep -q 'HTTP2 200' <<< "$out" && grep -q 'MATCH2 yes' <<< "$out"
arm "GET ?domain=Music&min_confidence=0.28 (the compiled row's domain, the fixture's floor) finds it too" $? "$out"
grep -q 'served      : 1 interest(s) unfiltered, 1 with domain and floor applied' <<< "$out" \
    && grep -q 'SEEDED, COMPILED AND SERVED' <<< "$out"
arm "the report prints both counts and the matched subject" $? "$out"
grep -q "$STUB_TOKEN" <<< "$out"
if [ $? -eq 0 ]; then tok_leak=1; else tok_leak=0; fi
arm "and the token appears NOWHERE in the output" "$tok_leak" "the token was printed"

# FINDING: the compile ran (generated_at advanced) and the API serves an
# artefact WITHOUT the subject. That names the compiler, and prints the count.
EMP="$WORK/empty-profile"; make_staged_tree "$EMP" "$BUNDLE"; make_stub_compiler "$EMP" 1 1 empty
D16="$WORK/seed-empty"; make_seed_dir "$D16" 0
out16="$(run_apply "$LIB" OSTLER_SEED_DIR="$D16" OSTLER_DIR="$EMP")"
grep -q 'STATE=unserved' <<< "$out16" && grep -q 'ADVANCED' <<< "$out16" \
    && grep -q 'FINDING: THE COMPILE RAN AND THE API DOES NOT SERVE THE SEED SUBJECT' <<< "$out16" \
    && grep -q 'returned 0 interest(s) unfiltered' <<< "$out16" \
    && grep -q 'emit_artefact.py' <<< "$out16" && grep -q 'RC=1' <<< "$out16"
arm "compile ran and the API lacks the subject is a FINDING that names the compiler and prints the count" $? "$out16"

# TOKEN ABSENT: the artefact was recompiled, and what it serves cannot be
# examined because the API fails closed. CANNOT-RUN, and the recompile is
# still reported so the reader knows the walk box was left in the better state.
NOTOK="$WORK/notoken"; make_staged_tree "$NOTOK" "$BUNDLE"; make_stub_compiler "$NOTOK" 1 1
rm -f "$NOTOK/secrets/service_token"
D17="$WORK/seed-notoken"; make_seed_dir "$D17" 0
out17="$(run_apply "$LIB" OSTLER_SEED_DIR="$D17" OSTLER_DIR="$NOTOK")"
grep -q 'STATE=uncompiled' <<< "$out17" && grep -q 'NO-TOKEN' <<< "$out17" \
    && grep -q 'CANNOT-RUN: token absent' <<< "$out17" && grep -q 'RC=1' <<< "$out17"
arm "no service token on the box is CANNOT-RUN: token absent" $? "$out17"

# WRONG TOKEN: the API answers 401. That is an auth fault, not a compiler
# fault, and it must not be reported as the compiler's FINDING.
BADTOK="$WORK/badtoken"; make_staged_tree "$BADTOK" "$BUNDLE"; make_stub_compiler "$BADTOK" 1 1
printf 'not-the-token\n' > "$BADTOK/secrets/service_token"
D18="$WORK/seed-badtoken"; make_seed_dir "$D18" 0
out18="$(run_apply "$LIB" OSTLER_SEED_DIR="$D18" OSTLER_DIR="$BADTOK")"
grep -q 'STATE=uncompiled' <<< "$out18" && grep -q 'HTTP1 401' <<< "$out18" \
    && grep -q 'CANNOT-RUN: the API could not be read (exit 2)' <<< "$out18"
arm "a 401 with the box's own token is CANNOT-RUN, never the compiler's FINDING" $? "$out18"

# ---------------------------------------------------------------------------
printf -- '\n-- 11. OSTLER_PREF_COMPILE_SKIP=1 is a named CANNOT-RUN, and forget recompiles --\n'
# ---------------------------------------------------------------------------
SK="$WORK/skip"; make_staged_tree "$SK" "$BUNDLE"; make_stub_compiler "$SK" 1 1
D19="$WORK/seed-skip"; make_seed_dir "$D19" 0
out19="$(run_apply "$LIB" OSTLER_SEED_DIR="$D19" OSTLER_DIR="$SK" OSTLER_PREF_COMPILE_SKIP=1)"
grep -q 'STATE=uncompiled' <<< "$out19" && grep -q 'CANNOT-RUN: OSTLER_PREF_COMPILE_SKIP=1' <<< "$out19" \
    && grep -q 'not a pass' <<< "$out19" && grep -q 'RC=1' <<< "$out19"
arm "OSTLER_PREF_COMPILE_SKIP=1 seeds and screens, then names itself as CANNOT-RUN" $? "$out19"
[ ! -f "$SK/launchctl.log" ]
arm "and triggers nothing" $? "launchctl.log: $(cat "$SK/launchctl.log" 2>/dev/null)"

# The forget path: the rows go, and the artefact is recompiled the same way
# and MEASURED (generated_at advances again), so it stops carrying the seed.
FG="$WORK/forget"; make_staged_tree "$FG" "$BUNDLE"; make_stub_compiler "$FG" 1 1
D20="$WORK/seed-forget"; make_seed_dir "$D20" 0
out20="$(PS_FORGET=1 run_apply "$LIB" OSTLER_SEED_DIR="$D20" OSTLER_DIR="$FG")"
grep -q 'STATE=seeded' <<< "$out20" && grep -q 'ARGS --forget' "$D20/RAN" \
    && grep -q 'recompiling the artefact so it stops carrying the seed subject' <<< "$out20" \
    && grep -q 'recompiled: generated_at advanced past 20' <<< "$out20" && grep -q 'FRC=0' <<< "$out20"
arm "forget removes the rows, re-triggers the compile and measures a second advance" $? "$out20"
[ "$(grep -c '^kickstart -k ' "$FG/launchctl.log")" = "2" ]
arm "two kickstarts in that run: one to serve the seed, one to stop serving it" $? \
    "launchctl.log: $(cat "$FG/launchctl.log" 2>/dev/null)"

# ---------------------------------------------------------------------------
printf -- '\n-- 12. every remote path expands $HOME ON THE BOX --\n'
# ---------------------------------------------------------------------------
# The generated remote text is captured as the box would receive it. $HOME
# must appear (the shape is examined, not assumed) and never inside single
# quotes, which is the v1.0.51 trap: a literal the box shell cannot expand.
CAP="$WORK/remote-text.captured"
HX="$WORK/homex"; make_staged_tree "$HX" "$BUNDLE"; make_stub_compiler "$HX" 1 1
D21="$WORK/seed-homex"; make_seed_dir "$D21" 0
out21="$(PS_CAPTURE="$CAP" run_apply "$LIB" OSTLER_SEED_DIR="$D21" OSTLER_DIR="$HX")"
grep -q 'STATE=seeded' <<< "$out21"
arm "the captured run still passes (the capture wrapper changed nothing)" $? "$out21"
home_refs="$(grep -c '\$HOME' "$CAP" 2>/dev/null || true)"
[ -s "$CAP" ] && [ "${home_refs:-0}" -ge 4 ]
arm "the remote text was captured and carries \$HOME (positive control: $home_refs reference(s))" $? \
    "captured $(wc -c < "$CAP" 2>/dev/null) bytes, $home_refs \$HOME reference(s)"
grep -q "'\\\$HOME" "$CAP"
if [ $? -eq 0 ]; then sq1=1; else sq1=0; fi
grep -q "\\\$HOME'" "$CAP"
if [ $? -eq 0 ]; then sq2=1; else sq2=0; fi
[ "$sq1" -eq 0 ] && [ "$sq2" -eq 0 ]
arm "no single-quoted literal \$HOME reaches the remote text" $? \
    "$(grep -n "'\\\$HOME\|\\\$HOME'" "$CAP")"

# And functionally: a box whose only root is $HOME/.ostler, with no
# OSTLER_DIR at all, is found through $HOME as the box's own shell expands it.
HB="$WORK/homebox"; mkdir -p "$HB"
make_staged_tree "$HB/.ostler" "$BUNDLE"; make_stub_compiler "$HB/.ostler" 1 1
mkdir -p "$HB/Library/LaunchAgents"; : > "$HB/Library/LaunchAgents/$LABEL.plist"
printf '%s/.ostler/preferences/interest_profile.json\n' "$HB" > "$API_POINTER"
D22="$WORK/seed-homebox"; make_seed_dir "$D22" 0
out22="$(env -u OSTLER_DIR -u OSTLER_PREF_SEED_SKIP -u OSTLER_PREF_COMPILE_SKIP -u OSTLER_ALLOW_INSTALLED_APP_BUNDLE \
    HOME="$HB" OSTLER_BOX_HOST= OSTLER_SEED_DIR="$D22" OSTLER_CM019_BUNDLE="$BUNDLE" \
    OSTLER_PREF_SEED_VOLUMES_DIR="$WORK/empty-volumes" \
    OSTLER_PREF_LAUNCHCTL="$WORK/bin/launchctl" OSTLER_PREF_API_BASE="$API_BASE" \
    OSTLER_PREF_COMPILE_BUDGET_S=10 OSTLER_PREF_COMPILE_POLL_S=1 \
    bash -c '. "$1"; preference_seed_apply; printf "RC=%s\n" "$?"; printf "STATE=%s\n" "${PREFERENCE_SEED_STATE}"' _ "$LIB" 2>&1)"
grep -q 'STATE=seeded' <<< "$out22" && grep -q "artefact    : $HB/.ostler/preferences/interest_profile.json" <<< "$out22" \
    && grep -q "^kickstart -k gui/$UID_NOW/$LABEL\$" "$HB/.ostler/launchctl.log"
arm "with OSTLER_DIR unset, the tick, the artefact, the token and the plist are all found under \$HOME" $? "$out22"

# ---------------------------------------------------------------------------
printf -- '\n-- 13. MUST-FAIL: the pre-change seed never queried the API --\n'
# ---------------------------------------------------------------------------
# The same stub box, the same pass conditions, the lib as it was before this
# step existed. It must report seeded with the request log EMPTY: that is the
# v1.0.82 shape (seed green, tool empty), and it is what the read-back arm
# exists to make impossible. The pre-change blob is used when this checkout
# can reach it; a shallow CI checkout cannot, so the fallback is a mutant with
# the compile-and-serve call removed, and the report says which was used.
OLD="$WORK/old-form.sh"
if git -C "$REPO" cat-file -e "$PRE_CHANGE_SHA:scripts/box_walk_probes/lib/preference_seed.sh" 2>/dev/null; then
    git -C "$REPO" show "$PRE_CHANGE_SHA:scripts/box_walk_probes/lib/preference_seed.sh" > "$OLD"
    OLD_SRC="the pre-change lib at $PRE_CHANGE_SHA"
else
    sed 's/^    if ! _ps_compile_and_serve; then$/    if false; then/' "$LIB" > "$OLD"
    OLD_SRC="a mutant with the compile-and-serve call removed ($PRE_CHANGE_SHA is not reachable here)"
fi
printf '  old form: %s\n' "$OLD_SRC"
old_calls="$(grep -c '_ps_compile_and_serve' "$OLD" || true)"
old_calls_live="$(grep -c '^    if ! _ps_compile_and_serve; then$' "$OLD" || true)"
[ "${old_calls_live:-0}" = "0" ]
arm "the old form has no live compile-and-serve call ($old_calls mention(s), 0 live)" $? \
    "live calls: $old_calls_live"

OLDR="$WORK/oldroot"; make_staged_tree "$OLDR" "$BUNDLE"; make_stub_compiler "$OLDR" 1 1
D23="$WORK/seed-old"; make_seed_dir "$D23" 0
: > "$API_REQLOG"
outo="$(run_apply "$OLD" OSTLER_SEED_DIR="$D23" OSTLER_DIR="$OLDR")"
grep -q 'STATE=seeded' <<< "$outo" && [ ! -s "$API_REQLOG" ]
if [ $? -eq 0 ]; then old_rc=0; else old_rc=1; fi
arm "MUST-FAIL: the old form reports seeded with ZERO API requests, so the read-back arm is a real assertion" "$old_rc" \
    "requests: [$(cat "$API_REQLOG")] output: $outo"

# ...and the new one, on the identical box, made exactly the two requests.
: > "$API_REQLOG"
outn="$(run_apply "$LIB" OSTLER_SEED_DIR="$D23" OSTLER_DIR="$OLDR")"
grep -q 'STATE=seeded' <<< "$outn" && [ "$(grep -c '^/api/v1/preferences?' "$API_REQLOG")" = "2" ] \
    && grep -q '^/api/v1/preferences?limit=200$' "$API_REQLOG" \
    && grep -q '^/api/v1/preferences?domain=Music&min_confidence=0.28&limit=200$' "$API_REQLOG"
arm "the new form, same box, makes exactly the two GETs the tool's route needs" $? \
    "requests: [$(cat "$API_REQLOG")] output: $outn"

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
