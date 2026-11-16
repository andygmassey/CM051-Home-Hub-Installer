#!/usr/bin/env bash
#
# tests/test_every_tier_lib_job_can_find_sysctl_in_its_plist_env.sh
#
# GUARD for the v1.0.121 derive defect (CM051 #3249). The tier lib reads load,
# cores and RAM with a bare `sysctl`, which macOS keeps in /usr/sbin. A job
# whose LaunchAgent PATH omits /usr/sbin reads '' / 0 and the tier gate defers
# (or picks the floor tier) for ever. #3249 fixed derive; this keeps the next
# job honest.
#
# DISCOVERY BY GREP, not a list. Every tracked shell wrapper that sources the
# tier lib is found; one that CALLS a sysctl-reading entry point
# (ostler_resource_tier_should_defer_nonessential, ostler_resource_tier_detect,
# ostler_rt_*) needs sysctl. One that only calls ostler_resource_tier_is_paused
# (a state-file read) is listed and does not. A wrapper that needs sysctl must
# have a LaunchAgent plist found for it; none found is a FAIL, never a skip,
# unless the wrapper is provably not installed (no plist and no mention in
# install.sh outside comments).
#
# PLIST: install.sh's own generated derive plist (function lifted and run in a
# sandbox HOME), and the shipped template next to each wrapper (<tree>/launchd/
# *.plist, which install.sh renders by sed without touching PATH). Its
# EnvironmentVariables are taken EXACTLY. A plist with no PATH gets launchd's
# default PATH=/usr/bin:/bin:/usr/sbin:/sbin (launchd.plist(5), EnvironmentVariables;
# measured on the v1.0.121 trial box: bundle ticks with no PATH read load and
# 10 cores, and `env -i PATH=<that default>` resolves /usr/sbin/sysctl).
# Under `env -i` + that env: `command -v sysctl` must resolve; on Darwin the
# tier lib must also read a numeric load and cores > 0 (hw.ncpu is a macOS
# key; on other hosts only the resolution is asserted, as in #3249).
#
# MUTANT (check M): derive's PATH is stripped of /usr/sbin in a copy of
# install.sh and this guard is re-run against it; it must exit 1.
# INSTALL_SH may point at another copy. Exit 0 pass, 1 fail, 2 cannot-run.
# Bash 3.2 portable. Synthetic only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3"; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
LAUNCHD_DEFAULT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/tier-jobs.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

# ---- the tier lib exactly as install.sh embeds it
sed -n '/<<.OSTLER_RESOURCE_TIER_EOF.$/,/^OSTLER_RESOURCE_TIER_EOF$/p' "$INSTALL_SH" | sed '1d;$d' > "${SANDBOX}/tier.sh"
/usr/bin/grep -q '^ostler_rt_loadavg_1m()' "${SANDBOX}/tier.sh" || { echo "CANNOT-RUN: embedded tier lib not found"; exit 2; }

# ---- DISCOVERY (git grep over tracked files; the repo being tested, not INSTALL_SH)
cd "$REPO" || exit 2
WRAPPERS="$(git grep -lE 'ostler-resource-tier|ostler_resource_tier_(should_defer_nonessential|detect)' -- '*.sh' \
    ':!tests' ':!scripts/tests' ':!lib' ':!scripts/box_walk_probes' ':!vendor/doctor' | sort)"
[ -n "$WRAPPERS" ] || { echo "CANNOT-RUN: discovery found no wrapper (git grep empty)"; exit 2; }
echo "discovered wrappers:"; echo "$WRAPPERS" | sed 's/^/    /'

# ---- plist -> "KEY=VALUE" lines + the PATH actually in force
plist_env() { # plist -> stdout env lines (always includes PATH)
    python3 -I - "$1" "$LAUNCHD_DEFAULT_PATH" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
e = dict(d.get("EnvironmentVariables", {}))
e.setdefault("PATH", sys.argv[2])
for k in sorted(e):
    print("%s=%s" % (k, e[k]))
PY
}
check_env() { # label plist
    local label="$1" plist="$2" line
    local -a envargs=()
    plist_env "$plist" > "${SANDBOX}/env.txt" 2>"${SANDBOX}/env.err" \
        || { bad "${label}: plist unparsable (${plist})"; return; }
    while IFS= read -r line; do envargs+=("$line"); done < "${SANDBOX}/env.txt"
    local pathline; pathline="$(/usr/bin/grep '^PATH=' "${SANDBOX}/env.txt")"
    local sp; sp="$(env -i "${envargs[@]}" /bin/bash -c 'command -v sysctl' 2>&1)"
    if [ -z "$sp" ]; then bad "${label}: sysctl NOT found under its plist env (${pathline})"; return; fi
    ok "${label}: sysctl -> ${sp} (${pathline})"
    if [ "$(uname -s)" = "Darwin" ]; then
        local load cores
        load="$(env -i "${envargs[@]}" /bin/bash -c ". '${SANDBOX}/tier.sh'; ostler_rt_loadavg_1m" 2>&1)"
        cores="$(env -i "${envargs[@]}" /bin/bash -c ". '${SANDBOX}/tier.sh'; ostler_rt_cpu_cores" 2>&1)"
        case "$load" in ''|*[!0-9.]*|.|*.*.*) bad "${label}: load not a number: '${load}'" ;; *) ok "${label}: load ${load}" ;; esac
        case "$cores" in ''|*[!0-9]*|0) bad "${label}: cores not > 0: '${cores}'" ;; *) ok "${label}: cores ${cores}" ;; esac
    fi
}

NEEDS=0
for f in $WRAPPERS; do
    if [ "$f" = "install.sh" ]; then
        # derive: the plist install.sh GENERATES.
        NEEDS=$((NEEDS + 1))
        start="$(/usr/bin/grep -nE '^_install_derive_preferences_agent\(\) \{' "$INSTALL_SH" | head -1 | cut -d: -f1)"
        [ -n "$start" ] || { bad "install.sh sources the tier lib but _install_derive_preferences_agent not found"; continue; }
        lifted=""
        for end in $(awk -v s="$start" 'NR > s && /^\}/ { print NR }' "$INSTALL_SH"); do
            sed -n "${start},${end}p" "$INSTALL_SH" > "${SANDBOX}/agent.sh"
            if bash -n "${SANDBOX}/agent.sh" 2>/dev/null; then lifted=1; break; fi
        done
        [ -n "$lifted" ] || { bad "could not lift _install_derive_preferences_agent"; continue; }
        BIN="${SANDBOX}/bin"; mkdir -p "$BIN"
        printf '#!/bin/sh\nexit 0\n' > "${BIN}/launchctl"; chmod +x "${BIN}/launchctl"
        H="${SANDBOX}/home"; O="${H}/.ostler"; mkdir -p "${O}/logs" "${H}/Library/LaunchAgents"
        (
            export HOME="$H" PATH="${BIN}:${PATH}"
            OSTLER_DIR="$O"; LOGS_DIR="${O}/logs"
            ok() { :; }; warn() { :; }; info() { :; }; _ks_bounded() { :; }
            # shellcheck source=/dev/null
            . "${SANDBOX}/agent.sh"
            _install_derive_preferences_agent
        ) >/dev/null 2>&1
        P="${H}/Library/LaunchAgents/com.ostler.derive-preferences.plist"
        if [ -f "$P" ]; then check_env "derive-preferences (generated by install.sh)" "$P"
        else bad "derive: the function wrote no plist"; fi
        continue
    fi
    if ! /usr/bin/grep -qE 'ostler_resource_tier_(should_defer_nonessential|detect)|ostler_rt_' "$f"; then
        echo "  info ${f}: sources the tier lib, calls no sysctl-reading entry point (state-file reads only); not subject"
        continue
    fi
    NEEDS=$((NEEDS + 1))
    tree="$(dirname "$(dirname "$f")")"
    plists="$(ls "${tree}"/launchd/*.plist 2>/dev/null)"
    if [ -z "$plists" ]; then
        base="$(basename "$f" .sh)"
        if git grep -qE "^[^#]*${base}" -- install.sh '*.plist' 2>/dev/null; then
            bad "${f}: needs sysctl and is referenced by install.sh or a plist, but no plist template was found next to it"
        else
            echo "  info ${f}: no plist and not referenced outside comments: not installed, not subject"
            NEEDS=$((NEEDS - 1))
        fi
        continue
    fi
    for p in $plists; do check_env "${f} -> ${p}" "$p"; done
done

if [ "$NEEDS" -ge 5 ]; then ok "denominator: ${NEEDS} sysctl-reading jobs examined (derive + 4 bundle ticks + any others)"
else bad "denominator: only ${NEEDS} sysctl-reading jobs examined, expected at least 5 (derive and the four bundle ticks); the discovery is blind"; fi

# ---- MUTANT: strip /usr/sbin from derive's PATH, the guard must go RED
if [ -z "${TIER_GUARD_IN_MUTANT:-}" ]; then
    sed '/<string>\/usr\/local\/bin:\/opt\/homebrew\/bin:\/usr\/bin:\/bin:\/usr\/sbin:\/sbin<\/string>/s|:/usr/sbin:/sbin||' "$INSTALL_SH" > "${SANDBOX}/install.mutant.sh"
    if cmp -s "$INSTALL_SH" "${SANDBOX}/install.mutant.sh"; then
        bad "M the mutant did not apply (no derive PATH line carried /usr/sbin)"
    else
        TIER_GUARD_IN_MUTANT=1 INSTALL_SH="${SANDBOX}/install.mutant.sh" bash "${BASH_SOURCE[0]}" >"${SANDBOX}/mutant.out" 2>&1
        mrc=$?
        if [ "$mrc" -eq 1 ] && /usr/bin/grep -q 'FAIL derive-preferences\|FAIL .*derive' "${SANDBOX}/mutant.out"; then
            ok "M mutant (derive PATH without /usr/sbin) is RED, rc=1, and names derive"
        else
            bad "M mutant was not caught (rc=${mrc})"; tail -5 "${SANDBOX}/mutant.out"
        fi
    fi
fi

echo "pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
