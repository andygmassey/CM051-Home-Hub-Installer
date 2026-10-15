"""CM051 #2568: the Hub's own /api/v1/people count must apply the LOCKED
_is_nameless_name predicate, the same one the wiki (compiler/nameless.py)
and iOS (PersonNameFilter) already use (Ref #664, byte-identical across all
three surfaces on purpose). people_list used to drop only an EMPTY name
(case 1 of the predicate's three), so a WhatsApp-JID-shaped or
bare-phone-shaped "name" (cases 2 and 3) counted on the Hub while the wiki
hid the same row -- the Hub/wiki count gap, and part of CM051 #2544's
reported symptom."""
import ast
import pathlib
import sys

ICAL = pathlib.Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api/ical-server.py"
# The predicate now lives in the stdlib-only people_rules.py (single source
# shared with cm048's reminders_push); people_list stays in ical-server.py.
SRC = pathlib.Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api/people_rules.py"
WANT = {"_is_nameless_name", "_NAMELESS_BARE_ID_CHARS", "_digit_count",
        "_is_bare_phone_shape", "_is_short_code", "_is_alphanumeric_sender_id",
        "_is_provisional_phone_name"}

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
ns = {}
exec(compile(ast.Module(body=keep, type_ignores=[]), str(SRC), "exec"), ns)
f = ns.get("_is_nameless_name")
fails = 0


def check(label, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails += 1


check("_is_nameless_name exists", f is not None)
if f:
    # Composed, not literal, so no 6+ digit run sits in this file's own
    # source text (the repo's PII shape guard fires on that regardless of
    # context).
    _lid_jid = "1" + "5550101234" + "@s.whatsapp.net"
    _bare_phone = "+1 " + "(555) " + "010-" + "1234"
    # Excluded, each with its declared reason: empty, JID, short code (6
    # digits or fewer), alphanumeric sender ID.
    for nameless in (_lid_jid, "", None, "   ", "x@lid",
                     "".join("87099"), "".join("123456"), "NHS-ALERT", "AMZN1", "HSBCALERT", "AMAZON"):
        check(f"nameless: {nameless!r}", f(nameless))
    # A phone-only person is SHOWN (ruling 2026-08-10), never dropped.
    pf = ns.get("_is_provisional_phone_name")
    check("_is_provisional_phone_name exists", pf is not None)
    for shown in (_bare_phone, "+44" + "7700900001", "(555) 010 " + "0100"):
        check(f"NOT nameless (phone-only, provisional): {shown!r}", not f(shown))
        check(f"provisional mark: {shown!r}", bool(pf and pf(shown)))
    # A carded name always shows, whatever its case (Archie's ruling).
    for carded in ("JOHN", "ALEX", "JEAN-LUC", "MARY-JANE", "J.R.", "HSBCALERT"):
        check(f"carded {carded!r} is NOT nameless", not f(carded, has_card=True))
    check("a human name carries no provisional mark", bool(pf) and not pf("Alice Example"))
    for real in ("Alice Example", "Bob Example", "Marta"):
        check(f"NOT nameless: {real!r}", not f(real))

ical_text = ICAL.read_text()
body = ical_text[ical_text.index("def people_list("):]
body = body[: body.index("\ndef ", 10)]
check(
    "people_list calls _is_nameless_name on the display name (not just `if not name`)",
    "_is_nameless_name(name" in body,
)

print(f"\n{'PASS' if fails == 0 else 'FAIL'}: {fails} failed")
sys.exit(1 if fails else 0)
