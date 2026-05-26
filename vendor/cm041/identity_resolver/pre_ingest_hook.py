"""Pre-ingest hook — lightweight duplicate check before creating a person node.

Wraps ``check_before_insert()`` from the batch resolver, adding confidence-aware
name checking so that shared/inherited email accounts (e.g. a deceased spouse's
address reused by the surviving partner) are flagged for review rather than
silently merged.

Usage::

    from identity_resolver.pre_ingest_hook import pre_ingest_check

    result = pre_ingest_check("Danny Kwan", email="danny@example.com")
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
from identity_resolver.normalise import normalise_email, normalise_phone


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

    # Strategy 1: Email match (strongest signal, but name-aware)
    if email:
        norm_email = normalise_email(email)
        for uri, p in persons.items():
            if norm_email not in p.emails:
                continue
            candidate_name = _normalise_name(p.display_name)
            name_sim = _jaro_winkler(incoming_name, candidate_name) if incoming_name and candidate_name else 0.0
            threshold = cfg.get("email_name_similarity_threshold", 0.7)
            if name_sim >= threshold:
                return {"action": "merge", "canonical_uri": uri}
            else:
                return {
                    "action": "review",
                    "canonical_uri": uri,
                    "confidence": cfg.get("email_name_mismatch_confidence", 0.7),
                    "reason": (
                        f"Shared email {norm_email} but names differ "
                        f"('{display_name}' vs '{p.display_name}', "
                        f"similarity {name_sim:.2f})"
                    ),
                }

    # Strategy 2: Phone match (name-aware)
    if phone:
        norm_phone = normalise_phone(phone, cfg.get("default_country_code", 852))
        for uri, p in persons.items():
            if norm_phone not in p.phones:
                continue
            candidate_name = _normalise_name(p.display_name)
            name_sim = _jaro_winkler(incoming_name, candidate_name) if incoming_name and candidate_name else 0.0
            threshold = cfg.get("phone_name_similarity_threshold", 0.6)
            if name_sim >= threshold:
                return {"action": "merge", "canonical_uri": uri}
            else:
                return {
                    "action": "review",
                    "canonical_uri": uri,
                    "confidence": cfg.get("phone_name_mismatch_confidence", 0.6),
                    "reason": (
                        f"Shared phone {norm_phone} but names differ "
                        f"('{display_name}' vs '{p.display_name}', "
                        f"similarity {name_sim:.2f})"
                    ),
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
