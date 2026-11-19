#!/usr/bin/env bash
# owner_mint_refuses_unauthenticated -- CB137 (CB137-PAIRCODE-MINT-UNAUTHENTICATED).
#
# QUESTION: on a live Hub, does POST /admin/paircode/new refuse a caller that
# does not present the owner credential, and mint only for one that does?
#
# Measured on the box, against 127.0.0.1:8000 (the gateway binds loopback):
#   arm 1: no X-Ostler-Owner header            -> must be 403, reason owner_header_absent
#   arm 2: X-Ostler-Owner = the owner secret   -> must be 200 with a qr_payload
# The owner secret is read on the box into a 0600 header file, passed to curl
# with -H @file, and removed. It never appears in argv, in this probe's output,
# or in the walk evidence. Only status codes and the refusal reason come back.
#
# Side effect: arm 2 mints a fresh pairing code on the box. Walk boxes only.
# CANNOT-RUN: no OSTLER_BOX_HOST (a request from the box itself is loopback), no
# HTTP answer, or no owner secret file on the box.
# A gate-removed mutant (arm 1 answers 200) must read FAIL. self_test proves it.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="owner_mint_refuses_unauthenticated"
PROBE_QUESTION="on the box, does POST /admin/paircode/new refuse with 403 without the owner credential, and mint with it?"

# Judge: reads "unauth_status<TAB>unauth_reason<TAB>auth_status<TAB>auth_has_envelope".
_judge() {
    python3 - "$1" <<'PY'
import sys
parts = sys.argv[1].split("\t")
if len(parts) != 4:
    print("CANNOT-RUN: capture malformed"); sys.exit(2)
unauth_status, unauth_reason, auth_status, auth_env = parts
ok = True
def line(tag, cond, msg):
    global ok
    print(("  ok " if cond else "  FAIL ") + msg)
    if not cond: ok = False
line("unauth", unauth_status == "403" and unauth_reason == "owner_header_absent",
     f"unauthenticated mint answered {unauth_status} reason={unauth_reason or '-'} (want 403 owner_header_absent)")
line("auth", auth_status == "200" and auth_env == "yes",
     f"owner-credentialed mint answered {auth_status} envelope={auth_env} (want 200 with envelope)")
sys.exit(0 if ok else 1)
PY
}

self_test() {
    # Negative control 1: gate removed. Unauthenticated mint answers 200 with an envelope.
    if _judge "200	-	200	yes" >/dev/null; then
        probe_examined 2 "canned captures"
        probe_pass "SELF-TEST BROKEN: the judge passed a mint that answered 200 with no owner credential"
    fi
    # Negative control 2: the gate is present but refuses the owner too.
    if _judge "403	owner_header_absent	403	no" >/dev/null; then
        probe_examined 2 "canned captures"
        probe_pass "SELF-TEST BROKEN: the judge passed a mint that refused the owner"
    fi
    # Positive control: the correct shape passes.
    if _judge "403	owner_header_absent	200	yes" >/dev/null; then
        probe_examined 2 "canned captures"
        probe_fail "negative control behaved: a gate-removed (200 unauthenticated) mint and a refused-owner mint both went red"
    fi
    probe_examined 2 "canned captures"
    probe_pass "SELF-TEST BROKEN: the judge passed the correct shape"
}

run_probe() {
    [ -n "${OSTLER_BOX_HOST:-}" ] || probe_cannot_run "OSTLER_BOX_HOST is unset: a request from the box itself is loopback and proves nothing about the gate"
    box_reachable || probe_cannot_run "cannot reach the box"
    local url="http://127.0.0.1:8000/admin/paircode/new"
    local unauth auth_out unauth_body unauth_status unauth_reason auth_status auth_body auth_env cap out rc
    unauth="$(box_run "curl -s -m 10 -X POST -w '\n%{http_code}' ${url}" )"
    [ -n "$unauth" ] || probe_cannot_run "no HTTP answer from the gateway on 127.0.0.1:8000"
    unauth_status="$(printf '%s' "$unauth" | tail -n1 | tr -dc '0-9')"
    unauth_body="$(printf '%s' "$unauth" | sed '$d')"
    unauth_reason="$(printf '%s' "$unauth_body" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("reason","") or "")
except Exception: print("")')"
    # Arm 2: the secret goes to a 0600 header file on the box, and is removed.
    auth_out="$(box_run 'f=$(mktemp) && chmod 600 "$f" && printf "X-Ostler-Owner: %s\n" "$(cat "$HOME/.ostler/secrets/owner_token" 2>/dev/null)" > "$f" && curl -s -m 10 -X POST -H @"$f" -w "\n%{http_code}" '"${url}"'; rm -f "$f"')"
    [ -n "$auth_out" ] || probe_cannot_run "no HTTP answer on the credentialed arm"
    auth_status="$(printf '%s' "$auth_out" | tail -n1 | tr -dc '0-9')"
    auth_body="$(printf '%s' "$auth_out" | sed '$d')"
    auth_env="$(printf '%s' "$auth_body" | python3 -c 'import json,sys
try: print("yes" if isinstance(json.load(sys.stdin).get("qr_payload"), dict) else "no")
except Exception: print("no")')"
    cap="$(printf '%s\t%s\t%s\t%s' "$unauth_status" "$unauth_reason" "$auth_status" "$auth_env")"
    probe_examined 2 "arms (unauthenticated, credentialed)"
    out="$(_judge "$cap")"; rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -eq 0 ]; then probe_pass "the mint refuses without the owner credential and mints with it"; fi
    if [ "$rc" -eq 2 ]; then probe_cannot_run "capture malformed"; fi
    probe_fail "the mint did not behave as the owner gate requires"
}

probe_main "$@"
