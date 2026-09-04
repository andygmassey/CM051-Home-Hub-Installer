#!/usr/bin/env bash
# Every reader must resolve the usage journal to the path the daemon writes (W006)
# ==============================================================================
#
# THE INPUT THIS TEST REPLAYS
#
# v1.0.63 walk 2. The `usage_journal_producers` probe reported:
#
#     journal on box : ~/.ostler/workspace/state/costs.jsonl
#     records        : 0  -- THE FILE DOES NOT EXIST. The directory does not exist.
#
# while the Bursar panel showed 73 model calls / 23.5K tokens for the same
# install. Both were telling the truth about different files.
#
# WHY THE TWO DISAGREE
#
# The daemon takes its workspace from the assistant LaunchAgent's
# ZEROCLAW_WORKSPACE=${OSTLER_DIR}/assistant-config, so its CostTracker reads
# <assistant-config>/workspace/state/costs.jsonl. Nothing else on the box has
# that variable. Every other reader -- the box-walk probe over ssh,
# scripts/verify_usage_journal_producers.py, Doctor, any CLI -- falls through
# to ${HOME}/.ostler/workspace/state/costs.jsonl, which install.sh's own
# compose comment calls "a DIFFERENT directory nothing reads back".
#
# Both resolvers DO honour a ${HOME}/.ostler/active_workspace.toml marker.
# Nothing had ever written it: `active_workspace` appeared 0 times in
# install.sh, against 19 hits for `config.toml` through the same search.
#
# WHAT THIS TEST ASSERTS
#
#   A   ORIGINAL FAILING INPUT. With the marker ABSENT -- the shipped state
#       before this fix -- the shipped resolver returns the ~/.ostler/workspace
#       path. This arm documents the defect and must keep passing: it is the
#       control that proves arm B is caused by the marker and not by anything
#       else in the environment.
#   B   WITH the marker present, the SHIPPED resolver
#       (scripts/verify_usage_journal_producers.py) returns the daemon's
#       assistant-config path. Same process, same env, one file added.
#   C   install.sh actually WRITES that marker. B is worthless if the product
#       never produces the file the test hands the resolver.
#   D   ENV STILL WINS. With ZEROCLAW_CONFIG_DIR set, the marker must not
#       override it -- the daemon and any operator override must be unaffected
#       by this fix.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
RESOLVER="${REPO}/scripts/verify_usage_journal_producers.py"

FAILURES=0; PASSES=0
fatal() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }
pass()  { PASSES=$((PASSES+1)); printf '  PASS  %s\n' "$1"; }
red()   { FAILURES=$((FAILURES+1)); printf '  RED   %s\n' "$1"; }

[[ -f "$INSTALL_SH" ]] || fatal "install.sh not found at ${INSTALL_SH}"
[[ -f "$RESOLVER" ]]   || fatal "resolver not found at ${RESOLVER} -- this test drives the SHIPPED one on purpose; a reimplementation would only test itself"
command -v python3 >/dev/null 2>&1 || fatal "python3 not on PATH"

# macOS TMPDIR ends in a slash. Left alone, "${TMPDIR}/w006-XXXXXX" yields a
# doubled separator that this test's expected strings carry and python's
# pathlib normalises away -- three arms went RED on `/T//w006` vs `/T/w006`
# while the resolver was returning exactly the right answers. Strip it, and
# compare normalised paths below rather than trusting string equality.
_tmpbase="${TMPDIR:-/tmp}"; _tmpbase="${_tmpbase%/}"
WORK="$(mktemp -d "${_tmpbase}/w006-XXXXXX")" || fatal "could not create a work dir"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
FAKE="${WORK}/home"
mkdir -p "${FAKE}/.ostler/assistant-config/workspace/state"

resolve() {
    # $@ = extra env assignments. Runs the SHIPPED resolver with a fake HOME
    # and the daemon's variables stripped, which is exactly a probe session.
    env -u ZEROCLAW_CONFIG_DIR -u OSTLER_WORKSPACE -u ZEROCLAW_WORKSPACE \
        HOME="$FAKE" "$@" \
        python3 -c "import sys; sys.path.insert(0, '${REPO}/scripts'); import verify_usage_journal_producers as v; print(v.resolve_journal_path())" 2>/dev/null
}

MARKER="${FAKE}/.ostler/active_workspace.toml"
WRONG="${FAKE}/.ostler/workspace/state/costs.jsonl"
RIGHT="${FAKE}/.ostler/assistant-config/workspace/state/costs.jsonl"

# --- A: the pre-fix state, and the control for B ---------------------------
rm -f "$MARKER"
GOT_A="$(resolve)"
[[ -n "$GOT_A" ]] || fatal "the shipped resolver produced no output -- it did not run, and every arm below would be measuring the harness"
if [[ "$GOT_A" == "$WRONG" ]]; then
    pass "A  control: with NO marker the shipped resolver returns the path nothing writes (${GOT_A##*/.ostler/})"
else
    red  "A  control FAILED: with no marker the resolver returned ${GOT_A}, expected ${WRONG}. B below can no longer be attributed to the marker."
fi

# --- B: the fix ------------------------------------------------------------
printf 'config_dir = "%s"\n' "${FAKE}/.ostler/assistant-config" > "$MARKER"
GOT_B="$(resolve)"
if [[ "$GOT_B" == "$RIGHT" ]]; then
    pass "B  with the marker, the shipped resolver returns the DAEMON's path (${GOT_B##*/.ostler/})"
else
    red  "B  with the marker present the resolver returned ${GOT_B}, expected the daemon's ${RIGHT}. Readers still disagree with the daemon -- this is W006."
fi

# --- C: does the product actually write it? --------------------------------
if grep -q 'active_workspace\.toml' "$INSTALL_SH"; then
    if grep -qE 'config_dir = "%s"' "$INSTALL_SH"; then
        pass "C  install.sh writes ${MARKER##*/} with a config_dir line"
    else
        red  "C  install.sh mentions active_workspace.toml but never writes a config_dir line -- the readers key on that field, so a marker without it resolves nothing"
    fi
else
    red  "C  install.sh never writes active_workspace.toml. B passes only because this test wrote the file by hand; on a real box nothing would."
fi

# --- D: env must still win -------------------------------------------------
OVERRIDE="${WORK}/override"
mkdir -p "${OVERRIDE}/workspace/state"
GOT_D="$(env HOME="$FAKE" ZEROCLAW_CONFIG_DIR="$OVERRIDE" \
    python3 -c "import sys; sys.path.insert(0, '${REPO}/scripts'); import verify_usage_journal_producers as v; print(v.resolve_journal_path())" 2>/dev/null)"
if [[ "$GOT_D" == "${OVERRIDE}/workspace/state/costs.jsonl" ]]; then
    pass "D  ZEROCLAW_CONFIG_DIR still wins over the marker -- the daemon and operator overrides are unaffected"
else
    red  "D  with ZEROCLAW_CONFIG_DIR set the resolver returned ${GOT_D}; the marker is overriding an explicit env var, which would move the DAEMON"
fi

printf '\n'
printf 'CONCLUSION HISTOGRAM\n'
printf '  PASS : %d\n' "$PASSES"
printf '  RED  : %d\n' "$FAILURES"
printf '  TOTAL: %d\n' "$((PASSES + FAILURES))"
[[ $FAILURES -eq 0 ]] || exit 1
exit 0
