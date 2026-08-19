"""Per-person ``lastContact<Channel>`` updater for CM048 bundles.

Background (#311)
-----------------
CM047 (standalone WhatsApp mining) is retired; CM048's source-agnostic
ConversationBundle pipeline now handles WhatsApp. CM047 owned one signal
CM048 did not: it wrote ``Person.lastContactWhatsApp`` on the People node
in Oxigraph each time a WhatsApp message arrived. That timestamp powers
the wiki person-page contact-recency row, the CM041 stale-contacts
surface, and the CM031 "last seen on WhatsApp" badge. Without a new
writer the field goes stale once CM047 retires.

This module is that writer. After a bundle is built and written, it walks
the bundle's participants and upserts ``Person.lastContact<Channel>`` to
the bundle's most-recent message timestamp (``ended_at``).

Read/write contract (VERIFIED, not assumed)
--------------------------------------------
This deliberately reuses the EXACT predicate, namespace, person-URI
scheme, and idempotent SPARQL pattern of the existing HR015 writer
(``ostler_fda/pwg_ingest.py::_update_last_contact`` +
``_person_id_from_identifier``), which is the same contract the wiki
reader consumes:

- Person nodes are typed ``pwg:Person`` in the namespace
  ``https://pwg.dev/ontology#`` (NOT CM048's ``urn:pwg:`` fact namespace).
- The predicate is ``pwg:lastContactWhatsApp`` for the WhatsApp channel,
  one of the four per-source predicates the wiki reader queries
  (``CM044/compiler/pwg_data.py`` ``LAST_CONTACT_PREDICATES`` /
  ``load_last_contacts_per_source``: lastContactCalendar /
  lastContactWhatsApp / lastContactEmail / lastContactIMessage).
- The value is an ``xsd:date`` literal (``YYYY-MM-DD``); the reader trims
  to 10 chars and does a lexicographic ``max()``.
- The person URI is ``https://pwg.dev/ontology#person_<uuid5>`` where the
  uuid5 is over ``https://pwg.dev/person/<cleaned-identifier>`` and the
  identifier is the raw WhatsApp participant id (phone or JID) exactly as
  HR015's ``ingest_whatsapp`` already creates the Person node from. Using
  the identical derivation is what lets this updater hit the SAME Person
  node HR015 created, rather than minting a parallel one.

This module intentionally does NOT use CM048's own ``ingest._write_oxigraph``
helper: that writer emits into the ``urn:pwg:`` fact namespace and never
creates ``pwg:Person`` nodes, so it is the wrong surface for the
per-source last-contact predicates the wiki reads. The right reuse is the
predicate + write mechanism of the historical per-source writer, mirrored
here.

Idempotency
-----------
The DELETE-INSERT-WHERE-FILTER pattern only writes when the new date is
strictly newer than (or absent of) the stored date, so re-running a
conversation, or processing an older conversation after a newer one, never
regresses ``lastContactWhatsApp`` to an older value. Matches the HR015
writer exactly.

Privacy
-------
L3 conversations must not write timestamps (an L3 conversation should not
surface in any recency surface). The caller short-circuits L3 before
reaching this module (mirroring the step-07 gist-sink L3 short-circuit);
this module also refuses L3 defensively.
"""
from __future__ import annotations

import logging
import uuid
from datetime import datetime
from typing import TYPE_CHECKING

import httpx

if TYPE_CHECKING:  # pragma: no cover - typing only
    from .conversation_writer import ConversationBundle

logger = logging.getLogger(__name__)


# ── Channel -> per-source predicate (CM041 schema/people.ttl) ──────────
#
# Single source of truth on the CM048 side, mirroring CM044's reader
# ``LAST_CONTACT_PREDICATES``. Channels absent here are not contact-recency
# producers and are skipped (a debug no-op) rather than minting a predicate
# the wiki reader cannot interpret. WhatsApp is the #311 target; the other
# channels already have their own writers (CM041 calendar, CM046 email,
# HR015 ostler_fda iMessage) so they are intentionally NOT duplicated here.
_CHANNEL_PREDICATE = {
    "whatsapp": "pwg:lastContactWhatsApp",
}

_PWG_NS = "https://pwg.dev/ontology#"


def _person_id_from_identifier(identifier: str) -> str:
    """Stable person id from a phone number / email / WhatsApp JID.

    Identical to HR015 ``pwg_ingest._person_id_from_identifier`` so the URI
    matches the Person node that pipeline already created for the same
    participant.
    """
    clean = identifier.strip().lower()
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://pwg.dev/person/{clean}"))


def _person_uri(person_id: str) -> str:
    return f"{_PWG_NS}person_{person_id}"


def _is_user_participant(identifier: str) -> bool:
    """The operator themselves is carried as the literal id ``"user"`` in
    CM048 bundle participants. They are not a "contact" to track recency
    against, so skip them (matches HR015 ingestors never minting a Person
    node for the operator)."""
    return identifier.strip().lower() == "user"


def _update_last_contact_triple(
    *,
    person_uri: str,
    predicate: str,
    date_str: str,
    oxigraph_url: str,
) -> bool:
    """Idempotent, no-downgrade upsert of a single ``lastContact*`` triple.

    Returns ``True`` if the SPARQL UPDATE was sent (the FILTER decides
    whether it actually changed anything), ``False`` on a write error
    (logged, never raised: a recency-index hiccup must not fail the
    already-written conversation).
    """
    sparql = (
        f"PREFIX pwg: <{_PWG_NS}>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        f"DELETE {{ <{person_uri}> {predicate} ?old }}\n"
        f'INSERT {{ <{person_uri}> {predicate} "{date_str}"^^xsd:date }}\n'
        "WHERE {\n"
        f"  OPTIONAL {{ <{person_uri}> {predicate} ?old }}\n"
        f'  FILTER (!BOUND(?old) || ?old < "{date_str}"^^xsd:date)\n'
        "}"
    )
    try:
        transport = httpx.HTTPTransport(proxy=None)
        with httpx.Client(timeout=30.0, transport=transport) as client:
            resp = client.post(
                f"{oxigraph_url}/update",
                content=sparql,
                headers={"Content-Type": "application/sparql-update"},
            )
            resp.raise_for_status()
        return True
    except Exception as exc:  # pragma: no cover - network error path
        logger.warning(
            "lastContact upsert failed for %s (%s): %s",
            person_uri, predicate, type(exc).__name__,
        )
        return False


def _to_date_str(timestamp: str) -> str | None:
    """Parse an ISO-8601 timestamp to a ``YYYY-MM-DD`` string, or None.

    Tolerates a trailing ``Z`` (mapped to ``+00:00``) the way the HR015
    writer does. A blank / malformed timestamp returns None (no-op).
    """
    if not timestamp or not timestamp.strip():
        return None
    try:
        dt = datetime.fromisoformat(timestamp.strip().replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d")
    except (ValueError, TypeError):
        return None


def update_last_contact_for_bundle(
    bundle: "ConversationBundle",
    *,
    oxigraph_url: str,
) -> list[str]:
    """Upsert ``Person.lastContact<Channel>`` for each participant.

    For the bundle's channel, resolve its per-source predicate, take the
    bundle's most-recent message timestamp (``ended_at``), and upsert it on
    every non-user participant's Person node (no-downgrade).

    Returns the list of person URIs whose timestamp upsert was sent. A
    channel without a recency predicate, an L3 bundle, a missing
    timestamp, or zero non-user participants returns ``[]``. Never raises:
    the conversation is already written; this is a secondary index.
    """
    # Defensive L3 refusal (the caller already short-circuits L3, this is
    # defence in depth: an L3 conversation must not surface in any recency
    # surface).
    if getattr(bundle, "privacy_level", None) == "L3":
        logger.debug(
            "L3 bundle %s: skipping lastContact upsert",
            getattr(bundle, "conversation_id", "?"),
        )
        return []

    predicate = _CHANNEL_PREDICATE.get(bundle.channel)
    if predicate is None:
        logger.debug(
            "No lastContact predicate for channel %r; skipping", bundle.channel
        )
        return []

    date_str = _to_date_str(bundle.ended_at)
    if date_str is None:
        logger.debug(
            "Bundle %s has no usable timestamp; skipping lastContact upsert",
            bundle.conversation_id,
        )
        return []

    updated: list[str] = []
    for participant in bundle.participants:
        if not participant or _is_user_participant(participant):
            continue
        person_uri = _person_uri(_person_id_from_identifier(participant))
        if _update_last_contact_triple(
            person_uri=person_uri,
            predicate=predicate,
            date_str=date_str,
            oxigraph_url=oxigraph_url,
        ):
            updated.append(person_uri)

    if updated:
        logger.info(
            "lastContact%s upsert -> %d participant(s) at %s for %s",
            bundle.channel.capitalize(),
            len(updated),
            date_str,
            bundle.conversation_id,
        )
    return updated
