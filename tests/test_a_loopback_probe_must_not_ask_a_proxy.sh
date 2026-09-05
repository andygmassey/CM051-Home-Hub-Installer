#!/usr/bin/env bash
# CM051 -- a loopback health probe must not be answered by the customer's proxy.
#
# THE DEFECT THIS GUARDS. `_probe_http_live` is the shared liveness helper and
# every one of its call sites probes 127.0.0.1. It did not pass --noproxy, so on
# a machine with HTTP_PROXY set the request goes to the proxy instead of the
# service.
#
# AND IT FAILS IN THE REASSURING DIRECTION, which is what makes it worth a gate.
# The helper counts any 1xx-5xx as "listening". MEASURED on a dev Mac
# 2026-09-05: Privoxy on 127.0.0.1:8118 answered a loopback request with 503.
# 503 is inside that range, so a DEAD service reads as LISTENING.
#
# Same class as the #1594 follow-on, where the installer's wiki poll was
# answered by a proxy rather than by the wiki.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -r "$INSTALL_SH" ] || { cant "install.sh unreadable"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
_l="$(wc -l < "$INSTALL_SH" | tr -d ' ')"
[ "${_l}" -ge 20000 ] || { cant "install.sh only ${_l} lines; refusing a truncated subject"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

BODY="$(sed -n '/^_probe_http_live()/,/^}/p' "$INSTALL_SH")"
_bl="$(printf '%s\n' "$BODY" | wc -l | tr -d ' ')"
if [ "${_bl}" -lt 6 ]; then
    cant "extracted ${_bl} line(s) of _probe_http_live; the anchors moved and this measures nothing"
    echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2
fi
ok "located _probe_http_live (${_bl} lines)"

# ARM 1 -- THE DEFECT.
#
# 🔴 COUNT CODE, NOT COMMENTS. The first version of this arm counted the flag
# anywhere in the helper body, and the comment ABOVE the curl line names the
# flag -- so a mutant that removed it from the CODE still scored a pass. The
# mutation test caught it; the arm did not. Blank the comments first.
BODY_CODE="$(printf '%s\n' "$BODY" | grep -vE '^[[:space:]]*#')"
if [ "$(printf '%s\n' "$BODY_CODE" | grep -c -- '--noproxy')" -gt 0 ]; then
    ok "the shared liveness helper bypasses a configured proxy"
else
    bad "_probe_http_live does not pass --noproxy, so a customer's proxy can answer a loopback probe"
fi

# ARM 2 -- the bypass is unconditionally correct only if every caller is loopback.
_sites="$(grep -c '_probe_http_live "http' "$INSTALL_SH")"
_loop="$(grep '_probe_http_live "http' "$INSTALL_SH" | grep -c '127\.0\.0\.1')"
if [ "${_sites}" -gt 0 ] && [ "${_sites}" -eq "${_loop}" ]; then
    ok "all ${_sites} call sites are loopback, so the bypass is always correct"
else
    bad "${_loop} of ${_sites} call sites are loopback; --noproxy would be wrong for the others"
fi

# ARM 3 -- MUST-MISS. Arm 1's predicate must reject the form that shipped.
_shipped="        _code=\$(curl -s -o /dev/null -m 3 -w '%{http_code}' \"\$_url\" 2>/dev/null || true)"
if [ "$(printf '%s\n' "$_shipped" | grep -c -- '--noproxy')" -eq 0 ]; then
    ok "must-miss: arm 1's predicate rejects the line the defect shipped as"
else
    bad "must-miss: arm 1's predicate accepts the shipped defect, so its pass proves nothing"
fi

# ARM 4 -- BEHAVIOURAL. A proxy pointed at a dead port must not break a loopback
# probe. Without --noproxy curl asks the dead proxy and fails; with it, it does not.
if ! command -v python3 >/dev/null 2>&1; then
    cant "python3 absent; cannot stand up a loopback server for the behavioural arm"
else
    _port=0
    for _p in 18711 18712 18713; do
        (python3 -m http.server "$_p" --bind 127.0.0.1 >/dev/null 2>&1 &) 
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            if curl -s -o /dev/null --noproxy '*' -m 1 "http://127.0.0.1:${_p}/" 2>/dev/null; then _port=$_p; break; fi
            sleep 0.3
        done
        [ "$_port" -ne 0 ] && break
    done
    if [ "$_port" -eq 0 ]; then
        cant "could not stand up a loopback HTTP server; the behavioural arm did not run"
    else
        # DEAD proxy: nothing listens on 9 (discard). curl must not use it.
        _with="$(HTTP_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
                 curl -s -o /dev/null -m 3 --noproxy '*' -w '%{http_code}' "http://127.0.0.1:${_port}/" 2>/dev/null || true)"
        _without="$(HTTP_PROXY=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
                 curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${_port}/" 2>/dev/null || true)"
        if [ "$_with" = "200" ] && [ "$_without" != "200" ]; then
            ok "behavioural: with --noproxy the loopback probe reaches the service (200); without it, ${_without}"
        elif [ "$_with" = "200" ]; then
            cant "behavioural: both spellings returned 200 (code without=${_without}); this environment ignores the proxy vars, so the arm cannot discriminate"
        else
            bad "behavioural: --noproxy did not reach the loopback service (got ${_with})"
        fi
        curl -s -o /dev/null --noproxy '*' -m 1 "http://127.0.0.1:${_port}/__shutdown" 2>/dev/null || true
        pkill -f "http.server ${_port}" 2>/dev/null || true
    fi
fi

echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
