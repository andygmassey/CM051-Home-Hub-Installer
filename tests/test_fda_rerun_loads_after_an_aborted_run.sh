#!/usr/bin/env bash
# NEW-119: an aborted install followed by a re-run must leave com.ostler.fda-rerun LOADED.
#
# THE DEFECT, MEASURED on the Mini 16, macOS 27.2, 2026-10-29 (diag118 rerun A).
# Run 1 wrote ~/Library/LaunchAgents/com.ostler.fda-rerun.plist and aborted
# before the deferred load. The customer re-ran, as ERR-13 tells them to. After
# the re-run:
#   launchctl print gui/<uid>/com.ostler.fda-rerun -> exit 113
#   the plist                                       -> present
#   install log                                      -> neither the scheduled nor
#                                                       the not-scheduled line
# The re-run found the plist present and current, so no rewrite trigger fired
# and _OSTLER_FDA_RERUN_LOAD_PENDING was never set; the quiesce sets it only when
# it boots out a LOADED job, and this one was not loaded. The hourly re-run was
# gone for good.
#
# WHAT THIS RUNS. The two real install.sh blocks, extracted by landmark: the
# plist decision (from the interval default to the end of the FDA branch) and
# the deferred load. launchctl is stubbed over a state directory, so `print`
# answers from what bootstrap/bootout actually did. The load helper is stubbed
# to bootout + bootstrap + `launchctl print`, the same oracle the real helper
# uses. Run 1 executes ONLY the decision block and then stops (the abort). Run 2
# is a fresh shell over the same HOME and executes both blocks.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO}/install.sh"
[ -f "$SRC" ] || { echo "CANNOT-RUN: no install.sh at ${SRC}" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

extract() {   # $1 = install.sh path, $2 = out dir; writes decide.sh + load.sh
  python3 - "$1" "$2" <<'PYEOF'
import sys, pathlib
src = open(sys.argv[1], encoding="utf-8").read().split("\n")
out = pathlib.Path(sys.argv[2])
start = next((i for i, l in enumerate(src)
              if l.strip() == ': "${OSTLER_FDA_RERUN_INTERVAL_S:=3600}"'), None)
end = None
if start is not None:
    for i in range(start, len(src) - 1):
        if src[i] == "else" and "Reachable only when --allow-plaintext" in src[i + 1]:
            end = i
            break
lstart = next((i for i, l in enumerate(src)
               if l.startswith("# ── THE DEFERRED fda-rerun LOAD")), None)
lend = None
if lstart is not None:
    lend = next((i for i in range(lstart, len(src)) if src[i] == "fi"), None)
if None in (start, end, lstart, lend):
    print("missing", start, end, lstart, lend); raise SystemExit(2)
(out / "decide.sh").write_text("\n".join(src[start:end]) + "\n")
(out / "load.sh").write_text("\n".join(src[lstart:lend + 1]) + "\n")
print(end - start, lend - lstart + 1)
PYEOF
}

# One installer run over a persistent HOME and launchd state.
#   $1 = dir holding decide.sh/load.sh, $2 = HOME, $3 = launchd state dir,
#   $4 = "abort" (decision block only) | "full" (decision + deferred load)
run_install() {
  HOME="$2" ST="$3" MODE="$4" D="$1" bash -c '
    set -euo pipefail
    launchctl() {
      case "$1" in
        print)     [ -f "$ST/loaded" ] ;;
        bootstrap) echo x >> "$ST/bootstraps"; : > "$ST/loaded" ;;
        load)      echo x >> "$ST/bootstraps"; : > "$ST/loaded" ;;
        bootout)   rm -f "$ST/loaded" ;;
        unload)    rm -f "$ST/loaded" ;;
        *) return 0 ;;
      esac
    }
    _ostler_launchagent_load_verified() {
      launchctl bootout "gui/$(id -u)/$(basename "$1" .plist)" || true
      launchctl bootstrap "gui/$(id -u)" "$1"
      launchctl print "gui/$(id -u)/$(basename "$1" .plist)"
    }
    ok() { echo "OK: $*"; }
    warn() { echo "WARN: $*"; }
    info() { :; }
    MSG_WARN_FDA_RE_RUN_NOT_SCHEDULED="not scheduled"
    MSG_OK_FDA_RE_RUN_SCHEDULED_RECURRING="scheduled every %s min"
    OSTLER_DIR="$HOME/.ostler"; LOGS_DIR="$OSTLER_DIR/logs"
    mkdir -p "$OSTLER_DIR/bin" "$LOGS_DIR"
    . "$D/decide.sh"
    [ "$MODE" = "abort" ] && exit 0
    printf "#!/bin/sh\nexit 0\n" > "$OSTLER_DIR/bin/ostler-fda"; chmod +x "$OSTLER_DIR/bin/ostler-fda"
    . "$D/load.sh"
  '
}

loads() { [ -f "$1/bootstraps" ] && wc -l < "$1/bootstraps" | tr -d " " || echo 0; }
is_loaded() { [ -f "$1/loaded" ] && echo yes || echo no; }

# Scenario: abort-then-rerun. Echoes "<bootstraps after rerun> <loaded>".
abort_then_rerun() {   # $1 = extracted dir
  local h="$1/home" st="$1/st"; mkdir -p "$h" "$st"
  run_install "$1" "$h" "$st" abort >/dev/null || { echo "run1-died"; return; }
  [ -f "$h/Library/LaunchAgents/com.ostler.fda-rerun.plist" ] || { echo "run1-no-plist"; return; }
  [ "$(loads "$st")" = 0 ] || { echo "run1-loaded"; return; }
  run_install "$1" "$h" "$st" full >/dev/null || { echo "run2-died"; return; }
  echo "$(loads "$st") $(is_loaded "$st")"
}

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

mkdir -p "$WORK/subj"
sizes="$(extract "$SRC" "$WORK/subj")" || { echo "CANNOT-RUN: landmarks not found in install.sh ($sizes)" >&2; exit 2; }
echo "     EXAMINED: decision block + deferred load, ${sizes% *} + ${sizes#* } line(s) of install.sh"

# ---- THE SUBJECT, FIRST (a control must never short-circuit it). -------------
got="$(abort_then_rerun "$WORK/subj")"
if [ "$got" = "1 yes" ]; then
  ok "abort then re-run: the re-run loads com.ostler.fda-rerun exactly once and it is loaded at the end"
else
  bad "abort then re-run left bootstraps/loaded = '$got' (want '1 yes'). The plist is present and"
  bad "  current, so the re-run never sets the load flag and the hourly FDA re-run stays unregistered."
fi

# ---- CONTROL 1: already loaded and current -> NOT loaded again. --------------
mkdir -p "$WORK/subj/c1/home" "$WORK/subj/c1/st"
cp "$WORK/subj/decide.sh" "$WORK/subj/load.sh" "$WORK/subj/c1/"
run_install "$WORK/subj/c1" "$WORK/subj/c1/home" "$WORK/subj/c1/st" full >/dev/null || true
rm -f "$WORK/subj/c1/st/bootstraps"          # first install loaded it; now measure a re-run
run_install "$WORK/subj/c1" "$WORK/subj/c1/home" "$WORK/subj/c1/st" full >/dev/null || true
c1="$(loads "$WORK/subj/c1/st") $(is_loaded "$WORK/subj/c1/st")"
if [ "$c1" = "0 yes" ]; then
  ok "CONTROL (already loaded): a re-run over a loaded, current agent does not bootstrap it again"
else
  bad "CONTROL (already loaded): bootstraps/loaded = '$c1' (want '0 yes'): a healthy agent was re-loaded."
fi

# ---- CONTROL 2: a fresh install still loads once (the pre-existing path). ----
mkdir -p "$WORK/subj/c2/home" "$WORK/subj/c2/st"
cp "$WORK/subj/decide.sh" "$WORK/subj/load.sh" "$WORK/subj/c2/"
run_install "$WORK/subj/c2" "$WORK/subj/c2/home" "$WORK/subj/c2/st" full >/dev/null || true
c2="$(loads "$WORK/subj/c2/st") $(is_loaded "$WORK/subj/c2/st")"
if [ "$c2" = "1 yes" ]; then
  ok "CONTROL (fresh install): no plist -> written and loaded once"
else
  bad "CONTROL (fresh install): bootstraps/loaded = '$c2' (want '1 yes')."
fi

# ---- CONTROL 3: the mutant. Remove the launchctl-print limb; must go RED. ----
mkdir -p "$WORK/mut"
cp "$WORK/subj/decide.sh" "$WORK/mut/"
# The limb sits on the deferred load's condition (kept off the plist write so
# install.sh's line-number citations do not move). The mutant collapses that
# condition back to the flag alone.
python3 - "$WORK/subj/load.sh" "$WORK/mut/load.sh" <<'PYEOF'
import sys
L = open(sys.argv[1]).read().split("\n")
i = next((k for k, l in enumerate(L) if 'launchctl print "gui/$(id -u)/com.ostler.fda-rerun"' in l), None)
if i is not None:
    s = i
    while not L[s].startswith("if "): s -= 1
    L[s:i + 1] = ['if [[ "${_OSTLER_FDA_RERUN_LOAD_PENDING:-0}" == "1" ]]; then']
open(sys.argv[2], "w").write("\n".join(L))
PYEOF
if cmp -s "$WORK/subj/load.sh" "$WORK/mut/load.sh"; then
  if [ "$got" = "1 yes" ]; then
    bad "CONTROL (mutant): no launchctl-print limb to remove, yet the subject passed. Something"
    bad "                  else loads the agent and this gate is not measuring what it claims."
  else
    echo "  [ -- ] CONTROL (mutant): skipped, the limb is absent -- which IS the failure above"
  fi
else
  mut="$(abort_then_rerun "$WORK/mut")"
  if [ "$mut" = "0 no" ]; then
    ok "CONTROL (mutant): with the launchctl-print limb removed the re-run never loads it, so this gate can fail"
  else
    bad "CONTROL (mutant): removing the limb still gave '$mut'. The verdict above is void."
  fi
fi

echo
echo "== $PASS pass / $FAIL fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
