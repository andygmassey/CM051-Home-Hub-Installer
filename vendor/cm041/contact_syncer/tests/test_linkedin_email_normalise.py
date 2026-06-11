"""BW-1b: LinkedIn-sourced person nodes must store NORMALISED email values.

The identity resolver normalises emails on read (find_by_identifier queries the
lower-cased, trimmed form). If create_person_oxigraph wrote the raw export
value, a LinkedIn connection whose email differs only in case would never match
the normalised contact-card node, leaving a duplicate person. This is the same
write/read mismatch as the BW-1 contact_syncer fix, in a second writer.

Fully offline: the Oxigraph update is monkeypatched, so nothing is queried.
All names/emails below are synthetic.
"""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

from identity_resolver.models import PersonIdentity  # noqa: E402
from identity_resolver.normalise import normalise_email  # noqa: E402
from contact_syncer import linkedin_connections  # noqa: E402


def _capture_sparql(monkeypatch):
    captured = {}

    def _fake_update(oxigraph_url, sparql):
        captured["sparql"] = sparql

    monkeypatch.setattr(linkedin_connections, "_sparql_update", _fake_update)
    return captured


def test_mixed_case_email_written_lowercased(monkeypatch):
    captured = _capture_sparql(monkeypatch)
    identity = PersonIdentity(display_name="Sam Carter")
    linkedin_connections.create_person_oxigraph(
        oxigraph_url="http://localhost:0",
        person_uri="https://pwg.dev/ontology#person_test",
        person_id="test",
        identity=identity,
        extra={"email": "  Sam.Carter@Example.COM "},
        user_id="u1",
        privacy_level="L2",
    )
    sparql = captured["sparql"]
    # The normalised form is what the resolver will look for on the next import.
    assert 'pwg:identifierValue "sam.carter@example.com"' in sparql
    # The raw mixed-case value must NOT be persisted.
    assert "Sam.Carter@Example.COM" not in sparql


def test_already_normalised_email_unchanged(monkeypatch):
    captured = _capture_sparql(monkeypatch)
    value = "jamie.rivera@example.com"
    assert normalise_email(value) == value  # guard the premise
    identity = PersonIdentity(display_name="Jamie Rivera")
    linkedin_connections.create_person_oxigraph(
        oxigraph_url="http://localhost:0",
        person_uri="https://pwg.dev/ontology#person_test2",
        person_id="test2",
        identity=identity,
        extra={"email": value},
        user_id="u1",
        privacy_level="L2",
    )
    assert f'pwg:identifierValue "{value}"' in captured["sparql"]


def test_no_email_writes_no_email_identifier(monkeypatch):
    captured = _capture_sparql(monkeypatch)
    identity = PersonIdentity(display_name="Robin Rivera")
    linkedin_connections.create_person_oxigraph(
        oxigraph_url="http://localhost:0",
        person_uri="https://pwg.dev/ontology#person_test3",
        person_id="test3",
        identity=identity,
        extra={"linkedin_url": "https://www.linkedin.com/in/robin-rivera"},
        user_id="u1",
        privacy_level="L2",
    )
    assert 'identifierType "email"' not in captured["sparql"]
