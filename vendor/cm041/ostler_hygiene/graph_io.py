"""SPARQL builders + binding parsers for the hygiene overlay.

Pure string-in/string-out functions (fully unit-testable offline). The
thin network runner lives in ``run.py``; everything here is
deterministic.

Two namespaces are read (spec 1.1/1.2): CM041 ``pwg:PersonFact`` under
``https://pwg.dev/ontology#`` in the default graph, and CM048
``urn:pwg:Fact`` inside per-user named graphs (``urn:pwg:user/<id>``).
CM048 fact triples carry no timestamp and no source predicate today, so
they parse as recency-incomparable ``conversation_memory`` facts (which
the engine will only ever flag, never auto-supersede).

WRITE SAFETY: every UPDATE this module builds touches ONLY the
``<urn:pwg:hygiene>`` named graph, and only verdict-URI subjects. There
is no code path here that can delete or mutate a source fact triple.
"""
from __future__ import annotations

import re
from datetime import datetime
from typing import Any, Dict, List, Optional

from ostler_hygiene.model import (
    FactRecord,
    HygieneVerdict,
    STATUS_ACTIVE,
    _privacy_class,
)

PWG_NS = "https://pwg.dev/ontology#"
HYGIENE_GRAPH = "urn:pwg:hygiene"

_CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def escape_literal(value: str) -> str:
    """Escape a string for a double-quoted SPARQL literal.

    Mirrors ``_sparql_escape_literal`` in assistant_api/ical-server.py
    (a hyphenated, non-importable script): backslash FIRST, then quote,
    then the line-structural characters. Control characters are rejected
    outright rather than silently stripped.
    """
    if _CONTROL_CHARS.search(value):
        raise ValueError("control character in SPARQL literal")
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def _validate_uri(uri: str) -> str:
    """Guard a URI before angle-bracket interpolation."""
    if not uri or re.search(r"[<>\s\"{}|\\^`]", uri):
        raise ValueError(f"unsafe URI for SPARQL interpolation: {uri!r}")
    return uri


# ---------------------------------------------------------------------------
# Reads
# ---------------------------------------------------------------------------

def build_facts_query(limit: Optional[int] = None) -> str:
    """SELECT all person facts across both namespaces.

    AUDIT_3 CRITICAL: the owning person node's ``pwg:privacyLevel`` is
    joined for facts from BOTH branches -- in the real graph L3 lives on
    the ``pwg:Person`` node (contact_syncer/syncer.py,
    linkedin_connections.py, owner_node.py), never on mined fact
    triples. The named-graph variant is also probed in case a CM048-side
    person node carries its own stamp; the parser takes the most
    restrictive of everything bound.
    """
    q = f"""PREFIX pwg: <{PWG_NS}>
SELECT ?fact ?person ?text ?source ?domain ?authoritative ?candidate
       ?createdAt ?validFrom ?validTo ?observedAt ?privacyLevel
       ?personPrivacy ?personPrivacyNG
WHERE {{
  {{
    ?fact a pwg:PersonFact ;
          pwg:aboutPerson ?person ;
          pwg:factText ?text .
    OPTIONAL {{ ?fact pwg:factSource ?source }}
    OPTIONAL {{ ?fact pwg:factDomain ?domain }}
    OPTIONAL {{ ?fact pwg:authoritative ?authoritative }}
    OPTIONAL {{ ?fact pwg:createdAt ?createdAt }}
    OPTIONAL {{ ?fact pwg:validFrom ?validFrom }}
    OPTIONAL {{ ?fact pwg:validTo ?validTo }}
    OPTIONAL {{ ?fact pwg:observedAt ?observedAt }}
    OPTIONAL {{ ?fact pwg:privacyLevel ?privacyLevel }}
  }} UNION {{
    GRAPH ?g {{
      ?fact a <urn:pwg:Fact> ;
            <urn:pwg:about> ?person ;
            <urn:pwg:text> ?text .
      OPTIONAL {{ ?fact <urn:pwg:domain> ?domain }}
      OPTIONAL {{ ?fact <urn:pwg:candidate> ?candidate }}
      OPTIONAL {{ ?fact <urn:pwg:observedAt> ?observedAt }}
      OPTIONAL {{ ?fact <urn:pwg:privacyLevel> ?privacyLevel }}
    }}
  }}
  OPTIONAL {{ ?person pwg:privacyLevel ?personPrivacy }}
  OPTIONAL {{ GRAPH ?pg {{ ?person <urn:pwg:privacyLevel> ?personPrivacyNG }} }}
}}"""
    if limit:
        q += f"\nLIMIT {int(limit)}"
    return q


def build_verdicts_query() -> str:
    """SELECT existing verdicts from the hygiene named graph."""
    return f"""PREFIX pwg: <{PWG_NS}>
SELECT ?verdict ?fact ?status ?supersededBy ?reason ?verdictAt ?run ?userOverride
       ?recencyWeight ?effectiveWeight ?corroborationCount
WHERE {{
  GRAPH <{HYGIENE_GRAPH}> {{
    ?verdict a pwg:HygieneVerdict ;
             pwg:verdictFact ?fact ;
             pwg:factStatus ?status .
    OPTIONAL {{ ?verdict pwg:supersededBy ?supersededBy }}
    OPTIONAL {{ ?verdict pwg:verdictReason ?reason }}
    OPTIONAL {{ ?verdict pwg:verdictAt ?verdictAt }}
    OPTIONAL {{ ?verdict pwg:verdictRun ?run }}
    OPTIONAL {{ ?verdict pwg:userOverride ?userOverride }}
    OPTIONAL {{ ?verdict pwg:recencyWeight ?recencyWeight }}
    OPTIONAL {{ ?verdict pwg:effectiveWeight ?effectiveWeight }}
    OPTIONAL {{ ?verdict pwg:corroborationCount ?corroborationCount }}
  }}
}}"""


def _parse_dt(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    v = value.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(v)
    except ValueError:
        # Date-only or unparseable oddities: try the date prefix, else None
        # (fail-safe: an unparseable timestamp makes the fact
        # recency-incomparable, never auto-superseded).
        try:
            return datetime.fromisoformat(v[:10])
        except ValueError:
            return None


def _parse_bool(value: Optional[str]) -> bool:
    return (value or "").strip().lower() == "true"


def _parse_float(value: Optional[str]) -> Optional[float]:
    try:
        return float(value) if value not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _parse_int(value: Optional[str]) -> Optional[int]:
    try:
        return int(value) if value not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _most_restrictive_privacy(*values: Optional[str]) -> Optional[str]:
    """Combine several privacy stamps for one node: any L3/unparseable
    stamp wins outright (fail-closed), else the highest safe level, else
    ``None`` (no signal -- which ``FactRecord.is_l3`` itself treats as
    most-restrictive).

    Classification goes through the single shared ``_privacy_class``
    (F8: one canonical L3 contract, ultimately
    ``contact_syncer.privacy_model.normalise_level``), never a local
    safe-level set."""
    known = [v for v in values if v and v.strip()]
    if not known:
        return None
    for v in known:
        if _privacy_class(v) == "l3":
            return v
    return max(known, key=lambda v: v.strip().lower())


def parse_fact_bindings(bindings: List[Dict[str, Any]]) -> List[FactRecord]:
    """Turn SPARQL SELECT bindings (already value-flattened, as
    ``_sparql_select`` returns them) into ``FactRecord`` objects."""
    facts = []
    for b in bindings:
        uri = b.get("fact")
        person = b.get("person")
        text = b.get("text")
        if not uri or not person or not text:
            continue
        is_cm048 = uri.startswith("urn:pwg:")
        source = b.get("source") or ("conversation_memory" if is_cm048 else None)
        facts.append(FactRecord(
            uri=uri,
            person_uri=person,
            text=text,
            source=source,
            domain=b.get("domain"),
            authoritative=_parse_bool(b.get("authoritative")),
            candidate=_parse_bool(b.get("candidate")),
            created_at=_parse_dt(b.get("createdAt")),
            valid_from=_parse_dt(b.get("validFrom")),
            valid_to=_parse_dt(b.get("validTo")),
            observed_at=_parse_dt(b.get("observedAt")),
            privacy_level=b.get("privacyLevel"),
            person_privacy_level=_most_restrictive_privacy(
                b.get("personPrivacy"), b.get("personPrivacyNG")),
        ))
    return facts


def parse_verdict_bindings(
    bindings: List[Dict[str, Any]],
) -> Dict[str, HygieneVerdict]:
    """Existing verdicts keyed by fact URI (input to the engine)."""
    verdicts: Dict[str, HygieneVerdict] = {}
    for b in bindings:
        fact = b.get("fact")
        if not fact:
            continue
        verdicts[fact] = HygieneVerdict(
            fact_uri=fact,
            status=b.get("status") or STATUS_ACTIVE,
            superseded_by=b.get("supersededBy"),
            reason=b.get("reason"),
            verdict_at=_parse_dt(b.get("verdictAt")),
            run_id=b.get("run"),
            user_override=_parse_bool(b.get("userOverride")),
            recency_weight=_parse_float(b.get("recencyWeight")),
            effective_weight=_parse_float(b.get("effectiveWeight")),
            corroboration_count=_parse_int(b.get("corroborationCount")),
        )
    return verdicts


# ---------------------------------------------------------------------------
# Writes (hygiene named graph ONLY)
# ---------------------------------------------------------------------------

def build_verdict_upsert(verdict: HygieneVerdict) -> str:
    """DELETE-then-INSERT one verdict, keyed by its deterministic URI.

    Idempotent: re-running the pass rewrites the same verdict row. Both
    statements are scoped to ``GRAPH <urn:pwg:hygiene>``; the source
    fact is referenced, never touched.
    """
    v_uri = _validate_uri(verdict.uri)
    f_uri = _validate_uri(verdict.fact_uri)
    lines = [
        f"<{v_uri}> a pwg:HygieneVerdict ;",
        f"  pwg:verdictFact <{f_uri}> ;",
        f'  pwg:factStatus "{escape_literal(verdict.status)}" ;',
    ]
    if verdict.superseded_by:
        s_uri = _validate_uri(verdict.superseded_by)
        lines.append(f"  pwg:supersededBy <{s_uri}> ;")
    if verdict.source_trust is not None:
        lines.append(
            f'  pwg:sourceTrust "{verdict.source_trust:.2f}"^^xsd:decimal ;'
        )
    if verdict.recency_weight is not None:
        lines.append(
            f'  pwg:recencyWeight "{verdict.recency_weight:.4f}"^^xsd:decimal ;'
        )
    if verdict.effective_weight is not None:
        lines.append(
            f'  pwg:effectiveWeight "{verdict.effective_weight:.4f}"^^xsd:decimal ;'
        )
    if verdict.corroboration_count is not None:
        lines.append(
            f'  pwg:corroborationCount "{int(verdict.corroboration_count)}"^^xsd:integer ;'
        )
    if verdict.observed_at is not None:
        lines.append(
            f'  pwg:observedAt "{verdict.observed_at.isoformat()}"^^xsd:dateTime ;'
        )
    if verdict.reason:
        lines.append(
            f'  pwg:verdictReason "{escape_literal(verdict.reason)}" ;'
        )
    if verdict.verdict_at is not None:
        lines.append(
            f'  pwg:verdictAt "{verdict.verdict_at.isoformat()}"^^xsd:dateTime ;'
        )
    if verdict.run_id:
        lines.append(f'  pwg:verdictRun "{escape_literal(verdict.run_id)}" ;')
    lines.append(
        f"  pwg:userOverride {'true' if verdict.user_override else 'false'} ."
    )
    body = "\n    ".join(lines)
    return f"""PREFIX pwg: <{PWG_NS}>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
DELETE WHERE {{ GRAPH <{HYGIENE_GRAPH}> {{ <{v_uri}> ?p ?o }} }} ;
INSERT DATA {{
  GRAPH <{HYGIENE_GRAPH}> {{
    {body}
  }}
}}"""


def build_verdict_undo(verdict_uri_str: str) -> str:
    """Delete one verdict row -- the UNDO affordance (spec 2.2: un-retiring
    / un-forgetting is deleting a verdict row). The source fact, having
    never been touched, is simply active again."""
    v_uri = _validate_uri(verdict_uri_str)
    return (
        f"DELETE WHERE {{ GRAPH <{HYGIENE_GRAPH}> {{ <{v_uri}> ?p ?o }} }}"
    )
