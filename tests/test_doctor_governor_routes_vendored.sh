#!/usr/bin/env bash
#
# test_doctor_governor_routes_vendored.sh
#
# v1018-D024, customer-visible half: "Governor -> Pause" in the Ostler
# sidebar surfaced `API 404` as "Could not pause".
#
# MECHANISM. The Hub frontend (web/src/lib/api.ts) calls three Doctor
# endpoints on the :8089 origin -- GET /api/v1/governor-status,
# GET+POST /api/v1/pause and POST /api/v1/resume. HR015 added all three
# upstream (#282, commit 6639c79) plus their backend module
# `pause_control.py`. The CM051 Doctor vendor pin is HELD at b0b3831,
# which predates #282, so the shipped payload registered NONE of them and
# every call 404'd. `box_status._pause()` imported the same missing module
# behind a bare `except`, so the header chip reported `paused: false`
# forever instead of saying it could not tell.
#
# WHY THIS GATE ASSERTS AGAINST vendor/ AND NOT AGAINST HR015. vendor/doctor/agent
# is the copy that SHIPS: gui/project.yml's postBuildScript copies it into
# Ostler.app's Contents/Resources/doctor/agent/, and install.sh:12097 copies
# that into ~/.ostler/doctor. A green upstream proves nothing about the
# artefact on the customer's Mac -- that gap IS v1018-D024.
#
# Six limbs, each with its own demonstrable RED:
#
#   A  Route table. The vendored web_ui.py registers the four handlers, and
#      registers them BEFORE register_proxy_routes(app) (Starlette matches in
#      registration order, so a later proxy entry for the same path would
#      shadow the native handler). Parsed with `ast`, not grep, so a path
#      inside a comment or a docstring cannot satisfy it.
#   B  Backend behaviour. The VENDORED pause_control.py is imported and a
#      pause is round-tripped through a temporary governor.env. Presence is
#      not behaviour.
#   C  Cross-component contract. The shell reader that every background tick
#      actually calls (lib/ostler-resource-tier.sh :: ostler_resource_tier_is_paused)
#      is sourced against the file the Python writer just wrote, and must agree
#      in both directions. A writer/reader pair that is only ever tested on one
#      side silent-fails.
#   D  Durability. sync_vendor.sh replaces the vendored tree wholesale, so a
#      file absent from source@pinned_sha survives only if doctor.patch creates
#      it. Without the new-file hunk the next re-vendor deletes pause_control.py
#      and this defect returns behind a clean-looking commit.
#   E  Loudness. The pause guard in box_status.py must not swallow a missing
#      backend into a permanent, indistinguishable `paused: false`.
#   F  Routing posture. The three paths must NOT appear in install.sh's
#      DOCTOR_PROXY_PATHS. That list is what the Doctor FORWARDS to the
#      loopback assistant API on :8090, which implements none of them; adding
#      them there is the plausible-looking "fix" that would re-break this.
#
# British English throughout. Runs under bash 3.2 (macOS) and bash 5 (CI).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$REPO_ROOT/vendor/doctor/agent"
WEB_UI="$AGENT/web_ui.py"
BOX_STATUS="$AGENT/box_status.py"
PAUSE_CONTROL="$AGENT/pause_control.py"
LIB="$REPO_ROOT/lib/ostler-resource-tier.sh"
PATCH="$REPO_ROOT/vendor/divergences/doctor.patch"
INSTALL_SH="$REPO_ROOT/install.sh"

FAILED=0
failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== v1018-D024 governor control surface, asserted against the SHIPPED vendor payload =="
echo "   payload: $WEB_UI"
echo

for f in "$WEB_UI" "$BOX_STATUS" "$LIB" "$PATCH" "$INSTALL_SH"; do
    [ -f "$f" ] || { echo "FAIL: missing prerequisite $f" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Limb A -- route table, parsed not grepped
# ---------------------------------------------------------------------------
#
# The extractor prints one `METHOD<TAB>PATH<TAB>LINE` row per @app.<verb>("...")
# decorator on a module-level handler, plus a `__PROXY__` row for the
# register_proxy_routes(app) call site. It carries its own positive control:
# /api/v1/box-status is a route this file has registered since before the
# defect, so an empty or near-empty table means the PREDICATE broke, not that
# the routes are missing. A zero denominator must never read as a verdict.

cat > "$TMP/route_table.py" <<'PY'
"""Emit the module-level FastAPI route table of a Doctor web_ui.py."""
import ast
import sys

src_path = sys.argv[1]
with open(src_path, "r", encoding="utf-8") as fh:
    tree = ast.parse(fh.read(), filename=src_path)


def _literal(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    # Allow a module-level constant used as the path (e.g. _HYDRATION_STATUS_PATH).
    if isinstance(node, ast.Name):
        return "<name:%s>" % node.id
    return None


rows = []
for node in tree.body:
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        for dec in node.decorator_list:
            if not isinstance(dec, ast.Call):
                continue
            fn = dec.func
            if not isinstance(fn, ast.Attribute):
                continue
            obj = fn.value
            if not (isinstance(obj, ast.Name) and obj.id == "app"):
                continue
            method = fn.attr.upper()
            if method not in ("GET", "POST", "PUT", "DELETE", "PATCH"):
                continue
            if not dec.args:
                continue
            path = _literal(dec.args[0])
            if path is None:
                continue
            rows.append((method, path, dec.lineno))

# Where does the proxy catch-all get wired in? Anything registered after it
# can be shadowed by a DOCTOR_PROXY_PATHS entry for the same path.
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
            and node.func.id == "register_proxy_routes":
        rows.append(("__PROXY__", "register_proxy_routes", node.lineno))

for method, path, lineno in rows:
    print("%s\t%s\t%d" % (method, path, lineno))
PY

python3 "$TMP/route_table.py" "$WEB_UI" > "$TMP/routes.tsv" 2>"$TMP/routes.err" || {
    echo "FAIL: could not parse $WEB_UI" >&2
    cat "$TMP/routes.err" >&2
    exit 1
}

ROUTE_N="$(grep -cv '^__PROXY__' "$TMP/routes.tsv" || true)"
echo "-- limb A: examined $ROUTE_N module-level app routes in $(basename "$WEB_UI")"

# Positive control FIRST. If this fails the extractor is broken and every
# absence below is manufactured.
if grep -q "^GET	/api/v1/box-status	" "$TMP/routes.tsv"; then
    pass "control: the extractor sees the pre-existing GET /api/v1/box-status route"
else
    echo "FAIL: positive control missing -- the route extractor is broken, so no" >&2
    echo "      absence it reports can be believed. Examined $ROUTE_N routes." >&2
    exit 1
fi

PROXY_LINE="$(awk -F'\t' '$1 == "__PROXY__" { print $3; exit }' "$TMP/routes.tsv")"
if [ -n "${PROXY_LINE:-}" ]; then
    pass "control: register_proxy_routes(app) call found at line $PROXY_LINE"
else
    failure "register_proxy_routes(app) not found -- ordering cannot be checked"
fi

check_route() {   # $1 = method, $2 = path
    local method="$1" path="$2" line
    line="$(awk -F'\t' -v m="$method" -v p="$path" '$1 == m && $2 == p { print $3; exit }' "$TMP/routes.tsv")"
    if [ -z "${line:-}" ]; then
        failure "$method $path is NOT registered in the shipped Doctor payload (this is the 404 the customer sees)"
        return
    fi
    pass "$method $path registered (line $line)"
    if [ -n "${PROXY_LINE:-}" ] && [ "$line" -gt "$PROXY_LINE" ]; then
        failure "$method $path is registered AFTER register_proxy_routes (line $line > $PROXY_LINE); a DOCTOR_PROXY_PATHS entry would shadow it"
    fi
}

check_route GET  /api/v1/governor-status
check_route GET  /api/v1/pause
check_route POST /api/v1/pause
check_route POST /api/v1/resume

echo

# ---------------------------------------------------------------------------
# Limb B -- the backend module actually works, exercised where it ships
# ---------------------------------------------------------------------------

if [ -s "$PAUSE_CONTROL" ]; then
    pass "pause_control.py present in the shipped payload"

    cat > "$TMP/exercise_pause.py" <<'PY'
"""Round-trip a pause through the VENDORED pause_control against a temp file."""
import os
import sys

sys.path.insert(0, sys.argv[1])          # the vendored agent dir
os.environ["OSTLER_GOVERNOR_ENV_FILE"] = sys.argv[2]
# Do not mirror into config.yaml or shell out to launchctl from a unit test.
os.environ["OSTLER_PAUSE_SKIP_MIRROR"] = "1"

import pause_control  # noqa: E402

state = pause_control.read_state()
assert state["paused"] is False, "a fresh box must not read as paused: %r" % state

state = pause_control.set_pause("hour")
assert state["paused"] is True, "set_pause('hour') did not take: %r" % state
assert isinstance(state["expiry"], int), "an hour pause must carry an expiry: %r" % state

state = pause_control.resume()
assert state["paused"] is False, "resume() did not clear the pause: %r" % state

# An unknown scope must be a 400, not a silent indefinite pause.
try:
    pause_control.set_pause("next tuesday")
except pause_control.PauseError as exc:
    assert exc.status == 400, "unknown scope mapped to %s, expected 400" % exc.status
else:
    raise AssertionError("an unknown pause scope was accepted silently")

print("OK")
PY

    if python3 "$TMP/exercise_pause.py" "$AGENT" "$TMP/governor.env" >"$TMP/pause.out" 2>&1; then
        pass "pause_control round-trip: read -> pause(hour) -> resume -> reject bad scope"
    else
        failure "pause_control round-trip failed against the vendored module"
        sed 's/^/      /' "$TMP/pause.out" >&2
    fi
else
    failure "pause_control.py MISSING from $AGENT -- the three routes have no backend, and box_status._pause() reports paused:false forever"
fi

echo

# ---------------------------------------------------------------------------
# Limb C -- writer/reader contract across the Python/shell boundary
# ---------------------------------------------------------------------------
#
# pause_control writes governor.env; the *-bundle-tick.sh wrappers, the wiki
# recompile tick and the CM059 editor tick all read it through
# ostler_resource_tier_is_paused. If the two ever disagree the UI says paused
# and the box keeps working, or the reverse. Test both directions.
#
# The reader is called the way a real tick calls it -- source the lib, run
# ostler_resource_tier_detect (which is what loads governor.env into the
# environment), THEN ask. Calling ostler_resource_tier_is_paused straight after
# sourcing reads an unset OSTLER_PAUSED and answers "running" for every input,
# which is a harness that cannot fail.

shell_says_paused() {   # $1 = path to governor.env; echoes "paused" or "running"
    OSTLER_GOVERNOR_SETTINGS="$1" bash -c '
        . "'"$LIB"'"
        ostler_resource_tier_detect >/dev/null 2>&1
        if ostler_resource_tier_is_paused; then echo paused; else echo running; fi
    ' 2>/dev/null
}

# Validate the probe before believing any answer it gives. A hand-written
# paused file must read as paused and a hand-written running file must read as
# running; if either control is wrong, every verdict below is manufactured.
printf 'export OSTLER_PAUSED=1\nexport OSTLER_PAUSE_UNTIL=\n' > "$TMP/control-paused.env"
printf 'export OSTLER_PAUSED=0\nexport OSTLER_PAUSE_UNTIL=\n' > "$TMP/control-running.env"
CTRL_P="$(shell_says_paused "$TMP/control-paused.env")"
CTRL_R="$(shell_says_paused "$TMP/control-running.env")"
if [ "$CTRL_P" = "paused" ] && [ "$CTRL_R" = "running" ]; then
    pass "control: the shell reader discriminates (hand-written paused -> paused, running -> running)"
else
    echo "FAIL: the shell-reader harness does not discriminate (paused file -> '$CTRL_P', running file -> '$CTRL_R')." >&2
    echo "      No contract verdict below can be believed. Fix the harness first." >&2
    exit 1
fi

if [ -s "$PAUSE_CONTROL" ]; then
    cat > "$TMP/write_pause.py" <<'PY'
import os
import sys

sys.path.insert(0, sys.argv[1])
os.environ["OSTLER_GOVERNOR_ENV_FILE"] = sys.argv[2]
os.environ["OSTLER_PAUSE_SKIP_MIRROR"] = "1"

import pause_control  # noqa: E402

if sys.argv[3] == "pause":
    pause_control.set_pause("indefinite")
else:
    pause_control.resume()
PY

    CONTRACT_ENV="$TMP/contract-governor.env"
    printf 'export OSTLER_THROTTLE_LEVEL=gentle\n' > "$CONTRACT_ENV"

    if python3 "$TMP/write_pause.py" "$AGENT" "$CONTRACT_ENV" pause >/dev/null 2>&1; then
        verdict="$(shell_says_paused "$CONTRACT_ENV")"
        if [ "$verdict" = "paused" ]; then
            pass "contract: the shell tick reader honours a pause written by the Doctor"
        else
            failure "contract BROKEN: pause_control wrote a pause, the shell reader says '$verdict' (the UI would say paused while every tick kept running)"
        fi
        if grep -q 'OSTLER_THROTTLE_LEVEL=gentle' "$CONTRACT_ENV"; then
            pass "contract: pausing preserved the operator's throttle choice"
        else
            failure "contract: pausing clobbered OSTLER_THROTTLE_LEVEL in governor.env"
        fi
    else
        failure "contract: could not write a pause with the vendored pause_control"
    fi

    if python3 "$TMP/write_pause.py" "$AGENT" "$CONTRACT_ENV" resume >/dev/null 2>&1; then
        verdict="$(shell_says_paused "$CONTRACT_ENV")"
        if [ "$verdict" = "running" ]; then
            pass "contract: the shell tick reader honours a resume written by the Doctor"
        else
            failure "contract BROKEN: pause_control resumed, the shell reader still says '$verdict' (background work wedged off)"
        fi
    else
        failure "contract: could not write a resume with the vendored pause_control"
    fi
else
    failure "contract limb skipped: pause_control.py is absent (see limb B)"
fi

echo

# ---------------------------------------------------------------------------
# Limb D -- the graft has a durable home
# ---------------------------------------------------------------------------
#
# scripts/sync_vendor.sh does `rm -rf vendor/doctor` then untars source@pinned_sha
# then applies the divergence patch. pause_control.py does not exist at the held
# pin, so ONLY a /dev/null new-file hunk in doctor.patch survives a re-vendor.
# sync_vendor.sh reads exactly this (vlib_patch_new_files) to decide a file is
# carried rather than genuinely vendor-only.

if awk '/^\+\+\+ b\/agent\/pause_control\.py$/ { found = 1 } END { exit !found }' "$PATCH"; then
    pass "doctor.patch creates agent/pause_control.py, so a re-vendor restores it"
else
    failure "doctor.patch has NO new-file hunk for agent/pause_control.py -- the next sync_vendor.sh doctor deletes it and this defect returns"
fi

if grep -q '/api/v1/governor-status' "$PATCH"; then
    pass "doctor.patch carries the governor route graft for web_ui.py"
else
    failure "doctor.patch does not carry the governor routes -- the next re-vendor drops them from web_ui.py"
fi

echo

# ---------------------------------------------------------------------------
# Limb E -- the pause guard is loud about its own failure
# ---------------------------------------------------------------------------
#
# The original: `try: from pause_control import read_state / except: return
# {"paused": False, ...}`. A missing backend and a genuinely running box
# produced byte-identical output, so the defect was undetectable from the
# outside for as long as it shipped, and the header chip cheerfully said
# "not paused" for months.
#
# Asserted by BEHAVIOUR, not by reading the source: box_status.py is copied
# alone into a temp directory (so `pause_control` genuinely cannot be
# imported), _pause() is called, and the run must both log at ERROR and return
# a payload that is distinguishable from a real not-paused reading. The control
# runs the same code with the real payload directory on the path and requires
# the opposite, so a handler that always shouts cannot pass either.

cat > "$TMP/check_loud.py" <<'PY'
"""Behavioural: does box_status._pause() report a missing backend, or hide it?

argv[1] = directory to put FIRST on sys.path
argv[2] = "missing" (backend must be unimportable) or "present"
"""
import io
import logging
import sys

sys.path.insert(0, sys.argv[1])
mode = sys.argv[2]

try:
    import pause_control  # noqa: F401
    importable = True
except Exception:
    importable = False

if mode == "missing" and importable:
    print("HARNESS BROKEN: pause_control is importable in the missing-backend case")
    sys.exit(2)
if mode == "present" and not importable:
    print("HARNESS BROKEN: pause_control is not importable in the control case")
    sys.exit(2)

stream = io.StringIO()
handler = logging.StreamHandler(stream)
handler.setLevel(logging.DEBUG)
root = logging.getLogger()
root.setLevel(logging.DEBUG)
root.addHandler(handler)

import box_status  # noqa: E402

state = box_status._pause()
logged = stream.getvalue()
shouted = any(
    rec in logged.lower() for rec in ("pause_control", "unavailable")
)
admits = bool(state.get("pause_unavailable"))

if mode == "missing":
    if not shouted:
        print("SILENT: the backend was missing and nothing was logged")
        sys.exit(1)
    if not admits:
        print("SILENT: the payload %r is indistinguishable from a running box" % state)
        sys.exit(1)
    print("LOUD: logged the failure and returned pause_unavailable=True")
    sys.exit(0)

# control: a working backend must be quiet and must not claim unavailability
if shouted or admits:
    print("NOISY: a working backend produced a failure report (%r / %r)"
          % (logged.strip(), state))
    sys.exit(1)
print("QUIET: a working backend reports a real state and logs nothing")
sys.exit(0)
PY

mkdir -p "$TMP/lonely"
cp "$BOX_STATUS" "$TMP/lonely/box_status.py"

LOUD_OUT="$(cd "$TMP/lonely" && python3 "$TMP/check_loud.py" "$TMP/lonely" missing 2>&1)"
if [ $? -eq 0 ]; then
    pass "box_status._pause() with the backend absent: $LOUD_OUT"
else
    failure "box_status._pause() swallows its own failure: $LOUD_OUT"
fi

if [ -s "$PAUSE_CONTROL" ]; then
    CTRL_OUT="$(cd "$AGENT" && OSTLER_GOVERNOR_ENV_FILE="$TMP/loud-control.env" python3 "$TMP/check_loud.py" "$AGENT" present 2>&1)"
    if [ $? -eq 0 ]; then
        pass "control: $CTRL_OUT"
    else
        failure "control failed, so the loudness verdict above cannot be trusted: $CTRL_OUT"
    fi
fi

echo

# ---------------------------------------------------------------------------
# Limb F -- routing posture
# ---------------------------------------------------------------------------
#
# DOCTOR_PROXY_PATHS is the list the Doctor FORWARDS to DOCTOR_GATEWAY_URL
# (127.0.0.1:8090, the assistant API). These three are Doctor-native and the
# assistant API implements none of them, so an entry here would forward a
# working route into a 404. Named explicitly because "the Doctor 404s it, so
# add it to the proxy list" is the wrong repair that looks right.

PROXY_LIST="$(grep -A 2 '<key>DOCTOR_PROXY_PATHS</key>' "$INSTALL_SH" | grep '<string>' | head -1)"
if [ -z "$PROXY_LIST" ]; then
    failure "could not read DOCTOR_PROXY_PATHS out of install.sh"
else
    LISTED=0
    for p in /api/v1/governor-status /api/v1/pause /api/v1/resume; do
        case "$PROXY_LIST" in
            *"$p"*) failure "$p is listed in DOCTOR_PROXY_PATHS; the Doctor would forward it to the assistant API on :8090, which does not implement it"; LISTED=1 ;;
        esac
    done
    [ "$LISTED" -eq 0 ] && pass "DOCTOR_PROXY_PATHS correctly does not list the three Doctor-native governor paths"
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL -- the shipped Doctor payload cannot serve the Hub Governor page." >&2
    exit 1
fi
echo "RESULT: PASS"
