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


# =========================================================================
# HR015 5116a151 (#415 / #480) -- THREE EXITS LEAKED SECRETS
# =========================================================================
#
# Grafted into the vendored tree 2026-08-19. All three limbs were present
# verbatim in the copy that ships, so these are not hypotheticals:
#
#   web_ui.py  mailto = _build_mailto(report)
#       "Send by Email" is the ONLY one of the three buttons that transmits
#       off the machine, and it was the only one that did not scrub.
#   web_ui.py  report_redacted = report      (in the except arm)
#       The redactor FAILED OPEN. Any exception inside it handed the caller
#       the raw report under the name of the redacted one, and the button
#       labelled "Copy redacted" copied an unredacted bundle with no
#       visible change.
#   web_ui.py  the leading \b in _SECRET_LABEL_RE
#       `_` is a word character, so in `redis_password` there is no word
#       boundary before `password` and the pattern never engaged. That is
#       the naming convention config files actually use.
#
# Each control below carries its own discriminator, so a green cannot come
# from an assertion that never fires.

# ---- 6. PREFIXED labels. The class the leading \b was blind to. ---------
PREFIXED = [
    f"redis_password: {TOK}",
    f"admin_token={TOK}",
    f"service_secret: {TOK}",
    f"db.password={TOK}",
]
pre_misses = [s for s in PREFIXED if not RX.search(s)]
if not pre_misses:
    ok(f"all {len(PREFIXED)} PREFIXED credential labels match (redis_password, admin_token, ...)")
else:
    for s in pre_misses:
        bad(f"prefixed label NOT matched, value ships in the clear: {s.split(chr(61))[0].split(chr(58))[0]!r}")

# CONTROL for (6): the pre-graft pattern must MISS these. Without it, a
# pattern that matched prefixes for some unrelated reason would still pass
# and we would learn nothing.
#
# 🔴 THE CONTROL CORRECTED ME ON ITS FIRST RUN, which is the only reason it
# is worth having. I wrote it over all four forms above and it went red on
# `db.password=`. It was right and my grouping was wrong: `.` is NOT a word
# character, so `\b` DOES engage before `password` there. The blind spot is
# specifically the UNDERSCORE-prefixed form -- and underscore is exactly
# what config files use. Naming the class loosely would have made the
# control unfalsifiable; it is scoped to the forms that were genuinely
# invisible.
UNDERSCORE_PREFIXED = [s for s in PREFIXED if "." not in s.split(":")[0].split("=")[0]]
PREFIX_BLIND = re.compile(
    r"(?i)\b(password|secret|token)\b\s*[:=]\s*\S+"
)
if UNDERSCORE_PREFIXED and all(not PREFIX_BLIND.search(s) for s in UNDERSCORE_PREFIXED):
    ok(f"CONTROL: the pre-graft \\b-anchored shape misses ALL {len(UNDERSCORE_PREFIXED)} "
       "underscore-prefixed labels, so (6) discriminates")
else:
    bad("CONTROL did not fire -- (6) would pass on the known-blind pattern")

# ---- 7. The UNLABELLED recovery key, matched by SHAPE. ------------------
recovery_src = None
for node in ast.walk(tree):
    if not isinstance(node, ast.Assign):
        continue
    if "_RECOVERY_KEY_RE" not in [t.id for t in node.targets if isinstance(t, ast.Name)]:
        continue
    call = node.value
    if isinstance(call, ast.Call) and call.args:
        try:
            recovery_src = ast.literal_eval(call.args[0])
        except ValueError:
            recovery_src = None
    break

if not isinstance(recovery_src, str):
    bad("_RECOVERY_KEY_RE absent -- the BARE recovery key in install.log has no label to anchor on "
        "and every label added above is blind to it")
else:
    ok("_RECOVERY_KEY_RE present and its pattern is a literal")
    RK = re.compile(recovery_src)
    # The measured shape is RAGGED: six groups of four then a final group
    # of TWO. A predicate written for a uniform 6x4 stops at the sixth
    # group and leaks the tail; one for a uniform 7x4 matches nothing.
    RAGGED = "-".join(["ABCD"] * 6) + "-EF"
    if RK.search(RAGGED) and RK.sub("X", RAGGED) == "X":
        ok("_RECOVERY_KEY_RE consumes the WHOLE ragged key, short final group included")
    else:
        bad("_RECOVERY_KEY_RE does not consume the ragged shape -- the tail would leak")
    # NEGATIVE CONTROL, and it is the one that matters. A real report
    # carries hundreds of UUIDs. A matcher that eats them destroys the
    # diagnostic value of the report, and the usual repair is to loosen it
    # until it stops matching the key at all.
    UUID = "3f2a1b9c-1234-5678-9abc-def012345678"
    if not RK.search(UUID):
        ok("NEGATIVE CONTROL: a UUID is NOT redacted (a matcher that eats UUIDs gets loosened until it is useless)")
    else:
        bad("_RECOVERY_KEY_RE matches a UUID -- it will redact the whole report and then be loosened away")

# ---- 8. Both new patterns are APPLIED, not merely defined. --------------
for name in ("_RECOVERY_KEY_RE", "_SLUG_EMAIL_RE"):
    applied = False
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "_redact_report":
            applied = any(
                isinstance(n, ast.Name) and n.id == name for n in ast.walk(node)
            )
            break
    if applied:
        ok(f"_redact_report applies {name}")
    else:
        bad(f"_redact_report does NOT apply {name} -- defined and never used redacts nothing")

# ---- 9. The mailto must carry the REDACTED bundle. ----------------------
# Measured on the call node, not on a grep: `_build_mailto(report)` and
# `_build_mailto(report_redacted)` differ by one identifier and a grep for
# the function name matches both.
mailto_args = []
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    fn = node.func
    if isinstance(fn, ast.Name) and fn.id == "_build_mailto":
        mailto_args.append([a.id if isinstance(a, ast.Name) else "<expr>" for a in node.args])

if not mailto_args:
    bad("no call to _build_mailto found -- the support-email path moved and this control is now blind")
elif all(args and args[0] == "report_redacted" for args in mailto_args):
    ok(f"every _build_mailto call ({len(mailto_args)}) is passed report_redacted, not the raw report")
else:
    bad(f"_build_mailto is passed the RAW report {mailto_args!r} -- the only button that transmits "
        "off the machine is the only one that does not scrub")

# ---- 10. Redaction must FAIL CLOSED. ------------------------------------
# A redactor that falls back to the raw report is not a redactor. Asserted
# structurally: inside _run_diagnostics, no handler may bind
# report_redacted to the raw report.
fail_open = False
fail_closed = False
for node in ast.walk(tree):
    if not (isinstance(node, ast.FunctionDef) and node.name == "_run_diagnostics"):
        continue
    for n in ast.walk(node):
        if not (isinstance(n, ast.Assign) and
                any(isinstance(t, ast.Name) and t.id == "report_redacted" for t in n.targets)):
            continue
        v = n.value
        if isinstance(v, ast.Name) and v.id == "report":
            fail_open = True
        if isinstance(v, ast.Name) and v.id == "REPORT_REDACTION_FAILED":
            fail_closed = True
    break

if fail_open:
    bad("redaction FAILS OPEN: report_redacted is bound to the raw report on the error path, so "
        "'Copy redacted' copies an unredacted bundle with no visible change")
elif fail_closed:
    ok("redaction FAILS CLOSED: the error path returns REPORT_REDACTION_FAILED, not the raw report")
else:
    bad("could not find the report_redacted error path in _run_diagnostics -- this control is blind, "
        "which is not the same as a pass")

print(f"\n=== {PASS} passed / {FAIL} failed ===")
sys.exit(1 if FAIL else 0)
