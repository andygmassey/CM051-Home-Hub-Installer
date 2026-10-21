#!/usr/bin/env bash
#
# tests/test_derive_preferences_is_scheduled.sh
#
# "What you like" has a PRODUCER on the box: some LaunchAgent the installer
# writes runs the preference-derivation engine.
#
# THE DEFECT. The wiki page (CM044 what_you_like) and the assistant tool
# (pwg_derived_preferences) both read the derived named graph, and nothing on
# a customer's Mac ever wrote it. The engine was not vendored, and once it was,
# nothing called it. So the feature shipped dark: an empty graph on every box.
#
# WHAT THIS PINS, against the REAL install.sh rather than a reading of it:
#
#   A  GENERATED SET. Every `_install_*_agent` function in install.sh is lifted
#      out and run for real in a sandboxed HOME, with launchctl stubbed. The
#      LaunchAgents they write are the generated launchd set. Following each
#      plist's ProgramArguments into the wrapper it names, at least one must
#      invoke `services.enrich.src.derive_runner`. Enumerated, not named: a
#      test that looked only for the function this change adds could not be
#      red before it existed.
#   B  that agent is a background citizen: ProcessType=Background, a
#      StartInterval, RunAtLoad false, and PYTHONPYCACHEPREFIX in its own
#      environment (launchd passes no other).
#   C  install.sh CALLS the installer, after the cm019 venv is set up (the
#      agent runs that venv's python) and not inside the enrichment-consent
#      branch (derivation is local only and must not depend on that answer).
#   D  the wrapper RUNS: executed against a stub interpreter, it invokes the
#      runner module with --user-id, from the cm019 tree. And the runner
#      module it names exists in the vendored tree that ships.
#
# RED TODAY: on origin/main before this change, arm A finds the enrichment
# agent and the dedupe catch-up agent and no derive invocation.
#
# INSTALL_SH may be overridden to point at another copy (that is how the red
# was watched). Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2 portable.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${REPO_ROOT}/install.sh}"
RUNNER="${REPO_ROOT}/vendor/cm019_preferences/services/enrich/src/derive_runner.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }

SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/derive-sched.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

FUNCS="$(grep -oE '^_install_[a-z_]*agent\(\) \{' "$INSTALL_SH" | sed 's/() {//')"
NFUNCS="$(printf '%s\n' "$FUNCS" | grep -c . || true)"
if [ "${NFUNCS:-0}" -lt 1 ]; then
    echo "CANNOT-RUN: no _install_*_agent function found in $INSTALL_SH; the enumeration is blind"
    exit 2
fi

echo "A: the generated launchd set (${NFUNCS} installer function(s): $(echo $FUNCS))"
HOME_S="${SANDBOX}/home"
BIN_S="${SANDBOX}/stubbin"
mkdir -p "$HOME_S" "$BIN_S"
cat > "${BIN_S}/launchctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${BIN_S}/launchctl"

# Lift one function out of install.sh. Its body can hold heredocs with their
# own column-0 `}` (the enrichment tick wrapper does), so the end is the FIRST
# column-0 `}` at which the text parses as a complete function, not merely the
# first one.
lift_function() { # name -> stdout
    local name="$1" start end
    start="$(grep -nE "^${name}\(\) \{" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    [ -n "$start" ] || return 1
    for end in $(awk -v s="$start" 'NR > s && /^\}/ { print NR }' "$INSTALL_SH"); do
        sed -n "${start},${end}p" "$INSTALL_SH" > "${SANDBOX}/lift.sh"
        if bash -n "${SANDBOX}/lift.sh" 2>/dev/null; then
            cat "${SANDBOX}/lift.sh"
            return 0
        fi
    done
    return 1
}

for f in $FUNCS; do
    body="${SANDBOX}/${f}.sh"
    lift_function "$f" > "$body" || { echo "CANNOT-RUN: could not lift $f from $INSTALL_SH"; exit 2; }
    (
        export HOME="$HOME_S" PATH="${BIN_S}:${PATH}"
        OSTLER_DIR="${HOME_S}/.ostler"
        LOGS_DIR="${OSTLER_DIR}/logs"
        SCRIPT_DIR="${SANDBOX}/payload"
        mkdir -p "$OSTLER_DIR" "$LOGS_DIR" "$SCRIPT_DIR"
        ok() { :; }; warn() { :; }; info() { :; }
        # shellcheck source=/dev/null
        . "$body"
        "$f"
    ) >/dev/null 2>&1 || true
done

PLISTS="$(ls "${HOME_S}/Library/LaunchAgents/"*.plist 2>/dev/null || true)"
NPLISTS="$(printf '%s\n' "$PLISTS" | grep -c . || true)"
if [ "${NPLISTS:-0}" -lt 1 ]; then
    echo "CANNOT-RUN: the installer functions wrote no plist at all; the sandbox is not exercising them"
    exit 2
fi
ok "control: ${NPLISTS} plist(s) generated, so the sandbox runs the real functions"

DERIVE_PLIST=""
DERIVE_WRAPPER=""
for p in $PLISTS; do
    for prog in $(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$p" \
                  | sed -n 's:.*<string>\(.*\)</string>.*:\1:p'); do
        if [ -f "$prog" ] && grep -q 'services\.enrich\.src\.derive_runner' "$prog"; then
            DERIVE_PLIST="$p"; DERIVE_WRAPPER="$prog"
        fi
    done
done
if [ -n "$DERIVE_PLIST" ]; then
    ok "derive invocation found: $(basename "$DERIVE_PLIST") -> $(basename "$DERIVE_WRAPPER")"
else
    bad "no generated LaunchAgent invokes services.enrich.src.derive_runner (generated: $(for p in $PLISTS; do basename "$p" .plist; done | tr '\n' ' '))"
fi

echo "B: it is a background citizen"
if [ -n "$DERIVE_PLIST" ]; then
    grep -q '<string>Background</string>' <<< "$(grep -A1 '<key>ProcessType</key>' "$DERIVE_PLIST")" \
        && ok "ProcessType Background" || bad "ProcessType is not Background"
    grep -q '<key>StartInterval</key>' "$DERIVE_PLIST" \
        && ok "has a StartInterval (re-runs on a cadence)" || bad "no StartInterval"
    grep -q '<false/>' <<< "$(grep -A1 '<key>RunAtLoad</key>' "$DERIVE_PLIST")" \
        && ok "RunAtLoad false (first pass after the install's import)" || bad "RunAtLoad is not false"
    grep -q '<key>PYTHONPYCACHEPREFIX</key>' "$DERIVE_PLIST" \
        && ok "PYTHONPYCACHEPREFIX in the plist environment" || bad "no PYTHONPYCACHEPREFIX"
else
    bad "skipped: no derive agent to inspect"
fi

echo "C: install.sh calls it in the right place"
if [ -n "$DERIVE_PLIST" ]; then
    fn="$(for f in $FUNCS; do
            grep -q 'derive_runner' "${SANDBOX}/${f}.sh" && echo "$f"; done | head -1)"
    setup_line="$(grep -n 'progress "Setting up preference enrichment" "cm019_setup"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
    call_line="$(grep -nE "^[[:space:]]*${fn}[[:space:]]*$" "$INSTALL_SH" | head -1 | cut -d: -f1)"
    if [ -n "$call_line" ] && [ -n "$setup_line" ] && [ "$call_line" -gt "$setup_line" ]; then
        ok "${fn} is called (line ${call_line}) after cm019_setup (line ${setup_line})"
    else
        bad "${fn:-the derive installer} has no call site after cm019_setup (call=${call_line:-none} setup=${setup_line:-none})"
    fi
    if [ -n "$call_line" ]; then
        guard="$(sed -n "$((call_line - 3)),$((call_line - 1))p" "$INSTALL_SH")"
        if grep -q 'ENRICH' <<< "$guard"; then
            bad "the call sits under an enrichment-consent guard; derivation is local only"
        else
            ok "the call is not gated on the enrichment answer"
        fi
    fi
else
    bad "skipped: no derive agent"
fi

echo "D: the wrapper runs the shipped runner"
if [ -n "$DERIVE_WRAPPER" ]; then
    CM019="${SANDBOX}/cm019"
    mkdir -p "${CM019}/.venv/bin"
    cat > "${CM019}/.venv/bin/python3" <<EOF
#!/bin/sh
printf '%s\n' "\$PWD" "\$@" > "${SANDBOX}/invoked"
exit 0
EOF
    chmod +x "${CM019}/.venv/bin/python3"
    HOME="$HOME_S" OSTLER_DIR="${HOME_S}/.ostler" OSTLER_CM019_DIR="$CM019" \
        OSTLER_DERIVE_USER="synthetic_owner" OSTLER_INGEST_SLOT=0 OSTLER_RESOURCE_GOVERNOR=0 \
        bash "$DERIVE_WRAPPER" >/dev/null 2>&1
    if [ -f "${SANDBOX}/invoked" ]; then
        args="$(tr '\n' ' ' < "${SANDBOX}/invoked")"
        case "$args" in
            "${CM019} -m services.enrich.src.derive_runner --user-id synthetic_owner "*)
                ok "wrapper ran: ${args}" ;;
            *) bad "wrapper invoked something else: ${args}" ;;
        esac
    else
        bad "wrapper never invoked the cm019 interpreter"
    fi
else
    bad "skipped: no wrapper"
fi
[ -f "$RUNNER" ] && ok "the runner module ships: vendor/cm019_preferences/services/enrich/src/derive_runner.py" \
                 || bad "runner module missing from the vendored tree"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
