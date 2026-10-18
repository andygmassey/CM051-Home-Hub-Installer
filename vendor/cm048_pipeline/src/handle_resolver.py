"""Resolve a carded contact's raw phone/email handle to their NAME in a
conversation transcript BEFORE fact extraction.

WHY (Andy's #30 console walk, SHAPE 1 -- the NEW-facts half)
===========================================================
A fact read "+447700900123 agreed to delete messages...", yet that number is
carded as "Jane Doe". CM048 treats the transcript's speaker
labels as authoritative (``bundle_extractor``) and does not resolve identity;
the iMessage stager labels a non-carded speaker by the raw handle, so the
extraction LLM bakes the number into the fact text. Verified on the live store
2026-10-17: the fact's ``urn:ostler:text`` literally contains the number, and
its provenance is ``pwg:src=im`` (iMessage), not cm052's AI wire.

This is the ONE convergence point every channel's facts pass through (im,
whatsapp, email, spoken), so resolving here -- once, from the SAME People graph
the wiki's node surfaces read -- fixes new facts for all of them. EXISTING
facts are repaired by a separate one-off backfill (ostler_fda
``repair_fact_text_identifiers``).

CONSERVATIVE: only a handle that resolves to a carded contact with a REAL human
name is substituted; an unknown number is left exactly as it was. Never raises:
an unreachable graph leaves handles unresolved rather than blocking extraction.
"""
from __future__ import annotations

import json as _json
import logging
import re
from pathlib import Path
from typing import Dict, Optional, Tuple

import httpx

logger = logging.getLogger(__name__)

# People + identifiers are written by CM044 into the DEFAULT graph
# (https://schema.ostler.ai/ontology#), NOT the per-user named graph the fact
# store uses -- verified on the live store 2026-10-17 -- so this query must NOT
# be scoped with default-graph-uri.
_NS = "https://schema.ostler.ai/ontology#"
_PHONE_RUN = re.compile(r"\+?\d[\d \-().]{6,}\d")
_EMAIL_RUN = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")

NameMap = Tuple[Dict[str, str], Dict[str, str]]  # (phone_by_canon, name_by_email)


def _canon_phone(value: str) -> str:
    return re.sub(r"\D", "", value or "")


def _is_real_name(name: str) -> bool:
    n = (name or "").strip()
    if not n or "@" in n:
        return False
    if re.fullmatch(r"\+?[\d \-().]+", n):  # a phone-shaped "name" is not a name
        return False
    return any(c.isalpha() for c in n)


class StoreQueryError(RuntimeError):
    """The people-graph query could not be EXECUTED (store unreachable, 401 on
    an enforce-ON install, 5xx). Deliberately distinct from a query that ran
    and returned no carded contacts -- the first is DEGRADED and must be loud,
    the second is a legitimate empty. Conflating them is how a no-auth query
    silently no-ops on every real box. Archie review of #87."""


def _select(sparql: str, oxigraph_url: str) -> list:
    """Run a SELECT against the SAME store endpoint the CM048 fact writer uses
    (``settings.oxigraph_url`` -- candidates.py ``/update``). Raises
    :class:`StoreQueryError` on any transport/HTTP failure so the caller can
    tell a DEGRADED store from an empty result; it does NOT swallow to []."""
    try:
        with httpx.Client(timeout=30.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(
                f"{oxigraph_url}/query",
                content=sparql,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json",
                },
            )
            resp.raise_for_status()
            return resp.json().get("results", {}).get("bindings", [])
    except Exception as exc:  # noqa: BLE001 -- surfaced as StoreQueryError, not []
        raise StoreQueryError(str(exc)) from exc


def _mark_degraded(settings, reason: str, *, clear: bool = False) -> None:
    """Write (or clear) a degraded-state marker so an unreachable/401 store is
    VISIBLE, not silent. A Doctor reader for this marker is a tracked
    follow-up (board row UNCLAIMED); nothing in CM051 reads it YET."""
    try:
        state_dir = getattr(settings, "processing_state_dir", None)
        if not state_dir:
            return
        marker = Path(state_dir) / "handle_resolver_degraded.json"
        if clear:
            marker.unlink(missing_ok=True)
            return
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(
            _json.dumps({"degraded": True, "reason": reason, "component": "handle_resolver"}),
            encoding="utf-8",
        )
    except Exception as exc:  # noqa: BLE001 -- marker is best-effort, never block
        logger.warning("handle_resolver: could not write degraded marker (%s)", exc)


def build_name_map(settings) -> NameMap:
    """``(phone_by_canon, name_by_email)`` for every carded contact with a real
    human name, from the People graph.

    A store that cannot be queried (unreachable, or 401 on an enforce-ON box)
    is reported DEGRADED -- a LOUD error log plus a degraded marker file (a
    Doctor reader is a tracked follow-up, not yet wired) --
    and returns empty maps; it is NOT treated as "no contacts" (which would
    silently no-op the fix on every real box). A query that succeeds with no
    carded contacts clears the marker and returns empty, legitimately."""
    try:
        rows = _select(
            f"PREFIX pwg: <{_NS}> "
            "SELECT ?name ?type ?val WHERE { "
            "?p a pwg:Person ; pwg:displayName ?name ; pwg:hasIdentifier ?i . "
            "?i pwg:identifierType ?type ; pwg:identifierValue ?val }",
            getattr(settings, "oxigraph_url", ""),
        )
    except StoreQueryError as exc:
        logger.error(
            "handle_resolver: people-graph query FAILED at %s (%s). Handles "
            "will NOT resolve and new facts keep raw numbers -- check store "
            "auth / enforcement. Reporting DEGRADED.",
            getattr(settings, "oxigraph_url", ""), exc,
        )
        _mark_degraded(settings, str(exc))
        return ({}, {})
    _mark_degraded(settings, "", clear=True)  # query ran: clear any stale marker
    phone: Dict[str, str] = {}
    email: Dict[str, str] = {}
    for r in rows:
        name = (r.get("name") or {}).get("value", "")
        if not _is_real_name(name):
            continue
        itype = (r.get("type") or {}).get("value", "")
        val = (r.get("val") or {}).get("value", "")
        if itype == "phone":
            canon = _canon_phone(val)
            if len(canon) >= 7:
                phone.setdefault(canon, name)
        elif itype == "email" and "@" in val:
            email.setdefault(val.strip().lower(), name)
    return phone, email


def resolve_text(text, phone: Dict[str, str], email: Dict[str, str]):
    """Replace every carded phone/email handle in ``text`` with the contact's
    name. Unknown handles are untouched. Idempotent (a name is not a handle)."""
    if not text:
        return text

    def _email_sub(m: "re.Match") -> str:
        return email.get(m.group(0).strip().lower()) or m.group(0)

    def _phone_sub(m: "re.Match") -> str:
        return phone.get(_canon_phone(m.group(0))) or m.group(0)

    out = _EMAIL_RUN.sub(_email_sub, str(text))
    out = _PHONE_RUN.sub(_phone_sub, out)
    return out


def resolve(
    transcript: str,
    metadata: dict,
    settings=None,
    name_map: Optional[NameMap] = None,
) -> Tuple[str, dict]:
    """``(transcript, metadata)`` with carded handles replaced by names in the
    transcript text AND the participant displays/ids. ``name_map`` may be given
    (tests) else it is built from the graph via ``settings``. A no-op when
    nothing resolves, so an unknown number is never touched."""
    if name_map is None:
        if settings is None:
            return transcript, metadata
        name_map = build_name_map(settings)
    phone, email = name_map
    if not phone and not email:
        return transcript, metadata

    new_transcript = resolve_text(transcript, phone, email)
    new_metadata = dict(metadata or {})
    parts = new_metadata.get("participants")
    if isinstance(parts, list):
        resolved_parts = []
        for entry in parts:
            if isinstance(entry, dict):
                entry = dict(entry)
                # Rewrite the DISPLAY only, NEVER the id. The id is a join key,
                # not a label: fact attribution keys on other:{id}, the bundle
                # folder slug is built from the participant ids, and people
                # linking / owner self-echo match on the id. Renaming the id
                # would split a thread already stored under the handle into a
                # new name-slugged folder and break attribution. The extraction
                # LLM reads display + transcript, so the fact text still gets
                # the name. (Archie review of #87.)
                if entry.get("display"):
                    entry["display"] = resolve_text(entry["display"], phone, email)
                resolved_parts.append(entry)
            else:
                # A STRING participant is left UNTOUCHED. processor's #12
                # normalisation turns a bare string into an id (its id IS the
                # string), and ids must stay raw handles -- rewriting the string
                # here would make a handle become a name id, the same break the
                # dict branch avoids. The transcript text is still resolved for
                # the LLM; only the structural id is preserved. (Archie #87.)
                resolved_parts.append(entry)
        new_metadata["participants"] = resolved_parts
    return new_transcript, new_metadata
