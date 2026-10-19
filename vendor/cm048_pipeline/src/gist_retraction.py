"""Retract one conversation's gist-arm writes before an update re-adds them.

WHY THIS EXISTS
---------------
A connector re-POSTs the SAME ``conversation_id`` when a thread grows (a
Slack reply, a Jira comment, an email reply, a chat that kept going).
``processor.process`` now re-runs the pipeline for a changed transcript,
and step 07 then writes the new facts. Without this module the OLD facts
stay beside them:

- Qdrant point ids are ``uuid5(conversation, kind, sha256(text))``, so a
  fact whose wording changed gets a NEW id and the old point is never
  overwritten. The conversation-summary point is keyed the same way.
- Oxigraph ``POST /store`` is additive. Fact, todo and signal nodes are
  keyed by content too, so the old nodes survive, and the conversation
  node and its linker edges accumulate a second ``similarityScore``.
- Topic mentions (default graph, written in step 09) are replaced per
  (conversation, slug) only, so a topic that left the conversation keeps
  its old mention and is still counted by the reader.

So an update first deletes everything this pipeline attributed to the
conversation, then the normal writers add the current version. Facts are
REPLACED, never duplicated.

SCOPE OF THE DELETE (deliberately narrow)
-----------------------------------------
- Qdrant: points whose payload has this ``conversation_id`` AND
  ``source=human_conversation`` AND ``point_type`` in
  {fact, conversation_summary}. Those are exactly the two point kinds
  ``ingest._write_qdrant`` creates; nothing another writer puts in the
  collection can match all three.
- Oxigraph named graph ``urn:ostler:user/<id>`` (step 07's graph):
  every node with ``fromConversation`` (facts, outstanding todos) or
  ``observedIn`` (relationship signals) pointing at this conversation,
  plus the conversation node's own outgoing triples (setting/shape/
  stakes, participants, linker edges). The Person nodes those triples
  point AT are not touched.
- Oxigraph default graph: ``pwg:TopicMention`` nodes whose
  ``pwg:inConversation`` is this conversation. The shared topic nodes
  are not touched.

Every request raises on failure. A retraction that silently failed would
leave the duplicates this module exists to prevent, so the caller's step
fails and is retried, which is the pipeline's normal failure path.
"""
from __future__ import annotations

import logging

import httpx

from .settings import Settings
from .turtle_escape import escape_turtle_iri_path
from .topic_writer import PWG_NS, conversation_uri as _topic_conversation_uri

logger = logging.getLogger(__name__)

# The point kinds ingest._write_qdrant writes. Kept as a literal tuple so
# a new point kind is a deliberate edit here, not an accidental delete.
QDRANT_POINT_TYPES = ("fact", "conversation_summary")


def qdrant_delete_filter(conversation_id: str) -> dict:
    return {
        "filter": {
            "must": [
                {"key": "conversation_id", "match": {"value": conversation_id}},
                {"key": "source", "match": {"value": "human_conversation"}},
                {"key": "point_type", "match": {"any": list(QDRANT_POINT_TYPES)}},
            ]
        }
    }


def build_oxigraph_retraction(conversation_id: str, settings: Settings) -> str:
    """SPARQL UPDATE that removes this conversation's CM048 triples."""
    conv = f"<urn:ostler:conversation/{escape_turtle_iri_path(conversation_id)}>"
    graph = f"<urn:ostler:user/{escape_turtle_iri_path(settings.user_id)}>"
    topic_conv = f"<{_topic_conversation_uri(conversation_id)}>"
    return (
        # Facts + outstanding todos (fromConversation) and relationship
        # signals (observedIn): the whole node goes.
        f"DELETE {{ GRAPH {graph} {{ ?s ?p ?o }} }}\n"
        f"WHERE {{ GRAPH {graph} {{\n"
        f"  ?s <urn:ostler:fromConversation>|<urn:ostler:observedIn> {conv} .\n"
        f"  ?s ?p ?o }} }} ;\n"
        # The conversation node's own outgoing triples.
        f"DELETE {{ GRAPH {graph} {{ {conv} ?p ?o }} }}\n"
        f"WHERE {{ GRAPH {graph} {{ {conv} ?p ?o }} }} ;\n"
        # Topic mentions live in the DEFAULT graph (topic_writer trap 2).
        f"DELETE {{ ?m ?p ?o }}\n"
        f"WHERE {{ ?m <{PWG_NS}inConversation> {topic_conv} .\n"
        f"  ?m a <{PWG_NS}TopicMention> .\n"
        f"  ?m ?p ?o }}"
    )


def retract_conversation(conversation_id: str, settings: Settings) -> None:
    """Delete this conversation's gist writes from Qdrant and Oxigraph."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as hc:
        resp = hc.post(
            f"{settings.qdrant_url}/collections/"
            f"{settings.qdrant_conversations_collection}/points/delete",
            json=qdrant_delete_filter(conversation_id),
            params={"wait": "true"},
        )
        # A collection that does not exist yet holds nothing to retract.
        if resp.status_code != 404:
            resp.raise_for_status()

        resp = hc.post(
            f"{settings.oxigraph_url}/update",
            content=build_oxigraph_retraction(conversation_id, settings).encode(),
            headers={"Content-Type": "application/sparql-update"},
        )
        if resp.status_code >= 400:
            logger.error(
                "Oxigraph rejected the retraction: HTTP %s -- %s",
                resp.status_code, (resp.text or "")[:300].replace("\n", " "),
            )
        resp.raise_for_status()
    logger.info("Retracted earlier gist writes for updated conversation %s", conversation_id)


__all__ = [
    "QDRANT_POINT_TYPES",
    "build_oxigraph_retraction",
    "qdrant_delete_filter",
    "retract_conversation",
]
