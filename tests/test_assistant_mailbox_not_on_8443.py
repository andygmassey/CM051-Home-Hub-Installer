#!/usr/bin/env python3
"""The assistant-mailbox routes are never on the 8443 companion listener.

Archie ruling (own-email, condition b): the Doctor's mailbox routes carry no
paired credential, so they must stay loopback-only. The companion listener
(:8443, reachable from the tailnet) serves exactly ostler-assistant's
FROZEN_COMPANION_ALLOWLIST (crates/zeroclaw-gateway/src/lib.rs), and that
repo's own test proves the router equals the list. This reads the list and
fails if any entry, wildcards included, would match a mailbox path.

    python3 tests/test_assistant_mailbox_not_on_8443.py <ostler-assistant checkout>
    python3 tests/test_assistant_mailbox_not_on_8443.py --self-test

Exit 0 none matched, 1 a mailbox path is on 8443, 2 CANNOT-RUN (the list could
not be read, or is implausibly short). Never a silent pass.
"""
import os
import re
import sys
import tempfile

MAILBOX_PATHS = [
    "/api/v1/assistant-mailbox",
    "/api/v1/assistant-mailbox/on",
    "/api/v1/assistant-mailbox/off",
    "/api/v1/assistant-mailbox/test-now",
    "/api/v1/assistant-mailbox/replace-password",
    "/api/assistant-mailbox/self-test",
]
REL = os.path.join("crates", "zeroclaw-gateway", "src", "lib.rs")


def allowlist(src):
    m = re.search(r"const FROZEN_COMPANION_ALLOWLIST[^=]*=\s*&\[(.*?)\n\s*\];", src, re.S)
    if not m:
        return None
    return re.findall(r'\(\s*"([^"]+)"\s*,', m.group(1))


def pattern(entry):
    out = ""
    for part in re.split(r"(\{\*[^}]+\}|\{[^}]+\})", entry):
        if part.startswith("{*"):
            out += ".*"
        elif part.startswith("{"):
            out += "[^/]+"
        else:
            out += re.escape(part)
    return re.compile("^" + out + "$")


def check(oa_dir):
    try:
        with open(os.path.join(oa_dir, REL), encoding="utf-8") as f:
            src = f.read()
    except OSError as e:
        return 2, ["CANNOT-RUN: %s unreadable (%s)" % (REL, e.strerror)]
    entries = allowlist(src)
    if not entries or len(entries) < 10:
        return 2, ["CANNOT-RUN: FROZEN_COMPANION_ALLOWLIST not found or implausibly short (%d)" % len(entries or [])]
    hits = [(p, e) for p in MAILBOX_PATHS for e in entries if pattern(e).match(p)]
    lines = ["examined %d allowlist entries x %d mailbox paths" % (len(entries), len(MAILBOX_PATHS))]
    for p, e in hits:
        lines.append("FAIL: %s is served on 8443 (allowlist entry %s)" % (p, e))
    if not hits:
        lines.append("ok: no mailbox path is on the 8443 allowlist")
    return (1 if hits else 0), lines


def self_test():
    ok = True
    base = '    const FROZEN_COMPANION_ALLOWLIST: &[(&str, &[&str], bool)] = &[\n%s\n    ];\n'
    real = "\n".join('        ("/api/v1/x%d", &["GET"], false),' % i for i in range(12))
    arms = [
        ("a clean list passes", real, 0),
        ("an exact mailbox entry fails", real + '\n        ("/api/v1/assistant-mailbox", &["GET"], false),', 1),
        ("a wildcard that swallows the mailbox fails", real + '\n        ("/api/v1/{*rest}", &["GET"], false),', 1),
        ("the gateway self-test route fails", real + '\n        ("/api/assistant-mailbox/self-test", &["POST"], false),', 1),
        ("an empty list is CANNOT-RUN", "", 2),
    ]
    with tempfile.TemporaryDirectory() as root:
        for i, (name, body, want) in enumerate(arms):
            d = os.path.join(root, str(i))
            os.makedirs(os.path.join(d, os.path.dirname(REL)))
            with open(os.path.join(d, REL), "w") as f:
                f.write(base % body)
            rc, _ = check(d)
            good = rc == want
            ok &= good
            print("  %s %s: rc=%d (want %d)" % ("ok  " if good else "FAIL", name, rc, want))
        rc, _ = check(os.path.join(root, "absent"))
    ok &= rc == 2
    print("  %s a missing checkout is CANNOT-RUN" % ("ok  " if rc == 2 else "FAIL"))
    return ok


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(0 if self_test() else 1)
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    rc, lines = check(sys.argv[1])
    print("\n".join(lines))
    sys.exit(rc)
