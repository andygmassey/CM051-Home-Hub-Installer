#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_uninstall_removes_every_launchagent_plist.sh
#
# Uninstalling Ostler must leave ~/Library/LaunchAgents with none of our
# plists in it. Not "unloaded". Gone.
#
# WHY THE FILE IS THE LOAD-BEARING HALF
# ---------------------------------------------------------------------------
# `launchctl bootout gui/<uid>/<label>` unloads a job from the CURRENT login
# session. It does not touch the plist on disk, and launchd rescans
# ~/Library/LaunchAgents at every login. So an uninstall that boots a job out
# and leaves its plist behind has uninstalled nothing that survives a reboot:
# the agent is running again the next time the customer logs in, on a Mac that
# no longer has Ostler on it.
#
# For com.ostler.stay-awake that means `caffeinate -s` holding a power
# assertion forever on an ex-customer's machine. For the agents whose
# ProgramArguments point into ~/.ostler (which uninstall deletes) it means
# launchd respawning a missing binary until it throttles, permanently.
#
# WHY THE EXISTING GATE DID NOT CATCH IT
# ---------------------------------------------------------------------------
# tests/test_every_launchagent_is_torn_down.sh treats a label as torn down if
# it appears on a bootout OR unload OR rm line, anywhere in install.sh. Three
# consequences, all live on main when this file was written:
#
#   1. bootout-without-rm reads as fully torn down. com.ostler.stay-awake and
#      com.ostler.aiconv-resume were in exactly that state.
#   2. It greps the whole of install.sh, so an INSTALL-time bootout counts as
#      teardown. com.creativemachines.ostler.tailscaled is booted out at
#      install.sh:16605 only to restart it before bootstrap, and the
#      uninstaller never mentioned it at all.
#   3. It measures source text, so the strongest thing it can ever say is
#      that a string is present.
#
# That gate and this defect sit on different surfaces, which is why it stayed
# green. This one runs the teardown and then looks at the disk.
#
# THE TWO AXES
# ---------------------------------------------------------------------------
#   A. COMPLETENESS. Every label install.sh writes a literal
#      Library/LaunchAgents/<label>.plist path for must be named in the
#      uninstaller's teardown. (Some agents are installed by vendored
#      sub-scripts and cannot be enumerated from install.sh; this axis
#      therefore covers the labels install.sh itself spells out, and axis B
#      covers everything the teardown names.)
#   B. BEHAVIOUR. Seed a sandboxed HOME with one plist per label the teardown
#      names, run the teardown, and require that nothing is left on disk.
#
# Labels are read from the teardown's CODE, never its prose. A comment naming
# an agent is a mention, not a teardown -- the same distinction CM051 #687 had
# to fix in the wiring gate.
#
# Deliberately shape-agnostic. It never greps for a literal `rm -f` line, so a
# teardown written as one loop over a label register passes on behaviour, and
# a teardown written as two hand-maintained walls passes only if the walls
# actually agree.
#
# NEGATIVE CONTROLS at the end: the same predicate must pass a balanced
# fixture and reject a bootout-only one. A gate never observed rejecting
# anything is indistinguishable from a gate that always passes.
#
# EXIT CODES
#   0  every named plist is gone, nothing is unnamed, and both controls behaved
#   1  a plist survived, a label is unnamed, or a control misbehaved
#   2  could not run. NOT a pass.
# ---------------------------------------------------------------------------
set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -n "${NO_COLOR:-}" ]] && { RED=""; GRN=""; YEL=""; OFF=""; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${1:-${REPO_ROOT}/install.sh}"

fails=0
ok()  { printf '  %sPASS%s  %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1" >&2; fails=$((fails + 1)); }
cannot() {
    printf '%sUNAVAILABLE%s %s\n' "$YEL" "$OFF" "$*" >&2
    printf '  A gate that could not run is NOT a pass.\n' >&2
    exit 2
}

[[ -f "$INSTALL_SCRIPT" ]] || cannot "no install.sh at: $INSTALL_SCRIPT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. Extract the uninstaller install.sh ships ────────────────────────────
# Single-quoted heredoc, so the body is verbatim: ${HOME} and $(id -u) are
# still unexpanded and resolve inside our sandbox when we run it.
#
# `^[^#]*` on the opening marker, so a COMMENT that merely MENTIONS
# <<'UNINSTALLEOF' does not start the capture. Without it this awk treated the
# first prose reference as the heredoc opening and swallowed everything from
# there to the real terminator -- thousands of lines of install.sh, which then
# failed `bash -n` and reported "teardown region does not parse". The gate did
# fail closed, which is the right direction, but it named the wrong thing: the
# uninstaller was fine and a comment was the cause. Found 2026-08-18 when a
# comment documenting the colima-teardown containment bug did exactly this.
awk '
    /^[^#]*<<'\''UNINSTALLEOF'\''/ { capture = 1; next }
    /^UNINSTALLEOF$/               { capture = 0 }
    capture                        { print }
' "$INSTALL_SCRIPT" > "${WORK}/ostler-uninstall"

body_lines=$(wc -l < "${WORK}/ostler-uninstall" | tr -d ' ')
if [[ "$body_lines" -lt 100 ]]; then
    cannot "extracted uninstaller is only ${body_lines} lines; the heredoc markers have changed shape and every check below would be measuring nothing"
fi

# ── 2. Isolate the LaunchAgent teardown region ─────────────────────────────
# From the first bootout to just before the RemoteCapture .app banner. Running
# the whole uninstaller would rm -rf real paths under /Applications on a
# developer's machine; this region touches nothing outside $HOME.
start=$(grep -nE 'launchctl[[:space:]]+bootout[[:space:]]+"gui/' "${WORK}/ostler-uninstall" \
        | head -1 | cut -d: -f1)
end=$(grep -nE '^#.*Ostler RemoteCapture \.app' "${WORK}/ostler-uninstall" \
      | head -1 | cut -d: -f1)
if [[ -z "$start" || -z "$end" || "$end" -le "$start" ]]; then
    cannot "could not locate the LaunchAgent teardown region in the uninstaller (start='${start}' end='${end}')"
fi
# The register, if there is one, is declared above the first bootout. Walk
# back to the top of the enclosing block so the labels come with the loop.
reg=$(grep -nE '^OSTLER_LAUNCHAGENT_LABELS=\(' "${WORK}/ostler-uninstall" | head -1 | cut -d: -f1)
if [[ -n "$reg" && "$reg" -lt "$start" ]]; then
    start="$reg"
fi
awk -v a="$start" -v b="$end" 'NR>=a && NR<b' "${WORK}/ostler-uninstall" > "${WORK}/teardown.sh"
region_lines=$(wc -l < "${WORK}/teardown.sh" | tr -d ' ')
if [[ "$region_lines" -lt 10 ]]; then
    cannot "teardown region is only ${region_lines} lines; refusing to draw a conclusion from it"
fi
if ! bash -n "${WORK}/teardown.sh" 2>"${WORK}/parse.err"; then
    bad "teardown region does not parse: $(head -1 "${WORK}/parse.err")"
    printf '\n%sthe teardown never ran, so nothing below would be a measurement%s\n' "$RED" "$OFF" >&2
    exit 1
fi

# ── 3. The labels the teardown NAMES, read from code only ──────────────────
# Strip comments first. A comment naming an agent is a mention, not a
# teardown; letting prose satisfy the gate is how a gate starts agreeing
# with its own documentation.
sed -e 's/[[:space:]]*#.*$//' "${WORK}/teardown.sh" \
    | grep -oE 'com\.[a-z0-9][a-z0-9.-]*[a-z0-9]' \
    | sed -E 's/\.plist$//' | sort -u > "${WORK}/named.txt"
named_count=$(grep -c . "${WORK}/named.txt" || true)
if [[ "$named_count" -lt 20 ]]; then
    cannot "the teardown names only ${named_count} labels; expected 20+, so the extraction predicate is wrong and a clean result would be fake"
fi
printf '  (%s lines of uninstaller, %s-line teardown, %s labels named in code)\n' \
       "$body_lines" "$region_lines" "$named_count"

# ── 4. Sandbox harness ─────────────────────────────────────────────────────
STUB_BIN="${WORK}/stub-bin"
mkdir -p "$STUB_BIN"
for cmd in launchctl brew docker sudo security pmset; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${STUB_BIN}/${cmd}"
    chmod +x "${STUB_BIN}/${cmd}"
done

# Run a teardown fragment against a HOME seeded with one plist per label.
# Echoes the labels whose plist SURVIVED, one per line.
run_teardown() {
    local fragment="$1"; shift
    local sandbox label
    sandbox="$(mktemp -d "${WORK}/sandbox.XXXXXX")"
    mkdir -p "${sandbox}/Library/LaunchAgents"
    for label in "$@"; do
        printf 'seeded\n' > "${sandbox}/Library/LaunchAgents/${label}.plist"
    done
    HOME="$sandbox" PATH="${STUB_BIN}:${PATH}" \
        bash "$fragment" >/dev/null 2>&1 || true
    for label in "$@"; do
        [[ -e "${sandbox}/Library/LaunchAgents/${label}.plist" ]] && printf '%s\n' "$label"
    done
    return 0
}

# ── 5. Axis A: completeness ────────────────────────────────────────────────
# Every label install.sh spells out a plist path for must be named by the
# teardown. Agents installed by vendored sub-scripts are out of reach of this
# predicate by construction; axis B still holds them to the same standard once
# the teardown names them.
grep -oE 'LaunchAgents/com\.[a-z0-9.-]+\.plist' "$INSTALL_SCRIPT" \
    | sed -E 's|LaunchAgents/||; s|\.plist$||' | sort -u > "${WORK}/written.txt"
written_count=$(grep -c . "${WORK}/written.txt" || true)
if [[ "$written_count" -lt 5 ]]; then
    cannot "found only ${written_count} literal LaunchAgent plist paths in install.sh; the extraction predicate is wrong"
fi
unnamed=$(comm -23 "${WORK}/written.txt" "${WORK}/named.txt")
if [[ -z "$unnamed" ]]; then
    ok "all ${written_count} labels install.sh writes a plist path for are named by the teardown"
else
    while IFS= read -r label; do
        [[ -n "$label" ]] || continue
        bad "${label} is installed by install.sh and the uninstaller never names it"
    done <<< "$unnamed"
fi

# ── 6. Axis B: behaviour ───────────────────────────────────────────────────
survivors=$(run_teardown "${WORK}/teardown.sh" $(cat "${WORK}/named.txt"))
survivor_count=$(printf '%s\n' "$survivors" | grep -c . || true)
if [[ "$survivor_count" -eq 0 ]]; then
    ok "all ${named_count} plists are removed from ~/Library/LaunchAgents by the teardown"
else
    while IFS= read -r label; do
        [[ -n "$label" ]] || continue
        bad "${label}.plist survives uninstall -- launchd reloads it at the next login"
    done <<< "$survivors"
    printf '\n  %d of %d plists survive. bootout unloads for this login session only;\n' \
           "$survivor_count" "$named_count" >&2
    printf '  the file on disk is what makes an uninstall survive a reboot.\n\n' >&2
fi

# ── 7. NEGATIVE CONTROLS ───────────────────────────────────────────────────
# Same predicate, known inputs. Without these, the PASS above is compatible
# with a run_teardown that never seeds anything.
cat > "${WORK}/control_balanced.sh" <<'CTRL'
launchctl bootout "gui/$(id -u)/com.ostler.alpha" 2>/dev/null || true
rm -f "${HOME}/Library/LaunchAgents/com.ostler.alpha.plist"
CTRL
cat > "${WORK}/control_bootout_only.sh" <<'CTRL'
launchctl bootout "gui/$(id -u)/com.ostler.alpha" 2>/dev/null || true
CTRL

control_a=$(run_teardown "${WORK}/control_balanced.sh" com.ostler.alpha)
if [[ -z "$control_a" ]]; then
    ok "CONTROL: a teardown that removes the plist reports zero survivors"
else
    bad "CONTROL BROKEN: balanced fixture reported a survivor -- the harness cannot see a removal"
fi

control_b=$(run_teardown "${WORK}/control_bootout_only.sh" com.ostler.alpha)
if [[ "$control_b" == "com.ostler.alpha" ]]; then
    ok "CONTROL: a bootout-only teardown is caught (this is the defect shape)"
else
    bad "CONTROL BROKEN: bootout-only fixture was not caught -- every PASS above proves nothing"
fi

echo
if [[ "$fails" -eq 0 ]]; then
    echo "test_uninstall_removes_every_launchagent_plist: clean, both controls behaved"
    exit 0
fi
echo "test_uninstall_removes_every_launchagent_plist: ${fails} FAILURE(S)" >&2
exit 1
