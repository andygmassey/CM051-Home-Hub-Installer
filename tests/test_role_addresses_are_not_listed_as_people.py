"""A record whose only name is a role or automation mailbox is not listed as a
person on the Hub People screen. Seen on the v1.0.106 walk: support and
promotions mailboxes in the list. Hidden from the LIST only, never deleted.
Judged by the local part, so a personal address at any domain stays listed."""
import ast
import pathlib
import re
import sys

API = pathlib.Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api"
ICAL = API / "ical-server.py"
# The rule is DEFINED in the stdlib-only people_rules.py (single source shared
# with cm048's reminders_push) and must be IMPORTED by ical-server.py, which
# serves the People list.
SRC = API / "people_rules.py"
WANT = {"_ROLE_ADDRESS_LOCAL_RE", "_is_role_address_name"}

try:
    text = SRC.read_text()
    tree = ast.parse(text)
except (OSError, SyntaxError) as exc:
    print("CANNOT-RUN: could not parse", SRC, exc)
    sys.exit(2)
keep = []
for node in tree.body:
    names = set()
    if isinstance(node, ast.FunctionDef):
        names = {node.name}
    elif isinstance(node, ast.Assign):
        names = {t.id for t in node.targets if isinstance(t, ast.Name)}
    if names & WANT:
        keep.append(node)
ns = {"re": re}
exec(compile(ast.Module(body=keep, type_ignores=[]), str(SRC), "exec"), ns)
f = ns.get("_is_role_address_name")
fails = 0


def check(label, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails += 1


check("_is_role_address_name exists", f is not None)

# LIVE ON THE SERVED PATH: ical-server.py must import both names from
# people_rules (a definition nobody imports hides nothing).
_imported = set()
for _n in ast.walk(ast.parse(ICAL.read_text())):
    if isinstance(_n, ast.ImportFrom) and _n.module == "people_rules":
        _imported |= {a.name for a in _n.names}
check("ical-server.py imports _is_role_address_name from people_rules", "_is_role_address_name" in _imported)
check("ical-server.py imports _ROLE_ADDRESS_LOCAL_RE from people_rules", "_ROLE_ADDRESS_LOCAL_RE" in _imported)

# Behavioural, when the server's own dependencies are present: the object
# ical-server exposes is the one that hides a role address.
try:
    import importlib.util
    import os

    os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-role-address")
    _spec = importlib.util.spec_from_file_location("_ical_role_addr", ICAL)
    _srv = importlib.util.module_from_spec(_spec)
    sys.path.insert(0, str(API))
    try:
        _spec.loader.exec_module(_srv)
    finally:
        sys.path.remove(str(API))
    _fn = getattr(_srv, "_is_role_address_name", None)
    check("served path: ical-server's _is_role_address_name hides a role address",
          _fn is not None and _fn("support@example.com") is True and _fn("a real name") is False)
except (ImportError, RuntimeError) as _exc:
    print("  n/a   served-path behavioural arm needs the server's dependencies (%s); the import assertions above still run" % _exc)
if f:
    for hidden in ("support@example.com", "promotions@shop.example", "no-reply@x.example",
                   "newsletter@x.example", "info@x.example", "team.updates@x.example"):
        check(f"hidden: {hidden}", f(hidden))
    for kept in ("someone" + "@" + "examplemail.co.uk", "a.person" + "@" + "bigco-group.com",
                 "promo" + "nent.name@x.example", "a real name", "", None):
        check(f"kept: {kept!r}", not f(kept))

_ical_text = ICAL.read_text()
body = _ical_text[_ical_text.index("def people_list("):]
body = body[: body.index("\ndef ", 10)]
check("people_list skips a role-address-only name", "_is_role_address_name(name)" in body)

print(f"\n{'PASS' if fails == 0 else 'FAIL'}: {fails} failed")
sys.exit(1 if fails else 0)
