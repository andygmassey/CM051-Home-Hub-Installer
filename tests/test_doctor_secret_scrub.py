#!/usr/bin/env python3
"""Credential scrub guard for the vendored Doctor support bundle.

WHAT THIS PROTECTS

``_redact_report`` builds the text behind the Doctor's "Copy redacted"
button, which a customer pastes into a support email. A credential in
that text leaves the machine. The scrub is grafted into the vendored
tree (HR015 a1245dc6, held pin), so nothing upstream guards the copy
that actually ships.

WHY IT READS THE FILE INSTEAD OF IMPORTING IT

``web_ui.py`` imports fastapi, and CI has no third-party deps -- the
same constraint that makes tests/test_vendor_import_resolution.py a
static guard. So this parses the vendored source and compiles the
REAL ``_SECRET_LABEL_RE`` assignment out of it. It never restates the
pattern: a hand-copied regex would drift from the shipped one and pass
while the artefact was broken, which is the defect class this repo
keeps meeting. Full behavioural coverage (calling _redact_report in a
venv with fastapi) is a local step; this is the part CI can hold.

WHAT IT ASSERTS
  1. the assignment exists and compiles
  2. it matches the labelled credential forms, INCLUDING the canonical
     ``Authorization: Bearer <token>`` shape
  3. it does NOT match ordinary prose
  4. ``_redact_report`` actually references it -- a correct pattern that
     nothing applies redacts nothing
  5. a positive control: a deliberately-neutered pattern must fail (2),
     so a green here cannot come from assertions that never fire

No credential-shaped literal is written into this file; every token is
composed at runtime, because the repo's own PII hook scans this file and
a guard must not carry the thing it hunts.
"""
import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WEB_UI = os.path.join(REPO, "vendor", "doctor", "agent", "web_ui.py")

PASS = FAIL = 0


def ok(msg):
    global PASS
    print(f"  PASS  {msg}")
    PASS += 1


def bad(msg):
    global FAIL
    print(f"  FAIL  {msg}")
    FAIL += 1


def token():
    return "AB" + "12" + "CD" + "34"


print("doctor credential scrub (vendored web_ui.py)")

if not os.path.isfile(WEB_UI):
    print(f"  CANNOT-RUN: no vendored web_ui.py at {WEB_UI}")
    print("  A missing subject is not a pass.")
    sys.exit(2)

src = open(WEB_UI, encoding="utf-8").read()
tree = ast.parse(src)

# ---- 1. Find the real assignment and compile it. ------------------------
pattern_src = None
for node in ast.walk(tree):
    if not isinstance(node, ast.Assign):
        continue
    names = [t.id for t in node.targets if isinstance(t, ast.Name)]
    if "_SECRET_LABEL_RE" not in names:
        continue
    call = node.value
    if isinstance(call, ast.Call) and call.args:
        try:
            pattern_src = ast.literal_eval(call.args[0])
        except ValueError:
            pattern_src = None
    break

if not isinstance(pattern_src, str):
    bad("_SECRET_LABEL_RE not found as a compilable literal in the vendored web_ui.py")
    print(f"\n=== {PASS} passed / {FAIL} failed ===")
    sys.exit(1)
ok("_SECRET_LABEL_RE present and its pattern is a literal")

RX = re.compile(pattern_src)

# ---- 2/3. What it must and must not match. ------------------------------
TOK = token()
MUST_MATCH = [
    f"pair code: {TOK}",
    f"pair_code={TOK}",
    f"pairing-code: {TOK}",
    f"access token: {TOK}",
    f"api_key={TOK}",
    f"verify token: {TOK}",
    f"app_secret: {TOK}",
    # The canonical HTTP form. Upstream's pattern required a separator
    # immediately AFTER the label, so `bearer` never fired on this and a
    # bearer token reached the report in the clear.
    f"Authorization: Bearer {TOK}",
]
MUST_NOT_MATCH = [
    "the pair code was requested but never entered",
    "no api key is configured for this install",
]


def check_pattern(rx, label):
    hits = [s for s in MUST_MATCH if rx.search(s)]
    misses = [s for s in MUST_MATCH if not rx.search(s)]
    false_pos = [s for s in MUST_NOT_MATCH if rx.search(s)]
    return hits, misses, false_pos


hits, misses, false_pos = check_pattern(RX, "real")
if not misses:
    ok(f"all {len(MUST_MATCH)} labelled credential forms match (incl. Authorization: Bearer)")
else:
    for m in misses:
        label = m.split(":")[0].split("=")[0]
        bad(f"credential form NOT matched, value would ship in the clear: {label!r}")

if not false_pos:
    ok("ordinary prose is not matched (a scrub that eats prose gets switched off)")
else:
    for f in false_pos:
        bad(f"false positive on prose: {f!r}")

# The value must be what gets replaced, not the scheme word.
m = RX.search(f"Authorization: Bearer {TOK}")
if m and TOK not in RX.sub(lambda mm: f"{mm.group(1)}: X", f"Authorization: Bearer {TOK}"):
    ok("the TOKEN is consumed, not just the scheme name")
else:
    bad("substitution leaves the token behind -- the scheme word was consumed instead")

# ---- 4. It must actually be applied. ------------------------------------
applied = False
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "_redact_report":
        applied = any(
            isinstance(n, ast.Name) and n.id == "_SECRET_LABEL_RE"
            for n in ast.walk(node)
        )
        break
if applied:
    ok("_redact_report references _SECRET_LABEL_RE (pattern is wired, not orphaned)")
else:
    bad("_redact_report does NOT reference _SECRET_LABEL_RE -- the scrub never runs")

# ---- 5. Positive control on this file's own assertions. -----------------
# Upstream's shape: label then a REQUIRED [:=]. It cannot match the
# canonical Authorization header, so the miss-detection above must fire.
UPSTREAM_SHAPE = re.compile(
    r"(?i)\b(pair[\s_-]?code|pairing[\s_-]?code|access[\s_-]?token|api[\s_-]?key"
    r"|verify[\s_-]?token|app[\s_-]?secret|bearer)\b\s*[:=]\s*\S+"
)
_, ctrl_misses, _ = check_pattern(UPSTREAM_SHAPE, "control")
if ctrl_misses:
    ok(f"CONTROL: the pre-fix pattern shape misses {len(ctrl_misses)} form(s), so these assertions discriminate")
else:
    bad("CONTROL did not fire -- these assertions would pass on a known-holed pattern")

print(f"\n=== {PASS} passed / {FAIL} failed ===")
sys.exit(1 if FAIL else 0)
