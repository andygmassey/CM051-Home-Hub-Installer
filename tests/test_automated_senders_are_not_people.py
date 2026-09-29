"""Automated and bulk senders do not become people, and old ones are removed.

CM051 v1.0.106. Andy's v1.0.105 console walk: the People list was full of a
card issuer, trade bodies, shops, promotions and app vendors, because
vendor/cm021/src/cli.py turned every inbound sender into a pwg:Person. On the
walk box 725 Persons had only the email-only shape this CLI writes.

This EXECUTES the shipped code:
  1. automated_sender_reason() on synthetic messages: list, bulk, auto
     submitted, feedback/campaign and no-reply senders are machine mail;
     a person writing (including "Auto-Submitted: no") is not.
  2. cmd_mbox() over a synthetic mbox with the REAL parser, in --dry-run:
     the automated messages are counted and skipped, the human one is not.
  3. _build_demote() against a real SPARQL engine (pyoxigraph): an email-only
     Person made for an automated sender is removed; a Person that another
     source also wrote (an extra predicate) or that anything points at is
     left alone, and so is an unrelated Person.
Synthetic data only.

EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
"""
import argparse
import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import os
# Hermetic: never read or write the developer's real ~/.ostler or Mail store.
_HERMETIC = tempfile.mkdtemp()
os.environ["OSTLER_HOME"] = str(Path(_HERMETIC) / "home")
os.environ["OSTLER_MAIL_DIR"] = str(Path(_HERMETIC) / "nomail")

REPO = Path(__file__).resolve().parent.parent
PKG = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "vendor" / "cm021"

try:
    import pyoxigraph
except ImportError:
    print("CANNOT-RUN: pyoxigraph is not installed", file=sys.stderr)
    sys.exit(2)

sys.path.insert(0, str(PKG))
try:
    from src import cli  # the shipped module, with its real parser
except Exception as exc:
    print(f"CANNOT-RUN: could not import {PKG}/src/cli.py: {exc}", file=sys.stderr)
    sys.exit(2)

fails = 0


def check(label, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + label)
    if not ok:
        fails += 1


def msg(addr, headers=None):
    return SimpleNamespace(from_address=addr, headers=headers or {})


print("1. automated_sender_reason")
reason = getattr(cli, "automated_sender_reason", None)
if reason is None:
    check("automated_sender_reason exists in the shipped cli", False)
else:
    check("a person writing is a person", reason(msg("jane.doe@example.org", {"From": "x"})) is None)
    check("Auto-Submitted: no is a person", reason(msg("jane@example.org", {"Auto-Submitted": "no"})) is None)
    check("List-Unsubscribe is bulk", reason(msg("hello@shop.example", {"List-Unsubscribe": "<mailto:u@shop.example>"})) == "header")
    check("header names are case-insensitive", reason(msg("a@b.example", {"list-id": "<l.example>"})) == "header")
    check("Precedence: bulk", reason(msg("a@b.example", {"Precedence": "bulk"})) == "precedence")
    check("Auto-Submitted: auto-generated", reason(msg("a@b.example", {"Auto-Submitted": "auto-generated"})) == "auto-submitted")
    check("Feedback-ID (bulk platform)", reason(msg("a@b.example", {"Feedback-ID": "1:2:3"})) == "header")
    for local in ("noreply", "no-reply", "no_reply", "donotreply", "notifications", "newsletter", "mailer-daemon"):
        check(f"local part {local}", reason(msg(f"{local}@b.example")) == "local-part")
    check("a name containing 'info' inside a word is a person", reason(msg("informal.joe@b.example")) is None)

print("2. cmd_mbox skips automated senders (real parser, dry run)")
mbox = (
    "From a@x 2026-01-01\n"
    "From: Jane Doe <jane.doe@example.org>\nTo: me@example.net\n"
    "Subject: lunch\nDate: Mon, 1 Jan 2026 10:00:00 +0000\nMessage-ID: <1@x>\n\nhi\n\n"
    "From b@x 2026-01-01\n"
    "From: shopdeals <hello@shop.example>\nTo: me@example.net\n"
    "List-Unsubscribe: <mailto:u@shop.example>\n"
    "Subject: sale\nDate: Mon, 1 Jan 2026 11:00:00 +0000\nMessage-ID: <2@x>\n\nbuy\n\n"
    "From c@x 2026-01-01\n"
    "From: cardissuer <no_reply@card.example>\nTo: me@example.net\n"
    "Subject: statement\nDate: Mon, 1 Jan 2026 12:00:00 +0000\nMessage-ID: <3@x>\n\nstatement\n\n"
    "From d@x 2026-01-01\n"
    "From: zentrovo account support team <help@zentrovo.example>\nTo: me@example.net\n"
    "Subject: your account\nDate: Mon, 1 Jan 2026 13:00:00 +0000\nMessage-ID: <4@x>\n\nhello\n\n"
)
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "t.mbox"
    p.write_text(mbox)
    args = argparse.Namespace(path=str(p), backfill_days=None,
                              graph_endpoint="http://127.0.0.1:9", json=True, dry_run=True)
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        cli.cmd_mbox(args)
    try:
        res = json.loads(out.getvalue().strip().splitlines()[-1])
    except Exception:
        res = {}
    check("4 messages read", res.get("messages_read") == 4)
    check("3 automated senders skipped (one by its org display name alone)", res.get("skipped_automated") == 3)
    check("1 person extracted", res.get("people_extracted") == 1)

print("3. _build_demote against pyoxigraph")
demote = getattr(cli, "_build_demote", None)
if demote is None:
    check("_build_demote exists", False)
else:
    NS = cli.PWG_NS
    store = pyoxigraph.Store()

    def upsert(addr, name=""):
        store.update(cli._build_upsert(person_iri=cli._safe_person_iri(addr), email=addr,
                                       name=name, last_contact_iso="2026-01-01T00:00:00+00:00"))

    def exists(addr):
        iri = cli._safe_person_iri(addr)
        return bool(store.query(f"ASK {{ <{iri}> ?p ?o }}"))

    upsert("hello@shop.example", "shopdeals")
    upsert("no_reply@card.example", "")
    upsert("shared@both.example", "Real Person")
    both = cli._safe_person_iri("shared@both.example")
    store.update(f'INSERT DATA {{ <{both}> <{NS}phone> "+000" }}')
    upsert("pointed@ref.example", "Pointed At")
    ref = cli._safe_person_iri("pointed@ref.example")
    store.update(f"INSERT DATA {{ <{NS}meeting_1> <{NS}attendee> <{ref}> }}")
    upsert("friend@example.org", "Friend")

    for addr in ("hello@shop.example", "no_reply@card.example", "shared@both.example", "pointed@ref.example"):
        store.update(demote(cli._safe_person_iri(addr)))
    check("email-only automated sender removed", not exists("hello@shop.example"))
    check("email-only automated sender with no name removed", not exists("no_reply@card.example"))
    check("a Person another source also wrote is kept", exists("shared@both.example"))
    check("a Person something points at is kept", exists("pointed@ref.example"))
    check("an unrelated Person is untouched", exists("friend@example.org"))

print("4. reclassify-mail reads .emlx headers and finds automated senders (dry run)")
rc = getattr(cli, "cmd_reclassify_mail", None)
if rc is None:
    check("reclassify-mail exists", False)
else:
    with tempfile.TemporaryDirectory() as td:
        d = Path(td) / "V10" / "acct" / "INBOX.mbox" / "Messages"
        d.mkdir(parents=True)
        def emlx(n, head):
            body = (head + "\n\nbody\n").encode()
            (d / f"{n}.emlx").write_bytes(str(len(body)).encode() + b"\n" + body)
        emlx(1, "From: Jane Doe <jane.doe@example.org>\nSubject: hi")
        emlx(2, "From: Shop <hello@shop.example>\nList-Unsubscribe: <x>\nSubject: sale")
        emlx(3, "From: Shop <hello@shop.example>\nList-Unsubscribe: <x>\nSubject: sale 2")
        emlx(4, "From: Bank <no_reply@card.example>\nSubject: statement")
        (d / "5.emlx").write_bytes(b"not a message")
        args = argparse.Namespace(mail_dir=td, graph_endpoint="http://127.0.0.1:9", dry_run=True)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc(args)
        try:
            res = json.loads(out.getvalue().strip().splitlines()[-1])
        except Exception:
            res = {}
        check("5 files read", res.get("files_read") == 5)
        check("2 distinct automated senders found", res.get("automated_senders") == 2)
        check("dry run demotes nothing", res.get("people_demoted") == 0)

print("5. install.sh runs the one-off reclassify once, behind a marker")
inst = (REPO / "install.sh").read_text(errors="replace") if (REPO / "install.sh").exists() else ""
check("install.sh calls reclassify-mail", "reclassify-mail" in inst)
check("the one-off is gated by a marker in state/", "email_reclassify_v2.done" in inst)

print("6. backup BEFORE delete, and hostile IRIs refused (Archie, review of #2479)")
dm = getattr(cli, "_demote", None)
if dm is None:
    check("_demote (backup then delete) exists", False)
else:
    import os
    store2 = pyoxigraph.Store()
    order = []

    def sel(endpoint, q):
        order.append("backup")
        return [(str(r["p"].value), str(r["o"].value)) for r in store2.query(q)]

    def upd(endpoint, q):
        order.append("delete")
        store2.update(q)

    cli._sparql_select = sel
    cli._post_sparql_update = upd
    for addr, nm in (("promo@shop.example", "Shop"), ("keep@friend.example", "Friend")):
        store2.update(cli._build_upsert(person_iri=cli._safe_person_iri(addr), email=addr,
                                        name=nm, last_contact_iso="2026-01-01T00:00:00+00:00"))
    iri = cli._safe_person_iri("promo@shop.example")
    before = {(str(q.predicate.value), str(q.object.value)) for q in store2.quads_for_pattern(pyoxigraph.NamedNode(iri), None, None)}
    with tempfile.TemporaryDirectory() as td:
        os.environ["OSTLER_HOME"] = td
        n = dm("http://x", iri, "header")
        bpath = Path(td) / "state" / "demoted_people.jsonl"
        lines = [json.loads(l) for l in bpath.read_text().splitlines()] if bpath.exists() else []
    check("the backup is written BEFORE the delete", order[:2] == ["backup", "delete"])
    check("the backup holds exactly the removed triples",
          {(l["p"], l["o"]) for l in lines} == before and len(lines) == n and n == len(before))
    check("every backup line names the subject and the rule",
          all(l["s"] == iri and l["reason"] == "header" for l in lines))
    check("the Person is gone after", not bool(store2.query(f"ASK {{ <{iri}> ?p ?o }}")))
    check("an unrelated Person is untouched",
          bool(store2.query(f"ASK {{ <{cli._safe_person_iri('keep@friend.example')}> ?p ?o }}")))

    def refused(x):
        try:
            cli._build_demote(x)
            return False
        except ValueError:
            return True
    good = cli._safe_person_iri("a@b.example")
    check("a normal person IRI is accepted", not refused(good))
    for hostile in (good + "> ?p ?o } ; DROP ALL ; #", good + " x", good + '"', "<" + good,
                    "http://evil.example/person_1", cli.PWG_NS + "Thing_1", ""):
        check(f"hostile IRI refused: {hostile[-24:]!r}", refused(hostile))

print("7. organisation display names (v1.0.106 walk residue: no bulk header, org name)")
onr = getattr(cli, "organisation_name_reason", None)
if onr is None:
    check("organisation_name_reason exists", False)
else:
    for org in ("zentrovo account support team", "quillmark customer service", "brindlecot ltd",
                "velmora group", "orlix bank", "PLUMVEX", "tessary promotions"):
        check(f"org name caught: {org}", onr(org) is not None)
    for person in ("zorblat quennix", "Ymir", "Quennix", "jane@example.org", "", None,
                   "dr zorblat quennix", "zorblat quennix-thorne"):
        check(f"person name kept: {person!r}", onr(person) is None)
    check("a bare message with only an org display name is automated",
          reason(SimpleNamespace(from_address="help@zentrovo.example", from_name="zentrovo support team", headers={})) == "org-name")

    # The graph pass: only EMAIL-ONLY Persons with an org name are selected.
    store3 = pyoxigraph.Store()
    def up3(addr, name):
        store3.update(cli._build_upsert(person_iri=cli._safe_person_iri(addr), email=addr,
                                        name=name, last_contact_iso="2026-01-01T00:00:00+00:00"))
    up3("help@zentrovo.example", "zentrovo account support team")
    up3("friend@example.org", "zorblat quennix")
    up3("contact@velmora.example", "velmora group")
    vel = cli._safe_person_iri("contact@velmora.example")
    store3.update(f'INSERT DATA {{ <{vel}> <{cli.PWG_NS}contactType> "business" }}')
    def fake_select(endpoint, query, names, timeout=20.0):
        return [tuple(str(r[n].value) for n in names) for r in store3.query(query)]
    real = cli._sparql_select_vars
    cli._sparql_select_vars = fake_select
    try:
        got = cli._org_named_email_only_persons("http://x")
    finally:
        cli._sparql_select_vars = real
    got_iris = {g[0] for g in (got or [])}
    check("graph pass selects the email-only org-named Person",
          cli._safe_person_iri("help@zentrovo.example") in got_iris)
    check("graph pass leaves a person-named Person", cli._safe_person_iri("friend@example.org") not in got_iris)
    check("graph pass leaves an org-named Person another source wrote (Contacts)", vel not in got_iris)
    def boom(*a, **k):
        raise RuntimeError("store down")
    cli._sparql_select_vars = boom
    try:
        check("a store failure is CANNOT-RUN (None), never zero found",
              cli._org_named_email_only_persons("http://x") is None)
    finally:
        cli._sparql_select_vars = real

print("8. one-way senders: a Person is someone the owner writes to")
if not hasattr(cli, "_one_way_email_only_persons"):
    check("one-way rule exists", False)
else:
    home = Path(os.environ["OSTLER_HOME"])
    mail = Path(_HERMETIC) / "mail8"
    sent_dir = mail / "V10" / "acct" / ("Sent " + "Messages.mbox") / "Data" / "Messages"
    inbox = mail / "V10" / "acct" / "INBOX.mbox" / "Data" / "Messages"
    sent_dir.mkdir(parents=True); inbox.mkdir(parents=True)
    body = b"From: me@example.net\nTo: zorblat quennix <zq@example.org>\nSubject: hi\n\nhello\n"
    (sent_dir / "1.emlx").write_bytes(str(len(body)).encode() + b"\n" + body)
    n, rec = cli._collect_sent_recipients(mail)
    check("sent mail read by headers", n == 1 and rec == {"zq@example.org"})
    ib = b"From: quillby life <hello@quillby.example>\nTo: me@example.net\nSubject: x\n\nx\n"
    (inbox / "2.emlx").write_bytes(str(len(ib)).encode() + b"\n" + ib)
    n2, rec2 = cli._collect_sent_recipients(mail)
    check("an inbox message is not counted as sent", n2 == 1 and "hello@quillby.example" not in rec2)

    store4 = pyoxigraph.Store()
    def up4(addr, name):
        store4.update(cli._build_upsert(person_iri=cli._safe_person_iri(addr), email=addr,
                                        name=name, last_contact_iso="2026-01-01T00:00:00+00:00"))
    up4("zq@example.org", "zorblat quennix")
    up4("hello@quillby.example", "quillby life")
    def fake4(endpoint, query, names, timeout=20.0):
        return [tuple(str(r[n].value) for n in names) for r in store4.query(query)]
    real = cli._sparql_select_vars
    cli._sparql_select_vars = fake4
    try:
        ow = cli._one_way_email_only_persons("http://x", {"zq@example.org"})
    finally:
        cli._sparql_select_vars = real
    iris = {i for i, _ in (ow or [])}
    check("a one-way brand with an ordinary name is selected",
          cli._safe_person_iri("hello@quillby.example") in iris)
    check("a correspondent the owner wrote to is kept", cli._safe_person_iri("zq@example.org") not in iris)

    # The hourly mbox run skips a one-way sender once a sent-to set exists.
    os.environ["OSTLER_MAIL_DIR"] = str(mail)
    mb = ("From a@x 2026-01-01\n"
          "From: zorblat quennix <zq@example.org>\nTo: me@example.net\n"
          "Subject: re\nDate: Mon, 1 Jan 2026 10:00:00 +0000\nMessage-ID: <81@x>\n\nhi\n\n"
          "From b@x 2026-01-01\n"
          "From: quillby life <hello@quillby.example>\nTo: me@example.net\n"
          "Subject: offer\nDate: Mon, 1 Jan 2026 11:00:00 +0000\nMessage-ID: <82@x>\n\nx\n\n")
    with tempfile.TemporaryDirectory() as td:
        pth = Path(td) / "m.mbox"; pth.write_text(mb)
        a = argparse.Namespace(path=str(pth), backfill_days=None,
                               graph_endpoint="http://127.0.0.1:9", json=True, dry_run=True)
        o = io.StringIO()
        with contextlib.redirect_stdout(o), contextlib.redirect_stderr(io.StringIO()):
            cli.cmd_mbox(a)
        r8 = json.loads(o.getvalue().strip().splitlines()[-1])
    check("the sent-to set was written, owner-only", (home / "state" / "email_sent_to.txt").exists()
          and oct((home / "state" / "email_sent_to.txt").stat().st_mode & 0o777) == "0o600")
    check("the one-way brand is skipped", r8.get("skipped_one_way") == 1)
    check("the correspondent is still a person", r8.get("people_extracted") == 1)
    os.environ["OSTLER_MAIL_DIR"] = str(Path(_HERMETIC) / "nomail")

print(f"\n{'PASS' if fails == 0 else 'FAIL'}: {fails} failed")
sys.exit(1 if fails else 0)
