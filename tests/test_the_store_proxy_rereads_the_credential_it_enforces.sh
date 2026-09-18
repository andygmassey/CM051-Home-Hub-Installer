#!/usr/bin/env bash
# A credential the proxy never re-reads is a credential it does not enforce.
#
# nginx READS ITS CONFIG AT START. ostler-store-auth.conf is a :ro bind-mount, so
# the host copy is live, but a proxy that is ALREADY RUNNING keeps enforcing the
# credential it read when it started. `docker compose up -d` does not restart a
# container whose spec has not changed, so the new token is written and never
# enforced.
#
# MEASURED ON THE MINI 2026-09-18, as an accidental controlled experiment. Same
# artefact, same box, same installer sha, twice, with ONE variable:
#
#   install 1   store secrets REUSED   privacy-backfill 401s: 0
#   install 2   store token FRESH      privacy-backfill 401s: 1
#
#   ostler-store-proxy started      16:23:30Z
#   ostler-store-auth.conf written  16:24:25Z   55 seconds LATER
#
# Source, client and server token were all 64 chars and all EQUAL, and the file
# inside the container matched the host byte for byte. Nothing was mismatched;
# nginx had simply not re-read it. The consequence reaches a person: privacy
# backfill and places-ingest both 401 against 7878, and the install prints
# "Privacy backfill did not complete (rc=1); readers stay fail-closed."
#
# A FIRST-TIME CUSTOMER INSTALL ALWAYS MINTS FRESH.
#
# THE CAVEAT, CARRIED BECAUSE IT DECIDES THE SIZE: the measured box had a
# PRE-EXISTING proxy container that was restarted. A first-ever install CREATES
# that container and creation may happen after the config write. Only a
# genuinely virgin box settles whether every new customer hits it. What is
# certain is that the ordering is wrong and the one reproducible condition
# reproduced it exactly.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - "$@" <<'PY'
import pathlib, re, sys

PASS, FAIL = [], []
def ok(m):   PASS.append(m); print("  [PASS] %s" % m)
def bad(m):  FAIL.append(m); print("  [FAIL] %s" % m)
def cant(m): print("CANNOT-RUN: %s" % m, file=sys.stderr); sys.exit(2)

RELOAD = "_ostler_reload_store_proxy_if_running"
AUTH = "ostler-store-auth.conf"


def analyse(lines):
    writes = [i + 1 for i, l in enumerate(lines)
              if AUTH in l and l.lstrip().startswith("cat >")]
    call = next((i + 1 for i, l in enumerate(lines)
                 if l.startswith(RELOAD) and not l.rstrip().endswith("{")), None)
    ups = [i + 1 for i, l in enumerate(lines)
           if "docker compose up -d" in l and "store-proxy" in l
           and not l.strip().startswith("#")]
    # does the helper guard on the container actually running?
    guarded = False
    start = next((i for i, l in enumerate(lines) if l.startswith(RELOAD + "()")), None)
    if start is not None:
        depth = 0
        for i in range(start, len(lines)):
            depth += lines[i].count("{") - lines[i].count("}")
            if "docker ps" in lines[i]:
                guarded = True
            if i > start and depth <= 0:
                break
    return writes, call, ups, guarded


print("-- controls: the ordering predicate must fire in both directions --")

GOOD = ['cat > "${OSTLER_DIR}/ostler-store-auth.conf" <<SAEOF', 'SAEOF',
        '%s() {' % RELOAD, '    docker ps --format x', '}', RELOAD,
        '    if docker compose up -d qdrant oxigraph redis store-proxy; then']
w, c, u, g = analyse(GOOD)
if w and c and u and max(w) < c < u[0] and g:
    ok("CONTROL: write then reload then up, with the running-container guard, reads as correct")
else:
    bad("CONTROL: a correct fixture did not read as correct (w=%s c=%s u=%s guard=%s). "
        "The reader is broken." % (w, c, u, g))

MISSING = [l for l in GOOD if not l.startswith(RELOAD) or l.endswith("{")]
MISSING = ['cat > "${OSTLER_DIR}/ostler-store-auth.conf" <<SAEOF', 'SAEOF',
           '    if docker compose up -d qdrant oxigraph redis store-proxy; then']
w, c, u, g = analyse(MISSING)
if c is None:
    ok("CONTROL: a tree with no reload at all is detected, so this gate can fail")
else:
    bad("CONTROL: a missing reload was not detected. This gate cannot fail.")

LATE = ['cat > "${OSTLER_DIR}/ostler-store-auth.conf" <<SAEOF', 'SAEOF',
        '    if docker compose up -d qdrant oxigraph redis store-proxy; then',
        '%s() {' % RELOAD, '    docker ps --format x', '}', RELOAD]
w, c, u, g = analyse(LATE)
if w and c and u and c > u[0]:
    ok("CONTROL: a reload placed AFTER the compose up is detected as mis-ordered")
else:
    bad("CONTROL: a reload after the compose up was not detected as mis-ordered")

print("-- subject: install.sh --")
path = pathlib.Path("install.sh")
if not path.is_file():
    cant("install.sh is not a file")
lines = path.read_text(encoding="utf-8").split("\n")
writes, call, ups, guarded = analyse(lines)

print("     EXAMINED: %d line(s); %d auth-config write(s); %d store-proxy compose up(s)"
      % (len(lines), len(writes), len(ups)))

if not writes:
    cant("no %s write was found, so ordering was not measured. The write form "
         "changed and this gate is blind." % AUTH)
if not ups:
    cant("no store-proxy compose up was found, so there is nothing to order "
         "against")

if call is None:
    bad("%s is never CALLED. A proxy that is already running keeps enforcing the "
        "PREVIOUS credential, so on any box where it exists the token is written "
        "and never enforced, and readers 401 against 7878." % RELOAD)
else:
    if call > max(writes):
        ok("the reload at line %d runs after every auth-config write (%s)"
           % (call, ", ".join(str(w) for w in writes)))
    else:
        bad("the reload at line %d runs BEFORE an auth-config write at %d, so the "
            "credential it reloads is not the one just written"
            % (call, max(writes)))
    if call < ups[0]:
        ok("the reload precedes the store-proxy compose up at line %d, so a fresh "
           "install is unaffected and an existing one is corrected" % ups[0])
    else:
        bad("the reload at line %d runs after the compose up at %d"
            % (call, ups[0]))
    if guarded:
        ok("the reload is guarded on the container actually running, so a first "
           "install and a box with no docker yet both do nothing")
    else:
        bad("the reload is not guarded on the container running, so it will "
            "report a failure on every first install, where there is correctly "
            "nothing to reload")

print()
print("== %d pass / %d fail / %d total ==" % (len(PASS), len(FAIL), len(PASS) + len(FAIL)))
sys.exit(1 if FAIL else 0)
PY
