#!/usr/bin/env bash
# probes/ostler_launchd_jobs_loaded_and_exit_clean.sh
# ============================================================================
# QUESTION: is EVERY Ostler LaunchAgent / LaunchDaemon on the box actually
#           loaded, and did its last run exit 0?
#
# WHY. `launchctl load` exits 0 ON FAILURE, so "the installer loaded it" proves
# nothing. Only `launchctl print` carries the two facts that do: whether the
# label is in the domain at all, and "last exit code". Before this probe the
# suite asked that of ONE label (com.ostler.fda-rerun, inside ingest_coverage);
# every other Ostler job could be unloaded or dying on every fire and no probe
# would say so.
#
# DENOMINATOR: every plist whose file name contains "ostler" in
# ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons,
# read ON THE BOX. Its Label is read from the plist (file name as fallback).
#
# VERDICT per label, from `launchctl print <domain>/<label>`:
#   NOT-LOADED   print fails: the plist is on disk, launchd does not know it.  FAIL
#   EXIT-<n>     not running and last exit code n != 0.                       FAIL
#   OK           last exit code 0.
#   RUNNING      running now (KeepAlive); a non-zero code from an EARLIER
#                instance is named as a note, not failed.
#   NEVER-RAN    "(never exited)" and not running: an interval job inside its
#                first interval (ingest_coverage's v1.0.82 lesson). Named, ok.
#   DISABLED     launchctl print-disabled lists it disabled. Named, ok.
# Zero plists found is CANNOT-RUN, never PASS.
#
# macOS bash 3.2 + BSD userland. British English; no em dashes.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="ostler_launchd_jobs_loaded_and_exit_clean"
PROBE_QUESTION="is every Ostler LaunchAgent/Daemon loaded (launchctl print), with last exit code 0?"

# Runs ON THE BOX, under whatever login shell ssh gives (zsh on a customer Mac):
# NO shell glob, because zsh aborts the whole loop on an unmatched one ("no matches
# found" on an empty /Library/LaunchAgents) and the probe then checked 0 jobs.
# One line per plist: label TAB domain TAB state TAB lastexit TAB disabled
_LAUNCHD_READ='uid=$(id -u)
dis=$(launchctl print-disabled "gui/$uid" 2>/dev/null; launchctl print-disabled system 2>/dev/null)
find "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons -maxdepth 1 -name "*.plist" 2>/dev/null | while IFS= read -r f; do
  [ -e "$f" ] || continue
  b=$(basename "$f" .plist)
  case "$b" in *ostler*|*Ostler*) ;; *) continue ;; esac
  lab=$(/usr/libexec/PlistBuddy -c "Print :Label" "$f" 2>/dev/null)
  [ -n "$lab" ] || lab=$b
  case "$f" in /Library/LaunchDaemons/*) dom=system ;; *) dom="gui/$uid" ;; esac
  st=-; le=-
  if out=$(launchctl print "$dom/$lab" 2>&1); then
    st=$(printf "%s\n" "$out" | awk -F" = " "/^\tstate = /{print \$2; exit}")
    le=$(printf "%s\n" "$out" | awk -F" = " "/^\tlast exit code = /{print \$2; exit}")
  else
    st=NOTLOADED
  fi
  d=no
  case "$dis" in *"\"$lab\" => disabled"*|*"\"$lab\" => true"*) d=yes ;; esac
  printf "%s\t%s\t%s\t%s\t%s\n" "$lab" "$dom" "${st:-?}" "${le:-?}" "$d"
done'

# adjudicate: reads the box lines on stdin, prints per-label rows and ONE final
# line: PASS <text> | FAIL <text> | CANNOT_RUN <text>. Pure, so self_test and
# run_probe share it.
adjudicate() {
    awk -F'\t' '
    NF < 5 { next }
    {
        n++; lab=$1; st=$3; le=$4; dis=$5
        code=le; sub(/:.*/, "", code); gsub(/ /, "", code)
        if (dis == "yes")            { v="DISABLED" }
        else if (st == "NOTLOADED")  { v="NOT-LOADED"; bad++ }
        else if (st == "running")    { v="RUNNING"; if (code != "0" && code !~ /^\(never/ && code != "-" && code != "?") v="RUNNING (an earlier instance exited " le ")" }
        else if (code == "0")        { v="OK" }
        else if (code ~ /^\(never/)  { v="NEVER-RAN" }
        else if (code ~ /^-?[0-9]+$/) { v="EXIT-" le; bad++ }
        else                         { v="UNREADABLE(last exit code=" le ")"; unread++ }
        printf "    %-58s %-12s %s\n", lab, $2, v
        if (v == "NOT-LOADED" || v ~ /^EXIT-/) badl = badl " " lab "(" v ")"
    }
    END {
        if (n == 0) { print "CANNOT_RUN no Ostler plist found in ~/Library/LaunchAgents, /Library/LaunchAgents or /Library/LaunchDaemons on the box: zero labels checked is not a pass"; exit }
        if (bad > 0) { printf "FAIL %d of %d Ostler launchd job(s) are not loaded or last exited non-zero:%s\n", bad, n, badl; exit }
        if (unread > 0) { printf "CANNOT_RUN %d of %d label(s) printed no readable last exit code\n", unread, n; exit }
        printf "PASS all %d Ostler launchd job(s) are loaded and none is stopped on a non-zero exit\n", n
    }'
}

_decide() {
    local lines="$1" v token detail
    v="$(printf '%s\n' "$lines" | adjudicate)"
    printf '%s\n' "$v" | sed '$d'
    v="$(printf '%s\n' "$v" | tail -n 1)"
    token="${v%% *}"; detail="${v#* }"
    probe_examined "$(printf '%s\n' "$lines" | awk -F'\t' 'NF>=5{n++} END{print n+0}')" "Ostler launchd plists, each asked with launchctl print"
    case "$token" in
        PASS)       probe_pass "$detail" ;;
        FAIL)       probe_fail "$detail" ;;
        CANNOT_RUN) probe_cannot_run "$detail" ;;
        *)          probe_fail "adjudicator returned an unrecognised line: ${v}" ;;
    esac
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "the box (${OSTLER_BOX_HOST:-local}) did not answer over ssh; no launchd job was read"
    fi
    _decide "$(box_run "$_LAUNCHD_READ")"
}

self_test() {
    probe_examined 5 "synthetic launchctl print readings (negative control)"
    local T=$'\t' good bad
    good="com.ostler.doctor${T}gui/501${T}running${T}(never exited)${T}no
com.ostler.fda-rerun${T}gui/501${T}not running${T}0${T}no
com.ostler.music-refresh${T}gui/501${T}not running${T}(never exited)${T}no
com.creativemachines.ostler.tailscaled${T}system${T}running${T}15: Terminated${T}no
com.ostler.stay-awake${T}gui/501${T}NOTLOADED${T}-${T}yes"
    case "$(printf '%s\n' "$good" | adjudicate | tail -n 1)" in
        PASS*) : ;;
        *) probe_pass "NEGATIVE CONTROL OVER-FIRED: loaded/exit-0/never-ran/running/disabled labels were not PASS. This probe would red a healthy box." ;;
    esac
    bad="${good}
com.ostler.enrich${T}gui/501${T}not running${T}1${T}no"
    case "$(printf '%s\n' "$bad" | adjudicate | tail -n 1)" in
        FAIL*com.ostler.enrich*) : ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a stopped job with last exit code 1 was not FAIL." ;;
    esac
    bad="${good}
com.ostler.ical-server${T}gui/501${T}NOTLOADED${T}-${T}no"
    case "$(printf '%s\n' "$bad" | adjudicate | tail -n 1)" in
        FAIL*com.ostler.ical-server*) : ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: a plist launchd does not know (the load call exits 0 on failure) was not FAIL." ;;
    esac
    bad="${good}
com.ostler.export-scan${T}gui/501${T}not running${T}78: EX_CONFIG${T}no"
    case "$(printf '%s\n' "$bad" | adjudicate | tail -n 1)" in
        FAIL*com.ostler.export-scan*) : ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: last exit code = 78: EX_CONFIG was not FAIL." ;;
    esac
    case "$(printf '' | adjudicate | tail -n 1)" in
        CANNOT_RUN*) : ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: zero plists was not CANNOT-RUN." ;;
    esac
    probe_fail "negative control behaved correctly on 5 readings (healthy set PASSes; exit 1, NOT-LOADED and EX_CONFIG FAIL; zero plists CANNOT-RUN)"
}

probe_main "$@"
