#!/usr/bin/env python3
"""#1611 -- the namespace migrator had no credential, and its refusal was silent.

WHY THIS EXISTS, and every link was measured on the shipped tree:

    install.sh   OSTLER_STORE_AUTH_ENFORCE defaults to 1, i.e. ON
    Oxigraph     401s a keyless request, body begins "<html>"
    migrator     built requests with Accept/Content-Type and NO credential
    migrator     a 401 hit the probe guard -> sys.exit(2)
    install.sh   case 2) : ;;   <- printed NOTHING

rc=2 is silenced ON PURPOSE: a fresh box genuinely has nothing to migrate. But
"the store is empty" and "the store is full and I was not allowed to look" are
opposite facts, and they printed identically. So the migration silently never
ran on any install carrying the shipped default.

NO FAKE STORE IS BOUND BY THIS TEST. The migrator hardcodes 127.0.0.1:7878, and
binding a stand-in there would impersonate the real service for every process on
a shared Mac -- a mock on a real service port has already cost this project one
unexplained hostile responder. The refusal path is exercised by calling the
function, which is the same code the transport reaches.

EXIT 0 green   1 RED   2 CANNOT-RUN
"""
import importlib.util
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUBJECT = os.path.join(HERE, "scripts", "migrate_graph_namespace.py")
INSTALL = os.path.join(HERE, "install.sh")

PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  [PASS] %s" % m)


def bad(m):
    global FAIL
    FAIL += 1
    print("  [FAIL] %s" % m, file=sys.stderr)


def cannot(m):
    print("  [CANNOT-RUN] %s" % m, file=sys.stderr)
    sys.exit(2)


if not os.path.exists(SUBJECT):
    cannot("no subject at %s" % SUBJECT)
if not os.path.exists(INSTALL):
    cannot("no install.sh at %s" % INSTALL)

spec = importlib.util.spec_from_file_location("mig", SUBJECT)
mig = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mig)
except SystemExit:
    pass
except Exception as e:  # noqa: BLE001
    cannot("subject would not import: %r" % (e,))

for fn in ("_load_store_headers", "_exit_probe_failure"):
    if not hasattr(mig, fn):
        cannot("subject has no %s; this test is measuring the wrong file" % fn)

# ── 1. THE FOUR CREDENTIAL STATES MUST DISCRIMINATE ─────────────────────────
# Collapsing them is how "0600, wrong account" gets reported as "no credential",
# which tells a tired human the opposite of true.
D = tempfile.mkdtemp()
absent = os.path.join(D, "nope.conf")

have = os.path.join(D, "have.conf")
# SYNTHETIC. Never a real token, and the value is never printed by the subject.
with open(have, "w") as fh:
    fh.write('header = "Authorization: Bearer SYNTHETIC-FIXTURE-VALUE"\n')

empty = os.path.join(D, "empty.conf")
with open(empty, "w") as fh:
    fh.write("# a comment and nothing else\n")

unread = os.path.join(D, "unread.conf")
with open(unread, "w") as fh:
    fh.write('header = "Authorization: Bearer SYNTHETIC-FIXTURE-VALUE"\n')
os.chmod(unread, 0)

seen = {}
for want, path in (("absent", absent), ("headers", have),
                   ("empty", empty), ("unreadable", unread)):
    hdrs, state = mig._load_store_headers(path)
    seen[want] = state
    if state == want:
        ok("credential state %-10s classified correctly" % want)
    else:
        bad("credential state %s classified as %s" % (want, state))

if os.geteuid() == 0 and seen.get("unreadable") != "unreadable":
    print("  [note] running as root, so the unreadable arm cannot be exercised")

if len(set(seen.values())) != 4:
    bad("CONTROL: the four states did not produce four distinct answers: %r" % seen)
else:
    ok("CONTROL: four inputs -> four distinct states, so the classifier is not constant")

# the header must actually be attached, not merely detected
hdrs, _ = mig._load_store_headers(have)
if hdrs.get("Authorization"):
    ok("a header line is parsed into a real Authorization header")
else:
    bad("a header line was NOT turned into an Authorization header: %r" % hdrs)

# ── 1b. THE HEADER MUST REACH THE REQUEST, NOT MERELY BE PARSED ────────────
# MUTATION-PROVEN NECESSARY. Without this arm the suite scored 15/15 against a
# mutant that parsed the credential and then never attached it -- i.e. it passed
# on a tree carrying the exact defect #1611 is about. Parsing is not sending.
#
# The opener is swapped for a recorder, so no socket is opened and no service is
# impersonated. Both transports are driven, because the fix had to be applied in
# two places and one could easily be missed.
# THE RECORDER MUST NOT RAISE. run() wraps the open in `except Exception` and
# converts anything thrown into a (out, err, rc) tuple, so a sentinel exception
# is swallowed and the arm reports "could not capture" -- which is what the
# first version of this arm did, and it looked like a subject failure rather
# than a harness one. Record and return a usable response instead.
_SEEN = []


class _Resp:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read(self):
        return b"{}"


class _Recorder:
    def open(self, req, timeout=None):  # noqa: D401
        _SEEN.append(req)
        return _Resp()


mig._STORE_CURL_CONF = have          # the fixture with one synthetic header
mig._OPENER = _Recorder()


def captured_headers(method):
    del _SEEN[:]
    try:
        if method == "GET":
            mig.run("local", "/store", "", "application/n-quads", method="GET")
        else:
            mig.run("local", "/query", "SELECT 1", "application/sparql-query")
    except Exception:  # noqa: BLE001
        pass
    return dict(_SEEN[0].headers) if _SEEN else None


for method in ("GET", "POST"):
    h = captured_headers(method)
    if h is None:
        bad("%s transport: could not capture a request at all" % method)
        continue
    # urllib capitalises header keys, so compare case-insensitively.
    keys = dict((k.lower(), v) for k, v in h.items())
    if "authorization" in keys:
        ok("%s transport ATTACHES the Authorization header to the request" % method)
    else:
        bad("%s transport built a request with NO Authorization header: %r"
            % (method, sorted(keys)))
    # CONTROL: the pre-existing headers must survive the merge, or the fix
    # would silently drop the Accept/Content-Type the store needs.
    if "accept" in keys:
        ok("CONTROL: %s transport still carries its Accept header" % method)
    else:
        bad("CONTROL: %s transport LOST its Accept header" % method)

# ── 2. A REFUSAL IS rc 3, AND ANYTHING ELSE IS STILL rc 2 ───────────────────
def exit_code_for(rc):
    try:
        mig._exit_probe_failure(rc, "stderr", "stdout")
    except SystemExit as e:
        return e.code
    return None


for rc in (401, 403):
    got = exit_code_for(rc)
    if got == 3:
        ok("HTTP %s exits 3 (REFUSED), not 2" % rc)
    else:
        bad("HTTP %s exited %r, expected 3" % (rc, got))

# CONTROL: a non-auth failure must NOT be promoted to 3, or the new arm would
# fire on an empty box and the fix would be worse than the defect.
for rc in (1, 7, 500):
    got = exit_code_for(rc)
    if got == 2:
        ok("CONTROL: rc %s still exits 2 (CANNOT-RUN), not 3" % rc)
    else:
        bad("CONTROL: rc %s exited %r, expected 2" % (rc, got))

# ── 3. install.sh MUST HAVE AN ARM THAT FIRES ON 3, WORDED HONESTLY ─────────
with open(INSTALL, "r", encoding="utf-8", errors="replace") as fh:
    sh = fh.read()

if re.search(r"^\s*3\)\s*$", sh, re.M):
    ok("install.sh has a case arm for rc 3")
else:
    bad("install.sh has NO arm for rc 3, so a refusal is still silent")

m = re.search(r"^\s*3\)\s*$(.*?)^\s*;;\s*$", sh, re.M | re.S)
arm = m.group(1) if m else ""
if "warn " in arm:
    ok("the rc 3 arm warns rather than staying silent")
else:
    bad("the rc 3 arm does not warn")

# A refusal means the store was NEVER written to. The sibling arm's wording
# ("may be part-migrated") would be a lie in the reassuring direction.
if "NOTHING in your store was changed" in arm:
    ok("the rc 3 arm states plainly that nothing was changed")
else:
    bad("the rc 3 arm does not state that nothing was changed")

if "part-migrated" in arm or "already have been rewritten" in arm:
    bad("the rc 3 arm reuses the sibling arm's wording, which is false for a refusal")
else:
    ok("CONTROL: the rc 3 arm does NOT claim a partial migration")

print("")
print("migrator credential + loud refusal: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
