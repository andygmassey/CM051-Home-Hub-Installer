#!/usr/bin/env bash
# The walk driver's port probe must not be STRICTER than the preflight it
# claims to predict.
#
# THE DEFECT, measured live on ttywalk run 9 (2026-09-04). The run refused:
#
#     WALK CANNOT-RUN: port preflight
#     2 of 6 declared port(s) are already held: 6333 8044. install.sh's own
#     preflight will refuse to start containers over them...
#
# Nothing held them. The run's OWN --reset had executed `colima stop` SEVEN
# SECONDS earlier, and netstat on the box showed ZERO LISTEN rows on both
# ports. What the bare bind() hit was TIME_WAIT. Demonstrated on an ephemeral
# port, same machine class:
#
#     netstat rows after close : 2, both TIME_WAIT; LISTEN rows: 0
#     bare bind()              : EADDRINUSE (errno 48)   -> reads "held"
#     bind + SO_REUSEADDR      : succeeds                <- what a server does
#
# So the harness manufactured the conflict it then refused on, and the quoted
# sentence was FALSE: install.sh does NOT refuse on that signal. Its
# `_check_port` (install.sh:15458) grades bind=held + 0 listeners as
# could-not-measure, in its own words because "Docker sets SO_REUSEADDR and
# may well survive it, so calling this a collision would block a working
# install".
#
# 🔴 THE INSTRUMENT WAS THE DEFECT, NOT THE PRODUCT. This test pins the
# driver's table to install.sh's, row by row, so the two cannot drift.
#
# rc=2 from this file means the harness could not set itself up.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${OSTLER_WALK_DRIVER:-${REPO_ROOT}/scripts/walk_drive.py}"
INSTALL_SH="${REPO_ROOT}/install.sh"

cannot() { echo "CANNOT-RUN [$1]: $2" >&2; exit 2; }

[ -f "${DRIVER}" ]     || cannot "driver-missing" "${DRIVER} not found -- nothing was checked."
[ -f "${INSTALL_SH}" ] || cannot "install-missing" "${INSTALL_SH} not found -- the contract has no other side."
command -v python3 >/dev/null 2>&1 || cannot "no-python3" "python3 is not on PATH."

python3 - "${DRIVER}" "${INSTALL_SH}" <<'PY'
import errno, importlib.util, socket, subprocess, sys

driver, install_sh = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("walk_drive_under_test", driver)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception as exc:                                  # noqa: BLE001
    print("CANNOT-RUN [import]: %s could not be imported: %s" % (driver, exc),
          file=sys.stderr)
    raise SystemExit(2)

for need in ("port_is_held", "port_bind_probe", "port_listeners"):
    if not hasattr(mod, need):
        print("CANNOT-RUN [premise]: the driver has no %r. The two-instrument "
              "table is what this file measures; without it nothing was "
              "measured." % need, file=sys.stderr)
        raise SystemExit(2)

# PREMISE: install.sh must still carry the adjudication we are pinning to.
# If _check_port were renamed or deleted, every arm below would still pass
# while measuring agreement with a contract that no longer exists.
try:
    with open(install_sh, "r", encoding="utf-8", errors="replace") as fh:
        install_body = fh.read()
except IOError as exc:
    print("CANNOT-RUN [premise]: install.sh unreadable: %s" % exc, file=sys.stderr)
    raise SystemExit(2)
for token in ("_check_port()", "_port_listeners()", "_port_bind_probe"):
    if token not in install_body:
        print("CANNOT-RUN [premise]: install.sh no longer defines %s. The "
              "driver's table is pinned to a contract that has moved; re-read "
              "install.sh before trusting either side." % token, file=sys.stderr)
        raise SystemExit(2)

rc = 0


def check(label, got, expected, why):
    global rc
    if got == expected:
        print("ok   %-46s -> %s" % (label, got))
    else:
        rc = 1
        print("FAIL %-46s -> %s, expected %s" % (label, got, expected))
        print("     %s" % why)


# ── The table, driven through the real port_is_held with stubbed limbs ──
#
# Stubbing the two probes is what makes every row reachable: a live box
# cannot be made to produce "bind=cant + listeners>=1" on demand. The
# ADJUDICATION under test is the driver's own; only its inputs are supplied.
ROWS = [
    ("free",   0,      "free",       "both instruments agree the port is idle"),
    ("held",   1,      "held",       "both agree: the REAL collision, must still be caught"),
    ("held",   0,      "unmeasured", "THE RUN-9 DEFECT. TIME_WAIT, not a collision."),
    ("free",   1,      "unmeasured", "a listener our bind did not hit; refuse to guess"),
    ("held",   "cant", "held",       "bind DEMONSTRATED the failure; netstat was corroboration"),
    ("cant",   0,      "unmeasured", "no authoritative instrument ran"),
    ("cant",   1,      "held",       "netstat alone, owner-blind, but a listener is a listener"),
    ("free",   "cant", "unmeasured", "only the weaker instrument spoke"),
]

real_bind, real_listen = mod.port_bind_probe, mod.port_listeners
try:
    for bind, listeners, expected, why in ROWS:
        mod.port_bind_probe = lambda _p, _b=bind: _b
        mod.port_listeners = lambda _p, _l=listeners: _l
        check("bind=%-5s listeners=%-4s" % (bind, listeners),
              mod.port_is_held(9999), expected, why)
finally:
    mod.port_bind_probe, mod.port_listeners = real_bind, real_listen

# ── The mechanism itself, on REAL sockets, on THIS host ──────────────
#
# The table above is only correct if TIME_WAIT genuinely produces
# bind=held + 0 listeners. That is a property of the kernel we ship onto,
# not of our code, so it is measured here rather than asserted.
#
# EPHEMERAL PORT ONLY. Binding a fixture to a real service port
# impersonates the service for anyone else on the machine.
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
cli = socket.socket(); cli.connect(("127.0.0.1", port))
con, _ = srv.accept()

check("a LIVE listener is held",
      mod.port_is_held(port), "held",
      "POSITIVE CONTROL. If this said anything else the probe would be blind "
      "to real collisions and every arm above would be vacuous.")

con.close(); cli.close(); srv.close()

listeners_now = mod.port_listeners(port)
bind_now = mod.port_bind_probe(port)
print("     after close: bind=%s listeners=%s" % (bind_now, listeners_now))
if bind_now == "held" and listeners_now == 0:
    check("TIME_WAIT is NOT a collision",
          mod.port_is_held(port), "unmeasured",
          "THE RUN-9 SHAPE, REPRODUCED LIVE. A bare bind() refuses while no "
          "listener exists. Grading it held is what refused the walk.")
else:
    # Not every kernel/timing leaves TIME_WAIT on this path. Say so, and do
    # NOT quietly count it as a pass -- an arm that did not run has not run.
    print("SKIP TIME_WAIT arm: this host produced bind=%s listeners=%s after "
          "close, so the shape was not reproduced here. The table arm above "
          "still pins the adjudication." % (bind_now, listeners_now))

if rc == 0:
    print("PASS: tests/test_walk_port_probe_matches_install_sh.sh "
          "(%d table rows + live controls)" % len(ROWS))
raise SystemExit(rc)
PY
