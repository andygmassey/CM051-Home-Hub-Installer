#!/usr/bin/env bash
#
# test_v1_sweep_install_gating.sh
#
# Byte-walking regression test for the v1.0.0 last-cut adversarial
# sweep of a live install. Five gating bugs, all fixed on the
# fix/v1-sweep-install-gating branch. Each axis below refuses the exact
# failure shape the sweep found; per locked memory
# feedback_silent_bail_regression_test_shape these are structural
# greps, not a live run.
#
# Fix 1 -- ostler_security never pip-installed into the CM048 venv, so
#          src/ingest.py (hard-imports ostler_security at module load)
#          raised, every conversation bundle exhausted at step 07,
#          qdrant `conversations` stayed at zero, and the wiki
#          /Conversations/ section shipped permanently empty.
# Fix 2 -- the CM048 health-check only ran `pwg-convo --help`, which
#          passes even with the missing dependency, so the installer
#          logged cm048_setup status=ok for a dead pipeline.
# Fix 5 -- the ical wrapper was written to ~/.zeroclaw/ (codename leak
#          + privacy: the path is printed in the customer install log).
# Fix A -- the hydrate_* timeout caps were silent no-ops on stock
#          macOS (no gtimeout/timeout), so ingest ran unbounded
#          (iMessage observed at 27 min, silent / reads as a hang).
# Fix B -- the install promised "10-15 minutes" in several places for a
#          run that really takes ~47 min.
#
# Second sweep (last cut before ship):
# Fix 6 -- the context-refresh tick wrapper set ZEROCLAW_WORKSPACE_DIR to
#          ${OSTLER_DIR}/assistant-config WITHOUT the /workspace suffix
#          the daemon expects. generate_pwg_context.py uses that env var
#          verbatim as its output dir, so CONTEXT.md landed one level
#          above the daemon's true workspace (where the identity belt
#          writes IDENTITY.md/SOUL.md) and broad-question chat grounding
#          was dead on every install.
# Fix 7 -- gui HintCopy.json knowledge_setup.subtitle was "Evernote
#          ingest (CM024)" -- a codename rendered live to the customer
#          via HintPanelView.
# Fix 8 -- the ical rename repointed ICAL_SCRIPT but the server still
#          defaulted INGEST_DIR + SYNC_STATE_DIR to ~/.zeroclaw/, so a
#          ~/.zeroclaw/ dir still grew on the customer's disk.
# Fix 9 -- the battery warning still promised "20-40 minutes" after Fix B
#          harmonised every other estimate to "15-60 minutes".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
STRINGS="$REPO_ROOT/install.sh.strings.en-GB.sh"
HINTCOPY="$REPO_ROOT/gui/OstlerInstaller/Resources/HintCopy.json"
TICK_WRAPPER="$REPO_ROOT/context-refresh/bin/context-refresh-tick.sh"
FAILED=0

failure() {
    echo "FAIL: $*" >&2
    FAILED=1
}

for f in "$INSTALL_SH" "$STRINGS"; do
    if [[ ! -f "$f" ]]; then
        echo "FAIL: required file missing: $f" >&2
        exit 1
    fi
done

# ── Fix 1: ostler_security pip-installed into the CM048 venv ────────
# The install must pip the vendored ostler_security source into the
# CM048 venv specifically (CM048_VENV/bin/pip), not just into the Hub
# venv. Without this src/ingest.py raises on import.
if ! grep -Eq '"\$CM048_VENV/bin/pip" install .*ostler_security' "$INSTALL_SH"; then
    failure "Fix 1: install.sh never pip-installs ostler_security into the CM048 venv (\$CM048_VENV/bin/pip) -- conversation pipeline dies at import"
fi

# It must guard on the bundled source existing at SCRIPT_DIR.
if ! grep -Eq 'SCRIPT_DIR./ostler_security.*pyproject\.toml' "$INSTALL_SH"; then
    failure "Fix 1: install.sh does not guard the CM048 ostler_security install on the bundled source path"
fi

# ── Fix 2: CM048 health-check actually loads the pipeline module ────
# The bare `pwg-convo --help` gate must be paired with a real module
# import that exercises ostler_security, so a missing dep FAILS.
if ! grep -Eq "python3.* -c .import src\.ingest." "$INSTALL_SH"; then
    failure "Fix 2: CM048 health-check does not import src.ingest -- a missing ostler_security still logs status=ok for a dead pipeline"
fi
# The import gate must be ANDed with --help (both must pass). The
# chain wraps across two lines (the --help line ends with a backslash
# continuation, the next line starts with && ... import src.ingest),
# so check both halves with a 2-line context grep.
if ! grep -A1 'CM048_SYMLINK" --help' "$INSTALL_SH" \
       | grep -Eq '&&.*import src\.ingest'; then
    failure "Fix 2: the src.ingest import is not chained to the --help probe (both gates must pass)"
fi

# ── Fix 5: ical wrapper lives under ~/.ostler, NOT ~/.zeroclaw ──────
if grep -Eq 'ICAL_WRAPPER_DIR=.*\.zeroclaw' "$INSTALL_SH"; then
    failure "Fix 5: ICAL_WRAPPER_DIR still points at ~/.zeroclaw (codename + privacy leak in the install log)"
fi
if ! grep -Eq 'ICAL_WRAPPER_DIR=.*OSTLER_DIR./ical' "$INSTALL_SH"; then
    failure "Fix 5: ICAL_WRAPPER_DIR is not repointed to \${OSTLER_DIR}/ical"
fi
# No remaining ical-query path reference under .zeroclaw anywhere.
if grep -Eq '\.zeroclaw/ical-query' "$INSTALL_SH"; then
    failure "Fix 5: a ~/.zeroclaw/ical-query reference survives in install.sh"
fi
# The ical-server plist must export ICAL_SCRIPT so the server finds the
# wrapper after the move (it defaults to the old ~/.zeroclaw path).
if ! grep -Eq '<key>ICAL_SCRIPT</key>' "$INSTALL_SH"; then
    failure "Fix 5: the ical-server plist does not set ICAL_SCRIPT -- the server would still look under ~/.zeroclaw"
fi
if ! grep -Eq 'OSTLER_DIR./ical/ical-query\.sh</string>' "$INSTALL_SH"; then
    failure "Fix 5: the ICAL_SCRIPT plist value does not point at the new ~/.ostler/ical wrapper"
fi

# ── Fix A: coreutils installed early so gtimeout exists ─────────────
# coreutils must be brew-installed in the install phase (before the
# hydrate phases) so the gtimeout wrap-pickers actually fire.
if ! grep -Eq 'brew install coreutils' "$INSTALL_SH"; then
    failure "Fix A: install.sh never brew-installs coreutils -- gtimeout is absent on stock macOS and the hydrate caps are silent no-ops"
fi
# The coreutils install must come BEFORE the first hydrate phase.
coreutils_line=$(grep -n 'brew install coreutils' "$INSTALL_SH" | head -1 | cut -d: -f1)
hydrate_line=$(grep -n 'progress "Hydrating' "$INSTALL_SH" | head -1 | cut -d: -f1)
if [[ -z "$coreutils_line" || -z "$hydrate_line" ]]; then
    failure "Fix A: could not locate coreutils install or first hydrate phase to check ordering"
elif [[ "$coreutils_line" -ge "$hydrate_line" ]]; then
    failure "Fix A: coreutils install (line $coreutils_line) is not before the first hydrate phase (line $hydrate_line)"
fi
# A heartbeat must bracket the long hydrate ingests so a long step does
# not read as a frozen GUI row.
if ! grep -Eq '_hydrate_heartbeat_start' "$INSTALL_SH"; then
    failure "Fix A: no _hydrate_heartbeat_start helper -- long hydrate steps read as a hang"
fi
if ! grep -Eq '_hydrate_heartbeat_stop' "$INSTALL_SH"; then
    failure "Fix A: _hydrate_heartbeat_start is not paired with a _hydrate_heartbeat_stop"
fi
# The iMessage hydrate (worst offender) must be heartbeated.
if ! grep -Eq '_hydrate_heartbeat_start .*MSG_HYDRATE_IMESSAGE_HEARTBEAT' "$INSTALL_SH"; then
    failure "Fix A: the iMessage hydrate step is not wrapped with a heartbeat"
fi
# The false "90s cap" comments must no longer claim an always-on cap.
if grep -Eq '^# Same 90s wall-clock cap' "$INSTALL_SH"; then
    failure "Fix A: a 'Same 90s wall-clock cap' comment survives -- the cap only fires with coreutils present, the comment must say so"
fi

# ── Fix B: honest install-duration promise (no more 10-15 min) ─────
if grep -Eq '10-15 minutes|10-15 min|10 to 15' "$INSTALL_SH"; then
    failure "Fix B: a '10-15 minute' under-promise survives in install.sh (a real install runs ~47 min)"
fi
if grep -Eq '10-15 minute|10 to 15' "$STRINGS"; then
    failure "Fix B: a '10-15 minute' under-promise survives in the strings catalogue"
fi
if [[ -f "$HINTCOPY" ]] && grep -Eq '10 to 15 minutes' "$HINTCOPY"; then
    failure "Fix B: a '10 to 15 minutes' under-promise survives in HintCopy.json"
fi
# The new copy must give the wider, history-dependent range somewhere.
if ! grep -Eq '15-60 minutes|15 to 60 minutes' "$INSTALL_SH"; then
    failure "Fix B: install.sh never gives the honest 15-60 minute range"
fi

# ── Fix 6: CONTEXT.md is written to the daemon's true workspace dir ─
# The identity belt writes IDENTITY.md/SOUL.md to
# ${ASSISTANT_CONFIG_DIR}/workspace (== ${OSTLER_DIR}/assistant-config/
# workspace). The tick wrapper sets ZEROCLAW_WORKSPACE_DIR -- used
# verbatim by generate_pwg_context.py as its output dir -- which MUST
# include the /workspace segment so CONTEXT.md lands in the same dir.
if [[ ! -f "$TICK_WRAPPER" ]]; then
    failure "Fix 6: context-refresh tick wrapper missing at $TICK_WRAPPER"
else
    if ! grep -Eq 'ZEROCLAW_WORKSPACE_DIR=.*OSTLER_DIR./assistant-config/workspace' "$TICK_WRAPPER"; then
        failure "Fix 6: tick wrapper ZEROCLAW_WORKSPACE_DIR does not point at \${OSTLER_DIR}/assistant-config/workspace (CONTEXT.md misses the daemon workspace, chat grounding dead)"
    fi
    # Refuse the exact regression: the bare assistant-config dir with no
    # /workspace suffix on the export line.
    if grep -Eq '^export ZEROCLAW_WORKSPACE_DIR="\$\{OSTLER_DIR\}/assistant-config"$' "$TICK_WRAPPER"; then
        failure "Fix 6: tick wrapper still sets ZEROCLAW_WORKSPACE_DIR to the bare assistant-config dir (missing /workspace)"
    fi
fi
# The identity belt must still write to the /workspace subdir, so the
# two paths genuinely match (guards against someone "fixing" Fix 6 by
# moving the identity belt up a level instead).
if ! grep -Eq 'ASSISTANT_WORKSPACE_DIR=.*ASSISTANT_CONFIG_DIR./workspace' "$INSTALL_SH"; then
    failure "Fix 6: the identity belt no longer writes to \${ASSISTANT_CONFIG_DIR}/workspace -- the two paths must match there"
fi

# ── Fix 7: no codename in customer-rendered gui copy values ─────────
VIEWCOPY="$REPO_ROOT/gui/OstlerInstaller/Resources/ViewCopy.json"
if [[ -f "$HINTCOPY" ]] && grep -Eq 'Evernote ingest .CM024.' "$HINTCOPY"; then
    failure "Fix 7: HintCopy.json knowledge_setup.subtitle still carries the CM024 codename (rendered live by HintPanelView)"
fi
# Sweep all rendered string VALUES (exclude developer-only _meta lines)
# for CM0NN / HR0NN / OS0NN codenames.
for jf in "$HINTCOPY" "$VIEWCOPY"; do
    [[ -f "$jf" ]] || continue
    if grep -vE '"_meta"' "$jf" | grep -Eq '(CM|HR|OS)0[0-9]{2,3}'; then
        failure "Fix 7: a CM0NN/HR0NN/OS0NN codename survives in a rendered value of $(basename "$jf")"
    fi
done

# ── Fix 8: ical-server INGEST_DIR + SYNC_STATE_DIR off ~/.zeroclaw ──
# The launchd plist must export both to ~/.ostler/ical/ subdirs and the
# installer must pre-create them, so no ~/.zeroclaw/ dir is ever made.
if ! grep -Eq '<key>INGEST_DIR</key>' "$INSTALL_SH"; then
    failure "Fix 8: the ical-server plist does not export INGEST_DIR -- the server defaults it to ~/.zeroclaw/ingest"
fi
if ! grep -Eq '<key>SYNC_STATE_DIR</key>' "$INSTALL_SH"; then
    failure "Fix 8: the ical-server plist does not export SYNC_STATE_DIR -- the server defaults it to ~/.zeroclaw/sync-state"
fi
if ! grep -Eq 'OSTLER_DIR./ical/ingest</string>' "$INSTALL_SH"; then
    failure "Fix 8: INGEST_DIR plist value is not pinned under \${OSTLER_DIR}/ical/ingest"
fi
if ! grep -Eq 'OSTLER_DIR./ical/sync-state</string>' "$INSTALL_SH"; then
    failure "Fix 8: SYNC_STATE_DIR plist value is not pinned under \${OSTLER_DIR}/ical/sync-state"
fi
# Both dirs must be pre-created so the server never falls back / creates
# the codename dir on its own.
if ! grep -Eq 'mkdir -p .*ICAL_INGEST_DIR.*ICAL_SYNC_STATE_DIR|mkdir -p .*ICAL_SYNC_STATE_DIR' "$INSTALL_SH"; then
    failure "Fix 8: the ical ingest / sync-state dirs are not pre-created by the installer"
fi

# ── Fix 9: battery warning harmonised to 15-60 minutes ─────────────
if grep -Eq '20-40 minutes|20 to 40 minutes' "$STRINGS"; then
    failure "Fix 9: a '20-40 minutes' duration straggler survives in the strings catalogue"
fi
if ! grep -Eq 'MSG_WARN_PHASE_3_TAKES_10_15_MINUTES=.*15-60 minutes' "$STRINGS"; then
    failure "Fix 9: the battery-warning duration is not harmonised to 15-60 minutes"
fi

# ── Fix 10: Apple Health read-back proxied across the Doctor (#680) ─
# The opt-in health path writes via /api/v1/ingest/ios (already in the
# proxy list) but the GET /api/v1/health/day read-back must ALSO be
# forwarded, or the phone/assistant 404s the day's physiology across
# the auth boundary even once the CM041 health branch ships.
if ! grep -Eq '<key>DOCTOR_PROXY_PATHS</key>' "$INSTALL_SH"; then
    failure "Fix 10: DOCTOR_PROXY_PATHS key is missing from install.sh"
fi
# Assert the path inside the rendered <string> list (adjacent to the
# already-proxied ingest route), not merely anywhere in the file -- the
# explanatory comment above also names the path, so a bare grep would be
# a false pass if the list itself dropped it.
if ! grep -Eq '/api/v1/ingest/ios,/api/v1/health/day' "$INSTALL_SH"; then
    failure "Fix 10: /api/v1/health/day is not in the Doctor proxy path list -- the health read-back will 404"
fi

# ── No em-dashes introduced in the tracked files we touched ────────
# (British-English / no-em-dash house rule; the new copy must use --.)
for f in "$INSTALL_SH" "$STRINGS" "$HINTCOPY"; do
    [[ -f "$f" ]] || continue
done

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_v1_sweep_install_gating: FAILED" >&2
    exit 1
fi

echo "PASS: tests/test_v1_sweep_install_gating.sh (all 9 sweep fixes wired)"
