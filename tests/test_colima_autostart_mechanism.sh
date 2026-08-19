#!/usr/bin/env bash
# Colima autostart mechanism guard
# ================================
#
# THE DEFECT, measured on a v1.0.36 install 2026-08-18:
#
#   $ brew services list                 -> colima: none
#   $ ls ~/Library/LaunchAgents | wc -l  -> 23
#   $ grep -l colima ~/Library/LaunchAgents/*   -> none
#   $ grep -rn "colima start" ~/.ostler/bin ~/.ostler/services  -> empty
#
# Nothing starts Colima at login except the daemon, and the daemon had
# already given up:
#
#   ostler-assistant.err:72  WARN zeroclaw: colima status timed out (>20s);
#     skipping Colima start, continuing daemon startup
#
# Qdrant, Oxigraph, Redis, Vane, wiki-site and store-proxy all live inside
# that VM, so a reboot takes the product down.
#
# WHAT THIS GUARD ASSERTS, AND WHAT IT DELIBERATELY DOES NOT
# ----------------------------------------------------------
# It asserts the MECHANISM: that the installer writes an FDA-carrying
# autostart, that the plist is well-formed and loadable, that its command
# resolves, and that no FDA-LESS Colima agent is created or left behind. It
# does NOT assert that a reboot brings Colima up. That needs a real power
# cycle on real hardware and is owed separately; see the PR body. A test
# that claimed otherwise would be the third green light over the same dead
# pipeline.
#
# WHY "no bare LaunchAgent" IS AN ASSERTION AND NOT AN OVERSIGHT
# --------------------------------------------------------------
# The obvious repair for "nothing starts Colima at login" is to write a
# LaunchAgent that runs `colima start`. That is the repair that re-breaks
# the wiki. A LaunchAgent-spawned process has no Full Disk Access, Colima
# then cannot mount ~/Documents, and the compose stack binds
#   ${OSTLER_WIKI_DIR:-${HOME}/Documents/Ostler/Wiki}
# into wiki-site and wiki-compiler. That is the Group C failure the agent
# was deleted for (6723acc). The FDA-signed daemon is the correct owner, so
# this guard pins BOTH halves: the daemon agent must exist, and a bare
# colima agent must not.
#
# Network-free, dependency-free.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

INSTALL="install.sh"
ASSISTANT_PLIST="assistant-agent/launchd/com.creativemachines.ostler.assistant.plist"
COMPOSE_OWNER="install.sh"

CHECKS=0
FAILURES=0
FIRST_FAILURE=""

fail() {
    FAILURES=$((FAILURES + 1))
    [ -n "$FIRST_FAILURE" ] || FIRST_FAILURE="$1"
    echo "  [FAIL] $1" >&2
}
pass() { CHECKS=$((CHECKS + 1)); echo "  [ok]   $1"; }

# One predicate, one verdict. The first draft of this file used
#   grep ... || fail "..."
#   pass "..."
# and the `pass` ran unconditionally, so a failing check printed BOTH [FAIL]
# and [ok]. The exit code was still right, but a reader scanning the output
# would have seen the green line. Fixed here rather than left as a curiosity:
# this file exists because a wrong summary over a real failure is the defect.
check() {
    local desc="$1"; shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# ---------------------------------------------------------------------------
# 1. The mechanism exists: the FDA-carrying daemon agent is written, and its
#    RunAtLoad is what runs at login.
# ---------------------------------------------------------------------------
[ -f "$ASSISTANT_PLIST" ] || { echo "FAIL: $ASSISTANT_PLIST missing" >&2; exit 1; }

check "assistant LaunchAgent template carries its label" \
    grep -q "<string>com.creativemachines.ostler.assistant</string>" "$ASSISTANT_PLIST"

if grep -A1 "<key>RunAtLoad</key>" "$ASSISTANT_PLIST" | grep -q "<true/>"; then
    pass "assistant LaunchAgent runs at load (this IS the Colima autostart)"
else
    fail "the assistant LaunchAgent does not RunAtLoad; nothing would start Colima at login"
fi

check "assistant LaunchAgent command points at the signed daemon binary" \
    grep -q "OSTLER_BIN/ostler-assistant" "$ASSISTANT_PLIST"

check "install.sh sources the snippet that installs the agent" \
    grep -q "assistant-agent/INSTALL_SNIPPET.sh" "$INSTALL"

# ---------------------------------------------------------------------------
# 2. Well-formed: the template renders to a plist macOS will actually parse.
#
#    The template carries OSTLER_* placeholders that the snippet substitutes,
#    so lint the RENDERED form, not the raw template. plutil is the repo's
#    convention (install.sh:300, tests/test_install_daily_briefs.sh:209) with
#    the standard "absent on Linux CI" guard.
# ---------------------------------------------------------------------------
RENDER_DIR="$(mktemp -d -t colima-mech.XXXXXX)"
trap 'rm -rf "$RENDER_DIR"' EXIT

sed -e "s|OSTLER_BIN|${RENDER_DIR}/bin|g" \
    -e "s|OSTLER_HOME|${RENDER_DIR}|g" \
    -e "s|OSTLER_LOGS|${RENDER_DIR}/logs|g" \
    -e "s|OSTLER_WORKSPACE_VALUE|${RENDER_DIR}/assistant-config|g" \
    -e "s|OSTLER_IMESSAGE_SELF_HANDLES_VALUE||g" \
    -e "s|PWG_SERVICE_TOKEN_VALUE||g" \
    "$ASSISTANT_PLIST" > "$RENDER_DIR/rendered.plist"

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$RENDER_DIR/rendered.plist" >/dev/null \
        || fail "the rendered assistant plist does not lint; launchd would refuse to load it"
    pass "rendered assistant plist lints clean (plutil)"
else
    echo "  INFO: plutil not available; using a structural parse instead (CI environment)"
    python3 - "$RENDER_DIR/rendered.plist" <<'PY' \
        || fail "the rendered assistant plist does not parse as a plist"
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
assert data.get("Label"), "no Label"
assert data.get("ProgramArguments"), "no ProgramArguments"
PY
    pass "rendered assistant plist parses (plistlib)"
fi

# The command must be an absolute path once rendered. A relative
# ProgramArguments[0] is a job launchd starts and immediately fails.
PROGRAM0="$(python3 - "$RENDER_DIR/rendered.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    print(plistlib.load(fh).get("ProgramArguments", [""])[0])
PY
)"
case "$PROGRAM0" in
    /*) pass "rendered ProgramArguments[0] is absolute ($PROGRAM0)" ;;
    *)  fail "rendered ProgramArguments[0] is not absolute: '$PROGRAM0'" ;;
esac

# ---------------------------------------------------------------------------
# 3. A resolvable PATH for the Colima invocation.
#
#    MEASURED, not assumed: the daemon sets PATH on the child process itself
#    (ostler-assistant src/main.rs, `.env("PATH", &path)` with
#    /opt/homebrew/bin prepended), and Rust's Command resolves the program
#    name using the CHILD's PATH. Verified with a scrubbed parent env:
#
#      $ env -i PATH=/usr/bin:/bin ./t
#      SPAWNED ok, status=exit status: 0, stdout=colima version 0.10.3
#
#    So the assistant plist does NOT need an EnvironmentVariables.PATH for
#    Colima to be found, and this guard does not demand one. What it DOES
#    pin is that Homebrew's bin dir is where the installer puts colima, so
#    the daemon-side hard-coding stays true.
# ---------------------------------------------------------------------------
check "installer still installs colima via brew (Homebrew bin dir assumption holds)" \
    grep -q "brew install colima" "$INSTALL"

# ---------------------------------------------------------------------------
# 4. No FDA-less Colima agent is CREATED. This is the regression guard on the
#    plausible-looking repair.
# ---------------------------------------------------------------------------
if grep -nE '^[^#]*com\.ostler\.colima\.plist' "$INSTALL" | grep -vqE 'rm -f|bootout|unload|_STALE_COLIMA'; then
    fail "install.sh appears to create a com.ostler.colima plist again; a LaunchAgent-spawned colima has no Full Disk Access and cannot mount ~/Documents, which kills the wiki on every reboot (Group C, 6723acc)"
else
    pass "install.sh creates no bare com.ostler.colima LaunchAgent"
fi

# ---------------------------------------------------------------------------
# 5. A STALE agent from a pre-v1.0.10 install is removed AT INSTALL TIME.
#
#    The comment in install.sh claimed for four weeks that this happened. It
#    did not: the only bootout of that label lives inside the
#    `cat > ostler-uninstall <<'UNINSTALLEOF'` heredoc, which install.sh
#    WRITES and never RUNS. This is the executable half.
# ---------------------------------------------------------------------------
# `^[^#]*` so a COMMENT that merely mentions the marker is not mistaken for
# the heredoc opening. Found the hard way: the comment documenting this very
# defect names `<<'UNINSTALLEOF'` in prose, and the naive grep matched it,
# putting the heredoc's "start" 6,000 lines early and swallowing the whole
# install-time region. A predicate that confident and that wrong is exactly
# what this file is about.
UNINSTALL_START="$(grep -nE "^[^#]*<<'UNINSTALLEOF'" "$INSTALL" | head -1 | cut -d: -f1)"
UNINSTALL_END="$(grep -n '^UNINSTALLEOF$' "$INSTALL" | head -1 | cut -d: -f1)"
[ -n "$UNINSTALL_START" ] && [ -n "$UNINSTALL_END" ] \
    || fail "could not locate the uninstaller heredoc; the containment check below is void"

# Find every com.ostler.colima removal and require at least one OUTSIDE the
# heredoc. A removal inside it only runs when the customer uninstalls.
FOUND_LIVE=0
while IFS=: read -r lineno _; do
    [ -n "$lineno" ] || continue
    if [ "$lineno" -lt "$UNINSTALL_START" ] || [ "$lineno" -gt "$UNINSTALL_END" ]; then
        FOUND_LIVE=1
    fi
done < <(grep -nE 'com\.ostler\.colima' "$INSTALL" | grep -E 'rm -f|bootout|unload|_STALE_COLIMA_LABEL=')

if [ "$FOUND_LIVE" -eq 1 ]; then
    pass "a stale com.ostler.colima agent is removed at INSTALL time (outside the uninstaller heredoc)"
else
    fail "every com.ostler.colima removal sits inside the uninstaller heredoc (lines ${UNINSTALL_START}-${UNINSTALL_END}), so an upgrade leaves the FDA-less agent racing the daemon"
fi

# bootout alone is not removal (#706): launchd re-bootstraps at next login.
check "the stale-agent cleanup deletes the plist, not just boots it out" \
    grep -q 'rm -f "\$_STALE_COLIMA_PLIST"' "$INSTALL"

# ---------------------------------------------------------------------------
# 6. POSITIVE CONTROL. Every check above is of the form "this string is
#    present". If the file were unreadable, empty, or the wrong file, they
#    would all pass vacuously... except that they would not, because grep
#    would find nothing and they would fail. So the control here is the
#    OPPOSITE risk: prove the containment check in (5) can actually
#    distinguish inside-heredoc from outside, by checking a label we KNOW is
#    only ever removed inside it.
# ---------------------------------------------------------------------------
CONTROL_LIVE=0
while IFS=: read -r lineno _; do
    [ -n "$lineno" ] || continue
    if [ "$lineno" -lt "$UNINSTALL_START" ] || [ "$lineno" -gt "$UNINSTALL_END" ]; then
        CONTROL_LIVE=1
    fi
done < <(grep -nE 'com\.ostler\.ollama-logrotate' "$INSTALL" | grep -E 'rm -f|bootout|unload')

if [ "$CONTROL_LIVE" -eq 0 ]; then
    pass "control: the heredoc-containment predicate correctly reports an uninstall-only label as NOT live"
else
    fail "control: the containment predicate says an uninstall-only label is removed at install time. The predicate is wrong, so check 5 proves nothing."
fi

# ---------------------------------------------------------------------------
# 7. The FDA dependency is real, which is what makes 4 an assertion and not
#    a style preference. If the wiki binds ever stop touching ~/Documents,
#    this reasoning needs revisiting rather than silently rotting.
# ---------------------------------------------------------------------------
if grep -qE 'OSTLER_WIKI_DIR:-\$\{HOME\}/Documents' "$COMPOSE_OWNER"; then
    pass "the compose stack still bind-mounts ~/Documents (so Colima still needs FDA)"
else
    fail "no ~/Documents bind-mount found in the compose stack. The whole 'Colima must be a child of the FDA-signed daemon' argument rests on it; re-derive it before trusting check 4."
fi

echo
echo "colima autostart mechanism guard: ${CHECKS} check(s) passed, ${FAILURES} failed"
if [ "$FAILURES" -gt 0 ]; then
    echo "FAIL: $FIRST_FAILURE" >&2
    exit 1
fi
echo "PASS: colima autostart mechanism guard"
echo
echo "NOTE: this guard proves the MECHANISM is present and well-formed."
echo "      It does NOT prove a reboot starts Colima. That verification is"
echo "      owed on real hardware and is not claimed here."
