"""Offline tests for IdentityResolver.register_person (#657).

register_person appends a newly-created person to the resolver's in-memory
fuzzy-candidate index so LATER rows in the SAME import run dedupe against it.
It was previously called by nobody, which let a one-shot bulk import mint a
fresh node for every repeat of a name (e.g. "Jay Livens x6").

These tests are fully offline and deterministic. They never hit Oxigraph:
we pre-seed _fuzzy_candidates to [] (so the index reads as "loaded" and empty,
suppressing the lazy network load) and exercise the in-memory Tier-3 fuzzy
path directly via _fuzzy_match.
"""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from identity_resolver.resolver import IdentityResolver  # noqa: E402


def _make_resolver() -> IdentityResolver:
    """Build a resolver with an empty, already-loaded in-memory index.

    The constructor only creates an httpx client (no network). Setting
    _fuzzy_candidates to [] marks the index as loaded so _fuzzy_match never
    triggers the lazy _load_fuzzy_candidates() Oxigraph query.
    """
    resolver = IdentityResolver(oxigraph_url="http://localhost:0")
    resolver._fuzzy_candidates = []
    return resolver


def test_register_person_makes_new_person_visible_in_same_run():
    """A second identical-name row with the SAME org dedupes against the first.

    Without register_person the second "Jay Livens" would not be in the
    in-memory index, so the fuzzy match would miss and a duplicate node would
    be minted -- the "Jay Livens x6" bug.
    """
    resolver = _make_resolver()

    # No candidate yet -> the first "Jay Livens" finds nothing.
    assert resolver._fuzzy_match("Jay Livens", org="Acme") is None

    # Caller created the person and registered it.
    resolver.register_person("uri1", "Jay Livens", org="Acme")

    # A LATER identical-name row in the SAME run now matches the registered one.
    match = resolver._fuzzy_match("Jay Livens", org="Acme")
    assert match is not None
    assert match.person_uri == "uri1"
    assert match.match_type == "fuzzy_name"


def test_register_person_does_not_force_merge_of_two_different_same_name_people():
    """Two genuinely different same-name people are NOT merged.

    Protects the golden "two Stuart Baileys" case: identical names but
    different LinkedIn profiles. The fuzzy path's hard blocker treats two
    different LinkedIn URLs as two different people regardless of name
    similarity, so register_person alone must never collapse them.
    """
    resolver = _make_resolver()

    resolver.register_person(
        "uri_stuart_a",
        "Stuart Bailey",
        org="Org A",
        linkedin_url="https://linkedin.com/in/stuart-bailey-a",
    )

    # The second Stuart Bailey carries a DIFFERENT LinkedIn URL and org, so the
    # exclude_linkedin_url hard blocker must prevent a match against the first.
    match = resolver._fuzzy_match(
        "Stuart Bailey",
        org="Org B",
        exclude_linkedin_url="https://linkedin.com/in/stuart-bailey-b",
    )
    assert match is None


def test_org_conflict_blocks_same_name_different_employer():
    """Two real "Stuart Bailey"s at DIFFERENT employers, no LinkedIn URL.

    This is the golden case the org-conflict guard protects. Identical names
    score 1.0, which would otherwise auto-merge via the >=0.93 path. With both
    sides carrying a recorded-but-conflicting organisation, they must NOT be
    merged: they are almost certainly two different people.
    """
    resolver = _make_resolver()
    resolver.register_person("uri_stuart_bank", "Stuart Bailey", org="Bank A")

    match = resolver._fuzzy_match("Stuart Bailey", org="Startup B")
    assert match is None


def test_same_name_no_org_conflict_still_merges():
    """Same name with NO conflicting org still merges (we did not over-tighten).

    Either side missing an org means there is no conflict, so the >=0.93 path
    still collapses the duplicate: the common "Jay Livens" cross-source case
    where one record has an org and the other does not.
    """
    resolver = _make_resolver()
    resolver.register_person("uri_jay", "Jay Livens", org="Acme")

    # Incoming row has no org recorded -> no conflict -> should still match.
    match = resolver._fuzzy_match("Jay Livens", org=None)
    assert match is not None
    assert match.person_uri == "uri_jay"
