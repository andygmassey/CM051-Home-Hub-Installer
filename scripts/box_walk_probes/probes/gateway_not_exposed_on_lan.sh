#!/usr/bin/env bash
# probes/gateway_not_exposed_on_lan.sh
# ============================================================================
# QUESTION: from the box's OWN LAN address (not loopback, not lsof), is the
#           gateway port 8000 REFUSED, and does the companion listener on 8443
#           refuse to serve /api/v1/frontpage/cards (404)?
#
# WHY (fix-register row 947). The gateway host defaults to 127.0.0.1 in the
# assistant's config schema, but install.sh writes port=8000 with no host, and
# :8443 is the companion route table. A listener table (lsof) says what is
# bound; it does not say what a neighbour on the LAN can reach. So this probe
# connects to the LAN IP itself, the way a neighbour would.
#
# POSITIVE CONTROL IN THE SAME RUN: https://<lan-ip>:8443/health must answer
# 2xx. That proves the LAN path works at all; without it a refused 8000 could be
# a dead interface. Control down = CANNOT-RUN, never PASS.
#
#   8000 connect refused (curl exit 7)              ok
#   8000 answers anything (connected)               FAIL
#   8000 neither refused nor answered (timeout)     CANNOT-RUN
#   8443 frontpage/cards != 404                     FAIL
#   no LAN IP on the box                            CANNOT-RUN
#
# macOS bash 3.2 + BSD userland. British English; no em dashes.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="gateway_not_exposed_on_lan"
PROBE_QUESTION="from the box's own LAN IP, is :8000 refused and :8443 frontpage/cards 404, with :8443/health answering as the control?"

# Runs ON THE BOX. Prints: IP <ip> <8000 curl exit> <8000 http> <health http> <cards http>, or NOIP.
_LAN_READ='ifc=$(route -n get default 2>/dev/null | awk "/interface:/{print \$2; exit}")
ip=""
for i in $ifc en0 en1; do ip=$(ipconfig getifaddr "$i" 2>/dev/null) && [ -n "$ip" ] && break; done
[ -n "$ip" ] || { echo NOIP; exit 0; }
c() { curl -sk -o /dev/null -w "%{http_code}" --noproxy "*" --connect-timeout 4 --max-time 8 "$1"; }
h=$(c "http://$ip:8000/"); e=$?
hl=$(c "https://$ip:8443/health")
cd=$(c "https://$ip:8443/api/v1/frontpage/cards")
echo "IP $ip $e ${h:-000} ${hl:-000} ${cd:-000}"'

# adjudicate "<line>" -> PASS|FAIL|CANNOT_RUN <text>. Pure; shared with self_test.
adjudicate() {
    local line="$1" tag ip e h hl cd
    read -r tag ip e h hl cd <<< "$line"
    if [ "$tag" != "IP" ] || [ -z "${cd:-}" ]; then
        echo "CANNOT_RUN the box reported no LAN IP (or no reading): '${line}'. Nothing on the LAN path was measured."; return
    fi
    case "$hl" in
        2??) : ;;
        *) echo "CANNOT_RUN positive control failed: https://${ip}:8443/health answered HTTP ${hl}, so the LAN path itself is not proven to work and a refused :8000 would mean nothing."; return ;;
    esac
    case "$e" in
        7) : ;;
        28) echo "CANNOT_RUN :8000 on ${ip} neither refused nor answered (curl exit 28, timeout)."; return ;;
        *) echo "FAIL the gateway answers on the LAN: http://${ip}:8000/ connected (curl exit ${e}, HTTP ${h}). It must be bound to loopback only."; return ;;
    esac
    if [ "$cd" != "404" ]; then
        echo "FAIL https://${ip}:8443/api/v1/frontpage/cards answered HTTP ${cd} on the LAN, expected 404: the companion listener exposes a front-page route."; return
    fi
    echo "PASS from the LAN IP ${ip}: :8000 refused, :8443 frontpage/cards 404, with :8443/health ${hl} as the control"
}

_decide() {
    local v token
    v="$(adjudicate "$1")"
    token="${v%% *}"
    probe_examined 3 "LAN-IP requests from the box (8000 connect, 8443 health control, 8443 frontpage/cards)"
    case "$token" in
        PASS)       probe_pass "${v#* }" ;;
        FAIL)       probe_fail "${v#* }" ;;
        CANNOT_RUN) probe_cannot_run "${v#* }" ;;
        *)          probe_fail "adjudicator returned an unrecognised line: ${v}" ;;
    esac
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "the box (${OSTLER_BOX_HOST:-local}) did not answer over ssh; the LAN path was not measured"
    fi
    _decide "$(box_run "$_LAN_READ" | tail -n 1)"
}

self_test() {
    probe_examined 6 "synthetic LAN readings (negative control)"
    local ip=192.0.2.10
    case "$(adjudicate "IP $ip 7 000 200 404")" in PASS*) : ;; *)
        probe_pass "NEGATIVE CONTROL OVER-FIRED: the correct state (8000 refused, cards 404, health 200) was not PASS." ;; esac
    case "$(adjudicate "IP $ip 0 200 200 404")" in FAIL*8000*) : ;; *)
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a gateway answering on the LAN IP was not FAIL." ;; esac
    case "$(adjudicate "IP $ip 52 000 200 404")" in FAIL*8000*) : ;; *)
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a connection accepted on :8000 with an empty reply was not FAIL." ;; esac
    case "$(adjudicate "IP $ip 7 000 200 200")" in FAIL*frontpage*) : ;; *)
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: 8443 serving frontpage/cards on the LAN was not FAIL." ;; esac
    case "$(adjudicate "IP $ip 7 000 000 404")" in CANNOT_RUN*control*) : ;; *)
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: the health control down was not CANNOT-RUN." ;; esac
    case "$(adjudicate "NOIP")" in CANNOT_RUN*) : ;; *)
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: no LAN IP was not CANNOT-RUN." ;; esac
    probe_fail "negative control behaved correctly on 6 readings (correct state PASSes; gateway on LAN, accepted-empty :8000 and 8443 cards FAIL; health control down and no IP CANNOT-RUN)"
}

probe_main "$@"
