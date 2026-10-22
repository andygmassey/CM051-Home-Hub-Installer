"""Every Person the shared email-correspondent sink creates records its TRUE
source (People join fix 3).

The Google Chat Takeout importer hands its correspondents to the same sink
Apple Mail uses (universal_import._persist_mail_contacts ->
pwg_ingest.ingest_mail_contacts), which hardcoded pwg:source "apple_mail_fda"
and identifierLabel "APPLE_MAIL". So a Chat correspondent was minted as an
Apple Mail person. Synthetic addresses only (example.com).

Runs under plain python3 (no pytest), like its privacy-spine siblings.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor"))

from ostler_fda import pwg_ingest as m  # noqa: E402
from ostler_fda import universal_import as ui  # noqa: E402

FAILURES = []


def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        FAILURES.append(msg)


class FakeStore:
    def __init__(self):
        self.updates = []

    def update(self, sparql):
        self.updates.append(sparql)

    def created(self):
        src, lab = [], []
        for u in self.updates:
            if "a pwg:Person" in u:
                src += re.findall(r'pwg:source "([^"]+)"', u)
                lab += re.findall(r'pwg:identifierLabel "([^"]+)"', u)
        return src, lab


def install():
    st = FakeStore()
    m._sparql_update = st.update
    m._sparql_query = lambda q: []
    m._person_uri_by_identifier_value = lambda v: None
    m._live_person = lambda uri: (uri, False)
    m._upsert_display_name = lambda uri, v: None
    m.load_owner_addresses = lambda d: set()
    m._machine_senders.load = lambda d: (set(), set())
    m._is_forgotten = lambda v: False
    return st


CONTACTS = {"chat.friend@example.com": 9, "chat.colleague@example.com": 5}

print("== Google Chat correspondents ==")
st = install()
res = ui._persist_mail_contacts(dict(CONTACTS), source="google_chat")
src, lab = st.created()
check(res.get("people_created") == 2, f"two people created, got {res}")
check(src == ["google_chat_takeout"] * 2, f"pwg:source is google_chat_takeout, got {src}")
check(lab == ["GOOGLE_CHAT"] * 2, f"identifierLabel is GOOGLE_CHAT, got {lab}")
check("apple_mail_fda" not in src and "APPLE_MAIL" not in lab,
      "no Chat person is labelled Apple Mail")

print("== control: a mail source keeps the Apple Mail labels ==")
for mail_source in ("mbox", "apple_mail_emlx", "mbox_catchup"):
    st = install()
    ui._persist_mail_contacts(dict(CONTACTS), source=mail_source)
    src, lab = st.created()
    check(src == ["apple_mail_fda"] * 2 and lab == ["APPLE_MAIL"] * 2,
          f"{mail_source}: unchanged Apple Mail labels, got {src} {lab}")

print("== a label is interpolated into SPARQL, so its shape is enforced ==")
st = install()
import tempfile, json  # noqa: E401,E402
d = Path(tempfile.mkdtemp())
(d / "apple_mail_contacts.json").write_text(json.dumps(CONTACTS))
for bad in ('x" . <a> <b> <c', "Upper", ""):
    try:
        m.ingest_mail_contacts(d, person_source=bad)
        check(False, f"refused person_source {bad!r}")
    except ValueError:
        check(True, f"refused person_source {bad!r}")
check(st.updates == [], "nothing written for a refused label")

print(f"\n{len(FAILURES)} failed")
sys.exit(1 if FAILURES else 0)
