"""Offline tests for the BW-1 shared-identifier name-agreement guard.

After the BW-1 normalisation fix, the syncer writes identifier values in the
resolver's lookup form, so Tier-1/Tier-2 exact-identifier dedup finally fires.
That makes a NEW risk live: a reused family email or a shared office phone
line would collapse two genuinely different people. The guard
(`_identifier_match_trustworthy`) only acts on a SHAREABLE identifier match
when the display names also agree.

All names/values below are synthetic. Fully offline: find_by_identifier and
_person_display_name are monkeypatched, so no Oxigraph is touched.
"""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from identity_resolver.models import PersonIdentity  # noqa: E402
from identity_resolver.resolver import IdentityResolver  # noqa: E402


def _make_resolver(existing_by_value, names_by_uri):
    """Resolver whose Oxigraph lookups are served from in-memory dicts.

    existing_by_value: {identifier_value -> person_uri} for find_by_identifier
    names_by_uri:      {person_uri -> displayName} for _person_display_name
    """
    r = IdentityResolver(oxigraph_url="http://localhost:0")
    r._fuzzy_candidates = []  # mark index loaded -> no network fuzzy load

    def _find(id_type, id_value):
        return existing_by_value.get(id_value)

    def _name(uri):
        return names_by_uri.get(uri)

    r.find_by_identifier = _find          # type: ignore[assignment]
    r._person_display_name = _name        # type: ignore[assignment]
    return r


SHARED_EMAIL = "shared.address@example.com"
SHARED_PHONE = "+443069990123"  # OFCOM fiction range, E.164


def test_same_name_shared_email_merges():
    """A second card with the SAME name + shared email must resolve to the
    existing node (the exact-identifier dedup BW-1 restores)."""
    r = _make_resolver(
        existing_by_value={SHARED_EMAIL: "uri_a"},
        names_by_uri={"uri_a": "Sam Carter"},
    )
    identity = PersonIdentity(display_name="Sam Carter", emails=[SHARED_EMAIL])
    match = r.resolve(identity, use_fuzzy=False)
    assert match.person_uri == "uri_a"
    assert match.match_type == "exact_identifier"


def test_different_name_shared_email_does_not_merge():
    """Two relatives who reused one email (different people, different names):
    the shared-email match must be declined so they stay as separate nodes."""
    r = _make_resolver(
        existing_by_value={SHARED_EMAIL: "uri_b"},
        names_by_uri={"uri_b": "Jamie Rivera"},
    )
    identity = PersonIdentity(display_name="Robin Rivera", emails=[SHARED_EMAIL])
    match = r.resolve(identity, use_fuzzy=False)
    assert match.person_uri is None
    assert match.match_type == "new"


def test_different_name_shared_phone_does_not_merge():
    """Two colleagues on the same office DID line must NOT merge."""
    r = _make_resolver(
        existing_by_value={SHARED_PHONE: "uri_c"},
        names_by_uri={"uri_c": "Alex Stone"},
    )
    identity = PersonIdentity(display_name="Pat Quinn", phones=[SHARED_PHONE])
    # phones are normalised by _iter_identifiers; SHARED_PHONE is already E.164
    # so it passes through normalise_phone unchanged.
    match = r.resolve(identity, use_fuzzy=False)
    assert match.person_uri is None
    assert match.match_type == "new"


def test_unique_identifier_match_always_trusted():
    """A unique iCloud UID: a match is trusted even if the display name differs
    (e.g. the card was renamed since first import)."""
    uid = "ABC-123-UID:ABPerson"
    r = _make_resolver(
        existing_by_value={uid: "uri_d"},
        names_by_uri={"uri_d": "Old Name"},
    )
    identity = PersonIdentity(display_name="New Name", icloud_uid=uid)
    match = r.resolve(identity, use_fuzzy=False)
    assert match.person_uri == "uri_d"
    assert match.match_type == "exact_identifier"


def test_missing_incoming_name_declines_shareable_match():
    """If the incoming contact has no name we cannot confirm same-person on a
    shared email, so decline (a recoverable duplicate beats a wrong merge)."""
    r = _make_resolver(
        existing_by_value={SHARED_EMAIL: "uri_a"},
        names_by_uri={"uri_a": "Sam Carter"},
    )
    identity = PersonIdentity(display_name="", emails=[SHARED_EMAIL])
    match = r.resolve(identity, use_fuzzy=False)
    assert match.person_uri is None


def test_guard_unit_email_case_insensitive_name():
    """The name check normalises case + whitespace, so trivial display
    differences still merge; unique ids bypass the name check entirely."""
    r = _make_resolver(
        existing_by_value={},
        names_by_uri={"uri_x": "  sam   CARTER "},
    )
    identity = PersonIdentity(display_name="Sam Carter")
    assert r._identifier_match_trustworthy("email", "uri_x", identity) is True
    assert r._identifier_match_trustworthy("icloud_contact_uid", "uri_x", identity) is True
