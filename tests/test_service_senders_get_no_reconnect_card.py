"""A service sender (Skype, PayPal, a no-reply mailbox) must never get a
"you have gone quiet" reconnect card. Seen on the v1.0.105 console walk."""
import pathlib, sys

SRC = pathlib.Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api/ical-server.py"

WANT = {"_SERVICE_SENDER_NAMES", "_SERVICE_MAILBOX_LOCALPARTS", "_is_service_sender"}

def load():
    """Lift only the predicate and its tables: the full module needs the
    product's encrypted-store stack, which a unit test must not require."""
    import ast
    try:
        tree = ast.parse(SRC.read_text())
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
    if "_is_service_sender" not in ns:
        print("FAIL: no _is_service_sender in the reconnect source: service senders get cards")
        sys.exit(1)
    return type("M", (), {"_is_service_sender": staticmethod(ns["_is_service_sender"])})

def main():
    m = load()
    f = m._is_service_sender
    fails = 0
    cases = [
        (("Skype", None), True, "known service brand"),
        (("PayPal", []), True, "known service brand"),
        (("Some Sender", ["noreply@example.com"]), True, "only a no-reply mailbox"),
        (("AcmeAlerts", ["alerts@acme.example", "notifications@acme.example"]), True, "only role mailboxes"),
        (("Jane Doe", ["jane@example.com"]), False, "a person"),
        (("Jane Doe", ["jane@example.com", "noreply@example.com"]), False, "a person with one personal address"),
        (("Skypebridge Testperson", None), False, "a name that merely starts like a brand"),
        (("", None), False, "empty is not this predicate's job"),
    ]
    for (args, want, why) in cases:
        got = f(*args)
        ok = got == want
        fails += not ok
        print(("ok  " if ok else "FAIL"), args[0] or "<empty>", "->", got, "|", why)
    src = SRC.read_text()
    calls = src.count("_is_service_sender(name")
    ok = calls >= 2
    fails += not ok
    print(("ok  " if ok else "FAIL"), f"reconnect and birthday paths both screen service senders ({calls} call sites)")
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
