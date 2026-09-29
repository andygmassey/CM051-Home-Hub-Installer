"""A record whose only name is a role or automation mailbox is not listed as a
person on the Hub People screen. Seen on the v1.0.106 walk: support and
promotions mailboxes in the list. Hidden from the LIST only, never deleted.
Judged by the local part, so a personal address at any domain stays listed."""
import ast
import pathlib
import re
import sys

SRC = pathlib.Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api/ical-server.py"
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
if f:
    for hidden in ("support@example.com", "promotions@shop.example", "no-reply@x.example",
                   "newsletter@x.example", "info@x.example", "team.updates@x.example"):
        check(f"hidden: {hidden}", f(hidden))
    for kept in ("someone" + "@" + "examplemail.co.uk", "a.person" + "@" + "bigco-group.com",
                 "promo" + "nent.name@x.example", "a real name", "", None):
        check(f"kept: {kept!r}", not f(kept))

body = text[text.index("def people_list("):]
body = body[: body.index("\ndef ", 10)]
check("people_list skips a role-address-only name", "_is_role_address_name(name)" in body)

print(f"\n{'PASS' if fails == 0 else 'FAIL'}: {fails} failed")
sys.exit(1 if fails else 0)
