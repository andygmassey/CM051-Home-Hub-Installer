#!/usr/bin/env python3
"""Row 947.

The pairing envelope validated hub_addr as "a non-empty string" and then
encoded it VERBATIM into the QR code the customer scans. Non-empty is not the
property that matters. The phone has to be able to OPEN it.

The case in the issue is an IPv6 LINK-LOCAL address with a zone index,
fe80::1%en0. That address is only meaningful on the interface its zone names,
and en0 on the Hub is not en0 on the phone: the scope travels with the string
while the thing it scopes does not. The QR scans perfectly and the connection
cannot succeed. That is the worst failure shape available, because nothing
looks broken, and it matches the thirteen refused 8443 connections exactly.

THE SUBJECT OF THESE ASSERTIONS IS THE QR A PERSON SCANS: the arms drive the
real envelope validator and check whether a payload is allowed to reach it.

A HOSTNAME IS DELIBERATELY NOT JUDGED. ostler.local is how a Mac is found on a
LAN and mDNS is the intended path, so the guard must accept it. An arm pins
that, because a guard that quietly rejected the normal case would replace one
silent failure with another.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor"))

PASS = FAIL = 0


def ok(m): 
    global PASS
    PASS += 1
    print(f"  ok    {m}")


def bad(m):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {m}")


try:
    from doctor.agent import pair_status as ps
except Exception as exc:  # pragma: no cover
    print(f"  CANNOT-RUN  doctor.agent.pair_status is not importable: {exc}")
    print("    NOTHING was checked. This is not a pass.")
    print("PASS=0 FAIL=0 CANNOT-RUN=1")
    sys.exit(1)

# MUST BE REFUSED: each of these scans fine and can never connect.
UNREACHABLE = [
    ("fe80::1%en0", "IPv6 link-local with a zone index, the case in the issue"),
    ("[fe80::1%en0]:8443", "the same address in bracketed host:port form"),
    ("169.254.13.9", "IPv4 link-local, the same class over IPv4"),
    ("127.0.0.1", "loopback, which on the phone means the phone"),
    ("::1", "IPv6 loopback"),
    ("0.0.0.0", "the listen-on-everything wildcard"),
]
# MUST BE ACCEPTED: rejecting these would be a worse defect than the one fixed.
REACHABLE = [
    ("ostler.local", "the mDNS name a Mac is normally found by"),
    ("ostler.local:8443", "the same with a port"),
    ("192.168.1.72:8443", "an ordinary routable LAN address"),
    ("[2001:db8::1]:8443", "a routable IPv6 address"),
]

print(f"EXAMINED: {len(UNREACHABLE)} unreachable and {len(REACHABLE)} reachable "
      f"addresses through the shipped validator")

for addr, why in UNREACHABLE:
    reason = ps._hub_addr_is_not_reachable_from_a_phone(addr)
    if reason:
        ok(f"refused {addr} ({why})")
    else:
        bad(f"ACCEPTED {addr}, which the phone cannot open ({why})")

for addr, why in REACHABLE:
    reason = ps._hub_addr_is_not_reachable_from_a_phone(addr)
    if reason is None:
        ok(f"accepted {addr} ({why})")
    else:
        bad(f"REFUSED {addr}, which is reachable ({why}): {reason}")

# The guard has to be REACHED by the real validator, not merely present.
env = {
    "v": 1,
    "rp_id": "creativemachines.ai",
    "hub_addr": "fe80::1%en0",
    "pairing_token": "t",
    "expires_at": 1,
}
problem = ps._validate_envelope(env)
if problem and "link-local" in problem:
    ok("the real envelope validator REJECTS a link-local hub_addr, so the guard is reached")
else:
    bad(f"the envelope validator did not reject it: {problem!r}")

# CONTROL: the same envelope with a reachable address must pass, otherwise the
# rejection above proves nothing about the address.
env_ok = dict(env, hub_addr="192.168.1.72:8443")
problem_ok = ps._validate_envelope(env_ok)
if problem_ok is None:
    ok("CONTROL: the identical envelope with a routable address passes, so the refusal is about the address")
else:
    bad(f"CONTROL FAILED: a good envelope was rejected: {problem_ok!r}")

print(f"PASS={PASS} FAIL={FAIL} CANNOT-RUN=0")
sys.exit(0 if FAIL == 0 and PASS >= 12 else 1)
