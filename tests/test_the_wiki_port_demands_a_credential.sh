#!/usr/bin/env bash
# CM051 #1594 -- :8044 must not hand the compiled wiki to any local account.
#
# THE DEFECT THIS GUARDS. DECISION_550 line 106 records the v1.0 disposition
# for 8044 as ABSENT: "one door via the daemon, direct publish removed". It
# was never built. At tag v1.0.71 the wiki-site container published the host
# port itself, so a second local account could run one unauthenticated GET
# and receive the whole compiled personal wiki -- every person, organisation,
# note, meeting, conversation and preference, LLM-summarised and full-text
# searchable. Strictly worse than the SPARQL read that opened #550, because
# the data arrives pre-digested.
#
# Measured before the fix, against the pinned nginx image:
#   direct publish, no credentials  -> 200, body = the wiki
# Measured after:
#   no credentials                  -> 401
#   wrong password / wrong user     -> 401
#   correct credentials             -> 200, body = the wiki
#
# WHY THE HOST-HEADER CHECKS IN FRONT OF IT ARE NOT ENOUGH. They read
# headers the CALLER WRITES. They were built against DNS-rebinding, which
# is a browser threat. Any other account on this Mac can send whatever Host
# it likes, so they are not an access control.
#
# ARM 7 IS THE ONE THAT KEEPS THE REST HONEST: it restores the shipped
# defect in a COPY and asserts arm 1 goes red on it. Without that, every
# structural arm above could be passing because it resolves nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
# CANNOT-RUN is neither PASS nor FAIL: three outcomes, three branches (#1239).
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -r "${INSTALL_SH}" ] || { cant "install.sh unreadable at ${INSTALL_SH}"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
# A validator passes on an empty subject, so assert a floor before believing
# any zero below.
_lines="$(wc -l < "${INSTALL_SH}" | tr -d ' ')"
[ "${_lines}" -ge 20000 ] || { cant "install.sh is only ${_lines} lines; refusing to measure a truncated subject"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

command -v python3 >/dev/null 2>&1 || { cant "python3 absent; the compose stanza cannot be parsed"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

# compose_ports <file> <service>  -> prints the service's published ports, one per line
compose_ports() {
    python3 - "$1" "$2" <<'PY'
import re, sys, yaml
s = open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = s.find('  wiki-site:')
if i < 0:
    sys.exit(3)
start = s.rfind('<<', 0, i)
line = s[s.rfind('\n', 0, start) + 1 : s.find('\n', start)]
m = re.search(r"<<-?'?([A-Za-z_]+)'?", line)
if not m:
    sys.exit(3)
delim = m.group(1)
body_start = s.find('\n', start) + 1
body_end = s.find('\n' + delim + '\n', body_start)
body = s[body_start:body_end]
d = yaml.safe_load(re.sub(r'\$\{[^}]*\}', 'X', body))
for p in (d['services'][sys.argv[2]] or {}).get('ports') or []:
    print(p)
PY
}

echo "== #1594: the wiki port demands a credential =="

# ARM 1 -- the defect itself: wiki-site must publish NOTHING to the host.
_ws_ports="$(compose_ports "${INSTALL_SH}" wiki-site)"; _rc=$?
if [ "${_rc}" -ne 0 ]; then
    cant "could not parse the compose stanza (rc=${_rc})"
elif [ -n "${_ws_ports}" ]; then
    bad "wiki-site publishes to the host: ${_ws_ports//$'\n'/, } -- a publish here BYPASSES the credential entirely, because that container has no idea one exists"
else
    ok "wiki-site publishes no host port"
fi

# ARM 2 -- the publish moved to the proxy, loopback-only.
_sp_ports="$(compose_ports "${INSTALL_SH}" store-proxy)"
if printf '%s\n' "${_sp_ports}" | grep -q '^127\.0\.0\.1:8044:8044$'; then
    ok "store-proxy publishes 127.0.0.1:8044 (loopback only)"
else
    bad "store-proxy does not publish 127.0.0.1:8044:8044; got: ${_sp_ports//$'\n'/, }"
fi

# ARM 3 -- the 8044 server block exists and applies the credential.
if awk '/^    server \{$/{b=""} {b=b"\n"$0} /^    \}$/{if (b ~ /listen 8044;/ && b ~ /include \/etc\/nginx\/ostler-wiki-auth\.conf;/) found=1} END{exit !found}' "${INSTALL_SH}"; then
    ok "the :8044 server block includes the credential file"
else
    bad "no :8044 server block that includes /etc/nginx/ostler-wiki-auth.conf"
fi

# ARM 4 -- the credential file really is an auth_basic challenge.
if grep -q '^auth_basic "' "${INSTALL_SH}" && grep -q '^auth_basic_user_file /etc/nginx/ostler-wiki-htpasswd;' "${INSTALL_SH}"; then
    ok "the credential file issues an auth_basic challenge against a user file"
else
    bad "ostler-wiki-auth.conf does not carry auth_basic + auth_basic_user_file"
fi

# ARM 5 -- 0600 via umask BEFORE the write, not chmod after (chmod after is a race).
if grep -q 'umask 0077' "${INSTALL_SH}" \
   && grep -q 'chmod 600 "\${OSTLER_DIR}/ostler-wiki-htpasswd" "\${OSTLER_DIR}/ostler-wiki-auth.conf"' "${INSTALL_SH}"; then
    ok "the credential is written under umask 0077 and left at 0600"
else
    bad "the wiki credential is not written 0600-from-birth"
fi

# ARM 6 -- MUST-MISS on the opt-out. The store credential has a flag because it
# had to flip in step with Qdrant's. This one must not: an env var that turns it
# off is the original defect with a name.
if grep -nE 'OSTLER_[A-Z_]*WIKI[A-Z_]*(AUTH|ENFORCE)[A-Z_]*' "${INSTALL_SH}" | grep -qv '^\s*#'; then
    bad "something looks like an opt-out flag for the wiki credential: $(grep -oE 'OSTLER_[A-Z_]*WIKI[A-Z_]*(AUTH|ENFORCE)[A-Z_]*' "${INSTALL_SH}" | sort -u | tr '\n' ' ')"
else
    ok "no environment variable can disable the wiki credential"
fi

# ARM 7 -- SELF-TEST. Restore the shipped defect in a COPY and require arm 1 to
# see it. If this arm ever passes silently, every arm above is unfalsifiable.
_tmp="$(mktemp -t wiki8044)" || _tmp=""
if [ -z "${_tmp}" ]; then
    cant "could not create a temp file for the self-test"
else
    python3 - "${INSTALL_SH}" "${_tmp}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8', errors='replace').read()
anchor = '    container_name: ostler-wiki-site\n'
assert anchor in s, "anchor for the mutation is gone; the self-test cannot inject"
# put the host publish back exactly as it shipped
s = s.replace(anchor, anchor + '    ports:\n      - "127.0.0.1:8044:' + '8000"\n', 1)
open(dst, 'w', encoding='utf-8').write(s)
PY
    if [ $? -ne 0 ]; then
        cant "the self-test mutation could not be injected"
    else
        _injected="$(grep -c '127\.0\.0\.1:8044:8000' "${_tmp}" | head -1)"
        _mutant_ports="$(compose_ports "${_tmp}" wiki-site)"
        if [ "${_injected}" -lt 1 ]; then
            cant "the self-test mutation did not land (a failed injection returns the green you were hoping for)"
        elif [ -n "${_mutant_ports}" ]; then
            ok "self-test: arm 1 detects a restored direct publish (mutation landed, ${_injected} occurrence)"
        else
            bad "self-test: arm 1 did NOT detect a restored direct publish -- arm 1 is blind and its pass above means nothing"
        fi
    fi
    rm -f -- "${_tmp}"
fi

echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
