#!/usr/bin/env bash
# probes/pairing_recovers_on_the_port_the_app_uses.sh
# ============================================================================
# QUESTION: if a customer's session dies, can they get back in?
#
# THE PROBE THAT WOULD HAVE CAUGHT THE v1.0.45 LOCKOUT.
#
# Measured on the Mac mini 2026-08-25. The upgrade restarted the daemon, which
# invalidated the app's session. The app offers exactly one recovery: enter a
# pairing code. Andy entered it and the app said:
#
#     Pairing failed (403): {"error":"Invalid pairing code"}
#
# One fresh code, posted back within the same second, 600s of expiry headroom:
#     POST http://127.0.0.1:8000/pair   -> {"paired":true,"token":"zc_..."}
#     POST https://127.0.0.1:8443/pair  -> {"error":"Invalid pairing code"}
#
# The app uses 8443. lsof showed ONE process on both ports, and the token store
# is SHARED (an 8000-minted token returns 200 from 8443/api/status). So this is
# not two services with separate state -- only CODE verification on the 8443
# listener is broken.
#
# An upgrade restarts the daemon. A restart kills the session. Pairing is the
# only route back. So an ordinary upgrade can lock a customer out of their own
# installed product with no way in. The CLI cannot rescue them either -- see
# cli_and_daemon_agree_on_gateway_port.sh.
#
# WHY A BOX PROBE, NOT A CUT GATE: it needs a live gateway holding real pairing
# state. At cut time there is nothing to pair with.
# ============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/probe.sh"

run() {
  box_reachable || { probe_cannot_run "box not reachable"; return; }

  local admin code r8000 r8443 rwrong up8000 up8443

  admin=$(box_run 'cat ~/.ostler/secrets/zeroclaw_admin_token 2>/dev/null') || true
  [ -n "${admin:-}" ] || {
    probe_cannot_run "no zeroclaw_admin_token on the box -- cannot mint a code. NOT a pass."
    return
  }

  # DENOMINATOR. Both listeners must be up, or a rejection proves nothing: a
  # dead port and a port that refuses codes are indistinguishable by response.
  up8000=$(box_run "curl -s  --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health")
  up8443=$(box_run "curl -sk --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/health")
  probe_examined "listeners: 8000=${up8000} 8443=${up8443}"
  if [ "$up8000" != "200" ] || [ "$up8443" != "200" ]; then
    probe_cannot_run "a listener is down (8000=${up8000} 8443=${up8443}) -- cannot tell 'rejects codes' from 'not running'"
    return
  fi

  code=$(box_run "curl -s --noproxy '*' --max-time 6 -X POST -H 'Authorization: Bearer ${admin}' http://127.0.0.1:8000/admin/paircode/new | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"pairing_code\"])'") || true
  [ -n "${code:-}" ] || { probe_cannot_run "gateway would not issue a pairing code"; return; }

  # Same code, both ports, immediately. Expiry cannot explain a difference.
  r8443=$(box_run "curl -sk --noproxy '*' --max-time 6 -X POST -H 'X-Pairing-Code: ${code}' https://127.0.0.1:8443/pair")
  r8000=$(box_run "curl -s  --noproxy '*' --max-time 6 -X POST -H 'X-Pairing-Code: ${code}' http://127.0.0.1:8000/pair")

  # CONTROL. A deliberately wrong code MUST be refused. Without this, "accepted"
  # could mean the endpoint accepts anything, which is a worse defect than the
  # one under test and would otherwise read as a pass.
  rwrong=$(box_run "curl -sk --noproxy '*' --max-time 6 -X POST -H 'X-Pairing-Code: 000000' https://127.0.0.1:8443/pair")
  probe_examined "control, wrong code on 8443: ${rwrong:0:60}"
  case "$rwrong" in
    *'"paired":true'*)
      probe_cannot_run "CONTROL FAILED: 8443 accepted a WRONG code. This probe cannot discriminate, and that is a worse finding than the one it tests for."
      return
      ;;
  esac

  case "$r8443" in
    *'"paired":true'*)
      probe_pass "8443 -- the port the app pairs against -- accepted a freshly issued code"
      ;;
    *)
      local extra=""
      case "$r8000" in
        *'"paired":true'*)
          extra=" AND 8000 ACCEPTED THE SAME CODE, so the code was valid and only the app's port refuses it"
          ;;
      esac
      probe_fail "8443 REJECTED a code the gateway had just issued${extra}. A customer whose session dies cannot get back in. 8443 said: ${r8443:0:80}"
      ;;
  esac
}

probe_main run
