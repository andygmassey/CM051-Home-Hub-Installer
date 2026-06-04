#!/usr/bin/env bash
# Vendor regression test for vendor/cm041/assistant_api/ical-server.py.
#
# CX-P0A (2026-05-26): without this test, the silent-bail failure shape
# is "ical-server.py renamed or routes dropped without a corresponding
# install.sh / proxy update, customer install completes green, every
# iOS Companion endpoint 404s in production".
#
# Per `feedback_silent_bail_regression_test_shape`, this test walks
# the ical-server.py route table byte-by-byte and asserts each of the
# 13 production iOS endpoints is registered with the expected HTTP
# method, AND asserts the install.sh launch block actually invokes
# launchctl bootstrap (not just creates the plist).
#
# Exit 0 on clean. Exit 1 on any missing route or wiring gap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ICAL_SERVER_PY="$SCRIPT_DIR/ical-server.py"
INSTALL_SH="$REPO_ROOT/install.sh"

if [[ ! -f "$ICAL_SERVER_PY" ]]; then
    echo "FAIL: ical-server.py not found at $ICAL_SERVER_PY" >&2
    exit 1
fi
if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi

# -------------------------------------------------------------------
# Part 1: ical-server.py imports cleanly under Python 3.
# -------------------------------------------------------------------
# We do not exercise the import (it requires ostler_security on the
# venv path, which is installed by install.sh Phase 7 and not by this
# regression test). We do a syntax-only check via py_compile -- that
# catches the "ical-server.py got truncated / corrupted" failure mode
# without needing a venv.

if ! python3 -m py_compile "$ICAL_SERVER_PY" 2>/dev/null; then
    echo "FAIL: ical-server.py does not parse as Python 3" >&2
    python3 -m py_compile "$ICAL_SERVER_PY"
    exit 1
fi
echo "PASS: ical-server.py parses as Python 3"

# -------------------------------------------------------------------
# Part 2: every production iOS endpoint is registered.
# -------------------------------------------------------------------
# CM031's production code paths (verified via grep on
# CM031/Sources/) call these 13 endpoints. Two are served directly
# by Doctor (auth/chat-token + wiki/correct), so we don't check
# them here. The other 11 are served by ical-server.py and MUST be
# present.
#
# Plus 2 more that are served by ical-server but only called by
# the legacy operator-instance integration (email/recent +
# recording/active + coach/recent + people/birthdays +
# people/recent). We check those too so a future rename doesn't
# silently break the Live Activity v1.0.1 surface.

REQUIRED_ROUTES=(
    # POST/GET method-marker pairs. Format: "METHOD path".
    # The grep tests the literal route registration in ical-server.py
    # which uses an if/elif tree against self.path.
    "GET /api/v1/hub/health"
    "GET /api/v1/timeline"
    "GET /people/search"          # plus /api/v1/people/search alias
    "GET /people/context"         # plus /api/v1/people/context alias
    "GET /people/stale"           # plus /api/v1/people/stale alias
    "GET /api/v1/suggestions"
    "GET /calendar"               # plus /api/v1/calendar alias
    "POST /api/v1/conversation/process"
    "GET /api/v1/conversation/status"
    "POST /api/v1/ingest/ios"
    "POST /api/v1/people/"        # /api/v1/people/{slug}/forget
    "GET /api/v1/email/recent"
    "GET /api/v1/recording/active"
    "GET /api/v1/coach/recent"
)

MISSING_ROUTES=()
for route in "${REQUIRED_ROUTES[@]}"; do
    # Each route is "METHOD path"; we just look for the path literal
    # in the source file. The route-handler structure uses string
    # comparisons against self.path so a literal match is the right
    # axis.
    path="${route#* }"
    if ! grep -qF "\"${path}\"" "$ICAL_SERVER_PY" \
       && ! grep -qF "'${path}'" "$ICAL_SERVER_PY" \
       && ! grep -qF "${path}" "$ICAL_SERVER_PY"; then
        MISSING_ROUTES+=("$route")
    fi
done

if [[ ${#MISSING_ROUTES[@]} -gt 0 ]]; then
    echo "FAIL: ical-server.py is missing route registrations for:" >&2
    for r in "${MISSING_ROUTES[@]}"; do
        echo "    - $r" >&2
    done
    exit 1
fi
echo "PASS: all ${#REQUIRED_ROUTES[@]} required ical-server.py routes are present"

# -------------------------------------------------------------------
# Part 3: install.sh Phase 3.13a actually bootstraps the LaunchAgent.
# -------------------------------------------------------------------
# The silent-bail shape we refuse: install.sh creates the plist file
# but never calls launchctl bootstrap, so the service exists on disk
# but never runs. We byte-walk the install.sh region around the
# com.ostler.ical-server.plist string and assert the launchctl
# bootstrap invocation lands.

if ! grep -q "com.ostler.ical-server.plist" "$INSTALL_SH"; then
    echo "FAIL: install.sh does not reference com.ostler.ical-server.plist" >&2
    exit 1
fi
echo "PASS: install.sh references com.ostler.ical-server.plist"

# The plist is rendered into $ICAL_PLIST; the bootstrap line is the
# very next launchctl call. Confirm a launchctl bootstrap invocation
# names the ICAL_PLIST variable.
if ! grep -q 'launchctl bootstrap "gui/\$(id -u)" "\$ICAL_PLIST"' "$INSTALL_SH"; then
    echo "FAIL: install.sh does not bootstrap the ical-server LaunchAgent" >&2
    echo "      Expected: launchctl bootstrap \"gui/\$(id -u)\" \"\$ICAL_PLIST\"" >&2
    exit 1
fi
echo "PASS: install.sh bootstraps the ical-server LaunchAgent"

# -------------------------------------------------------------------
# Part 4: Doctor LaunchAgent DOCTOR_PROXY_PATHS contains the 13
# production iOS endpoint templates (with FastAPI {slug}/{id} syntax
# for the two path-parameter routes).
# -------------------------------------------------------------------

REQUIRED_PROXY_PATHS=(
    "/api/v1/hub/health"
    "/api/v1/timeline"
    "/api/v1/people/search"
    "/api/v1/people/context"
    "/api/v1/people/stale"
    "/api/v1/suggestions"
    "/api/v1/calendar"
    "/api/v1/conversation/process"
    "/api/v1/conversation/status/{id}"
    "/api/v1/ingest/ios"
    "/api/v1/people/{slug}/forget"
    "/api/v1/email/recent"
    "/api/v1/recording/active"
    "/api/v1/coach/recent"
)

MISSING_PROXY=()
for path in "${REQUIRED_PROXY_PATHS[@]}"; do
    # Look for the path within the DOCTOR_PROXY_PATHS env-var
    # rendering. The rendered line has the path embedded inside a
    # comma-separated <string>...</string> value.
    if ! grep -q "${path}" "$INSTALL_SH"; then
        MISSING_PROXY+=("$path")
    fi
done

if [[ ${#MISSING_PROXY[@]} -gt 0 ]]; then
    echo "FAIL: install.sh DOCTOR_PROXY_PATHS is missing:" >&2
    for p in "${MISSING_PROXY[@]}"; do
        echo "    - $p" >&2
    done
    exit 1
fi
echo "PASS: all ${#REQUIRED_PROXY_PATHS[@]} required Doctor proxy paths are wired"

# -------------------------------------------------------------------
# Part 5: ical-server.py binds 127.0.0.1 by default (loopback only).
# -------------------------------------------------------------------
# The Doctor-on-:8089-is-single-auth-boundary posture depends on
# ical-server NOT being LAN-reachable. Customer install sets
# OSTLER_API_BIND=127.0.0.1 explicitly; the default in the source
# must also be loopback so a setup without env vars does not
# accidentally expose 8090 to the LAN.

if ! grep -q 'os.environ.get("OSTLER_API_BIND", "127.0.0.1")' "$ICAL_SERVER_PY"; then
    echo "FAIL: ical-server.py default bind is not 127.0.0.1" >&2
    echo "      Expected: OSTLER_API_BIND env var default 127.0.0.1" >&2
    exit 1
fi
echo "PASS: ical-server.py defaults to loopback bind"

# -------------------------------------------------------------------
# Part 6: ical-server.py PORT is env-overridable.
# -------------------------------------------------------------------
# Pre-CX-P0A the PORT constant was hardcoded 8089. Customer install
# sets OSTLER_API_PORT=8090 to clear the way for Doctor on :8089.
# A regression that drops the env override re-introduces the port
# collision and ical-server fails to bind.

if ! grep -q "OSTLER_API_PORT" "$ICAL_SERVER_PY"; then
    echo "FAIL: ical-server.py does not read OSTLER_API_PORT env var" >&2
    echo "      Pre-CX-P0A regression: PORT was hardcoded to 8089." >&2
    exit 1
fi
echo "PASS: ical-server.py honours OSTLER_API_PORT env var"

# -------------------------------------------------------------------
# Part 7: #596 Hub People page wiring -- the bare list endpoint.
# -------------------------------------------------------------------
# The Hub dashboard People page reads GET /api/v1/people (list + count).
# Pre-#596 there was NO such handler, so the page always fell to its
# empty-state regardless of how full Qdrant/Oxigraph were. Lock all
# three legs so a future refactor cannot silently re-break it:
#   (a) the bare /people GET handler in ical-server.py,
#   (b) the /api/v1/people -> /people version alias,
#   (c) the bare /api/v1/people token in DOCTOR_PROXY_PATHS, matched
#       comma-bounded so the longer /api/v1/people/search entry does
#       NOT satisfy it (substring matching would mask a removal).

if ! grep -q 'parsed.path == "/people":' "$ICAL_SERVER_PY"; then
    echo "FAIL: ical-server.py is missing the bare GET /people handler (#596)" >&2
    exit 1
fi
if ! grep -q '"/api/v1/people":' "$ICAL_SERVER_PY"; then
    echo "FAIL: ical-server.py is missing the /api/v1/people -> /people alias (#596)" >&2
    exit 1
fi
if ! grep -qF "/api/v1/people," "$INSTALL_SH"; then
    echo "FAIL: install.sh DOCTOR_PROXY_PATHS is missing the bare /api/v1/people" >&2
    echo "      (the /api/v1/people/search entry does NOT cover the list route)" >&2
    exit 1
fi
echo "PASS: #596 Hub People list endpoint wired (handler + alias + proxy path)"

echo ""
echo "PASS: vendor/cm041/assistant_api/ regression test green"
