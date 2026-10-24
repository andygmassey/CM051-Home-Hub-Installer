#!/usr/bin/env bash
# probes/phone_reaches_hub_over_tailnet.sh
# ============================================================================
# QUESTION: v1.0.108 wow-moment #10, the phone works away from home. The
#           pairing QR carries hub_tailnet_addr (100.x.y.z:8443). Does the
#           Hub's companion listener actually ANSWER on that address, with the
#           certificate the phone paired against, and with the loopback-trusted
#           routes absent?
#
# THREE ASSERTIONS, measured on the box against its own tailnet IP:
#   (a) https://<tailnet ip>:8443/health answers 200;
#   (b) the certificate SERVED there has the SAME SPKI SHA-256 as the Hub's own
#       companion-cert.pem (the pin the phone took at pairing). A TLS-
#       TERMINATING `tailscale serve` presents Tailscale's certificate and
#       fails this; the installer serves RAW TCP so it holds;
#   (c) https://<tailnet ip>:8443/admin/paircode answers 404: `tailscale serve`
#       presents every tailnet peer to the listener as 127.0.0.1, so a route
#       that trusts loopback would be open to the whole tailnet. 8443 is an
#       allowlist (ostler-assistant #492); this is the live proof.
#
# THREE OUTCOMES:
#   PASS        all three held.
#   FAIL        the port is not forwarded on the tailnet, or the served SPKI is
#               not the Hub's, or /admin/paircode is anything but 404.
#   CANNOT-RUN  no tailnet IP (Tailscale skipped or not signed in), no
#               companion cert, no openssl, OR the box cannot dial its own
#               tailnet IP while `tailscale serve` DOES list 8443 (userspace
#               tailscaled does not route its own address back to itself, so
#               that case needs a second device on the tailnet and is not a
#               verdict either way).
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="phone_reaches_hub_over_tailnet"
PROBE_QUESTION="does the Hub answer on its tailnet IP at 8443 with the certificate the phone paired against, and is /admin/paircode a 404 there?"

# _classify <health> <paircode> <pinned> <served> <serve_listed>
#   health/paircode : HTTP status as digits, or "" when the connection failed
#   pinned          : SPKI sha256 of the Hub's companion-cert.pem
#   served          : SPKI sha256 of the cert presented on the tailnet IP, or ""
#   serve_listed    : yes|no|unknown -- does `tailscale serve` list 8443
# THE ONE DECISION FUNCTION, shared by run_probe and self_test.
_classify() {
    _h="$1"; _p="$2"; _pin="$3"; _srv="$4"; _sl="${5:-unknown}"
    if [ -z "$_h" ] && [ -z "$_srv" ]; then
        # Nothing answered. Is that "not forwarded" or "cannot dial myself"?
        case "$_sl" in
            no)  printf 'FAIL-NOT-FORWARDED'; return ;;
            yes) printf 'CANNOT-RUN-SELF-DIAL'; return ;;
            *)   printf 'CANNOT-RUN-INCONCLUSIVE'; return ;;
        esac
    fi
    if [ -n "$_srv" ] && [ "$_srv" != "$_pin" ]; then
        printf 'FAIL-SPKI-MISMATCH'; return
    fi
    if [ "$_h" != "200" ]; then
        printf 'FAIL-HEALTH'; return
    fi
    if [ "$_p" != "404" ]; then
        printf 'FAIL-PAIRCODE-REACHABLE'; return
    fi
    if [ -z "$_srv" ]; then
        printf 'CANNOT-RUN-INCONCLUSIVE'; return
    fi
    printf 'PASS'
}

run_probe() {
    box_reachable || probe_cannot_run "box ${OSTLER_BOX_HOST:-<local>} is not reachable over ssh. Nothing was inspected, and that is not a pass."

    _facts="$(box_run '
        TS=$(command -v tailscale 2>/dev/null); SOCK="$HOME/.ostler/tailscale/tailscaled.sock"
        command -v openssl >/dev/null 2>&1 || { echo "no_openssl=1"; exit 0; }
        IP=""; [ -n "$TS" ] && IP=$("$TS" --socket="$SOCK" ip --4 2>/dev/null | head -1)
        echo "ip=$IP"
        CERT=$(find "$HOME/.ostler" -name companion-cert.pem 2>/dev/null | head -1)
        echo "cert=$CERT"
        spki() { openssl x509 -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null | openssl dgst -sha256 | sed "s/.*= //"; }
        [ -n "$CERT" ] && echo "pinned=$(spki < "$CERT")"
        SL=unknown
        if [ -n "$TS" ]; then
            J=$("$TS" --socket="$SOCK" serve status --json 2>/dev/null)
            if [ -n "$J" ]; then case "$J" in *\"8443\"*) SL=yes ;; *) SL=no ;; esac; fi
        fi
        echo "serve_listed=$SL"
        if [ -n "$IP" ]; then
            echo "served=$(echo | openssl s_client -connect "$IP:8443" 2>/dev/null | spki)"
            echo "health=$(curl -sk -m 8 --noproxy "*" -o /dev/null -w "%{http_code}" "https://$IP:8443/health" 2>/dev/null)"
            echo "paircode=$(curl -sk -m 8 --noproxy "*" -o /dev/null -w "%{http_code}" "https://$IP:8443/admin/paircode" 2>/dev/null)"
        fi
    ')"
    _get() { printf '%s\n' "$_facts" | sed -n "s/^$1=//p" | head -1; }
    _code() { case "$1" in 000|'') printf '' ;; *) printf '%s' "$1" ;; esac; }

    [ "$(_get no_openssl)" = "1" ] && probe_cannot_run "openssl is not on the box, so the served SPKI cannot be compared."
    _ip="$(_get ip)"; _cert="$(_get cert)"
    [ -n "$_ip" ] || probe_cannot_run "the box has no tailnet IPv4 (Tailscale skipped or not signed in). The phone has no off-LAN route to test, which is coverage absent, not a pass."
    [ -n "$_cert" ] || probe_cannot_run "no companion-cert.pem under ~/.ostler on the box: there is no paired SPKI to compare against."

    _pin="$(_get pinned)"; _srv="$(_get served)"
    _h="$(_code "$(_get health)")"; _p="$(_code "$(_get paircode)")"; _sl="$(_get serve_listed)"
    probe_examined 3 "assertions on https://${_ip}:8443 (health 200, served SPKI equals the Hub's cert SPKI, /admin/paircode 404)"
    probe_note "health=${_h:-none} paircode=${_p:-none} serve_lists_8443=${_sl:-unknown} pinned=${_pin:-none} served=${_srv:-none}"

    case "$(_classify "$_h" "$_p" "$_pin" "$_srv" "$_sl")" in
        PASS) probe_pass "the Hub answered 200 on ${_ip}:8443, presented the SPKI the phone pairs against, and /admin/paircode there is a 404." ;;
        FAIL-NOT-FORWARDED) probe_fail "🔴 NOTHING ANSWERS ON ${_ip}:8443 and \`tailscale serve\` does not list 8443: the QR advertises a tailnet address the phone cannot reach. The installer's serve for 8443 did not take." ;;
        FAIL-SPKI-MISMATCH) probe_fail "🔴 the certificate served on ${_ip}:8443 is NOT the Hub's companion cert (served ${_srv}, pinned ${_pin}). A TLS-terminating serve presents Tailscale's cert; the phone's SPKI pin would reject every off-LAN connection." ;;
        FAIL-HEALTH) probe_fail "🔴 https://${_ip}:8443/health answered '${_h:-no response}', not 200." ;;
        FAIL-PAIRCODE-REACHABLE) probe_fail "🔴 /admin/paircode on ${_ip}:8443 answered '${_p:-no response}', not 404. A loopback-trusted route is reachable from the tailnet." ;;
        CANNOT-RUN-SELF-DIAL) probe_cannot_run "the box could not dial its own tailnet IP, but \`tailscale serve\` lists 8443. Userspace tailscaled does not route its own address back to itself, so this needs a SECOND device on the tailnet. Neither reachable nor unreachable was established." ;;
        *) probe_cannot_run "the measurement was inconclusive (health='${_h}', paircode='${_p}', served='${_srv}', serve_listed='${_sl}')." ;;
    esac
}

self_test() {
    fails=0
    _t() { got="$(_classify "$1" "$2" "$3" "$4" "$5")"; if [ "$got" = "$6" ]; then printf 'arm OK: -> %s\n' "$got"; else printf 'arm BROKEN: (%s %s %s %s %s) -> %s, wanted %s\n' "$1" "$2" "$3" "$4" "$5" "$got" "$6"; fails=$((fails+1)); fi; }
    _t 200 404 aaa aaa yes PASS
    _t 200 404 aaa bbb yes FAIL-SPKI-MISMATCH       # TLS-terminating serve
    _t 200 200 aaa aaa yes FAIL-PAIRCODE-REACHABLE  # loopback route open to the tailnet
    _t 200 404 aaa ""  yes CANNOT-RUN-INCONCLUSIVE  # health but no cert read: not a pass
    _t 503 404 aaa aaa yes FAIL-HEALTH
    _t ""  ""  aaa ""  no  FAIL-NOT-FORWARDED
    _t ""  ""  aaa ""  yes CANNOT-RUN-SELF-DIAL
    _t ""  ""  aaa ""  unknown CANNOT-RUN-INCONCLUSIVE
    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required"
        probe_pass "SELF-TEST BROKEN: ${fails} arm(s) failed. This probe cannot demonstrate a FAIL, so its real result must not be trusted."
    fi
    probe_examined 8 "self-test arms (pass / spki mismatch / paircode open / no cert read / bad health / not forwarded / self-dial / inconclusive)"
    probe_fail "negative control behaved correctly on all 8 arms: a mismatched SPKI, an open /admin/paircode, a bad /health and an unforwarded port each FAIL, the all-good case PASSes, and the cannot-dial-myself cases are CANNOT-RUN rather than a verdict"
}

probe_main "$@"
