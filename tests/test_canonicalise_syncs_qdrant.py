"""Walk #6, bug 2: canonicalising a person's displayName in Oxigraph must
also reach Qdrant, or the Hub's People list (which reads ONLY Qdrant, see
vendor/cm041/assistant_api/ical-server.py's people_list) keeps showing the
name this just replaced.

ROOT CAUSE, measured by direct source inspection: ``resolver.py``'s
``IdentityResolver`` is Oxigraph-only by construction and has ZERO
references to Qdrant anywhere in the module. ``batch_resolver.py`` has a
SEPARATE merge path with its OWN Qdrant sync (``_merge_qdrant``) --
resolver.py's ``merge_persons`` / ``canonicalise_display_name`` had no
equivalent. Live-box confirmation: two distinct Contacts-linked people
(each proven by an icloud_contact_uid identifier) still displayed by a bare
email in the Hub's People list despite having given_name/family_name
available -- consistent with a canonicalise that fixed the graph but never
told Qdrant.

Vendored into CM051 from the CM041 source graft (same fix, same tests),
with only the sys.path shim below added -- the divergent-twin discipline:
graft the diff, do not clean-re-vendor. See tests/test_resolver_robustness.py
for the same shim pattern already established in this repo.

All URIs/names here are SYNTHETIC (Rule 0): no real personal data.
"""
from __future__ import annotations

import sys
import uuid
from pathlib import Path
from typing import Any, Dict, List
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm041"))

from identity_resolver.resolver import IdentityResolver  # noqa: E402

PERSON = "https://schema.ostler.ai/ontology#person_example"


class _RecordingResolver(IdentityResolver):
    """Captures every SPARQL query/update and every Qdrant-sync call
    instead of issuing them, so these tests have no network dependency."""

    def __init__(self, select_bindings: List[Dict[str, Dict[str, str]]]) -> None:
        # Deliberately does not call super().__init__ -- no real httpx client.
        self._select_bindings = select_bindings
        self.update_queries: List[str] = []
        self.qdrant_sync_calls: List[tuple] = []

    def _sparql_query(self, query: str) -> Dict[str, Any]:  # type: ignore[override]
        return {"results": {"bindings": self._select_bindings}}

    def _sparql_update(self, query: str) -> None:  # type: ignore[override]
        self.update_queries.append(query)

    def _sync_qdrant_display_name(self, person_uri: str, display_name: str) -> None:  # type: ignore[override]
        self.qdrant_sync_calls.append((person_uri, display_name))


def _binding(name: str, given: str = None, family: str = None) -> Dict[str, Dict[str, str]]:
    b = {"name": {"value": name}}
    if given is not None:
        b["given"] = {"value": given}
    if family is not None:
        b["family"] = {"value": family}
    return b


def test_canonicalise_syncs_the_chosen_name_to_qdrant():
    """RED before the fix: canonicalise_display_name computed the right
    name and wrote it to Oxigraph, but nothing told Qdrant."""
    r = _RecordingResolver([
        _binding("person.example@example.com"),
        _binding("Person Example", given="Person", family="Example"),
    ])

    result = r.canonicalise_display_name(PERSON)

    assert result == "Person Example"
    assert r.qdrant_sync_calls == [(PERSON, "Person Example")], (
        "canonicalise_display_name must propagate the chosen name to Qdrant, "
        "not just Oxigraph -- the Hub's People list reads only Qdrant"
    )


def test_control_a_single_existing_binding_is_a_noop_and_does_not_touch_qdrant():
    """CONTROL: the documented no-op path (<=1 displayName value, nothing
    to collapse) must not issue a Qdrant sync either -- proves the sync is
    tied to an ACTUAL collapse, not fired on every read."""
    r = _RecordingResolver([_binding("Person Example")])

    result = r.canonicalise_display_name(PERSON)

    assert result == "Person Example"
    assert r.update_queries == []
    assert r.qdrant_sync_calls == []


def test_control_no_bindings_returns_none_and_does_not_touch_qdrant():
    """CONTROL: a node with no displayName at all is a no-op too."""
    r = _RecordingResolver([])

    result = r.canonicalise_display_name(PERSON)

    assert result is None
    assert r.qdrant_sync_calls == []


# ---------------------------------------------------------------------------
# _sync_qdrant_display_name itself: the Qdrant-facing half, independent of
# the SPARQL plumbing above.
# ---------------------------------------------------------------------------


class _BareResolver(IdentityResolver):
    def __init__(self) -> None:
        pass  # no super().__init__ -- this half never touches Oxigraph


def test_sync_sets_payload_on_the_deterministic_point_id():
    r = _BareResolver()
    fake_client = MagicMock()
    fake_client.retrieve.return_value = [object()]  # point exists

    with patch("qdrant_client.QdrantClient", return_value=fake_client):
        r._sync_qdrant_display_name(PERSON, "Person Example")

    expected_point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, PERSON))
    fake_client.set_payload.assert_called_once_with(
        collection_name="people",
        payload={"display_name": "Person Example", "name": "Person Example"},
        points=[expected_point_id],
    )


def test_control_no_matching_qdrant_point_does_not_set_payload():
    """CONTROL: a person with no Qdrant point (never contact-synced into
    Qdrant) is legitimately nothing to sync -- must not error, must not
    fabricate a point."""
    r = _BareResolver()
    fake_client = MagicMock()
    fake_client.retrieve.return_value = []  # no point

    with patch("qdrant_client.QdrantClient", return_value=fake_client):
        r._sync_qdrant_display_name(PERSON, "Person Example")

    fake_client.set_payload.assert_not_called()


def test_control_qdrant_client_not_installed_does_not_raise():
    """CONTROL: the graph-side canonicalisation has already succeeded by
    the time this runs -- a missing qdrant-client must degrade silently
    (loudly logged, never raised), matching batch_resolver._merge_qdrant's
    own stance."""
    r = _BareResolver()
    with patch.dict(sys.modules, {"qdrant_client": None}):
        r._sync_qdrant_display_name(PERSON, "Person Example")  # must not raise


def test_control_a_qdrant_exception_does_not_raise():
    """CONTROL: an unreachable/erroring Qdrant must not undo or interrupt
    the graph-side fix that already landed."""
    r = _BareResolver()
    fake_client = MagicMock()
    fake_client.retrieve.side_effect = RuntimeError("connection refused")

    with patch("qdrant_client.QdrantClient", return_value=fake_client):
        r._sync_qdrant_display_name(PERSON, "Person Example")  # must not raise
