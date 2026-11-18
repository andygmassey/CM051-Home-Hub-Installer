#!/bin/sh
# lib/no_l3_preflight.sh -- runs ON THE BOX, before any seed. Prints PF_* key=value lines
# describing the RUNNING ical-server, for the walker's preflight to judge. Reads the
# service from launchctl and takes the .py path from its ProgramArguments: nothing is
# hard-coded. Reads files and process state only; changes nothing.
uid="$(id -u)"
svc="gui/${uid}/com.ostler.ical-server"
lp="$(launchctl print "${svc}" 2>/dev/null)"
pid="$(printf '%s\n' "${lp}" | awk '/^[[:space:]]*pid = /{print $3; exit}')"
script="$(printf '%s\n' "${lp}" | awk '/arguments = \{/{f=1;next} f&&/^[[:space:]]*\}/{exit} f{gsub(/^[[:space:]]+/,""); if ($0 ~ /\.py$/) {print; exit}}')"
running=0
if [ -n "${pid}" ] && [ -n "${script}" ] && [ -r "${script}" ] && kill -0 "${pid}" 2>/dev/null; then
    running=1
fi
echo "PF_RUNNING=${running}"
echo "PF_PID=${pid:-}"
if [ "${running}" = 1 ]; then
    sha="$(shasum -a 256 "${script}" | awk '{print $1}')"
    lstart="$(LC_ALL=C ps -o lstart= -p "${pid}" | tr -s ' ' | sed 's/^ //')"
    start_epoch="$(LC_ALL=C date -j -f '%a %b %e %T %Y' "${lstart}" +%s 2>/dev/null)"
    mtime_epoch="$(stat -f %m "${script}")"
    echo "PF_SHA=${sha}"
    echo "PF_START_EPOCH=${start_epoch:-}"
    echo "PF_START_ISO=$(LC_ALL=C date -u -r "${start_epoch:-0}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    echo "PF_MTIME_EPOCH=${mtime_epoch}"
    echo "PF_MTIME_ISO=$(LC_ALL=C date -u -r "${mtime_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
fi
