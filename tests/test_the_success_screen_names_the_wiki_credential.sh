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

# --- THE COUPLING PREDICATE, RE-DERIVED ----------------------------------
# 🔴 THIS TEST USED TO COUPLE TO THE WRONG FACT, and Andy's walk is what
# exposed it. Arm 5 asked "is ostler-wiki-auth.conf still installed?" and
# treated that as "does the customer meet a password box?". Those were the
# same fact when it was written and they are not any more.
#
# The credential still exists, and MUST: the daemon's wiki proxy presents it
# on its own loopback hop. What changed is that :8044 no longer CHALLENGES a
# browser. `auth_basic` answers an uncredentialled request with
# `401 + WWW-Authenticate: Basic`, and that header alone is what pops the
# box. install.sh now answers the empty-Authorization case in nginx's
# REWRITE phase, before the access phase runs, so auth_basic never fires and
# no challenge is emitted.
#
# So the question this test exists to ask -- "is the last click of a GUI
# install an unexplained password box?" -- is answered by the CHALLENGE, not
# by the credential. Measured on nginx 1.27-alpine, the pinned image: with
# the guard, an uncredentialled GET returns 403 and ZERO WWW-Authenticate
# headers; without it, 401 and one.
#
# Extract the `listen 8044` server block and ask it directly.
WIKI_BLOCK="$(awk '/^ *server \{$/{buf=""} {buf=buf $0 "\n"} /^ *\}$/{if (buf ~ /listen 8044;/) {printf "%s", buf; exit}}' "${INSTALL_SH}")"
if [ -z "${WIKI_BLOCK}" ]; then
    cant "could not extract the 'listen 8044' server block from install.sh, so the challenge question cannot be asked"
    finish
fi
# Positive control: the block we extracted must be the wiki one. A predicate
# that silently matched the wrong block would answer confidently and wrongly.
if ! printf '%s' "${WIKI_BLOCK}" | /usr/bin/grep -q 'ostler-wiki-auth.conf'; then
    cant "the extracted 8044 block does not include the wiki auth conf; the extractor matched the wrong block"
    finish
fi
CHALLENGES=yes
if printf '%s' "${WIKI_BLOCK}" | /usr/bin/grep -q 'http_authorization = ""'; then
    CHALLENGES=no
fi

if [ "${CHALLENGES}" = no ]; then
    # --- arm 3/4 (no-challenge form): the hint must NOT send the customer
    # hunting for a password, because no box will ever ask for one.
    if printf '%s' "${HINT}" | /usr/bin/grep -q 'wiki_password'; then
        bad "the hint still tells the customer where the wiki password is, but :8044 no longer asks a browser for one; that sends them to a file they do not need"
    else
        ok "the hint does not send the customer after a password they will never be asked for"
    fi
    # It must instead say where the wiki actually is. The Hub reaches it
    # through the daemon proxy, so the answer is the Ostler app.
    if printf '%s' "${HINT}" | /usr/bin/grep -qi 'ostler\|sidebar'; then
        ok "the hint names where the wiki actually opens (in the app)"
    else
        bad "the hint neither explains a password box nor says where the wiki opens, so the button is unexplained either way"
    fi
    # --- arm 5: COUPLING, restated on the real fact ----------------------
    ok ":8044 emits no challenge to a browser, so there is no password box for the success screen to explain"
else
    # --- arm 3: it names the username the htpasswd line actually writes ---
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

    # --- arm 4: it says where the password is ----------------------------
    if printf '%s' "${HINT}" | /usr/bin/grep -q 'wiki_password'; then
        ok "the hint says where the password is"
    else
        bad "the hint never names the wiki_password file, so it tells the customer nothing actionable"
    fi

    # --- arm 5: COUPLING --------------------------------------------------
    if [ "${_rc}" -eq 0 ]; then
        ok ":8044 still challenges a browser AND the success screen explains it"
    else
        bad ":8044 challenges a browser but the success screen does not explain it"
    fi
fi

# --- arm 5b: the button must not open the port that has no wiki for it ----
# Whatever the challenge state, "Open your Wiki" must not send the customer
# to a browser on :8044. With the challenge it was a password box; without
# it, it is a signpost telling them to go and open the app instead.
#
# Matches the CONSTRUCT, `URL(string: "http://localhost:8044"`, not the bare
# string. The block above this function explains the defect and necessarily
# quotes the old URL, and a substring grep cannot tell that comment from the
# code it describes -- it flagged exactly that on first run. Stripping `//`
# lines first would be the other classic wrong answer: it cannot see a
# trailing comment and would quietly shrink the subject.
_URLCALL='URL(string: "http://localhost:8044"'
# Positive control: the construct must exist in this file at all, or a zero
# below means "my pattern shape is wrong", not "the call is gone".
_ctl="$(/usr/bin/grep -cF 'URL(string: "' "${VIEW}")"
if [ "${_ctl}" -lt 1 ]; then
    cant "no 'URL(string: \"' construct found in InstallCompleteView.swift at all; the pattern shape cannot measure anything"
elif /usr/bin/grep -qF "${_URLCALL}" "${VIEW}"; then
    bad "InstallCompleteView.swift still opens a browser at :8044; the wiki is reached through the daemon proxy inside Ostler.app"
else
    ok "the success screen does not open a browser at :8044 (${_ctl} URL(string:) calls examined)"
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
