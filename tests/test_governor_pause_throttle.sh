#!/usr/bin/env bash
#
# test_governor_pause_throttle.sh
#
# Tests for the user-facing Pause + Throttle controls layered on top of
# the adaptive resource governor. The engine already scales background
# work to the hardware tier; these controls let the operator (via the
# Doctor Settings panel) pause background work or ease it off, and -- the
# whole point -- have that choice actually reach the engine.
#
# Proves:
#   1. PAUSE makes a non-essential tick yield unconditionally (even at
#      low load), and auto-resumes when the pause window elapses. A
#      malformed pause window fails OPEN (never wedges work forever).
#   2. THROTTLE levels map onto the concrete knobs: gentle => low ceiling
#      + off-peak + defer; full => high ceiling + no off-peak + no defer;
#      balanced => the hardware-tier default is left untouched.
#   3. An explicitly-set environment variable still wins over the file
#      (operator/command-line override precedence).
#   4. END-TO-END: the real Doctor Settings panel (config_panel.py) writes
#      governor.env and the shell engine consumes it -- the writer/reader
#      round-trip that the old dead-yaml Config page never had.
#   5. Static wiring guard: the panel emits the bridge file on write and
#      the lib carries the pause/throttle functions.
#
# British English throughout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/ostler-resource-tier.sh"
PANEL_DIR="$REPO_ROOT/vendor/doctor/agent"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

[ -f "$LIB" ] || { echo "FAIL: missing $LIB" >&2; exit 1; }
bash -n "$LIB" || failure "lib has a bash syntax error"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Helper: write a governor.env, then source the lib with it, run detect,
# and echo "defer"/"proceed" for a non-essential tick. Extra shell can be
# passed to pin cores/load. Args: <governor.env body> <extra pre-detect>
run_gate() {
    local body="$1" extra="${2:-}"
    printf '%s\n' "$body" > "$TMP/governor.env"
    OSTLER_GOVERNOR_SETTINGS="$TMP/governor.env" bash -c '
        . "'"$LIB"'"
        '"$extra"'
        ostler_resource_tier_detect
        if ostler_resource_tier_should_defer_nonessential; then
            echo "defer:${OSTLER_DEFER_REASON:-?}"
        else
            echo "proceed:${OSTLER_DEFER_REASON:-?}"
        fi
    '
}

# --------------------------------------------------------------------
# Section 1 -- PAUSE.
# --------------------------------------------------------------------
# Paused + LOW load (0.1/core) must still DEFER, reason "paused".
got="$(run_gate 'export OSTLER_PAUSED=1' 'OSTLER_CPU_CORES=8; export FAKE=0')"
case "$got" in
    defer:paused) pass "pause makes a non-essential tick yield unconditionally" ;;
    *) failure "paused tick should defer with reason 'paused', got '$got'" ;;
esac

# Paused with an until in the PAST -> auto-resumed -> PROCEED (low load).
got="$(run_gate "export OSTLER_PAUSED=1
export OSTLER_PAUSE_UNTIL=100" 'OSTLER_DEFER_NONESSENTIAL=0; OSTLER_LOADAVG_CEILING=8.0; OSTLER_CPU_CORES=8')"
case "$got" in
    proceed:*) pass "pause auto-resumes once the pause window has elapsed" ;;
    *) failure "an elapsed pause window should auto-resume (proceed), got '$got'" ;;
esac

# Malformed until -> fail OPEN (not paused) -> PROCEED at low load.
got="$(run_gate "export OSTLER_PAUSED=1
export OSTLER_PAUSE_UNTIL=whenever" 'OSTLER_DEFER_NONESSENTIAL=0; OSTLER_LOADAVG_CEILING=8.0; OSTLER_CPU_CORES=8')"
case "$got" in
    proceed:*) pass "a malformed pause window fails open (never wedges work forever)" ;;
    *) failure "malformed pause window should fail open (proceed), got '$got'" ;;
esac

# --------------------------------------------------------------------
# Section 2 -- THROTTLE level -> concrete knobs. Read them back via the
# CLI print form so we assert on the composed policy, not internals.
# --------------------------------------------------------------------
knobs() {
    # knobs <throttle-level> [pinned-tier]
    local level="$1" tier="${2:-}"
    printf 'export OSTLER_THROTTLE_LEVEL=%s\n' "$level" > "$TMP/governor.env"
    env OSTLER_GOVERNOR_SETTINGS="$TMP/governor.env" \
        ${tier:+OSTLER_TIER="$tier"} bash "$LIB"
}

out="$(knobs gentle)"
echo "$out" | grep -q '^OSTLER_LOADAVG_CEILING=1.0$'   || failure "gentle should set ceiling 1.0, got: $out"
echo "$out" | grep -q '^OSTLER_DEFER_NONESSENTIAL=1$'  || failure "gentle should defer"
echo "$out" | grep -q '^OSTLER_INGEST_OFFPEAK_ONLY=1$' || failure "gentle should keep off-peak on"
echo "$out" | grep -q '^OSTLER_THROTTLE_LEVEL=gentle$' || failure "gentle level should round-trip"
[ "$FAILED" -eq 0 ] && pass "gentle throttle -> low ceiling + off-peak + defer"

out="$(knobs full)"
echo "$out" | grep -q '^OSTLER_LOADAVG_CEILING=8.0$'   || failure "full should set ceiling 8.0, got: $out"
echo "$out" | grep -q '^OSTLER_DEFER_NONESSENTIAL=0$'  || failure "full should not defer"
echo "$out" | grep -q '^OSTLER_INGEST_OFFPEAK_ONLY=0$' || failure "full should drop the off-peak clamp"
[ "$FAILED" -eq 0 ] && pass "full throttle -> high ceiling + no off-peak + no defer"

# balanced leaves the hardware-tier default untouched (pin HIGH -> 3.0).
out="$(knobs balanced high)"
echo "$out" | grep -q '^OSTLER_LOADAVG_CEILING=3.0$'   || failure "balanced+HIGH should keep the tier ceiling 3.0, got: $out"
echo "$out" | grep -q '^OSTLER_THROTTLE_LEVEL=balanced$' || failure "balanced level should round-trip"
[ "$FAILED" -eq 0 ] && pass "balanced throttle leaves the hardware-tier default in place"

# --------------------------------------------------------------------
# Section 3 -- explicit environment wins over the file.
# --------------------------------------------------------------------
got="$(run_gate 'export OSTLER_PAUSED=1' 'export OSTLER_PAUSED=0; OSTLER_DEFER_NONESSENTIAL=0; OSTLER_LOADAVG_CEILING=8.0; OSTLER_CPU_CORES=8')"
case "$got" in
    proceed:*) pass "an explicit env var overrides the settings file" ;;
    *) failure "explicit OSTLER_PAUSED=0 should override the file's 1, got '$got'" ;;
esac

# --------------------------------------------------------------------
# Section 4 -- END-TO-END: the real panel writes governor.env; the engine
# consumes it. Skips (does not fail) if python3 or PyYAML is unavailable.
# --------------------------------------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1 && [ -f "$PANEL_DIR/config_panel.py" ]; then
    ENVF="$TMP/e2e-governor.env"
    ( cd "$PANEL_DIR" && \
      OSTLER_GOVERNOR_ENV_FILE="$ENVF" \
      OSTLER_CONFIG_FILE="$TMP/e2e-config.yaml" \
      python3 -c "import config_panel as c; c.write_config({'background_paused': True, 'background_throttle': 'gentle'})" ) \
      || failure "panel write_config raised"
    grep -q '^export OSTLER_PAUSED=1$' "$ENVF"            || failure "panel did not write OSTLER_PAUSED=1"
    grep -q '^export OSTLER_THROTTLE_LEVEL=gentle$' "$ENVF" || failure "panel did not write the throttle level"
    got="$(OSTLER_GOVERNOR_SETTINGS="$ENVF" bash -c '
        . "'"$LIB"'"
        OSTLER_CPU_CORES=8
        ostler_resource_tier_detect
        if ostler_resource_tier_should_defer_nonessential; then
            echo "defer:${OSTLER_DEFER_REASON}:${OSTLER_LOADAVG_CEILING}"
        else echo proceed; fi')"
    case "$got" in
        defer:paused:1.0) pass "END-TO-END: panel pause+gentle reaches the engine (defer, ceiling 1.0)" ;;
        *) failure "end-to-end panel->engine round-trip wrong, got '$got'" ;;
    esac
else
    echo "skip: python3/PyYAML unavailable -- end-to-end round-trip not exercised"
fi

# --------------------------------------------------------------------
# Section 5 -- static wiring guards.
# --------------------------------------------------------------------
grep -q 'ostler_rt_load_user_settings' "$LIB"        || failure "lib must load the user settings file"
grep -q 'ostler_resource_tier_is_paused' "$LIB"      || failure "lib must expose the pause check"
grep -q 'ostler_rt_apply_throttle_level' "$LIB"      || failure "lib must map the throttle level"
grep -q 'is_paused' "$LIB" && grep -q 'return 0' "$LIB" || true
# The pause check must be consulted by the non-essential defer gate.
awk '/ostler_resource_tier_should_defer_nonessential\(\)/{f=1} f && /ostler_resource_tier_is_paused/{print; found=1} END{exit !found}' "$LIB" \
    >/dev/null || failure "the defer gate must consult the pause check"

if [ -f "$PANEL_DIR/config_panel.py" ]; then
    grep -q '_write_governor_env' "$PANEL_DIR/config_panel.py" \
        || failure "config_panel.write_config must emit the governor bridge file"
    grep -q 'OSTLER_THROTTLE_LEVEL' "$PANEL_DIR/config_panel.py" \
        || failure "config_panel must render the throttle level into governor.env"
    grep -q 'background_paused' "$PANEL_DIR/config_panel.py" \
        || failure "config_panel must expose the Pause control"
fi
[ "$FAILED" -eq 0 ] && pass "static wiring: lib + panel carry the pause/throttle contract"

# The wiki recompile (the biggest LLM producer) must honour an explicit
# operator Pause even though it is essential and not load-deferred.
WIKI="$REPO_ROOT/wiki-recompile/bin/wiki-recompile-tick.sh"
if [ -f "$WIKI" ]; then
    bash -n "$WIKI" || failure "wiki tick has a bash syntax error"
    grep -q 'ostler_resource_tier_is_paused' "$WIKI" \
        || failure "wiki recompile must yield to an explicit operator Pause"
    # It must still NOT load-defer (that behaviour is unchanged).
    grep -q 'ostler_resource_tier_should_defer_nonessential' "$WIKI" \
        && failure "wiki recompile must remain essential (never load-defer)"
    [ "$FAILED" -eq 0 ] && pass "wiki recompile honours Pause but is still not load-deferred"
fi

# Discoverability: the dashboard header must carry a prominent Settings
# entry point to /config (not just the buried footer meta link). The
# RENDERED look is device-gated (needs the doctor venv); this asserts the
# markup + copy are present offline.
if [ -f "$PANEL_DIR/web_ui.py" ]; then
    grep -q 'href="/config" id="settingsBtn"' "$PANEL_DIR/web_ui.py" \
        || failure "dashboard header must link to /config (a real Settings entry point)"
    grep -q 'DASHBOARD_BTN_SETTINGS' "$PANEL_DIR/web_ui_copy.py" \
        || failure "web_ui_copy must define the Settings button copy"
    [ "$FAILED" -eq 0 ] && pass "discoverability: dashboard header carries a Settings entry point"
fi

# --------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
    echo "ALL GOVERNOR PAUSE/THROTTLE TESTS PASSED"
    exit 0
fi
echo "GOVERNOR PAUSE/THROTTLE TESTS FAILED" >&2
exit 1
