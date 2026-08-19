"""Pre-ingest hook — lightweight duplicate check before creating a person node.

Wraps ``check_before_insert()`` from the batch resolver, adding confidence-aware
name checking so that shared/inherited email accounts (e.g. a deceased spouse's
address reused by the surviving partner) are flagged for review rather than
silently merged.

Usage::

    from identity_resolver.pre_ingest_hook import pre_ingest_check

    result = pre_ingest_check("Jane Doe", email="jane@example.com")
    if result["action"] == "create":
        # No existing match — safe to create a new person node.
        ...
    elif result["action"] == "merge":
        # Existing person found — update their node instead.
        person_uri = result["canonical_uri"]
        ...
    elif result["action"] == "review":
        # Possible match but low confidence — flag for manual review.
        person_uri = result["canonical_uri"]
        confidence = result["confidence"]
        reason = result["reason"]
        ...

Environment variables:
    OXIGRAPH_URL   (default: http://localhost:7878)
"""
from __future__ import annotations

import os
from typing import Any, Dict, Optional

import httpx

from identity_resolver.batch_resolver import (
    DEFAULT_CONFIG,
    _fetch_all_persons,
    _jaro_winkler,
    _normalise_name,
)
from identity_resolver.normalise import names_agree, normalise_email, normalise_phone


def pre_ingest_check(
    display_name: str,
    email: Optional[str] = None,
    phone: Optional[str] = None,
    *,
    oxigraph_url: Optional[str] = None,
    config: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Check whether a person already exists before creating a new node.

    Returns a dict with one of three ``action`` values:

    - ``{"action": "create"}`` — no match found, safe to insert.
    - ``{"action": "merge", "canonical_uri": "..."}`` — high-confidence match,
      merge into the existing node.
    - ``{"action": "review", "canonical_uri": "...", "confidence": float,
      "reason": "..."}`` — possible match but needs human review.

    Args:
        display_name: The person's display name (required).
        email: Optional email address.
        phone: Optional phone number (any format — normalised internally).
        oxigraph_url: Override for the Oxigraph SPARQL endpoint.
        config: Override individual config keys (merged with DEFAULT_CONFIG).
    """
    url = oxigraph_url or os.environ.get("OXIGRAPH_URL", "http://localhost:7878")
    cfg = {**DEFAULT_CONFIG, **(config or {})}

    client = httpx.Client(timeout=30.0)
    try:
        persons = _fetch_all_persons(url, client, cfg)
    finally:
        client.close()

    incoming_name = _normalise_name(display_name)

    # Strategies 1 and 2: SHAREABLE identifiers (email, phone).
    #
    # These do not identify a person on their own -- households share a
    # landline, couples share an address-book entry, families share an iPad.
    # So a shared value only merges when the NAMES AGREE (see
    # normalise.names_agree; surname equality is the hard gate). Anything else
    # goes to review rather than merge: the pair then appears on the wiki's
    # duplicate-review page with Combine / Different-people buttons, which
    # costs one click, where a wrong merge is unpickable.
    #
    # This replaces a raw Jaro-Winkler threshold (0.7 email / 0.6 phone) that
    # merged "Sandra Andersson" into "Sandra Stewart" at 0.867 because JW
    # rewards a shared prefix and a shared FIRST NAME is the most common thing
    # two different people have.
    for kind, raw_value, norm in (
        ("email", email, lambda v: normalise_email(v)),
        ("phone", phone, lambda v: normalise_phone(v, cfg.get("default_country_code", 852))),
    ):
        if not raw_value:
            continue
        norm_value = norm(raw_value)
        bucket = "emails" if kind == "email" else "phones"
        for uri, p in persons.items():
            if norm_value not in getattr(p, bucket):
                continue
            verdict = names_agree(display_name, p.display_name)
            if verdict == "agree":
                return {"action": "merge", "canonical_uri": uri}
            if verdict == "disagree":
                reason = (
                    f"Shared {kind} {norm_value} but different surnames "
                    f"('{display_name}' vs '{p.display_name}') -- most likely "
                    f"two people sharing one {kind}"
                )
            else:
                reason = (
                    f"Shared {kind} {norm_value} and the names may or may not "
                    f"be the same person ('{display_name}' vs '{p.display_name}')"
                )
            return {
                "action": "review",
                "canonical_uri": uri,
                "confidence": cfg.get(f"{kind}_name_mismatch_confidence", 0.7),
                "reason": reason,
            }

    # Strategy 3: Exact name match (only if unambiguous)
    exact_matches = [
        uri for uri, p in persons.items()
        if _normalise_name(p.display_name) == incoming_name
    ]
    if len(exact_matches) == 1:
        return {"action": "merge", "canonical_uri": exact_matches[0]}

    # Strategy 4: Fuzzy name match (conservative — JW >= 0.93 only)
    for uri, p in persons.items():
        candidate_name = _normalise_name(p.display_name)
        if not candidate_name or candidate_name == incoming_name:
            continue
        jw = _jaro_winkler(incoming_name, candidate_name)
        if jw >= 0.93:
            return {"action": "merge", "canonical_uri": uri}

    return {"action": "create"}
