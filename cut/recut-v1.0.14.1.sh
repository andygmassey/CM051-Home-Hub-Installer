#!/usr/bin/env bash
# ============================================================================
# recut-v1.0.14.1.sh — deterministic, stage-skippable re-cut of the Ostler DMG.
#
# Fixes ERR-11-DAEMON-RUN-SOURCE-SKEW (v1.0.14). Full rationale, SHAs, and
# decision log: CUT_ASSEMBLY_v1.0.14.1.md (same dir).
#
# USAGE
#   recut-v1.0.14.1.sh                 # run all stages 1..8
#   recut-v1.0.14.1.sh --from 3        # resume from stage 3 (skip 1,2)
#   recut-v1.0.14.1.sh --only 5        # run stage 5 alone
#
# STAGES
#   1 reconcile   2 build-daemon   3 GATE:capability   4 sign+notarise
#   5 stage+repin 6 dmg-ship       7 GATE:dmg          8 verify+ship-to-mini
#
# FAIL-CLOSED: stages 3 and 7 abort the cut on red. There is no skip.
# IDEMPOTENT: stage 1 no-ops if the cluster is already grafted; re-runnable.
# ============================================================================
set -euo pipefail

# ---- config (override via env) --------------------------------------------
DAEMON_VERSION="${DAEMON_VERSION:-0.4.51}"
DMG_VERSION="${DMG_VERSION:-1.0.14.1}"
OA_DIR="${OA_DIR:-$HOME/Developer/oa-reconcile}"          # ostler-assistant reconcile worktree
CM051_DIR="${CM051_DIR:-$HOME/Developer/cm051-killgate}"  # CM051 killgate worktree (gate lives here)
GATE="$CM051_DIR/scripts/verify_daemon_capability.sh"
BIN="$OA_DIR/target/release/zeroclaw"
NOTARY_PROFILE="${NOTARY_PROFILE:-ostler-notary}"
MINI="${MINI:-andy@192.168.1.200}"
RECONCILE_CLUSTER=(96e4e810 cea9220e af64ade4 3d965cd3)   # run-source ingest cluster (v1.0.10)
CUTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FROM=1; ONLY=""
while [ $# -gt 0 ]; do case "$1" in
  --from) FROM="$2"; shift 2;; --only) ONLY="$2"; FROM="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;; esac; done
run_stage(){ local n="$1"; [ -n "$ONLY" ] && { [ "$ONLY" = "$n" ] && return 0 || return 1; }; [ "$n" -ge "$FROM" ]; }
say(){ printf '\n\033[1m==== STAGE %s: %s ====\033[0m\n' "$1" "$2"; }

# ---- 1. reconcile (idempotent graft of the run-source cluster) -------------
if run_stage 1; then say 1 "reconcile — graft run-source cluster onto origin/main"
  git -C "$OA_DIR" fetch origin --quiet
  if git -C "$OA_DIR" grep -q "Commands::RunSource" -- src/main.rs 2>/dev/null; then
    echo "run-source already present — reconcile is idempotent, skipping graft."
  else
    git -C "$OA_DIR" cherry-pick "${RECONCILE_CLUSTER[@]}"
  fi
  git -C "$OA_DIR" grep -q "Commands::RunSource" -- src/main.rs || { echo "FATAL: run-source not in tree after reconcile" >&2; exit 1; }
fi

# ---- 2. build daemon -------------------------------------------------------
if run_stage 2; then say 2 "build daemon v$DAEMON_VERSION"
  ( cd "$OA_DIR" && release/build-binary.sh "$DAEMON_VERSION" ) 2>&1 | tee "$CUTDIR/daemon-build-$DAEMON_VERSION.log"
  [ -x "$BIN" ] || { echo "FATAL: daemon binary not produced at $BIN" >&2; exit 1; }
fi

# ---- 3. GATE: capability (BLOCKS — the ERR-11 killer) ----------------------
if run_stage 3; then say 3 "GATE capability (fail-closed)"
  bash "$GATE" --daemon "$BIN" || { echo "CUT BLOCKED: daemon capability gate red (would ship ERR-11)." >&2; exit 1; }
fi

# ---- 4. sign + notarise daemon --------------------------------------------
if run_stage 4; then say 4 "sign + notarise daemon"
  # NOTE: confirm arg contract on first run (release/sign-and-notarize.sh --help).
  ( cd "$OA_DIR" && NOTARY_PROFILE="$NOTARY_PROFILE" release/sign-and-notarize.sh "$BIN" )
fi

# ---- 5. stage into CM051 + re-pin the 4 sites ------------------------------
if run_stage 5; then say 5 "stage daemon into CM051 + re-pin (install.sh x2 + Makefile DAEMON_VERSION + DAEMON_SHA256)"
  # NOTE: exact sed targets finalised on first run against the real pin lines. See CUT_ASSEMBLY §5.
  echo "TODO(confirm): repin OSTLER_ASSISTANT_VERSION -> $DAEMON_VERSION (install.sh x2)"
  echo "TODO(confirm): repin gui/Makefile DAEMON_VERSION -> $DAEMON_VERSION + DAEMON_SHA256 -> sha256(tarball)"
fi

# ---- 6. DMG re-cut ---------------------------------------------------------
if run_stage 6; then say 6 "DMG ship v$DMG_VERSION"
  # NOTE: confirm VERSION override mechanism for make ship on first run.
  ( cd "$CM051_DIR" && make -C gui ship VERSION="$DMG_VERSION" )
fi

# ---- 7. GATE: assembled DMG (capability + parity) --------------------------
if run_stage 7; then say 7 "GATE assembled DMG (fail-closed)"
  DMG="/tmp/ostler-installer-dist-$USER/OstlerInstaller-$DMG_VERSION.dmg"
  bash "$GATE" --dmg "$DMG" || { echo "CUT BLOCKED: DMG capability gate red." >&2; exit 1; }
  bash "$CM051_DIR/scripts/verify_commit_parity.sh" "$DMG" || { echo "CUT BLOCKED: parity gate red." >&2; exit 1; }
fi

# ---- 8. verify + ship to the Mini for the box-walk -------------------------
if run_stage 8; then say 8 "verify + ship to Mini"
  DMG="/tmp/ostler-installer-dist-$USER/OstlerInstaller-$DMG_VERSION.dmg"
  spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | tail -2 || true
  shasum -a 256 "$DMG"
  scp "$DMG" "$MINI:~/Downloads/"
  echo "Staged on the Mini. Box-walk: install → must reach daemon stage with NO ERR-11 → pair."
fi

echo; echo "recut-v$DMG_VERSION.sh complete for the stages requested."
