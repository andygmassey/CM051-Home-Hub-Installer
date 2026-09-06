#!/usr/bin/env bash
# CM051 #1660 -- :3000 must not hand the customer's AI chat history to any
# local account.
#
# THE DEFECT THIS GUARDS. The vane container published 127.0.0.1:3000 itself,
# with no `environment:` block and no credential anywhere. A second account on
# the owner's Mac could read `vane_data` -- the whole AI conversation history --
# and issue searches against the local model AS THEM, with one unauthenticated
# GET.
#
# WHY IT WAS OPEN. DECISION_550_what_shut_means_2026-08-28.md:107 deferred 3000
# to v1.0.1, and the reason recorded was that a browser surface "can take no
# bearer". #1594 refuted that premise and shipped the refutation on 8044: HTTP
# authentication is not a cookie, its protection space is scheme + AUTHORITY,
# and authority includes the port. The deferral's grounds were gone, so this
# closes the surface rather than inheriting the decision.
#
# THE WEBSOCKET ARMS ARE NOT DECORATION. Vane is a chat UI and its streaming
# legs are websockets. A proxy_pass without the Upgrade/Connection pair
# authenticates the page and then silently stops the conversation streaming,
# which is the worst kind of regression: it looks like it worked. nginx also
# refuses to start at all if the map is missing, which is measured in the last
# arm rather than asserted.
#
# ARM 8 IS THE ONE THAT KEEPS THE REST HONEST: it restores the shipped defect
# in a COPY and asserts arm 1 goes red on it. Without that, every structural arm
# above could be passing because it resolves nothing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
# CANNOT-RUN is neither PASS nor FAIL: three outcomes, three branches (#1239).
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

[ -r "${INSTALL_SH}" ] || { cant "install.sh unreadable at ${INSTALL_SH}"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

# A validator passes on an empty subject, so assert a floor before believing any
# zero below. install.sh is tens of thousands of lines; 10000 is a floor, not a
# measurement.
_lines="$(wc -l < "${INSTALL_SH}" | tr -d ' ')"
if [ "${_lines}" -lt 10000 ]; then
    cant "install.sh is only ${_lines} lines -- too small to be the real file, refusing to report zeros against it"
    echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2
fi

# ── the assertions, as a function so the mutation arm can re-run arm 1 ──────
vane_publishes_directly() {
    # The shipped defect: a `ports:` entry for 3000 inside the vane service.
    awk '/^  vane:/{v=1} v&&/^  [a-z_-]+:/&&!/^  vane:/{v=0} v&&/127\.0\.0\.1:3000:3000/{found=1} END{exit !found}' "$1"
}

echo "== :3000 must demand a credential =="
echo

# ARM 1 -- the defect itself
if vane_publishes_directly "${INSTALL_SH}"; then
    bad "arm 1: the vane service still publishes 127.0.0.1:3000 itself, so nothing is in front of it"
else
    ok "arm 1: the vane service does not publish a host port"
fi

# ARM 2 -- it moved to the proxy
if grep -q '127\.0\.0\.1:3000:3000' "${INSTALL_SH}"; then
    ok "arm 2: 3000 is still published (moved, not deleted -- the feature must keep working)"
else
    bad "arm 2: 3000 is published nowhere. The surface is closed by REMOVING the feature, which is not the fix."
fi

# ARM 3 -- a listener exists in the generated nginx conf
grep -q 'listen 3000;' "${INSTALL_SH}" \
  && ok "arm 3: the store proxy declares a listener on 3000" \
  || bad "arm 3: no 'listen 3000;' in the generated nginx conf"

# ARM 4 -- that listener demands a credential
grep -q 'include /etc/nginx/ostler-vane-auth\.conf;' "${INSTALL_SH}" \
  && ok "arm 4: the 3000 listener includes the vane credential" \
  || bad "arm 4: the 3000 listener does not include ostler-vane-auth.conf"

# ARM 5 -- the credential is real, and written 0600
grep -q 'auth_basic "Ostler assistant";' "${INSTALL_SH}" \
  && grep -q 'auth_basic_user_file /etc/nginx/ostler-vane-htpasswd;' "${INSTALL_SH}" \
  && ok "arm 5: the credential file declares auth_basic and a user file" \
  || bad "arm 5: the vane auth conf does not declare auth_basic + auth_basic_user_file"

grep -q 'chmod 600 "\${OSTLER_DIR}/ostler-vane-htpasswd" "\${OSTLER_DIR}/ostler-vane-auth\.conf"' "${INSTALL_SH}" \
  && ok "arm 6: both credential files are chmod 600" \
  || bad "arm 6: the vane credential files are not chmod 600 -- a shared secret must not be world-readable"

# ARM 7 -- websockets survive the proxy
_ws=0
grep -q 'map \$http_upgrade \$ostler_connection_upgrade' "${INSTALL_SH}" || _ws=1
grep -q 'proxy_set_header Upgrade \$http_upgrade;' "${INSTALL_SH}" || _ws=1
grep -q 'proxy_set_header Connection \$ostler_connection_upgrade;' "${INSTALL_SH}" || _ws=1
if [ "$_ws" -eq 0 ]; then
    ok "arm 7: the websocket map and both upgrade headers are present"
else
    bad "arm 7: websocket passthrough is incomplete -- the page would authenticate and the conversation would not stream"
fi

# ARM 7b -- THE CONSUMER MUST BE ABLE TO AUTHENTICATE.
# Closing the port is only half of it. The assistant CALLS vane
# (web_search_tool.rs:157, a bare client.get with no Authorization header), so
# install.sh must hand it the credential or web search 401s and blames the
# container. reqwest takes basic auth from the URL's userinfo -- measured
# against the pinned nginx with the proxy disabled: userinfo 200, bare 401,
# wrong password 401.
if grep -q 'vane_url = .http://ostler:\${VANE_PASSWORD}@localhost:3000' "${INSTALL_SH}"; then
    ok "arm 7b: the assistant's vane_url carries the credential"
else
    bad "arm 7b: vane_url has no credential -- the port is shut and the assistant cannot get in, so web search 401s"
fi

# ARM 8 -- THE MUTATION CONTROL. Restore the shipped defect in a COPY and assert
# arm 1 fires on it. Without this, arms 1-7 could all be passing because the
# predicate resolves nothing.
_tmp="$(mktemp)"
trap 'rm -f "${_tmp}"' EXIT
awk '
  /^  vane:/ { print; invane=1; next }
  invane && /^    volumes:/ { print "    ports:"; print "      - \"127.0.0.1:3000:3000\""; print; invane=0; next }
  { print }
' "${INSTALL_SH}" > "${_tmp}"

if ! grep -q '127\.0\.0\.1:3000:3000' "${_tmp}"; then
    cant "arm 8: could not plant the defect into the copy, so arms 1-7 are unproven"
elif vane_publishes_directly "${_tmp}"; then
    ok "arm 8: with the direct publish restored, arm 1's predicate FIRES -- the arms above are real"
else
    bad "arm 8: the defect was planted and arm 1's predicate did NOT fire. Every arm above is measuring nothing."
fi

echo
printf '== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"
[ "$CANT" -gt 0 ] && exit 2
[ "$FAIL" -eq 0 ] || exit 1
exit 0
