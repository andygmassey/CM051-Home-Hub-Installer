#!/usr/bin/env bash
# CM051 #1725 -- the last click of a GUI install must not be an unexplained
# password box.
#
# THE DEFECT THIS GUARDS. #1594/#1609 put auth_basic on :8044, correctly:
# before it, any second local account could GET the whole compiled personal
# wiki. tests/test_the_wiki_port_demands_a_credential.sh guards that the
# restriction is ON. Nothing guarded the complement -- that the person who
# just installed can still GET IN.
#
# The installer's success screen ends with a button, "Open your Wiki", which
# opens http://localhost:8044. Since #1609 that opens a browser credential
# prompt. Measured on the GUI tree at df19895f: ZERO mentions of the
# credential anywhere under gui/, against a control of 10 files mentioning
# "wiki" and 10 mentioning "password" -- every one of the latter being the
# admin password, the SQLCipher passphrase or a Google app password.
#
# install.sh's own terminal banner does this properly: it prints the
# username, the password, and copies it to the clipboard. That banner has no
# gui_active guard so it still RUNS under OSTLER_GUI=1 -- it just lands in
# the scrolling log, hours of install before the button that needs it, and
# not on the screen the customer is looking at.
#
# ARM 5 IS THE COUPLING ARM and it is why this is a property test rather
# than a string test: the hint is only REQUIRED while :8044 actually demands
# a credential. If a future change removes auth_basic, this test stops
# demanding the copy instead of going stale and being deleted.
#
# ARM 6 IS THE MUST-FAIL ARM: it removes the key from a COPY and asserts
# arm 2 goes red on it. Without it every arm above could be passing because
# it resolves nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
VIEW="${REPO}/gui/OstlerInstaller/Views/InstallCompleteView.swift"
COPY="${REPO}/gui/OstlerInstaller/Resources/ViewCopy.json"
INSTALL_SH="${REPO}/install.sh"
KEY="wiki_signin_hint"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
# CANNOT-RUN is neither PASS nor FAIL: three outcomes, three branches (#1239).
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

finish() {
    printf '== %s pass / %s fail / %s cannot-run ==\n' "${PASS}" "${FAIL}" "${CANT}"
    [ "${FAIL}" -gt 0 ] && exit 1
    [ "${CANT}" -gt 0 ] && exit 2
    exit 0
}

for f in "${VIEW}" "${COPY}" "${INSTALL_SH}"; do
    [ -r "${f}" ] || { cant "unreadable: ${f}"; finish; }
done

# A validator passes on an empty subject. Assert floors before believing any
# zero below -- a truncated checkout must read CANNOT-RUN, never PASS.
_vl="$(wc -l < "${VIEW}" | tr -d ' ')"
_cl="$(wc -l < "${COPY}" | tr -d ' ')"
[ "${_vl}" -ge 200 ] || { cant "InstallCompleteView.swift is only ${_vl} lines; refusing to measure a truncated subject"; finish; }
[ "${_cl}" -ge 100 ] || { cant "ViewCopy.json is only ${_cl} lines; refusing to measure a truncated subject"; finish; }

# --- arm 1: the view renders the hint -------------------------------------
if /usr/bin/grep -q "install_complete\.${KEY}" "${VIEW}"; then
    ok "the success view renders install_complete.${KEY}"
else
    bad "InstallCompleteView.swift never references install_complete.${KEY}; the button opens a password box with nothing beside it"
fi

# --- arm 2: the copy exists (this is the arm the must-fail arm flips) ------
copy_key_present() {
    python3 - "$1" "${KEY}" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
sys.exit(0 if d.get("install_complete", {}).get(sys.argv[2], "").strip() else 1)
PY
}
copy_key_present "${COPY}"; _rc=$?
if [ "${_rc}" -eq 0 ]; then
    ok "ViewCopy.json defines a non-empty install_complete.${KEY}"
elif [ "${_rc}" -eq 2 ]; then
    cant "ViewCopy.json did not parse as JSON"
else
    bad "ViewCopy.json has no non-empty install_complete.${KEY}"
fi

HINT="$(python3 -c "
import json,sys
d=json.load(open('${COPY}',encoding='utf-8'))
sys.stdout.write(d.get('install_complete',{}).get('${KEY}',''))
" 2>/dev/null)"

# --- arm 3: it names the username the htpasswd line actually writes --------
# Read the username from install.sh rather than hardcoding it here, so a
# rename cannot leave this test asserting a stale value that still passes.
USERNAME="$(/usr/bin/grep -oE "printf '[a-z]+:%s" "${INSTALL_SH}" | head -1 | sed "s/printf '//; s/:%s//")"
if [ -z "${USERNAME}" ]; then
    cant "could not read the htpasswd username out of install.sh; not assuming one"
elif printf '%s' "${HINT}" | /usr/bin/grep -q "${USERNAME}"; then
    ok "the hint names the username install.sh writes (${USERNAME})"
else
    bad "the hint does not name the username install.sh writes (${USERNAME})"
fi

# --- arm 4: it says where the password is ---------------------------------
if printf '%s' "${HINT}" | /usr/bin/grep -q 'wiki_password'; then
    ok "the hint says where the password is"
else
    bad "the hint never names the wiki_password file, so it tells the customer nothing actionable"
fi

# --- arm 5: COUPLING. Required only while :8044 demands a credential -------
if /usr/bin/grep -q 'ostler-wiki-auth.conf' "${INSTALL_SH}"; then
    if [ "${_rc}" -eq 0 ]; then
        ok ":8044 still demands a credential AND the success screen explains it"
    else
        bad ":8044 demands a credential (ostler-wiki-auth.conf is still installed) but the success screen does not explain it"
    fi
else
    ok "install.sh no longer installs the wiki auth include, so the hint is not required"
fi

# --- arm 6: MUST-FAIL. Remove the key from a copy, arm 2 must go red ------
_tmp="$(mktemp -t viewcopy)" || { cant "mktemp failed"; finish; }
trap 'rm -f "${_tmp}"' EXIT
python3 - "${COPY}" "${_tmp}" "${KEY}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d.get("install_complete", {}).pop(sys.argv[3], None)
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PY
if [ ! -s "${_tmp}" ]; then
    cant "could not build the mutant copy; the must-fail arm did not run"
else
    copy_key_present "${_tmp}"; _mrc=$?
    if [ "${_mrc}" -eq 1 ]; then
        ok "must-fail arm: with the key removed, arm 2's predicate goes red"
    else
        bad "must-fail arm: arm 2's predicate returned ${_mrc} on a copy with the key REMOVED, so it proves nothing"
    fi
fi

finish
