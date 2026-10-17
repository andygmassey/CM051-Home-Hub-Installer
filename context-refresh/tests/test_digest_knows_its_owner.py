"""The digest must know its owner (Ostler v1.0.107 candidate #10).

Measured on a candidate box, 2026-10-07: CONTEXT.md, injected into every chat
system prompt, was 1,966 bytes. It said "nothing stored" for preferences and
key organisations, its People section listed calendar organiser mailboxes and
the owner themself, and there was no section about the owner at all. Asked
"Where have I worked?", the assistant said it had no record, on a box whose
graph held the owner's LinkedIn positions and 4,628 interests.

This suite runs the generator against a REAL SPARQL engine (pyoxigraph) holding
a SYNTHETIC seed graph, behind a fake Oxigraph that enforces a bearer exactly as
the shipped store proxy does, plus a fake ical-server that enforces the service
token. A query with the wrong predicate finds nothing here, just as on a box,
so these tests discriminate on the queries and not on a stub's routing.

Every name, employer and place below is fictional.

Three kinds of test:
  RED    the pre-fix generator, pinned by SHA, run on the same seed, renders
         the defect: no About you, no Work line, and "nothing stored" claims
         beside data the stores hold.
  GREEN  the fixed generator renders every section from the same seed.
  HONEST a failed store read is declared COULD NOT BE READ, never "nothing
         stored".
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

import pyoxigraph as ox

_HERE = Path(__file__).resolve().parent
_SCRIPT = _HERE.parent / "bin" / "generate_pwg_context.py"
_REPO = _HERE.parent.parent

# The generator as it shipped before this fix (sha256 15a1c4dd..., the copy
# measured on the box). Pinned to a SHA, never to a moving ref: once this fix
# lands, origin/main IS the fixed module and a baseline taken from it would
# stop being a baseline.
_PREFIX_SHA = "c4d4b5af953d286ca9f3397ef2926d08dd6ee798"

PWG = "https://schema.ostler.ai/ontology#"
STORE_TOKEN = "synthetic-oxigraph-token-0000"
SERVICE_TOKEN = "synthetic-service-token-0000"

OWNER_ID = "jane"
OWNER_NAME = "Jane Doe"
OWNER_EMAIL = "jane@example.com"
NEIGHBOUR_PLACE = "Sam Patel is based in Lyonville."
# #27: UNTAGGED legacy location facts. A contact's must go; the owner as explicit subject stays.
UNTAGGED_CONTACT_PLACES = ("Lizzie Li lives in Harborview", "Is based in Robbieton")
UNTAGGED_OWNER_PLACE = "Jane Doe lives in Seaford"
PLACE_WITH_PHONE = "Office line " + "".join(["5550", "1991", "11"]) + " in Seaford"   # owner-tagged, but a raw phone never prints
_PHONE_DIGITS = "".join(["5550", "1990", "00"])  # composed: no phone literal in source
CONTACT_PHONE_FACT = f"+{_PHONE_DIGITS} has a son"
OWNER_END_FACT = "Liz Doe is the sister of Jane Doe"
# #25: UNTAGGED legacy facts about OTHER people (walk #24 shapes), cast names.
UNTAGGED_OTHERS = (
    "Sam Patel met Robbie Wang, Lizzie Li, Wei Zhang at a party",
    "Sam Patel mentioned Robbie Wang got a job",
    "Sam Patel has a son",
    "Jane Doe met Sam Patel at a party",        # owner is the subject but it is not kinship
)
UNTAGGED_OWNER_DAUGHTER = "Jane Doe has a daughter Lizzie Li"

# Strings that must NEVER reach the digest (L3, or not a person).
FORBIDDEN = (
    "Skunkworks", "L3 SECRET FAMILY FACT", "Tom Brown",
    "L3 private appointment", "Secret hobby", "organiser@example.invalid",
    "Hushco",
)


# ── Seed graph ───────────────────────────────────────────────────────────────


def _n(local: str) -> ox.NamedNode:
    return ox.NamedNode(PWG + local)


def _lit(v) -> ox.Literal:
    return ox.Literal(str(v))


def _seed_store(*, mecard_org: str | None = "ExampleCo",
                linkedin_current: str | None = None,
                neighbour_place: bool = False,
                contact_family: bool = False,
                untagged_places: bool = False,
                phone_place: bool = False) -> ox.Store:
    store = ox.Store()
    dg = ox.DefaultGraph()
    rdf_type = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")

    def add(s, p, o, g=dg):
        store.add(ox.Quad(s, p if isinstance(p, ox.NamedNode) else _n(p), o, g))

    now = datetime.now(timezone.utc)

    def stamp(days: float) -> str:
        return (now + timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S+00:00")

    # The owner, fragmented across two nodes as on a real box.
    owner = _n(f"user_{OWNER_ID}")
    add(owner, rdf_type, _n("Person"))
    add(owner, "displayName", _lit(OWNER_NAME))
    add(owner, "privacyLevel", _lit("L0"))
    owner2 = ox.NamedNode("https://example.invalid/person/jane-mecard")
    add(owner2, rdf_type, _n("Person"))
    add(owner2, "displayName", _lit(OWNER_NAME))
    add(owner2, "privacyLevel", _lit("L0"))
    if mecard_org:
        add(owner2, "organization", _lit(mecard_org))
        add(owner2, "jobTitle", _lit("Head of Widgets"))

    # LinkedIn Positions.csv import: career_position PersonFacts.
    def career(fid, org, title, start, end=None, level="L2"):
        f = ox.NamedNode(f"https://example.invalid/fact/{fid}")
        add(f, rdf_type, _n("PersonFact"))
        add(f, "factType", _lit("career_position"))
        add(f, "source", _lit("linkedin_positions"))
        add(f, "aboutPerson", owner)
        add(f, "organization", _lit(org))
        add(f, "jobTitle", _lit(title))
        add(f, "startDate", _lit(start))
        if end:
            add(f, "endDate", _lit(end))
        add(f, "privacyLevel", _lit(level))
        add(f, "factText", _lit(f"{title} at {org}"))

    career("c1", "Initech", "Engineer", "2015-03-01", "2019-06-30")
    career("c2", "Skunkworks", "Agent", "2019-07-01", "2020-01-01",
           level="L3")
    if linkedin_current:
        career("c3", linkedin_current, "Director", "2021-01-01")

    # Conversation-mined facts in the owner's named graph.
    ug = ox.NamedNode(f"urn:ostler:user/{OWNER_ID}")

    def ufact(fid, text, ftype, domain, level="L0", about=None):
        f = ox.NamedNode(f"urn:ostler:fact/{fid}")
        if about:
            add(f, ox.NamedNode("urn:ostler:about"), ox.NamedNode(about), ug)
        add(f, rdf_type, ox.NamedNode("urn:ostler:Fact"), ug)
        add(f, ox.NamedNode("urn:ostler:text"), _lit(text), ug)
        add(f, ox.NamedNode("urn:ostler:userId"), _lit(OWNER_ID), ug)
        add(f, ox.NamedNode("urn:ostler:type"), _lit(ftype), ug)
        add(f, ox.NamedNode("urn:ostler:domain"), _lit(domain), ug)
        add(f, ox.NamedNode("urn:ostler:privacyLevel"), _lit(level), ug)
        add(f, ox.NamedNode("urn:ostler:observedAt"), _lit(stamp(-3)), ug)

    # One fact the owner confirmed to the assistant (POST /api/v1/memory/assert
    # writes exactly this shape).
    af = ox.NamedNode("https://example.invalid/fact/asserted-1")
    add(af, rdf_type, _n("PersonFact"))
    add(af, "factText", _lit("the boat is called seaworthy"))
    add(af, "factSource", _lit("user_asserted"))
    add(af, "privacyLevel", _lit("L1"))
    add(af, "belongsToUser", owner)
    add(af, "createdAt", _lit(stamp(-1)))

    ufact("u1", "Lives in Fictionville", "location", "general",
          about=f"urn:ostler:user/{OWNER_ID}")
    ufact("u2", "Has a sister called Liz Doe", "relationship", "family",
          about=f"urn:ostler:user/{OWNER_ID}")
    ufact("u3", "L3 SECRET FAMILY FACT", "relationship", "family", level="L3")
    if neighbour_place:
        # F12: the CM048 writer's real shape. The owner's own place carries
        # about=urn:ostler:user/<id>; a contact's carries their person URN.
        # Both sit in the OWNER's graph with the owner's userId.
        ufact("u4", "Works from Harbourtown on Fridays", "location", "general",
              about=f"urn:ostler:user/{OWNER_ID}")
        ufact("u5", NEIGHBOUR_PLACE, "location", "general",
              about="urn:ostler:person/sam_patel")

    if contact_family:
        # A fact ABOUT a contact (their person URN), phone handle as subject.
        ufact("u6", CONTACT_PHONE_FACT, "relationship", "family",
              about="urn:ostler:person/sam_patel")
        # A relationship fact linking the owner to that contact: owner is one end.
        ufact("u7", OWNER_END_FACT, "relationship", "family",
              about="urn:ostler:person/liz_doe")

    if contact_family:
        for i, t in enumerate(UNTAGGED_OTHERS):
            ufact(f"x{i}", t, "relationship", "family")          # no urn:ostler:about
        ufact("x9", UNTAGGED_OWNER_DAUGHTER, "relationship", "family")

    if phone_place:
        ufact("y8", PLACE_WITH_PHONE, "location", "general", about=f"urn:ostler:user/{OWNER_ID}")
    if untagged_places:
        for i, t in enumerate(UNTAGGED_CONTACT_PLACES):
            ufact(f"y{i}", t, "location", "general")                 # no urn:ostler:about
        ufact("y9", UNTAGGED_OWNER_PLACE, "location", "general")

    # People the owner interacts with.
    def person(pid, name, org=None, level="L2"):
        p = ox.NamedNode(f"https://example.invalid/person/{pid}")
        add(p, rdf_type, _n("Person"))
        add(p, "displayName", _lit(name))
        add(p, "privacyLevel", _lit(level))
        if org:
            add(p, "organization", _lit(org))
        return p

    mary = person("mary", "Mary Smith", "Acme Corp")
    bob = person("bob", "Bob Jones", "Globex")
    sam = person("sam", "Sam Patel", "Acme Corp")
    mailbox = person("organiser", "organiser@example.invalid")
    hidden = person("tom", "Tom Brown", "Hushco", level="L3")

    def signal(sid, about, total):
        s = ox.NamedNode(f"https://example.invalid/signal/{sid}")
        add(s, rdf_type, _n("RelationshipSignal"))
        add(s, "signalType", _lit("linkedin_messaging"))
        add(s, "about", about)
        add(s, "totalMessages", _lit(total))
        add(s, "privacyLevel", _lit("L2"))

    signal("s1", mary, 40)
    signal("s2", bob, 12)
    signal("s3", sam, 3)
    signal("s4", hidden, 500)
    signal("s5", owner, 900)

    def meeting(mid, summary, days, attendees, level="L2"):
        m = ox.NamedNode(f"https://example.invalid/meeting/{mid}")
        add(m, rdf_type, _n("Meeting"))
        add(m, "meetingSummary", _lit(summary))
        add(m, "meetingDate", _lit(stamp(days)))
        add(m, "privacyLevel", _lit(level))
        add(m, "source", _lit("icloud_calendar"))
        for a in attendees:
            add(m, "meetingAttendee", a)

    meeting("m1", "Design review with Mary", -2, [mary, owner, mailbox])
    meeting("m2", "Planning with Bob", 2, [bob, owner, mailbox])
    meeting("m3", "Supplier call", -40, [mailbox, owner])
    meeting("m4", "Quarterly sync", -60, [mailbox, mary])
    meeting("m5", "L3 private appointment", 1, [owner], level="L3")
    for i in range(30):
        meeting(f"x{i}", f"Organiser block {i}", -100 - i, [mailbox])
    return store


# ── Fake stores ──────────────────────────────────────────────────────────────


def _serialise(results) -> dict:
    names = [v.value for v in results.variables]
    bindings = []
    for sol in results:
        row = {}
        for name in names:
            term = sol[name]
            if term is None:
                continue
            kind = "uri" if isinstance(term, ox.NamedNode) else (
                "bnode" if isinstance(term, ox.BlankNode) else "literal")
            row[name] = {"type": kind, "value": term.value}
        bindings.append(row)
    return {"head": {"vars": names}, "results": {"bindings": bindings}}


def _serve(handler_cls):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def _oxigraph_server(store: ox.Store, *, token: str | None = STORE_TOKEN):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):  # noqa: N802
            n = int(self.headers.get("Content-Length") or 0)
            query = self.rfile.read(n).decode("utf-8") if n else ""
            # The store proxy's posture, as measured: bearer or 401.
            # token None = the store as it was before auth was switched on.
            if token is not None and (
                    self.headers.get("Authorization") or "") != f"Bearer {token}":
                self._send(401, {"error": "unauthorised"})
                return
            try:
                self._send(200, _serialise(store.query(query)))
            except Exception as exc:  # a malformed query is a 400, as live
                self._send(400, {"error": str(exc)})

    return _serve(H)


def _ical_server(routes: dict):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802
            if (self.headers.get("Authorization") or "") != f"Bearer {SERVICE_TOKEN}":
                self._send(401, {"error": "unauthorised"})
                return
            path = self.path.split("?", 1)[0]
            self._send(200, routes.get(path, {}))

    return _serve(H)


_PREFERENCES = {"interests": [
    {"subject": "Trail running", "domain": "Sport", "polarity": "positive",
     "privacy": "L2", "score": 0.9},
    {"subject": "Jazz", "domain": "Music", "polarity": "positive",
     "privacy": "2", "score": 0.8},
    {"subject": "Secret hobby", "domain": "Private", "polarity": "positive",
     "privacy": "L3", "score": 0.99},
    {"subject": "Opera", "domain": "Music", "polarity": "negative",
     "privacy": "L2", "score": 0.5},
]}


def _routes(*, employer: dict | None = None) -> dict:
    return {
        "/api/v1/employer": employer or {"found": False},
        "/api/v1/preferences": _PREFERENCES,
        "/api/v1/coach/recent": {"observations": [], "note": "Coach database not found"},
        "/api/v1/timeline": {"items": []},
        "/api/v1/suggestions": {
            # The old People source: organiser mailboxes and the owner.
            "recent_meetings": [
                {"name": "organiser@example.invalid", "meeting_date": "2026-10-01"},
                {"name": OWNER_NAME, "meeting_date": "2026-10-01"},
            ],
            "birthdays": [], "reconnect": [],
        },
    }


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def env(monkeypatch, tmp_path):
    """Owner identity and both bearers, pinned. Nothing from the developer's
    own install can reach the run."""
    for key in ("USER_ID", "USER_NAME", "USER_EMAIL", "WIKI_OPERATOR_NAME",
                "WIKI_OPERATOR_EMAILS", "PWG_SERVICE_TOKEN", "OXIGRAPH_TOKEN"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "ostler"))
    (tmp_path / "ostler" / "config").mkdir(parents=True)
    # Identity arrives the way it does on a box: from the installer env file,
    # because the context-refresh LaunchAgent carries only PATH.
    (tmp_path / "ostler" / "config" / ".env").write_text(
        f'USER_ID="{OWNER_ID}"\nUSER_NAME="{OWNER_NAME}"\n', encoding="utf-8")
    (tmp_path / "ostler" / ".env").write_text(
        f"WIKI_OPERATOR_EMAILS={OWNER_EMAIL}\n", encoding="utf-8")
    monkeypatch.setenv("OSTLER_SERVICE_TOKEN", SERVICE_TOKEN)
    monkeypatch.setenv("OSTLER_OXIGRAPH_TOKEN", STORE_TOKEN)
    monkeypatch.setenv("OSTLER_SERVICE_TOKEN_FILE", str(tmp_path / "none"))
    monkeypatch.setenv("OSTLER_OXIGRAPH_TOKEN_FILE", str(tmp_path / "none"))
    monkeypatch.setenv("ZEROCLAW_WORKSPACE_DIR", str(tmp_path / "ws"))
    monkeypatch.setenv("no_proxy", "127.0.0.1,localhost")
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    return monkeypatch


def _build(env, module_path: Path, store: ox.Store, *, routes=None,
           store_token: str | None = STORE_TOKEN, name="gen_under_test"):
    ox_srv = _oxigraph_server(store, token=store_token)
    ical_srv = _ical_server(routes or _routes())
    try:
        env.setenv("OXIGRAPH_URL", f"http://127.0.0.1:{ox_srv.server_address[1]}")
        env.setenv("OSTLER_ICAL_BASE_URL",
                   f"http://127.0.0.1:{ical_srv.server_address[1]}")
        gen = _load(module_path, name)
        return gen, gen.build_digest()
    finally:
        ox_srv.shutdown()
        ical_srv.shutdown()


def _section(digest: str, heading: str) -> str:
    assert f"## {heading}" in digest, f"missing section: {heading}\n{digest}"
    return digest.split(f"## {heading}", 1)[1].split("\n## ", 1)[0]


def _gap_line(digest: str, heading: str) -> str:
    for line in digest.splitlines():
        if line.startswith(f"- {heading}:"):
            return line
    return ""


# ── The control: the fixture is a real store, and it holds the data ──────────


def test_seed_store_holds_what_the_sections_need():
    """If the seed were empty, every RED below would be RED for the wrong
    reason. Counts taken with the real engine."""
    store = _seed_store()

    def count(q):
        return int(next(iter(store.query(
            "PREFIX pwg: <%s>\nSELECT (COUNT(*) AS ?n) WHERE { %s }" % (PWG, q)
        )))["n"].value)

    assert count('?f pwg:factType "career_position"') == 2
    assert count("?p pwg:organization ?o") >= 4
    assert count("?m a pwg:Meeting") >= 30
    assert count("?s a pwg:RelationshipSignal") == 5


# ── RED: the shipped generator on the same seed ──────────────────────────────


@pytest.fixture()
def prefix_module(tmp_path) -> Path:
    try:
        src = subprocess.run(
            ["git", "-C", str(_REPO), "show",
             f"{_PREFIX_SHA}:context-refresh/bin/generate_pwg_context.py"],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout
    except (subprocess.CalledProcessError, OSError) as exc:
        # CANNOT-RUN is not PASS: fail loudly rather than skip.
        pytest.fail(f"CANNOT-RUN: pre-fix generator not readable at "
                    f"{_PREFIX_SHA} (needs full history): {exc}")
    out = tmp_path / "generate_pwg_context_prefix.py"
    out.write_text(src, encoding="utf-8")
    return out


def test_red_shipped_generator_does_not_know_its_owner(env, prefix_module):
    """The defect, reproduced: the stores hold the owner's work history,
    people, meetings and interests, and the shipped generator renders none of
    it. (Its SPARQL carries no bearer, so on today's store it is refused;
    we hand it the store open, as on the 11:00 UTC tick, so this measures the
    queries and endpoints rather than the auth.)"""
    store = _seed_store()
    gen, digest = _build(env, prefix_module, store, store_token=None,
                         name="gen_prefix")
    assert digest is not None
    # The store answered every read: the claims below are not auth noise.
    assert ": COULD NOT BE READ" not in digest
    assert "## About you" not in digest
    assert "- Work:" not in digest
    assert "ExampleCo" not in digest and "Initech" not in digest
    # It claims emptiness beside data the stores hold.
    assert _gap_line(digest, "Preferences and things to keep in mind").endswith(
        "nothing stored.")
    assert _gap_line(digest, "Key organisations").endswith("nothing stored.")
    # Its People section is the organiser mailbox and the owner.
    people = _section(digest, "People you interact with most")
    assert "Mary Smith" not in people
    assert "organiser@example.invalid" in people or OWNER_NAME in people


# ── GREEN: the fixed generator on the same seed ──────────────────────────────


def test_green_every_section_from_the_seed(env, capsys):
    store = _seed_store()
    gen, digest = _build(env, _SCRIPT, store)
    assert digest is not None

    about = _section(digest, "About you")
    assert f"- Name: {OWNER_NAME}" in about
    work = [ln for ln in about.splitlines() if ln.startswith("- Work:")]
    assert work == ["- Work: ExampleCo, Initech"], about
    assert "Engineer at Initech (2015 to 2019)" in about
    assert "Lives in Fictionville" in about
    assert "Liz Doe" in about

    people = _section(digest, "People you interact with most")
    names = [ln for ln in people.splitlines() if ln.startswith("- ")]
    assert names[0].startswith("- Mary Smith, Acme Corp")
    assert any(ln.startswith("- Bob Jones") for ln in names)
    assert OWNER_NAME not in people

    assert "Design review with Mary" in _section(digest, "Recent meetings (last 7 days)")
    calendar = _section(digest, "Calendar events by owner")
    assert "Planning with Bob" in calendar
    assert "**Unattributed:**" in calendar  # pwg:Meeting has no owner field

    prefs = _section(digest, "Preferences and things to keep in mind")
    assert "- Trail running (Sport)" in prefs
    assert "- Jazz (Music)" in prefs
    assert "- Not keen on: Opera (Music)" in prefs

    orgs = _section(digest, "Key organisations")
    assert orgs.strip().splitlines()[0] == "- Acme Corp (2 people)"

    for bad in FORBIDDEN:
        assert bad not in digest, f"withheld or non-person value leaked: {bad}"
    assert ": nothing stored." not in digest
    assert ": COULD NOT BE READ" not in digest
    assert "the boat is called seaworthy" in _section(
        digest, "Confirmed by you")
    assert len(digest.encode("utf-8")) < 6000
    with capsys.disabled():
        print(f"\n[seed digest after fix] {len(digest.encode('utf-8'))} bytes, "
              f"{len(digest.splitlines())} lines")


def test_linkedin_positions_alone_reach_work(env):
    """No me-card organisation, no employer resolver: a LinkedIn
    career_position with no end date is the current employer, listed first."""
    store = _seed_store(mecard_org=None, linkedin_current="ExampleCo")
    _, digest = _build(env, _SCRIPT, store)
    about = _section(digest, "About you")
    assert "- Work: ExampleCo, Initech" in about


def test_mecard_organisation_alone_reaches_work(env):
    store = _seed_store(mecard_org="ExampleCo")
    _, digest = _build(env, _SCRIPT, store)
    assert "- Work: ExampleCo" in _section(digest, "About you")


def test_employer_resolver_leads_work(env):
    """The ical-server's deterministic resolver, when it has an answer, is
    the current employer and goes first."""
    store = _seed_store(mecard_org=None)
    routes = _routes(employer={"found": True, "employer": "Globex",
                               "job_title": "CTO", "start_date": "2022-02-01",
                               "former_employers": ["Initech", "Riverside"]})
    _, digest = _build(env, _SCRIPT, store, routes=routes)
    work = [ln for ln in _section(digest, "About you").splitlines()
            if ln.startswith("- Work:")]
    assert work == ["- Work: Globex, Initech, Riverside"]


# ── HONEST: a failed store read is never "nothing stored" ────────────────────


def test_failed_store_read_prints_could_not_be_read(env):
    """Oxigraph refuses (wrong bearer). Every section behind it must say
    COULD NOT BE READ with the status observed, and none may say "nothing
    stored"."""
    store = _seed_store()
    _, digest = _build(env, _SCRIPT, store, store_token="a-different-token")
    assert digest is not None  # About you still has the name; prefs answered
    for heading in ("People you interact with most", "Key organisations",
                    "Confirmed by you", "Calendar events by owner",
                    "Recent meetings (last 7 days)"):
        line = _gap_line(digest, heading)
        assert "COULD NOT BE READ" in line and "HTTP 401" in line, (heading, line)
        assert "nothing stored" not in line
    assert ": nothing stored." not in digest


def test_digest_is_capped_on_a_busy_graph(env):
    store = _seed_store()
    _, digest = _build(env, _SCRIPT, store)
    assert len(digest) <= 6000 + 80


# ── F12: a contact's place is not the owner's ────────────────────────────────
#
# Cut #17 device walk: asked "what do you know about me", the assistant listed
# another contact's "is based in <city>" as the owner's. On the box the fact
# was a CM048 urn:ostler:Fact with userId = the owner and urn:ostler:about =
# that contact's person URN, and CONTEXT.md's About you Places line had it.

def _about_places(digest: str) -> str:
    about = _section(digest, "About you")
    return "\n".join(ln for ln in about.splitlines() if ln.startswith("- Places:"))


def test_f12_control_the_seed_holds_both_places():
    store = _seed_store(neighbour_place=True)
    texts = {r["t"].value for r in store.query(
        "SELECT ?t WHERE { GRAPH ?g { ?f <urn:ostler:type> \"location\" ; "
        "<urn:ostler:text> ?t ; <urn:ostler:userId> ?u } }")}
    assert NEIGHBOUR_PLACE in texts and "Works from Harbourtown on Fridays" in texts


def test_f12_a_contacts_place_is_absent_from_about_you(env):
    """STRAIGHT arm: FAILS on the generator at 23555fa7 (main before this fix),
    passes with it."""
    _, digest = _build(env, _SCRIPT, _seed_store(neighbour_place=True), name="gen_f12")
    places = _about_places(digest)
    print(f"\n[F12] {places}")
    assert NEIGHBOUR_PLACE not in places, f"a contact's place is on the owner's Places line: {places}"
    assert NEIGHBOUR_PLACE not in _section(digest, "About you")


def test_f12_control_the_owners_own_places_still_render(env):
    _, digest = _build(env, _SCRIPT, _seed_store(neighbour_place=True), name="gen_f12c")
    places = _about_places(digest)
    # Control: the owner's own places, tagged and legacy-untagged, still show.
    assert "Works from Harbourtown on Fridays" in places
    assert "Lives in Fictionville" in places


# ── A contact's family fact is not the owner's family ────────────────────────
#
# DMG #23 walk: "Family and close people: <raw phone> has a son". A fact ABOUT a
# contact (about = their person URN) sat on the owner's family line, with a raw
# phone handle as its subject.

def _about_family(digest: str) -> str:
    about = _section(digest, "About you")
    return "\n".join(ln for ln in about.splitlines() if ln.startswith("- Family and close people:"))


def test_family_control_the_seed_holds_the_contact_fact():
    store = _seed_store(contact_family=True)
    texts = {r["t"].value for r in store.query(
        "SELECT ?t WHERE { GRAPH ?g { ?f <urn:ostler:type> \"relationship\" ; "
        "<urn:ostler:text> ?t ; <urn:ostler:userId> ?u } }")}
    assert CONTACT_PHONE_FACT in texts and OWNER_END_FACT in texts


def test_family_a_contacts_fact_and_its_phone_are_absent(env):
    """RED on main before this fix, green with it."""
    _, digest = _build(env, _SCRIPT, _seed_store(contact_family=True), name="gen_fam")
    fam = _about_family(digest)
    print(f"\n[FAMILY] {fam}")
    assert "has a son" not in fam, f"a contact's fact is on the owner's family line: {fam}"
    assert _PHONE_DIGITS not in digest


def test_family_owner_relations_survive(env):
    _, digest = _build(env, _SCRIPT, _seed_store(contact_family=True), name="gen_famc")
    fam = _about_family(digest)
    assert "Has a sister called Liz Doe" in fam      # tagged to the owner
    assert OWNER_END_FACT in fam                      # owner is one end of the relation


def test_family_location_bucket_unchanged(env):
    _, digest = _build(env, _SCRIPT, _seed_store(contact_family=True, neighbour_place=True), name="gen_famp")
    places = _about_places(digest)
    assert "Works from Harbourtown on Fridays" in places and "Lives in Fictionville" in places
    assert NEIGHBOUR_PLACE not in places


def test_family_untagged_facts_about_other_people_are_dropped(env):
    """#25 RED on the #2833 generator: untagged legacy facts about OTHER people
    (walk #24 shapes) still sat on the owner's family line."""
    _, digest = _build(env, _SCRIPT, _seed_store(contact_family=True), name="gen_fam25")
    fam = _about_family(digest)
    for t in UNTAGGED_OTHERS:
        assert t not in fam, f"untagged other-people fact on the owner's family line: {t!r}"
    assert "Sam Patel" not in fam


def test_family_untagged_owner_relation_with_owner_as_subject_stays(env):
    _, digest = _build(env, _SCRIPT, _seed_store(contact_family=True), name="gen_fam25c")
    fam = _about_family(digest)
    assert UNTAGGED_OWNER_DAUGHTER in fam
    assert "Has a sister called Liz Doe" in fam and OWNER_END_FACT in fam


# ── #27: untagged location facts leave the Places line ───────────────────────

def test_places_untagged_contact_locations_are_dropped(env):
    """RED on the #2841 generator: the Places bucket kept untagged location facts."""
    _, digest = _build(env, _SCRIPT, _seed_store(untagged_places=True), name="gen_pl27")
    places = _about_places(digest)
    for t in UNTAGGED_CONTACT_PLACES:
        assert t not in places, f"untagged location fact on the owner's Places line: {t!r}"


def test_places_owner_tagged_and_owner_subject_stay(env):
    _, digest = _build(env, _SCRIPT, _seed_store(untagged_places=True, neighbour_place=True), name="gen_pl27c")
    places = _about_places(digest)
    assert "Lives in Fictionville" in places            # tagged to the owner
    assert "Works from Harbourtown on Fridays" in places
    assert UNTAGGED_OWNER_PLACE in places               # owner is the explicit subject
    assert NEIGHBOUR_PLACE not in places


def test_places_a_raw_phone_never_prints(env):
    _, digest = _build(env, _SCRIPT, _seed_store(phone_place=True), name="gen_pl27p")
    assert "55501991" not in digest
    assert "Lives in Fictionville" in _about_places(digest)      # the control: places do render here


# ── People from the signal a messaging customer's graph actually carries ─────
#
# Walk #31 (v1.0.108): "People you interact with most: nothing stored" beside a
# store holding people. The seed above ranks people by pwg:RelationshipSignal
# pwg:totalMessages, a shape only the LinkedIn messages importer writes. The
# shipped iMessage / WhatsApp ingest (vendor/ostler_fda/pwg_ingest.py
# _update_last_contact) and email ingest (vendor/cm021/src/cli.py) store ONE
# last-contact date per channel per person and discard the message count. This
# store is built in exactly those shapes, with no RelationshipSignal and no
# meeting attendee, which is a customer who texts and emails but sends no
# calendar invites.

# The v1.0.108 cut generator, pinned: the build walk #31 measured.
_PREFIX_SHA_LAST_CONTACT = "56a5ed21f708e517bc812fa03b6ff49b01bc2fc8"
XSD = "http://www.w3.org/2001/XMLSchema#"
STALE_CONTACT = "Olga Stale"          # last in touch 200 days ago
L3_CONTACT = "Priya Private"          # L3 person, recent contact
PLACEHOLDER_PHONE = "+447700900199"   # displayName still the phone handle


def _messaging_only_store() -> ox.Store:
    store = ox.Store()
    dg = ox.DefaultGraph()
    rdf_type = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    today = datetime.now(timezone.utc).date()

    def add(s, p, o):
        store.add(ox.Quad(s, _n(p) if isinstance(p, str) else p, o, dg))

    def day(n):  # pwg_ingest._update_last_contact: "YYYY-MM-DD"^^xsd:date
        return ox.Literal((today - timedelta(days=n)).isoformat(),
                          datatype=ox.NamedNode(XSD + "date"))

    def stamp(n):  # cm021 email: ISO "..."^^xsd:dateTime
        return ox.Literal(
            (datetime.now(timezone.utc) - timedelta(days=n)).strftime("%Y-%m-%dT%H:%M:%S+00:00"),
            datatype=ox.NamedNode(XSD + "dateTime"))

    owner = _n(f"user_{OWNER_ID}")
    add(owner, rdf_type, _n("Person"))
    add(owner, "displayName", _lit(OWNER_NAME))

    def person(local, name, level="L2", **last):
        uri = ox.NamedNode(f"https://schema.ostler.ai/ontology#person_{local}")
        add(uri, rdf_type, _n("Person"))
        add(uri, "contactType", _lit("person"))
        add(uri, "privacyLevel", _lit(level))
        add(uri, "source", _lit("imessage_fda"))
        add(uri, "displayName", _lit(name))
        for pred, val in last.items():
            add(uri, pred, val)
        return uri

    person("mary", "Mary Smith", lastContactIMessage=day(1), lastContactEmail=stamp(3))
    person("bob", "Bob Jones", lastContactWhatsApp=day(4))
    person("sam", "Sam Patel", lastContactEmail=stamp(20))
    person("olga", STALE_CONTACT, lastContactIMessage=day(200))
    person("priya", L3_CONTACT, level="L3", lastContactIMessage=day(2))
    person("handle", PLACEHOLDER_PHONE, lastContactIMessage=day(2))
    # The owner's own node can carry a last-contact (a self-thread).
    add(owner, "lastContactIMessage", day(1))
    return store


def test_messaging_control_store_has_no_count_signal_and_has_dates():
    """The RED below must be RED because the dates were ignored, not because
    the store is empty."""
    store = _messaging_only_store()

    def count(q):
        return int(next(iter(store.query(
            "PREFIX pwg: <%s>\nSELECT (COUNT(*) AS ?n) WHERE { %s }" % (PWG, q)
        )))["n"].value)

    assert count("?s a pwg:RelationshipSignal") == 0
    assert count("?m pwg:meetingAttendee ?p") == 0
    assert count("?p pwg:lastContactIMessage ?d") == 5  # incl. the owner self-thread
    assert count("?p pwg:lastContactEmail ?d") == 2
    assert count("?p pwg:lastContactWhatsApp ?d") == 1


@pytest.fixture()
def prefix_module_last_contact(tmp_path) -> Path:
    try:
        src = subprocess.run(
            ["git", "-C", str(_REPO), "show",
             f"{_PREFIX_SHA_LAST_CONTACT}:context-refresh/bin/generate_pwg_context.py"],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout
    except (subprocess.CalledProcessError, OSError) as exc:
        pytest.fail(f"CANNOT-RUN: v1.0.108 generator not readable at "
                    f"{_PREFIX_SHA_LAST_CONTACT} (needs full history): {exc}")
    out = tmp_path / "generate_pwg_context_v1_0_108.py"
    out.write_text(src, encoding="utf-8")
    return out


def test_red_v1_0_108_says_nothing_stored_for_a_messaging_customer(
        env, prefix_module_last_contact):
    gen, digest = _build(env, prefix_module_last_contact, _messaging_only_store(),
                         name="gen_v1_0_108")
    assert digest is not None
    assert ": COULD NOT BE READ" not in digest
    assert _gap_line(digest, "People you interact with most").endswith(
        "nothing stored.")


def test_green_people_ranked_from_last_contact_dates(env):
    gen, digest = _build(env, _SCRIPT, _messaging_only_store())
    assert digest is not None
    people = _section(digest, "People you interact with most")
    rows = [ln for ln in people.splitlines() if ln.startswith("- ")]
    assert [r.split(" (", 1)[0] for r in rows] == [
        "- Mary Smith", "- Bob Jones", "- Sam Patel"], people
    assert "via iMessage, email" in rows[0] or "via email, iMessage" in rows[0], rows[0]
    assert "via WhatsApp" in rows[1], rows[1]
    for absent in (STALE_CONTACT, L3_CONTACT, PLACEHOLDER_PHONE, OWNER_NAME):
        assert absent not in people, f"{absent} must not rank: {people}"
    assert _gap_line(digest, "People you interact with most") == ""


def test_counted_interactions_still_outrank_last_contact_only(env):
    """The original seed's ranking is unchanged: a person with counted
    messages or meetings sits above anyone known only by a recent date."""
    store = _seed_store()
    newcomer = ox.NamedNode("https://schema.ostler.ai/ontology#person_newcomer")
    rdf_type = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    for p, o in ((rdf_type, _n("Person")), (_n("displayName"), _lit("Nina Newcomer")),
                 (_n("lastContactIMessage"), ox.Literal(
                     datetime.now(timezone.utc).date().isoformat(),
                     datatype=ox.NamedNode(XSD + "date")))):
        store.add(ox.Quad(newcomer, p, o, ox.DefaultGraph()))
    gen, digest = _build(env, _SCRIPT, store)
    rows = [ln for ln in _section(digest, "People you interact with most").splitlines()
            if ln.startswith("- ")]
    assert rows[0].startswith("- Mary Smith, Acme Corp"), rows
    names = [r for r in rows if "Nina Newcomer" in r]
    assert not names or rows.index(names[0]) > rows.index(
        next(r for r in rows if r.startswith("- Bob Jones"))), rows


def test_every_shipped_last_contact_predicate_is_read():
    """Producer contract: each per-channel last-contact predicate a shipped
    writer emits is one the digest ranks by. A new channel added to the
    ingest without the digest reading it goes RED here."""
    import re
    ingest = (_REPO / "vendor" / "ostler_fda" / "pwg_ingest.py").read_text(encoding="utf-8")
    block = ingest.split("_SOURCE_PREDICATE = {", 1)[1].split("}", 1)[0]
    written = set(re.findall(r'"pwg:(lastContact\w+)"', block))
    email = (_REPO / "vendor" / "cm021" / "src" / "cli.py").read_text(encoding="utf-8")
    written |= set(re.findall(r"pwg:(lastContact\w+) ", email))
    assert {"lastContactIMessage", "lastContactWhatsApp",
            "lastContactCalendar", "lastContactEmail"} <= written, written
    gen = _load(_SCRIPT, "gen_contract")
    read = {pred for pred, _label in gen._LAST_CONTACT_CHANNELS}
    assert written <= read, f"written but never ranked: {sorted(written - read)}"
