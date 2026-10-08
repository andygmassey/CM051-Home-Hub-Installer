"""A synthetic, fictional People Graph for the meeting-brief tests and walk probe.

Shared by tests/helpers/real_hub_seed.py (CI, in-memory store) and the
meeting_brief_text_is_grounded walk probe (the box's own Oxigraph).

Every name, address and sentence here is invented. The shapes follow what the
shipped writers produce, as read by ical-server.py:

  Person / Meeting / PersonFact   pwg: default graph      (CM041 writers)
  conversation links, todos       <urn:ostler:user/ID>    (CM048 writers)

Three contacts, one per behaviour the brief must get right:

  RICH   Mira Okonkwo    meetings, a conversation, a channel marker, a stored
                         fact, an open promise from the owner
  NONE   Corin Vasquez   a person with a relationship and a last-contact date
                         but NO logged meetings (the "first meeting" bug)
  THIN   Jules Marlowe   a name and an email, nothing else
"""
import datetime

PWG = "https://schema.ostler.ai/ontology#"
USER_GRAPH = "urn:ostler:user/fixtureowner"

RICH = {"name": "Mira Okonkwo", "slug": "mira-okonkwo", "email": "mira@fixture.example"}
NONE = {"name": "Corin Vasquez", "slug": "corin-vasquez", "email": "corin@fixture.example"}
THIN = {"name": "Jules Marlowe", "slug": "jules-marlowe", "email": "jules@fixture.example"}


def _person(uri, name, email, extra=""):
    return f"""
    <{uri}> a pwg:Person ; pwg:displayName "{name}" ; pwg:privacyLevel "L1" ;
        pwg:hasIdentifier <{uri}/email> {extra} .
    <{uri}/email> pwg:identifierType "email" ; pwg:identifierValue "{email}" .
    """


# Fixed anchor so the captured Hub responses are byte-stable run to run.
ANCHOR = datetime.date(2026, 6, 30)


def sparql(today=ANCHOR, with_named_graph=True):
    """The two SPARQL UPDATEs that build the graph: (default graph, named graph)."""
    d = lambda n: (today - datetime.timedelta(days=n)).isoformat()
    ug = USER_GRAPH
    default = f"""PREFIX pwg: <{PWG}>
    INSERT DATA {{
    {_person("urn:ostler-walk-fixture:mira", RICH["name"], RICH["email"],
        f'; pwg:organization "Fernwood Labs" ; pwg:jobTitle "Head of Design" '
        f'; pwg:relationship "former client" ; pwg:howWeMet "a design conference" '
        f'; pwg:lastContactEmail "{d(5)}"')}
    <urn:ostler-walk-fixture:fact1> a pwg:PersonFact ; pwg:aboutPerson <urn:ostler-walk-fixture:mira> ;
        pwg:factText "Moved to Fernwood Labs in January" ; pwg:privacyLevel "L1" .
    <urn:ostler-walk-fixture:fact2> a pwg:PersonFact ; pwg:aboutPerson <urn:ostler-walk-fixture:mira> ;
        pwg:factText "Private medical detail that must never surface" ; pwg:privacyLevel "L3" .
    <urn:ostler-walk-fixture:m1> a pwg:Meeting ; pwg:meetingAttendee <urn:ostler-walk-fixture:mira> ;
        pwg:meetingSummary "Lisbon workshop budget review" ;
        pwg:meetingDate "{d(40)}" ; pwg:meetingLocation "Studio Nine" ; pwg:meetingId "m1" .
    <urn:ostler-walk-fixture:m2> a pwg:Meeting ; pwg:meetingAttendee <urn:ostler-walk-fixture:mira> ;
        pwg:meetingSummary "Autumn roadmap check-in" ;
        pwg:meetingDate "{d(200)}" ; pwg:meetingLocation "Harbour Cafe" ; pwg:meetingId "m2" .
    {_person("urn:ostler-walk-fixture:corin", NONE["name"], NONE["email"],
        f'; pwg:organization "Northwind Studio" ; pwg:relationship "client" '
        f'; pwg:lastContactWhatsApp "{d(30)}"')}
    {_person("urn:ostler-walk-fixture:jules", THIN["name"], THIN["email"])}
    }}"""
    named = f"""PREFIX pwg: <{PWG}>
    INSERT DATA {{ GRAPH <{ug}> {{
    <urn:ostler:fact/c1> <urn:ostler:about> <urn:ostler-walk-fixture:mira> ;
        <urn:ostler:fromConversation> <urn:ostler:conversation/conv-1> ;
        <urn:ostler:privacyLevel> "L1" .
    <urn:ostler:conversation/conv-1> <urn:ostler:date> "{d(12)}" .
    <urn:ostler:todo/t1> a <urn:ostler:OutstandingTodo> ;
        <urn:ostler:aboutPerson> <urn:ostler-walk-fixture:mira> ;
        <urn:ostler:todoText> "Send Mira the workshop deck" ;
        <urn:ostler:owner> "user" ; <urn:ostler:ownerDisplay> "Sam" ;
        <urn:ostler:status> "open" ; <urn:ostler:deadline> "2030-01-31" ;
        <urn:ostler:todoCreatedAt> "{d(10)}T09:00:00Z" .
    <urn:ostler:todo/t2> a <urn:ostler:OutstandingTodo> ;
        <urn:ostler:aboutPerson> <urn:ostler-walk-fixture:mira> ;
        <urn:ostler:todoText> "Share the venue shortlist" ;
        <urn:ostler:owner> "other" ; <urn:ostler:status> "open" ;
        <urn:ostler:todoCreatedAt> "{d(9)}T09:00:00Z" .
    <urn:ostler:todo/t3> a <urn:ostler:OutstandingTodo> ;
        <urn:ostler:aboutPerson> <urn:ostler-walk-fixture:mira> ;
        <urn:ostler:todoText> "Already sent the contract" ;
        <urn:ostler:owner> "user" ; <urn:ostler:status> "done" ;
        <urn:ostler:todoCreatedAt> "{d(30)}T09:00:00Z" .
    }} }}"""
    return default, (named if with_named_graph else None)


def forget_sparql():
    """Remove every default-graph triple this seed wrote (the box probe never
    writes the named graph, so there is nothing to remove there)."""
    return (
        'DELETE { ?s ?p ?o } WHERE { ?s ?p ?o . '
        'FILTER(STRSTARTS(STR(?s), "urn:ostler-walk-fixture:")) }'
    )


_START = {}


def calendar_events(minutes_ahead=10):
    """What the calendar source would return: one meeting per contact, soon.
    The start is fixed per process so two ticks see the SAME meeting, as a real
    calendar would, which is what makes the idempotency key (uid|start) testable."""
    if minutes_ahead not in _START:
        _START[minutes_ahead] = (datetime.datetime.now(datetime.timezone.utc)
                                 + datetime.timedelta(minutes=minutes_ahead)).replace(microsecond=0)
    start = _START[minutes_ahead]
    iso = start.strftime("%Y-%m-%dT%H:%M:%S+00:00")
    out = []
    for i, p in enumerate((RICH, NONE, THIN)):
        out.append({
            "uid": f"fixture-uid-{i}", "summary": f"Catch up with {p['name'].split()[0]}",
            "start": iso, "start_formatted": start.strftime("%H:%M"),
            "location": "Harbour Cafe",
            "attendees": [{"name": p["name"], "email": p["email"]},
                          {"name": "Sam Fixture", "email": "sam@fixture.example"}],
        })
    return out
