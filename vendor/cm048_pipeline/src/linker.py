"""Phase C.6 — Cross-conversation linking via Qdrant similarity.

After enrichment, this module queries the existing `conversations`
collection for semantically similar conversations and writes
`related_conversation_ids` into the new conversation's frontmatter.

Deterministic - no LLM involved. Uses the embedding model already
running on the embedding service (nomic-embed-text by default) to
embed the new conversation's summary + topics, then runs a cosine
similarity search against the existing collection.

Also emits `pwg:relatedTo` graph edges to Oxigraph for graph queries
and wiki cross-linking (CM044).
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from pathlib import Path

import httpx

from .ollama_client import OllamaClient
from .settings import Settings

logger = logging.getLogger(__name__)


# ── Configuration ──────────────────────────────────────────────────

DEFAULT_SIMILARITY_THRESHOLD = 0.70
DEFAULT_MAX_RELATED = 5


@dataclass
class LinkResult:
    """Result of a cross-conversation linking pass."""
    conversation_id: str
    related_ids: list[str]
    scores: dict[str, float]  # conversation_id -> similarity score
    oxigraph_triples_emitted: int


# ── Public entry point ─────────────────────────────────────────────


def find_related(
    conversation_id: str,
    summary_text: str,
    settings: Settings,
    *,
    threshold: float = DEFAULT_SIMILARITY_THRESHOLD,
    max_results: int = DEFAULT_MAX_RELATED,
    dry_run: bool = False,
) -> LinkResult:
    """Find conversations similar to the given summary text.

    Args:
        conversation_id: the new conversation's ID (excluded from results)
        summary_text: the text to embed and search against (typically
            the Summary + Key topics sections from enrichment)
        settings: loaded Settings
        threshold: minimum cosine similarity to include (0.0-1.0)
        max_results: maximum related conversations to return
        dry_run: if True, skip the actual search and return empty

    Returns a LinkResult with related IDs and scores.
    """
    if dry_run:
        logger.info("dry_run: would search Qdrant for related conversations")
        return LinkResult(
            conversation_id=conversation_id,
            related_ids=[],
            scores={},
            oxigraph_triples_emitted=0,
        )

    # 1. Embed the summary text
    client = OllamaClient(base_url=settings.ollama_url)
    try:
        vector = client.embed(summary_text)
    except Exception as exc:
        logger.warning("Embedding failed for linker: %s", exc)
        return LinkResult(
            conversation_id=conversation_id,
            related_ids=[],
            scores={},
            oxigraph_triples_emitted=0,
        )

    # 2. Search Qdrant for similar points
    hits = _search_qdrant(
        vector=vector,
        conversation_id=conversation_id,
        settings=settings,
        limit=max_results * 3,  # over-fetch to allow dedup and filtering
    )

    # 3. Filter by threshold + deduplicate by conversation_id
    #    (multiple points from the same conversation may match)
    seen: dict[str, float] = {}
    for hit in hits:
        score = hit.get("score", 0.0)
        cid = hit.get("payload", {}).get("conversation_id", "")
        if not cid or cid == conversation_id:
            continue
        if score < threshold:
            continue
        # Keep highest score per conversation
        if cid not in seen or score > seen[cid]:
            seen[cid] = score

    # Sort by score descending, take top N
    sorted_related = sorted(seen.items(), key=lambda x: x[1], reverse=True)
    related_ids = [cid for cid, _ in sorted_related[:max_results]]
    scores = {cid: score for cid, score in sorted_related[:max_results]}

    logger.info(
        "Linker found %d related conversations for %s (threshold=%.2f)",
        len(related_ids),
        conversation_id,
        threshold,
    )

    return LinkResult(
        conversation_id=conversation_id,
        related_ids=related_ids,
        scores=scores,
        oxigraph_triples_emitted=0,  # emitted separately by write_link_triples
    )


def write_link_triples(
    link_result: LinkResult,
    settings: Settings,
    *,
    dry_run: bool = False,
) -> int:
    """Emit pwg:relatedTo triples to Oxigraph for the linked conversations.

    Returns the number of triples written.
    """
    if not link_result.related_ids:
        return 0

    if dry_run:
        logger.info(
            "dry_run: would emit %d relatedTo triples",
            len(link_result.related_ids),
        )
        return len(link_result.related_ids)

    conv_uri = f"<urn:pwg:conversation/{link_result.conversation_id}>"
    graph_uri = f"urn:pwg:user/{settings.user_id}"

    triples = []
    for related_id in link_result.related_ids:
        related_uri = f"<urn:pwg:conversation/{related_id}>"
        score = link_result.scores.get(related_id, 0.0)
        # Bidirectional link: A relatedTo B and B relatedTo A
        triples.append(
            f'{conv_uri} <urn:pwg:relatedTo> {related_uri} .\n'
            f'{conv_uri} <urn:pwg:similarityScore> "{score:.4f}"^^<http://www.w3.org/2001/XMLSchema#float> .\n'
            f'{related_uri} <urn:pwg:relatedTo> {conv_uri} .'
        )

    ttl = "\n".join(triples)
    try:
        with httpx.Client(timeout=60.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(
                f"{settings.oxigraph_url}/store",
                content=ttl.encode(),
                headers={
                    "Content-Type": "text/turtle",
                },
                params={"graph": graph_uri},
            )
            resp.raise_for_status()
    except Exception as exc:
        logger.error("Oxigraph relatedTo write failed: %s", exc)
        raise

    count = len(link_result.related_ids) * 3  # 2 relatedTo + 1 score per pair
    logger.info("Wrote %d relatedTo triples to Oxigraph", count)
    return count


def update_frontmatter(
    enrichment_md_path: Path,
    related_ids: list[str],
) -> None:
    """Update the related_conversation_ids field in the enrichment
    markdown's YAML frontmatter.

    This is a simple text-level update — finds the
    `related_conversation_ids: []` line and replaces it.
    """
    if not enrichment_md_path.exists():
        return
    content = enrichment_md_path.read_text()

    # Replace empty list
    if "related_conversation_ids: []" in content:
        yaml_list = "\n".join(f"  - {cid}" for cid in related_ids)
        replacement = f"related_conversation_ids:\n{yaml_list}"
        content = content.replace("related_conversation_ids: []", replacement)
        enrichment_md_path.write_text(content)
        logger.info("Updated frontmatter with %d related IDs", len(related_ids))


# ── Qdrant search ─────────────────────────────────────────────────


def _search_qdrant(
    vector: list[float],
    conversation_id: str,
    settings: Settings,
    limit: int = 15,
) -> list[dict]:
    """Search the conversations collection for similar vectors.

    Filters out points from the same conversation_id and restricts
    to the current user_id.
    """
    url = (
        f"{settings.qdrant_url}/collections/"
        f"{settings.qdrant_conversations_collection}/points/search"
    )
    payload = {
        "vector": vector,
        "limit": limit,
        "with_payload": ["conversation_id", "text"],
        "filter": {
            "must": [
                {
                    "key": "user_id",
                    "match": {"value": settings.user_id},
                },
                {
                    "key": "point_type",
                    "match": {"value": "conversation_summary"},
                },
            ],
            "must_not": [
                {
                    "key": "conversation_id",
                    "match": {"value": conversation_id},
                },
            ],
        },
    }
    try:
        with httpx.Client(timeout=30.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        return data.get("result", [])
    except Exception as exc:
        logger.warning("Qdrant search failed: %s", exc)
        return []


# ── Utility: extract summary text from enrichment MD ──────────────


def extract_summary_for_linking(enrichment_md_path: Path) -> str:
    """Extract text from an enrichment markdown file for use as the
    linking query text.

    Grabs the first ~2000 chars of content after any YAML frontmatter.
    This is model-agnostic — doesn't depend on specific heading names,
    so it works regardless of whether the model followed the prompt's
    section structure or used its own headings.

    Returns a plain text string suitable for embedding.
    """
    if not enrichment_md_path.exists():
        return ""

    content = enrichment_md_path.read_text()
    if not content.strip():
        return ""

    lines = content.split("\n")

    # Skip YAML frontmatter if present
    start_idx = 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                start_idx = i + 1
                break

    # Take the first ~2000 chars of content (summary + early topics)
    # Strip markdown formatting for cleaner embedding
    body = "\n".join(lines[start_idx:])
    # Remove markdown bold/italic markers for cleaner text
    import re
    body = re.sub(r'\*{1,3}', '', body)
    # Remove heading markers
    body = re.sub(r'^#{1,4}\s*', '', body, flags=re.MULTILINE)

    return body[:2000].strip()
