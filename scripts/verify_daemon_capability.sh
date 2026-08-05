#!/usr/bin/env bash
# ============================================================================
# verify_daemon_capability.sh -- CUT-TIME daemon command-contract gate.
#
# WHY THIS EXISTS (the cycle-breaker)
# -----------------------------------
# Class-of-bug shipped in v1.0.14 (ERR-11-DAEMON-RUN-SOURCE-SKEW):
#   * The bundled daemon was built from a lineage MISSING the `run-source`
#     subcommand (a v1.0.10 feature that lived only on `integration`, never
#     forward-ported to `main`).
#   * `install.sh` REQUIRES `run-source` to route ingest through Full Disk
#     Access. It has its OWN preflight (`run-source --help`) -- but that
#     preflight fires on the CUSTOMER'S Mac, after a 40-minute install, as a
#     fail-closed ERR-11. The cut itself had no such check.
#   * Signing passed. Notarisation passed. Frontend commit-parity passed.
#     None of them test the daemon's COMMAND SURFACE. So a daemon that could
#     not do what install.sh calls sailed through every build gate.
#
# THE PRINCIPLE: capability > provenance.
# We stop trusting "the daemon came from the right branch" (which keeps getting
# tangled by the main<->integration split) and instead assert the binary
# FUNCTIONALLY DOES what install.sh invokes. A capability-incomplete daemon
# then physically cannot pass -- regardless of lineage confusion.
#
# This is install.sh's ERR-11 preflight, moved LEFT to cut time, generalised to
# the whole daemon command contract, and run against the assembled bundle
# BEFORE a byte is signed.
#
# USAGE
#   verify_daemon_capability.sh --daemon <path-to-ostler-assistant>
#   verify_daemon_capability.sh --dmg <path-to.dmg>          # mount + locate + verify
#   HOST=andy@host verify_daemon_capability.sh --remote-daemon <path>   # over ssh
#
# EXIT CODES
#   0  daemon supports every required subcommand  (cut may proceed)
#   1  one or more required subcommands missing   (BLOCK the cut)
#   2  usage / environment error (binary not found, mount failed)
#
# NO SKIP: there is deliberately no env var that disables this gate. A silent
# no-op gate is worse than none (feedback_ships_dark_wire_and_gate). If an
# assertion is wrong, fix the REQUIRED_CMDS list; do not add a bypass.
#
# MAINTAINING THE CONTRACT
#   REQUIRED_CMDS is the set of daemon subcommands install.sh invokes. Regenerate
#   after any install.sh change with:
#     grep -oE '(\$ASSISTANT_BINARY|ostler-assistant)[[:space:]]+[a-z-]+' install.sh
#     grep -E '<string>(daemon|run-source|setup|doctor)</string>' install.sh   # plist ProgramArguments
# ============================================================================
set -euo pipefail

# --- the contract: every daemon subcommand install.sh depends on -------------
# (run-source is the one v1.0.14 shipped without.)
REQUIRED_CMDS=(run-source daemon setup doctor)
# run-source must additionally accept the ingest source enum install.sh passes:
REQUIRED_RUN_SOURCE_ARGS=(imessage fda-rerun aiconv)

GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
ok()  { printf '%b  OK%b   %s\n' "$GREEN" "$RST" "$*"; }
bad() { printf '%bFAIL%b   %s\n' "$RED" "$RST" "$*" >&2; }
die() { bad "$*"; exit 2; }

MODE=""; TARGET=""; SSH_HOST="${HOST:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --daemon)        MODE=local;  TARGET="${2:-}"; shift 2 ;;
    --remote-daemon) MODE=remote; TARGET="${2:-}"; shift 2 ;;
    --dmg)           MODE=dmg;    TARGET="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,50p' "$0"; exit 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ -n "$MODE" && -n "$TARGET" ]] || die "usage: $0 --daemon <path> | --dmg <path> | --remote-daemon <path> (HOST=...)"

# --- resolve a runner that executes "<daemon> <args...>" ----------------------
DAEMON=""
cleanup(){ [[ -n "${_MOUNT:-}" ]] && hdiutil detach "$_MOUNT" >/dev/null 2>&1 || true; }
trap cleanup EXIT
if [[ "$MODE" == dmg ]]; then
  [[ -f "$TARGET" ]] || die "DMG not found: $TARGET"
  _MOUNT="$(hdiutil attach "$TARGET" -nobrowse -readonly 2>&1 | tail -1 | awk -F'\t' '{print $NF}')"
  [[ -d "$_MOUNT" ]] || die "mount failed for $TARGET"
  DAEMON="$_MOUNT/OstlerInstaller.app/Contents/Resources/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
  [[ -e "$DAEMON" ]] || DAEMON="$_MOUNT/OstlerInstaller.app/Contents/Resources/assistant-agent/bin/ostler-assistant"
fi
[[ "$MODE" == local  ]] && DAEMON="$TARGET"
[[ "$MODE" == remote ]] && DAEMON="$TARGET"

run_help() {  # $1=subcmd  -> exit status of "<daemon> <subcmd> --help"
  if [[ "$MODE" == remote ]]; then
    [[ -n "$SSH_HOST" ]] || die "--remote-daemon needs HOST=user@host"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" "'$DAEMON' $1 --help" >/dev/null 2>&1
  else
    [[ -x "$DAEMON" ]] || die "daemon not found/executable: $DAEMON"
    "$DAEMON" $1 --help >/dev/null 2>&1
  fi
}

echo "=============================================================="
echo " DAEMON CAPABILITY GATE  --  $DAEMON"
echo "=============================================================="
missing=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  if run_help "$cmd"; then ok "subcommand present: $cmd"
  else bad "subcommand MISSING: $cmd"; missing+=("$cmd"); fi
done
# run-source source-enum contract (only meaningful if run-source itself exists)
if run_help "run-source"; then
  for src in "${REQUIRED_RUN_SOURCE_ARGS[@]}"; do
    if run_help "run-source $src"; then ok "run-source accepts: $src"
    else bad "run-source REJECTS source: $src"; missing+=("run-source $src"); fi
  done
fi

echo "--------------------------------------------------------------"
if (( ${#missing[@]} == 0 )); then
  ok "daemon supports every command install.sh invokes -- cut may proceed."
  exit 0
fi
bad "DAEMON CAPABILITY GATE FAILED -- missing: ${missing[*]}"
printf '%s\n' \
  "  The bundled daemon cannot do what install.sh calls. Installing it would" \
  "  fail (or silently break ingest) on the customer's Mac -- this is the" \
  "  ERR-11-DAEMON-RUN-SOURCE-SKEW class (v1.0.14)." \
  "  FIX: rebuild the daemon from a lineage that has these commands (the" \
  "  v1.0.10 ingest-reroute cluster must be present), then re-cut." >&2
exit 1
