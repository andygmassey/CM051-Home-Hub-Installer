"""Topic bridge: CM048 bundle topics -> the graph the assistant reads.

Background
----------
CM048 has extracted conversation topics since the four-artefact bundle
landed (``bundle_extractor.py`` / ``prompts/09_bundle_extract.md``):
``BundleExtraction.topics`` is a list of dicts with a ``"name"`` and a
list of ``"points"``, 1-7 per conversation. Those topics were rendered
into the episodic markdown and then dropped on the floor -- nothing
turned them into triples.

The assistant's ``pwg_topics`` tool calls ``GET /api/v1/topics`` on the
Hub API (CM041 ``assistant_api/ical-server.py::topics_list``). That
handler asks for ``?topic a pwg:ConversationTopic``. With no writer for
that class anywhere in the estate, the endpoint answered
``{"topics": [], "count": 0}`` on every install -- a 200 with an empty
array, which looks exactly like "this customer has no topics yet".

This module is the missing writer. The extractor and the reader are both
correct and unchanged; only the bridge between them is new.

Read/write contract (VERIFIED against the reader, not assumed)
--------------------------------------------------------------
Two properties of the reader decide whether this bridge is alive or
dead, and CM048's house style gets BOTH of them wrong. They are called
out here because a mistake in either produces the *identical* symptom to
the bug being fixed -- a 200 with an empty array.

**1. Namespace.** The reader resolves ``pwg:`` to
``https://schema.ostler.ai/ontology#``. CM048's own entities
(Conversation / Fact / RelationshipSignal / OutstandingTodo) live under
``urn:ostler:`` via ``ingest._turtle_prefixes`` / ``ingest._urn``. Both
namespaces are legitimate and both are consumed -- ical-server reads
``urn:ostler:about``/``warmth``/``trust`` for RelationshipSignal -- so
this is not a global bug to "fix". Topics specifically must match their
reader, so this module never touches ``ingest._urn``; it builds explicit
``https://schema.ostler.ai/ontology#`` IRIs, the same way
``ingest._person_graph_uri`` does for the cross-linked Person nodes.

**2. Graph.** ``ingest._write_oxigraph`` POSTs its Turtle to
``{oxigraph_url}/store?graph=urn:ostler:user/{user_id}`` -- a NAMED
graph. The reader's ``topics_list`` query carries no ``GRAPH`` clause,
so it reads the DEFAULT graph. Triples written by the CM048 sink path
are therefore invisible to it. This module consequently does NOT reuse
``ingest._write_oxigraph``: it issues a SPARQL UPDATE with no ``GRAPH``
clause, which lands in the default graph where the reader looks. That is
the same decision -- for the same reason -- that
``last_contact_updater.py`` already documents for ``lastContact*``.

Emitted shape (mirrors the reader's docstring exactly)::

    <NS#topic_<slug>>  a  <NS#ConversationTopic> ;
        <NS#topicSlug>  "<slug>" ;
        rdfs:label      "<label>" .

    <NS#topicmention_<uuid5>>  a  <NS#TopicMention> ;
        <NS#mentionsTopic>   <NS#topic_<slug>> ;
        <NS#topicWeight>     "<n>"^^xsd:integer ;
        <NS#inConversation>  <urn:ostler:conversation/<id>> .

``inConversation`` (plus the optional ``viaChannel`` / ``validFrom``) is
what the sibling ``GET /api/v1/topics/<slug>/mentions`` endpoint in the
same reader queries; without it that endpoint reports a topic with zero
mentions.

Idempotency
-----------
- The topic node is keyed by slug, so re-processing a conversation
  re-asserts the same node rather than minting a second one, and two
  conversations about the same subject share ONE topic node.
- The mention node is keyed by ``(conversation_id, slug)`` through
  ``ingest._deterministic_id``, so one topic accumulates a mention per
  conversation without collision, and a re-run overwrites its own
  mention instead of adding a duplicate.
- Both nodes are written DELETE-then-INSERT. This is load-bearing, not
  tidiness: the reader does ``SUM(?w)``, so a re-run that left a second
  ``topicWeight`` on the same mention would silently double that topic's
  rank. The topic's ``rdfs:label`` is likewise replaced, so a re-extract
  that capitalises the name differently cannot produce two rows for one
  slug (the reader groups by ``?topic ?slug ?label``).

Privacy
-------
Topics are a gist-arm surface. L3 conversations skip the gist sinks
entirely (``processor.py`` step 07 short-circuit) and must not appear in
a discovery endpoint either, so this module refuses L3. Non-relational
bulk/marketing mail is refused for the same reason the fact fan-out and
the contact-recency bump refuse it (``bulk_classifier.py``): a
newsletter's "topics" are the sender's marketing categories, not the
customer's interests.
"""
from __future__ import annotations

import logging
import re
import unicodedata
import urllib.parse

import httpx

from .ingest import _deterministic_id
from .settings import Settings
from .turtle_escape import escape_turtle_literal

logger = logging.getLogger(__name__)


# ── Namespaces ──────────────────────────────────────────────────────
#
# NOT ``urn:ostler:``. See the module docstring, trap 1. This is the
# namespace CM041's ical-server resolves ``pwg:`` to; a topic written
# under any other namespace is invisible to ``pwg_topics``.
PWG_NS = "https://schema.ostler.ai/ontology#"
RDFS_NS = "http://www.w3.org/2000/01/rdf-schema#"
XSD_NS = "http://www.w3.org/2001/XMLSchema#"

# The reader validates a slug with this exact grammar before it will
# resolve ``GET /api/v1/topics/<slug>/mentions`` (ical-server
# ``_SLUG_PATTERN``). A slug we mint outside it is listable but not
# clickable, so ``slugify_topic`` is built to satisfy it by
# construction and this pattern is the assertion of that.
SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")

_MAX_SLUG_LEN = 80
# Topic names are LLM output. Bound the label so a model that ran away
# on one topic cannot write an unbounded literal into the graph.
_MAX_LABEL_LEN = 200
# The prompt asks for 1-7 topics with 3-10 points each. These ceilings
# only ever bite on malformed model output.
_MAX_TOPICS_PER_CONVERSATION = 50
_MAX_WEIGHT = 99

_ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# Twin of CM041 ``identity_resolver.compartment.PRIMARY_USER_FALLBACK``.
_PRIMARY_USER_FALLBACK = "primary"


# ── Identity ────────────────────────────────────────────────────────


def normalise_user_id(raw: object) -> str:
    """Fold an operator-supplied ``user_id`` into an IRI-safe slug.

    MUST match CM041 ``identity_resolver.compartment.normalise_user_id``,
    which is what the Hub API uses to build its own ``USER_URI``. It is
    duplicated rather than imported for the same reason
    ``ingest._person_id_from_identifier`` is: CM048 ships independently
    of the Hub API package and must not take a hard dependency on it.

    Real values arrive from CM051's free-text "what should your
    assistant call you?" prompt, so they can be ``Jane``, ``jane.doe``
    or ``jane@home``. Every one of them folds to something that cannot
    break out of an IRI.
    """
    s = str(raw or "").strip().lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", s)
    s = re.sub(r"^[^a-z0-9]+", "", s)
    s = s[:64]
    s = s.rstrip("-_")
    return s or _PRIMARY_USER_FALLBACK


def user_uri(settings: Settings) -> str:
    """The per-install owner IRI, derived from settings.

    NEVER a hardcoded operator name. The dead CM040 predecessor pinned
    its topic triples to one literal, hardcoded operator id, which is
    one of the two reasons it is being replaced; every install must own
    its own topics.
    """
    return f"{PWG_NS}user_{normalise_user_id(settings.user_id)}"


# ── Slug / URI helpers ──────────────────────────────────────────────


def slugify_topic(name: object) -> str:
    """Reduce an LLM topic name to the reader's slug grammar.

    Returns ``""`` when nothing usable survives (an empty or
    punctuation-only name). Callers MUST skip such a topic rather than
    mint a node with a blank ``topicSlug`` -- the reader would list it
    as an unnamed, unresolvable row.
    """
    s = unicodedata.normalize("NFKD", str(name or ""))
    s = s.encode("ascii", "ignore").decode("ascii").lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")[:_MAX_SLUG_LEN].rstrip("-")
    if not s or not s[0].isalnum():
        # Leading run was stripped above; anything still non-alnum at
        # the front cannot satisfy the reader's grammar.
        s = s.lstrip("-")
    return s if SLUG_PATTERN.match(s) else ""


def topic_uri(slug: str) -> str:
    """Topic node IRI. Keyed by slug -> shared across conversations."""
    return f"{PWG_NS}topic_{slug}"


def mention_uri(conversation_id: str, slug: str) -> str:
    """Mention node IRI, keyed by (conversation, slug).

    ``ingest._deterministic_id`` is a uuid5, so the same conversation +
    topic always resolves to the same node and a re-run overwrites
    rather than duplicates.
    """
    return f"{PWG_NS}topicmention_{_deterministic_id(conversation_id, 'topic_mention', slug)}"


def conversation_uri(conversation_id: str) -> str:
    """The CM048 conversation node this mention points back at.

    Percent-encoded so a malformed conversation id can never terminate
    the IRI early inside the SPARQL UPDATE. For the real
    ``YYYY-MM-DD_slug`` id shape the encoding is a no-op, so the IRI is
    byte-identical to ``ingest._urn("conversation/<id>")``.
    """
    return "urn:ostler:conversation/" + urllib.parse.quote(
        str(conversation_id or ""), safe=""
    )


# ── Topic aggregation ───────────────────────────────────────────────


def collect_topics(topics: object) -> list[tuple[str, str, int]]:
    """Normalise ``BundleExtraction.topics`` to ``(slug, label, weight)``.

    ``weight`` is the number of extracted points for that topic, which is
    the extractor's own measure of how much of the conversation the topic
    accounted for; it is what the reader sums to rank topics. A topic
    with no points still weighs 1 -- it was discussed, just briefly.

    Topics whose names slug identically inside ONE conversation are
    merged (weights summed, first label kept); they would otherwise
    collide on the same mention IRI and silently lose one of the two.
    """
    if not isinstance(topics, list):
        return []

    merged: dict[str, list] = {}
    order: list[str] = []
    for entry in topics[:_MAX_TOPICS_PER_CONVERSATION]:
        if not isinstance(entry, dict):
            continue
        raw_name = entry.get("name")
        slug = slugify_topic(raw_name)
        if not slug:
            continue
        label = str(raw_name or "").strip()[:_MAX_LABEL_LEN]
        points = entry.get("points")
        weight = len(points) if isinstance(points, list) else 0
        weight = max(1, min(int(weight), _MAX_WEIGHT))
        if slug in merged:
            merged[slug][1] = min(merged[slug][1] + weight, _MAX_WEIGHT)
        else:
            merged[slug] = [label, weight]
            order.append(slug)
    return [(slug, merged[slug][0], merged[slug][1]) for slug in order]


# ── SPARQL UPDATE builder ───────────────────────────────────────────


def build_topic_update(
    conversation_id: str,
    topics: object,
    settings: Settings,
    metadata: dict | None = None,
) -> str | None:
    """Build the SPARQL UPDATE that lands one conversation's topics.

    Returns ``None`` when there is nothing to write.

    NOTE the deliberate absence of a ``GRAPH`` clause: an UPDATE without
    one operates on the DEFAULT graph, which is where the reader looks.
    See the module docstring, trap 2. Adding a ``GRAPH`` wrapper here
    would move these triples somewhere ``pwg_topics`` cannot see them and
    the endpoint would go back to returning an empty array.
    """
    collected = collect_topics(topics)
    if not collected:
        return None

    metadata = metadata or {}
    owner = user_uri(settings)
    conv = conversation_uri(conversation_id)
    safe_user_id = escape_turtle_literal(settings.user_id)

    channel = str(metadata.get("channel") or "").strip().lower()
    raw_date = str(metadata.get("date") or "").strip()[:10]
    date = raw_date if _ISO_DATE.match(raw_date) else ""

    deletes: list[str] = []
    inserts: list[str] = []

    for idx, (slug, label, weight) in enumerate(collected):
        t_uri = topic_uri(slug)
        m_uri = mention_uri(conversation_id, slug)
        safe_slug = escape_turtle_literal(slug)
        safe_label = escape_turtle_literal(label or slug)

        # Replace, never accumulate: one label per topic, and the whole
        # mention rewritten so a changed weight cannot be double-counted
        # by the reader's SUM().
        deletes.append(f"DELETE WHERE {{ <{t_uri}> rdfs:label ?l{idx} }}")
        deletes.append(f"DELETE WHERE {{ <{m_uri}> ?p{idx} ?o{idx} }}")

        inserts.append(
            f"  <{t_uri}> a pwg:ConversationTopic ;\n"
            f'    pwg:topicSlug "{safe_slug}" ;\n'
            f'    rdfs:label "{safe_label}" ;\n'
            f"    pwg:belongsToUser <{owner}> ;\n"
            f'    pwg:userId "{safe_user_id}" .'
        )

        mention_lines = [
            f"  <{m_uri}> a pwg:TopicMention ;",
            f"    pwg:mentionsTopic <{t_uri}> ;",
            f'    pwg:topicWeight "{weight}"^^xsd:integer ;',
            f"    pwg:inConversation <{conv}> ;",
            f"    pwg:belongsToUser <{owner}> ;",
            f'    pwg:userId "{safe_user_id}"',
        ]
        if channel:
            mention_lines.append(f'    ; pwg:viaChannel "{escape_turtle_literal(channel)}"')
        if date:
            mention_lines.append(f'    ; pwg:validFrom "{date}"^^xsd:date')
        mention_lines.append("    .")
        inserts.append("\n".join(mention_lines))

    prologue = (
        f"PREFIX pwg: <{PWG_NS}>\n"
        f"PREFIX rdfs: <{RDFS_NS}>\n"
        f"PREFIX xsd: <{XSD_NS}>\n"
    )
    body = " ;\n".join(deletes)
    body += " ;\nINSERT DATA {\n" + "\n".join(inserts) + "\n}"
    return prologue + body


# ── Writer ──────────────────────────────────────────────────────────


def write_topics(
    *,
    conversation_id: str,
    topics: object,
    settings: Settings,
    privacy_level: str | None = None,
    metadata: dict | None = None,
    dry_run: bool = False,
) -> int:
    """Land one conversation's topics in the graph ``pwg_topics`` reads.

    Returns the number of topics written (0 for any refusal). Never
    raises: the conversation and its episodic bundle are already on
    disk by the time this runs, and a discovery index must not be able
    to fail a completed ingest. A failure is logged at WARNING with the
    topic count that was lost, so a dead bridge is visible in the log
    rather than silent.
    """
    metadata = metadata or {}

    # Defence in depth -- the call site gates these too.
    if privacy_level == "L3":
        logger.debug(
            "L3 conversation %s: skipping topic write", conversation_id
        )
        return 0
    if metadata.get("non_relational"):
        logger.info(
            "Non-relational conversation %s: skipping topic write",
            conversation_id,
        )
        return 0
    if not conversation_id:
        logger.warning("No conversation_id; skipping topic write")
        return 0

    sparql = build_topic_update(
        conversation_id, topics, settings, metadata=metadata
    )
    if sparql is None:
        logger.debug("No usable topics for %s", conversation_id)
        return 0

    count = len(collect_topics(topics))

    if dry_run:
        logger.info(
            "dry_run: would write %d topic(s) for %s", count, conversation_id
        )
        return count

    try:
        transport = httpx.HTTPTransport(proxy=None)
        with httpx.Client(timeout=30.0, transport=transport) as client:
            resp = client.post(
                f"{settings.oxigraph_url}/update",
                content=sparql.encode("utf-8"),
                headers={"Content-Type": "application/sparql-update"},
            )
            resp.raise_for_status()
    except Exception as exc:
        logger.warning(
            "Topic write failed for %s (%d topic(s) lost): %s: %s",
            conversation_id,
            count,
            type(exc).__name__,
            exc,
        )
        return 0

    logger.info(
        "Topics -> graph: %d topic(s) for %s (%s)",
        count,
        conversation_id,
        ", ".join(slug for slug, _l, _w in collect_topics(topics)),
    )
    return count


__all__ = [
    "PWG_NS",
    "SLUG_PATTERN",
    "build_topic_update",
    "collect_topics",
    "conversation_uri",
    "mention_uri",
    "normalise_user_id",
    "slugify_topic",
    "topic_uri",
    "user_uri",
    "write_topics",
]
