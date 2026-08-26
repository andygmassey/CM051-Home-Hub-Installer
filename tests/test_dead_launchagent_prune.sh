#!/usr/bin/env bash
# tests/test_dead_launchagent_prune.sh
# ============================================================================
# AN OSTLER LAUNCHAGENT WHOSE PROGRAM IS GONE MUST BE PRUNED -- AND NOTHING
# ELSE MAY BE TOUCHED.
#
# WHY. Measured live 2026-08-26 on andy@.228: com.ostler.enrich pointed at
# ~/.ostler/bin/ostler-enrich-tick, which did not exist. launchd penalty-boxed
# it (last exit code = 78: EX_CONFIG), and a plain `launchctl kickstart` on a
# penalty-boxed job BLOCKS -- wedging the whole export-scan -> import ingest
# chain for 23h56m on 40ms of CPU. Nothing ingested for a day.
#
# The plist survived the enrichment agent being gated off; the script did not,
# and nothing pruned it. install.sh had ONE hard-coded stale label
# (com.ostler.colima). §3.2b-bis is the generic sweep.
#
# 🔴 THIS TEST EXECUTES THE SHIPPED BLOCK. IT DOES NOT RE-IMPLEMENT IT.
#
# The first draft of this file re-typed the predicate into the test and ran
# THAT against the fixtures. Every arm passed -- and would have gone on passing
# with install.sh's real block deleted outright, because nothing the arms
# touched came from install.sh. That is the same defect this branch exists to
# kill (a gate whose surface differs from the defect's surface is green
# forever), committed by the gate itself. So the block is now sed-extracted
# from install.sh between its own anchors and eval'd, with HOME pointed at a
# fixture tree and launchctl stubbed. If the block moves or is deleted, the
# extraction comes back empty and this exits CANNOT-RUN -- not PASS.
#
# launchctl is STUBBED, never invoked for real: a test that boots out a live
# agent on the developer's own Mac would be a defect, and CANNOT-RUN is not
# PASS, so the stub records calls instead of skipping the arm.
#
# Run: bash tests/test_dead_launchagent_prune.sh
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILURES=0
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
pass() { printf '  ok    %s\n' "$1"; }

[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: no readable $INSTALL_SH"; exit 2; }

# ── EXTRACT THE REAL BLOCK ────────────────────────────────────────────────
# Anchored on the block's own first and last lines. Both anchors are
# line-start-anchored so a mention inside a comment cannot move them.
BLOCK="$(sed -n '/^_PRUNE_QUARANTINE=/,/^unset _PRUNE_QUARANTINE/p' "$INSTALL_SH")"
BLOCK_LINES=$(printf '%s\n' "$BLOCK" | grep -c '' || true)
START_LINE=$(grep -n '^_PRUNE_QUARANTINE=' "$INSTALL_SH" | head -1 | cut -d: -f1)

if [ -z "$BLOCK" ] || [ "${BLOCK_LINES:-0}" -lt 20 ]; then
    echo "CANNOT-RUN: could not extract §3.2b-bis from install.sh (${BLOCK_LINES:-0} lines)."
    echo "  The block has moved, been renamed, or been deleted. Re-point this test"
    echo "  rather than deleting it -- the 24h ingest deadlock it guards is real."
    exit 2
fi
# The extraction must contain the loop, not just the two assignment lines.
if ! printf '%s\n' "$BLOCK" | grep -q 'PlistBuddy'; then
    echo "CANNOT-RUN: extracted block has no PlistBuddy read. Anchors matched the"
    echo "  wrong region. Not a pass."
    exit 2
fi
printf 'EXAMINED: §3.2b-bis extracted from install.sh:%s, %s lines\n' "$START_LINE" "$BLOCK_LINES"

# ── FIXTURES ──────────────────────────────────────────────────────────────
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
LA="$FIX/Library/LaunchAgents"
mkdir -p "$LA" "$FIX/bin"
printf '#!/bin/sh\nexit 0\n' > "$FIX/bin/alive"; chmod +x "$FIX/bin/alive"

_plist() {  # $1=label  $2=program path
    cat > "$LA/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>$2</string></array>
</dict></plist>
PLIST
}

# DEAD, ours -> must be pruned. The first is the label measured on .228.
_plist com.ostler.enrich                "$FIX/bin/ostler-enrich-tick"
_plist com.creativemachines.ostler.gone "$FIX/bin/also-absent"
# ALIVE, ours -> must be LEFT
_plist com.ostler.assistant             "$FIX/bin/alive"
# DEAD, NOT ours -> must be LEFT. Over-reach is worse than the defect.
_plist com.apple.something              "$FIX/bin/absent-apple"
_plist com.spotify.webhelper            "$FIX/bin/absent-spotify"
# Relative program -> resolves via PATH at spawn; unjudgeable, must be LEFT
_plist com.ostler.relative              "some-command-on-path"
# Program key instead of ProgramArguments, dead -> the fallback read must work
cat > "$LA/com.ostler.progkey.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.ostler.progkey</string>
  <key>Program</key><string>$FIX/bin/absent-progkey</string>
</dict></plist>
PLIST
# Unreadable/corrupt plist, ours -> CANNOT-RUN is not a licence to delete
printf 'this is not a plist\n' > "$LA/com.ostler.corrupt.plist"

BEFORE=$(ls "$LA" | grep -c '' || true)
printf 'EXAMINED: %s fixture plists (3 dead-ours, 1 alive-ours, 2 dead-foreign, 1 relative, 1 corrupt)\n' "$BEFORE"

# ── RUN THE SHIPPED BLOCK AGAINST THE FIXTURES ────────────────────────────
# HOME is redirected so the block's own "${HOME}/Library/LaunchAgents/" glob
# and its "${HOME}/.ostler/quarantine" target both land inside the fixture.
LCLOG="$FIX/launchctl.calls"
: > "$LCLOG"
(
    export HOME="$FIX"
    # Stubs for the installer's own output helpers.
    warn() { :; }
    ok()   { :; }
    info() { :; }
    # 🔴 launchctl NEVER runs for real here. It records and succeeds.
    launchctl() { printf '%s\n' "$*" >> "$LCLOG"; return 0; }
    eval "$BLOCK"
) > "$FIX/block.out" 2>&1
BLOCK_RC=$?
printf 'EXAMINED: shipped block executed, rc=%s, %s launchctl call(s) recorded\n\n' \
    "$BLOCK_RC" "$(grep -c '' < "$LCLOG" || true)"

QUAR="$FIX/.ostler/quarantine/launchagents"

# ── ARM 0: the block must not blow up. A non-zero rc here would abort the
# ── installer mid-run under `set -e`, which is worse than the orphan plist.
if [ "$BLOCK_RC" -eq 0 ]; then
    pass "the block completed cleanly (rc=0) -- it cannot abort the install"
else
    fail "the block exited rc=$BLOCK_RC; under set -e that aborts the installer"
    sed 's/^/        /' "$FIX/block.out" | head -20
fi

# ── ARM 1: all three dead OURS are gone, including the Program-key one.
for l in com.ostler.enrich com.creativemachines.ostler.gone com.ostler.progkey; do
    if [ -f "$LA/$l.plist" ]; then fail "$l is DEAD and ours but was NOT pruned"
    else pass "$l pruned (program absent)"; fi
done

# ── ARM 2: ARCHIVED, not destroyed. A wrong call must be recoverable.
for l in com.ostler.enrich com.creativemachines.ostler.gone com.ostler.progkey; do
    if [ -f "$QUAR/$l.plist" ]; then pass "$l archived to quarantine, not deleted"
    else fail "$l was DELETED, not archived -- a wrong prune must be recoverable"; fi
done

# ── ARM 3: THE CONTROL that matters most. A live agent must survive. Without
# ── this, a prune that removed everything would pass arms 1-2.
if [ -f "$LA/com.ostler.assistant.plist" ]; then
    pass "CONTROL: the live Ostler agent survived (program exists)"
else
    fail "CONTROL FAILED: a LIVE agent was pruned. This would break a working box."
fi

# ── ARM 4: NO OVER-REACH. Foreign dead agents are none of our business.
for l in com.apple.something com.spotify.webhelper; do
    if [ -f "$LA/$l.plist" ]; then pass "$l left alone (not an Ostler label)"
    else fail "$l was pruned -- the sweep touched an agent we do not own"; fi
done

# ── ARM 5: a relative program is unjudgeable from here, so leave it.
if [ -f "$LA/com.ostler.relative.plist" ]; then
    pass "relative-program agent left alone (resolves via PATH at spawn)"
else
    fail "pruned an agent whose program is a bare command name -- unjudgeable, not dead"
fi

# ── ARM 6: an unreadable plist is a CANNOT-RUN, not a licence to delete.
if [ -f "$LA/com.ostler.corrupt.plist" ]; then
    pass "unreadable plist left alone (cannot-run is not a verdict of dead)"
else
    fail "deleted a plist it could not read -- cannot-run is not a licence to delete"
fi

# ── ARM 7: the job must be UNLOADED, not merely unlinked. Removing the plist
# ── while the job stays bootstrapped leaves the penalty-boxed job live until
# ── the next logout -- which is precisely the state that wedged .228.
for l in com.ostler.enrich com.creativemachines.ostler.gone com.ostler.progkey; do
    if grep -q "bootout .*/${l}\$" "$LCLOG"; then
        pass "$l was booted out of launchd before archiving"
    else
        fail "$l plist moved but the job was never booted out -- it stays live until logout"
    fi
done

# ── ARM 8: and the survivors must never have been touched by launchctl.
for l in com.ostler.assistant com.ostler.relative com.apple.something; do
    if grep -q "${l}\$" "$LCLOG"; then
        fail "launchctl was invoked against $l, which must have been left alone"
    else
        pass "no launchctl call against $l"
    fi
done

# ── ARM 9: the sweep must state its denominator even at zero. A silent zero
# ── and "did not look" print identically.
if printf '%s\n' "$BLOCK" | grep -q 'Dead-LaunchAgent sweep: 0 pruned'; then
    pass "the sweep states its denominator even when it prunes nothing"
else
    fail "a silent zero and 'did not look' print identically -- state the denominator"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS -- dead Ostler agents pruned + unloaded; live, foreign, relative and"
    echo "        unreadable agents untouched. Assertions ran against the SHIPPED block."
    exit 0
fi
echo "FAIL -- $FAILURES assertion(s) failed."
exit 1
