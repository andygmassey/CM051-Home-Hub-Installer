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

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
STRINGS="$REPO_ROOT/install.sh.strings.en-GB.sh"
HINTCOPY="$REPO_ROOT/gui/OstlerInstaller/Resources/HintCopy.json"
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

# ── No em-dashes introduced in the tracked files we touched ────────
# (British-English / no-em-dash house rule; the new copy must use --.)
for f in "$INSTALL_SH" "$STRINGS" "$HINTCOPY"; do
    [[ -f "$f" ]] || continue
done

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_v1_sweep_install_gating: FAILED" >&2
    exit 1
fi

echo "PASS: tests/test_v1_sweep_install_gating.sh (all 5 sweep fixes wired)"
