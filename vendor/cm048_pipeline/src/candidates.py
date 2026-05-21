"""Foundry candidate promotion.

Newly extracted facts are stamped as candidates by the ingest path.
This module finds corroborations and flips the `pwg:candidate` flag
to "false" when a second independent source supports the same claim.

Corroboration rule (per Archie's review):

    Different conversation_id AND
    (different non-user participants OR different setting)

The "different non-user participants" half guards against the
same-source-repeated case: two operator+Pierre conversations on different
days both claiming "Pierre is starting a CVC" is NOT corroboration –
that's one source (Pierre) repeated. But operator+Pierre claiming it AND
operator+Sarah mentioning Pierre's CVC IS corroboration – two independent
sources.

The setting check is a secondary corroboration path: the same
participants meeting in a different context (work meeting vs. social
coffee) gives the claim enough independence to promote. We OPTIONAL
the setting triple in the SPARQL so legacy conversations that lack it
don't kill the match — the participants rule alone still applies.

LLM-confidence auto-promote is explicitly NOT implemented here: the
whole point of the pattern is that single-source claims are
untrustworthy regardless of how confidently the model asserts them.
For manual override, see the `pwg-convo candidates --promote` CLI in
cli.py (Increment 3).
"""
from __future__ import annotations

import logging
from pathlib import Path

import httpx

from .ingest import _deterministic_id
from .ollama_client import OllamaClient
from .schemas import read_json
from .settings import Settings


logger = logging.getLogger(__name__)


# Cosine similarity threshold for treating two facts as "the same
# claim". Set higher than the conversation-linker's 0.70 because we
# want near-identical claims, not just topical relatedness.
SIMILARITY_THRESHOLD = 0.85


def promote_corroborated(
    conversation_id: str,
    state_dir: Path,
    settings: Settings,
    *,
    dry_run: bool = False,
) -> dict:
    """Check this conversation's candidate facts for corroboration.

    For each candidate, search Qdrant for a semantically-similar fact
    (same subject, different conversation), then verify the
    corroboration rule via SPARQL. Satisfied → SPARQL UPDATE flips both
    facts' ``pwg:candidate`` to "false".

    Returns ``{"checked": N, "corroborated": N, "promoted": N}``.
    ``promoted`` counts each affected fact, so a single corroboration
    pair increments it by 2.
    """
    stats = {"checked": 0, "corroborated": 0, "promoted": 0}

    facts_path = state_dir / "05_facts.json"
    if not facts_path.exists():
        return stats
    facts = read_json(facts_path)
    if not isinstance(facts, list):
        return stats

    candidates = [f for f in facts if f.get("candidate", False)]
    if not candidates:
        logger.info("No candidate facts to check for %s", conversation_id)
        return stats

    client = OllamaClient(base_url=settings.ollama_url)

    for fact in candidates:
        text = fact.get("text", "")
        subject = fact.get("subject", "")
        if not text or not subject:
            continue
        stats["checked"] += 1

        try:
            vec = client.embed(text)
        except Exception as exc:
            logger.warning("Embed failed for candidate fact: %s", exc)
            continue

        hits = _search_similar_facts(
            vec, conversation_id, subject, settings,
        )
        for hit in hits:
            other_conv = (hit.get("payload") or {}).get("conversation_id", "")
            if not other_conv or other_conv == conversation_id:
                continue
            if not _corroboration_satisfied(
                conversation_id, other_conv, settings,
            ):
                continue

            fact_id_new = _fact_id(conversation_id, text)
            fact_id_other = str(hit.get("id", ""))
            if not fact_id_other:
                continue

            stats["corroborated"] += 1
            logger.info(
                "Corroboration: %s (%s) <=> %s (%s)",
                fact_id_new, conversation_id,
                fact_id_other, other_conv,
            )
            if not dry_run:
                _promote_pair(fact_id_new, fact_id_other, settings)
            stats["promoted"] += 2
            break  # one corroboration suffices per candidate

    logger.info(
        "Candidates for %s: checked=%d corroborated=%d promoted=%d",
        conversation_id, stats["checked"],
        stats["corroborated"], stats["promoted"],
    )
    return stats


# ── Qdrant similarity search ─────────────────────────────────────────


def _search_similar_facts(
    vector: list[float],
    conversation_id: str,
    subject: str,
    settings: Settings,
) -> list[dict]:
    """Find high-similarity facts with matching subject in OTHER convos.

    Returns [] on any Qdrant error — the caller treats "no hits" and
    "Qdrant down" identically (leave fact as candidate, try again next
    compile). Deliberately don't raise: a transient Qdrant hiccup
    shouldn't fail the pipeline.
    """
    url = (
        f"{settings.qdrant_url}/collections/"
        f"{settings.qdrant_conversations_collection}/points/search"
    )
    payload = {
        "vector": vector,
        "limit": 5,
        "with_payload": ["conversation_id", "subject", "text"],
        "score_threshold": SIMILARITY_THRESHOLD,
        "filter": {
            "must": [
                {"key": "user_id", "match": {"value": settings.user_id}},
                {"key": "point_type", "match": {"value": "fact"}},
                {"key": "subject", "match": {"value": subject}},
            ],
            "must_not": [
                {"key": "conversation_id", "match": {"value": conversation_id}},
            ],
        },
    }
    try:
        with httpx.Client(timeout=30.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        return data.get("result", []) or []
    except Exception as exc:
        logger.warning("Qdrant candidate-search failed: %s", exc)
        return []


# ── Corroboration rule check ─────────────────────────────────────────


def _corroboration_satisfied(
    conv_a: str,
    conv_b: str,
    settings: Settings,
) -> bool:
    """Archie's rule: different conversation_id AND (different
    participants OR different setting).

    Uses OPTIONAL in the setting SPARQL so pre-pattern conversations
    (no pwg:setting triple) fall back to the participants rule alone.
    """
    setting_a, setting_b = _get_settings(conv_a, conv_b, settings)
    if setting_a and setting_b and setting_a != setting_b:
        return True

    participants_a = _get_participants(conv_a, settings)
    participants_b = _get_participants(conv_b, settings)
    # If either has a participant the other lacks, sources differ.
    # Empty sets (no signals) fall through as "can't confirm" — don't
    # promote on participant grounds; require the setting path instead.
    if participants_a and participants_b and participants_a != participants_b:
        return True

    return False


def _get_settings(
    conv_a: str,
    conv_b: str,
    settings: Settings,
) -> tuple[str, str]:
    """Fetch both conversations' pwg:setting values in one query.

    Returns ("", "") when missing — triggers fallback to the
    participants-differ check, per the migration semantic.
    """
    sparql = f"""
PREFIX pwg: <urn:pwg:>
SELECT ?setting_a ?setting_b WHERE {{
  OPTIONAL {{ <urn:pwg:conversation/{conv_a}> pwg:setting ?setting_a }}
  OPTIONAL {{ <urn:pwg:conversation/{conv_b}> pwg:setting ?setting_b }}
}}
"""
    rows = _sparql_select(sparql, settings)
    if not rows:
        return "", ""
    r = rows[0]
    return r.get("setting_a", ""), r.get("setting_b", "")


def _get_participants(conv: str, settings: Settings) -> set[str]:
    """Return the set of non-user participant URIs for a conversation.

    Derived from pwg:RelationshipSignal triples: each signal records
    one non-user participant via pwg:about. An empty set means the
    conversation had no signals (solo monologue or pre-signals data).
    """
    sparql = f"""
PREFIX pwg: <urn:pwg:>
SELECT DISTINCT ?person WHERE {{
  ?signal pwg:observedIn <urn:pwg:conversation/{conv}> ;
          pwg:about ?person .
}}
"""
    rows = _sparql_select(sparql, settings)
    return {r.get("person", "") for r in rows if r.get("person")}


# ── SPARQL execution helpers ─────────────────────────────────────────


def _sparql_select(sparql: str, settings: Settings) -> list[dict]:
    """Execute a SPARQL SELECT and return binding dicts.

    Uses the user's named graph (urn:pwg:user/{user_id}).
    """
    graph_uri = f"urn:pwg:user/{settings.user_id}"
    try:
        with httpx.Client(timeout=30.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(
                f"{settings.oxigraph_url}/query",
                content=sparql,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json",
                },
                params={"default-graph-uri": graph_uri},
            )
            resp.raise_for_status()
            data = resp.json()
    except Exception as exc:
        logger.warning("SPARQL select failed: %s", exc)
        return []

    out: list[dict] = []
    for binding in data.get("results", {}).get("bindings", []):
        row: dict = {}
        for var, val in binding.items():
            row[var] = val.get("value", "")
        out.append(row)
    return out


def _promote_pair(
    fact_id_a: str,
    fact_id_b: str,
    settings: Settings,
) -> None:
    """Flip both facts' pwg:candidate to 'false' via SPARQL UPDATE.

    Uses DELETE/INSERT WHERE so the update is idempotent — running it
    again on an already-promoted fact is a no-op.
    """
    graph_uri = f"urn:pwg:user/{settings.user_id}"
    sparql = f"""
PREFIX pwg: <urn:pwg:>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>

DELETE {{
  <urn:pwg:fact/{fact_id_a}> pwg:candidate ?old_a .
  <urn:pwg:fact/{fact_id_b}> pwg:candidate ?old_b .
}}
INSERT {{
  <urn:pwg:fact/{fact_id_a}> pwg:candidate "false"^^xsd:boolean .
  <urn:pwg:fact/{fact_id_b}> pwg:candidate "false"^^xsd:boolean .
}}
WHERE {{
  OPTIONAL {{ <urn:pwg:fact/{fact_id_a}> pwg:candidate ?old_a }}
  OPTIONAL {{ <urn:pwg:fact/{fact_id_b}> pwg:candidate ?old_b }}
}}
"""
    try:
        with httpx.Client(timeout=30.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(
                f"{settings.oxigraph_url}/update",
                content=sparql,
                headers={"Content-Type": "application/sparql-update"},
                params={"using-graph-uri": graph_uri},
            )
            resp.raise_for_status()
    except Exception as exc:
        logger.error(
            "SPARQL promote update failed for %s / %s: %s",
            fact_id_a, fact_id_b, exc,
        )


# ── ID helpers ───────────────────────────────────────────────────────


def _fact_id(conversation_id: str, text: str) -> str:
    """Reconstruct the fact URI fragment that ingest uses.

    Imports ingest._deterministic_id directly so the two paths can't
    drift — any schema change in one side breaks the other at import,
    not silently at SPARQL-query time.
    """
    return _deterministic_id(conversation_id, "fact", text)


# ── CLI-facing helpers ───────────────────────────────────────────────


def list_candidates(
    settings: Settings,
    *,
    conversation_id: str | None = None,
    limit: int = 20,
) -> list[dict]:
    """Return the current candidate facts in Oxigraph.

    Each row: ``{"fact_uri", "conversation_id", "subject", "text"}``.
    Optional ``conversation_id`` filter narrows to one conversation.
    Facts with no pwg:candidate triple are NOT returned — the
    migration semantic treats them as already-promoted.
    """
    filter_clause = ""
    if conversation_id:
        filter_clause = (
            f"FILTER(?conv = <urn:pwg:conversation/{conversation_id}>)"
        )
    sparql = f"""
PREFIX pwg: <urn:pwg:>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>

SELECT ?fact ?conv ?subject ?text WHERE {{
  ?fact a <urn:pwg:Fact> ;
        <urn:pwg:candidate> "true"^^xsd:boolean ;
        <urn:pwg:fromConversation> ?conv ;
        <urn:pwg:about> ?subject ;
        <urn:pwg:text> ?text .
  {filter_clause}
}}
LIMIT {int(limit)}
"""
    rows = _sparql_select(sparql, settings)
    return [
        {
            "fact_uri": r.get("fact", ""),
            "conversation_id": r.get("conv", "").rsplit("/", 1)[-1],
            "subject": r.get("subject", ""),
            "text": r.get("text", ""),
        }
        for r in rows
    ]


def set_candidate(
    fact_uri: str,
    value: bool,
    settings: Settings,
) -> None:
    """Manually set a single fact's pwg:candidate flag.

    Used by ``pwg-convo candidates promote/unpromote`` for operator
    override. DELETE/INSERT WHERE with OPTIONAL matches the idempotent
    shape of _promote_pair — re-running is a no-op.
    """
    graph_uri = f"urn:pwg:user/{settings.user_id}"
    literal = "true" if value else "false"
    sparql = f"""
PREFIX pwg: <urn:pwg:>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>

DELETE {{ <{fact_uri}> pwg:candidate ?old }}
INSERT {{ <{fact_uri}> pwg:candidate "{literal}"^^xsd:boolean }}
WHERE {{ OPTIONAL {{ <{fact_uri}> pwg:candidate ?old }} }}
"""
    try:
        with httpx.Client(timeout=30.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(
                f"{settings.oxigraph_url}/update",
                content=sparql,
                headers={"Content-Type": "application/sparql-update"},
                params={"using-graph-uri": graph_uri},
            )
            resp.raise_for_status()
    except Exception as exc:
        logger.error("set_candidate failed for %s: %s", fact_uri, exc)
        raise


def promote_conversation(
    conversation_id: str,
    settings: Settings,
) -> int:
    """Flip every candidate fact in a conversation to promoted.

    Returns the number of facts updated. Intended for the ``pwg-convo
    candidates promote <conversation_id>`` operator-override path, not
    for auto-promotion (which goes through promote_corroborated).
    """
    candidates = list_candidates(
        settings, conversation_id=conversation_id, limit=10_000,
    )
    for row in candidates:
        set_candidate(row["fact_uri"], False, settings)
    return len(candidates)
