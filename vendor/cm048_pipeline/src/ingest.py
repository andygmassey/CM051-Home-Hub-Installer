"""Sink writers for CM048.

Takes the per-conversation state directory's step outputs and writes
them to durable stores:
- Conversation MD → ~/.pwg/conversations/{id}.md
- Qdrant points → `conversations` collection
- Oxigraph triples → relationship signals + facts
- SQLite → coach observations (in ~/.pwg/coach/observations.db)
- Speaker-label feedback → a queue file at
  ~/.pwg/speaker_feedback/{id}.json

All writes are idempotent — deterministic IDs derived from
(conversation_id, content hash) ensure re-runs overwrite cleanly
without duplicates.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import sqlite3
import sys

# SECURITY: encrypted database wrapper from ostler_security.
#
# Hard-fail at import time if the package is missing. A missing
# package is a deploy bug, not a runtime fallback path; silently
# degrading to plaintext when the security module is absent is
# the bug we are removing. Missing key (passed in as parameter
# rather than env var here) is still a fall-through with a loud
# warning, since CM048 is also invoked in test contexts where no
# key is set.
try:
    from ostler_security.database import get_db_connection as _secure_connect
    from ostler_security.posture import record_posture
except ImportError as exc:
    raise RuntimeError(
        "ostler_security is required but not installed in this Python "
        "environment. Refusing to start CM048 ingest with potentially "
        "unencrypted databases. Install with: "
        "pip install /path/to/HR015/ostler_security/"
    ) from exc

# Posture is recorded based on whether a key exists in env at import
# time. CM048's run-loop reads the key from settings rather than env,
# so this marker is a "best-known" startup snapshot. The per-write
# warning still fires if a particular invocation gets no key.
_KEY_SOURCE = "OSTLER_DB_KEY" if os.environ.get("OSTLER_DB_KEY") else None
if _KEY_SOURCE:
    record_posture(
        "cm048-ingest",
        "enabled",
        key_source=_KEY_SOURCE,
        backend="sqlcipher",
    )
else:
    record_posture(
        "cm048-ingest",
        "disabled",
        reason="no_key",
        backend="plaintext",
    )

_PLAINTEXT_WARNED = False


def _warn_plaintext_once(db_path: str, encryption_key: str | None) -> None:
    """One-shot stderr warning when the CM048 coach DB falls through
    to plaintext SQLite. Reachable only when no key is provided to
    the writer; a missing module hard-fails at import."""
    global _PLAINTEXT_WARNED
    if _PLAINTEXT_WARNED:
        return
    _PLAINTEXT_WARNED = True
    print(
        f"WARNING: opening {db_path} as plaintext SQLite "
        "(encryption key not provided). Set OSTLER_DB_KEY or pass "
        "an encryption_key in settings to enable at-rest encryption.",
        file=sys.stderr,
        flush=True,
    )
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx

from .turtle_escape import escape_turtle_literal
from . import outstanding_todos as _outstanding_todos
from .schemas import (
    Classification,
    ExtractedFact,
    PipelineState,
    read_json,
)
from .settings import Settings


logger = logging.getLogger(__name__)


# ── Participant-identity bridge (CM044 conversations-ingest fix) ─────
#
# The gist-sink writers below historically had no access to the
# conversation metadata, so a conversation's Qdrant points carried no
# `channel` tag and its Oxigraph facts/signals could not be linked back
# to the JID/handle-keyed `pwg:Person` nodes that ostler_fda.pwg_ingest
# creates for the SAME contacts. Result: a graph that "mentioned"
# whatsapp/imessage facts but could not answer "who did I talk to"
# structurally, because the conversation participants were never tied to
# the people graph.
#
# These helpers reconstruct the exact Person URI pwg_ingest keys a
# contact by (uuid5 over the normalised phone/email identifier), so a
# conversation can emit a `pwg:participatedIn` edge from the real Person
# node to the conversation. The key derivation here MUST stay
# byte-identical to ostler_fda.pwg_ingest._person_id_from_identifier /
# _person_uri / _whatsapp_phone_e164 -- it is duplicated (not imported)
# because CM048 ships independently of ostler_fda and must not take a
# hard dependency on it. See the ORM upstream-twin note in the PR body.


def _person_id_from_identifier(identifier: str) -> str:
    """Stable person id from a phone number or email.

    MUST match ostler_fda.pwg_ingest._person_id_from_identifier.
    """
    clean = identifier.strip().lower()
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://pwg.dev/person/{clean}"))


def _person_graph_uri(person_id: str) -> str:
    """Person node URI. MUST match ostler_fda.pwg_ingest._person_uri."""
    return f"https://pwg.dev/ontology#person_{person_id}"


def _participant_uri_key(channel: str, raw: str) -> str:
    """The EXACT string pwg_ingest feeds to ``_person_id_from_identifier``
    when it keys this participant's Person node URI.

    This is the only thing that decides whether the conversation's
    ``pwg:participatedIn`` / ``pwg:hasParticipant`` edge resolves to the
    real Person node or dangles to a phantom URI, so it MUST match
    ostler_fda.pwg_ingest byte-for-byte (modulo the shared
    ``.strip().lower()`` inside ``_person_id_from_identifier``).

    pwg_ingest keys a WhatsApp participant by the **raw JID**
    (``<e164>@s.whatsapp.net``) -- ``ingest_whatsapp`` passes the JID
    verbatim into ``_person_id_from_identifier`` (it only NORMALISES the
    number for the displayed phone ``identifierValue``, NOT for the URI
    key). iMessage/SMS participants arrive as a bare handle which
    pwg_ingest keys verbatim. So: raw JID for WhatsApp, verbatim handle
    otherwise.
    """
    if not raw:
        return ""
    return raw.strip()


def _normalise_chat_identifier(channel: str, raw: str) -> str:
    """Human-facing chat identifier literal (NOT the URI key).

    WhatsApp participants arrive as a JID (``<e164>@s.whatsapp.net``);
    this presents the ``+<e164>`` phone so the surfaced
    ``pwg:chatIdentifier`` reads as a phone (and mirrors pwg_ingest's
    own ``identifierValue`` via ``_whatsapp_phone_e164``). iMessage/SMS
    handles pass through verbatim.

    NOTE: this is deliberately NOT used to derive the Person URI key --
    see ``_participant_uri_key``. Keying the URI off the e164 form here
    was the original dangling-edge bug (the URI no longer matched
    pwg_ingest's raw-JID-keyed node).
    """
    if not raw:
        return ""
    raw = raw.strip()
    if channel == "whatsapp":
        local = raw.split("@", 1)[0] if "@" in raw else raw
        return ("+" + local) if local.isdigit() else raw
    return raw


def _participant_identifier(channel: str, entry: dict) -> str:
    """Pull the raw chat identifier from a participant dict.

    Returns the RAW chat identifier (JID for WhatsApp, handle for
    iMessage) -- the URI-key derivation (``_participant_uri_key``) and
    the display normalisation (``_normalise_chat_identifier``) are
    applied by the caller. WhatsApp renderer carries it as ``jid``;
    iMessage threader as ``handle``. Both fall back to nothing for the
    operator's own ``user`` row (role == "user"), which never maps to a
    contact node.
    """
    if not isinstance(entry, dict):
        return ""
    if (entry.get("role") or "").lower() == "user":
        return ""
    raw = entry.get("jid") or entry.get("handle") or ""
    return raw.strip()


def _load_metadata(state_dir: Path) -> dict:
    """Best-effort read of the persisted conversation metadata.

    Step 00 writes ``00_metadata.json`` with at least ``channel`` and
    ``participants``. A missing/garbled file degrades to ``{}`` so the
    sink writers keep working on legacy state dirs.
    """
    meta_path = state_dir / "00_metadata.json"
    if not meta_path.exists():
        return {}
    try:
        data = read_json(meta_path)
        return data if isinstance(data, dict) else {}
    except Exception:  # pragma: no cover - defensive
        return {}


# ── Public entry point ──────────────────────────────────────────────


def write_all(
    *,
    state_dir: Path,
    conversation_id: str,
    classification: Classification,
    settings: Settings,
    dry_run: bool = False,
    metadata: dict | None = None,
) -> dict:
    """Write every step's output to its destination sink.

    Returns a dict summarising what was written (counts per sink),
    useful for logs and tests.

    ``metadata`` carries the conversation's ``channel`` + ``participants``
    so the gist sinks can (a) tag Qdrant points with the channel and
    (b) link the conversation to the JID/handle-keyed people-graph Person
    nodes. When omitted it is read from ``state_dir/00_metadata.json``;
    a missing file degrades the channel tag / participant edges to no-op.
    """
    if metadata is None:
        metadata = _load_metadata(state_dir)
    summary: dict = {
        "md": None,
        "qdrant_points": 0,
        "oxigraph_triples": 0,
        "coach_rows": 0,
        "speaker_feedback": None,
    }

    # 1. Conversation MD
    md_path = _write_conversation_md(
        state_dir, conversation_id, settings, dry_run
    )
    summary["md"] = str(md_path) if md_path else None

    # 2. Qdrant: conversation chunks + facts
    summary["qdrant_points"] = _write_qdrant(
        state_dir, conversation_id, classification, settings, dry_run,
        metadata=metadata,
    )

    # 3. Oxigraph: relationship signals + facts as RDF
    summary["oxigraph_triples"] = _write_oxigraph(
        state_dir, conversation_id, classification, settings, dry_run,
        metadata=metadata,
    )

    # 4. SQLite: coach observation
    summary["coach_rows"] = _write_coach(
        state_dir, conversation_id, settings, dry_run
    )

    # 5. Speaker feedback queue
    summary["speaker_feedback"] = _write_speaker_feedback(
        state_dir, conversation_id, settings, dry_run
    )

    logger.info("Ingest summary for %s: %s", conversation_id, summary)
    return summary


# ── 1. Conversation MD ──────────────────────────────────────────────


def _write_conversation_md(
    state_dir: Path,
    conversation_id: str,
    settings: Settings,
    dry_run: bool,
) -> Path | None:
    enrichment_md_path = state_dir / "02_enrichment.md"
    if not enrichment_md_path.exists():
        return None
    out_dir = settings.output_conversations_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{conversation_id}.md"
    if dry_run:
        logger.info("dry_run: would write %s", out_path)
        return out_path
    out_path.write_text(enrichment_md_path.read_text())
    return out_path


# ── 2. Qdrant ───────────────────────────────────────────────────────


def _write_qdrant(
    state_dir: Path,
    conversation_id: str,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
    metadata: dict | None = None,
) -> int:
    """Write conversation summary + per-fact Qdrant points.

    Two types of points are written:
    - One conversation-level point (from enrichment summary) — used by
      the linker for cross-conversation similarity search.
    - Per-fact points – used by the assistant for knowledge retrieval.
    """
    from .ollama_client import OllamaClient
    from .linker import extract_summary_for_linking
    from . import provenance

    if metadata is None:
        metadata = _load_metadata(state_dir)
    # `channel` discriminates whatsapp / imessage / sms / email / spoken
    # in the points. Legacy points carried only the un-channelled
    # `source=human_conversation`, so nothing downstream could filter or
    # label by channel. Keep `source` for back-compat; ADD the channel tag.
    channel = (metadata.get("channel") or "").strip().lower() or None

    # Provenance header (REUSE-5): each chunk's *embedded text* gets a
    # compact one-line source tag so retrieved chunks self-describe their
    # origin and citations are strong. `src` = channel (the source kind:
    # imessage/email/whatsapp/sms/spoken); fall back to `source` then a
    # safe default. `id`/`date` come from the conversation metadata.
    prov_src = channel or (metadata.get("source") or "").strip().lower() or "conversation"
    prov_date = (
        (metadata.get("date") or metadata.get("started_at") or "").strip()[:10]
        or None
    )

    client = OllamaClient(base_url=settings.ollama_url)
    points = []
    base_payload = {
        "user_id": settings.user_id,
        "visibility": "private",
        "source": "human_conversation",
        "channel": channel,
        "conversation_id": conversation_id,
        "classification_slug": classification.suggested_type_slug,
        "sensitivity_level": classification.sensitivity.level,
        "ingested_at": datetime.now(timezone.utc).isoformat(),
        "retention_tier": _retention_tier_for(classification),
    }

    # Conversation-level point from enrichment summary
    enrichment_path = state_dir / "02_enrichment.md"
    summary_text = extract_summary_for_linking(enrichment_path)
    if summary_text:
        if dry_run:
            logger.info("dry_run: would embed conversation summary")
        else:
            try:
                # The summary point doubles as the linker's
                # cross-conversation similarity target. The linker embeds
                # a *raw* summary as its query, so the stored summary
                # vector must also be raw or the symmetry breaks. We
                # therefore keep the embedded text un-headered here and
                # carry provenance only in the payload (header string +
                # headered `text` for citation display).
                summary_header = provenance.build_header(
                    src=prov_src,
                    source_id=conversation_id,
                    date=prov_date,
                )
                vec = client.embed(summary_text)
                point_id = _deterministic_id(conversation_id, "summary", summary_text)
                points.append({
                    "id": point_id,
                    "vector": vec,
                    "payload": {
                        **base_payload,
                        "text": provenance.prepend_header(
                            summary_text[:500],
                            src=prov_src,
                            source_id=conversation_id,
                            date=prov_date,
                        ),
                        "provenance_header": summary_header,
                        "point_type": "conversation_summary",
                    },
                })
            except Exception as exc:
                logger.warning("Embed failed for conversation summary: %s", exc)

    # Per-fact points
    facts_path = state_dir / "05_facts.json"
    if facts_path.exists():
        facts = read_json(facts_path)
        if isinstance(facts, list):
            for fact in facts:
                text = fact.get("text", "")
                if not text:
                    continue
                if dry_run:
                    points.append({"id": "dry_run", "vector": [], "payload": {}})
                    continue
                # `subject` is the fact's speaker/sender ("user" for the
                # operator); surface it as the header's `from=` field.
                fact_speaker = (fact.get("subject") or "").strip() or None
                fact_header = provenance.build_header(
                    src=prov_src,
                    source_id=conversation_id,
                    date=prov_date,
                    speaker=fact_speaker,
                )
                fact_chunk = provenance.prepend_header(
                    text,
                    src=prov_src,
                    source_id=conversation_id,
                    date=prov_date,
                    speaker=fact_speaker,
                )
                try:
                    vec = client.embed(fact_chunk)
                except Exception as exc:
                    logger.warning("Embed failed for fact: %s", exc)
                    continue
                point_id = _deterministic_id(conversation_id, "fact", text)
                points.append({
                    "id": point_id,
                    "vector": vec,
                    "payload": {
                        **fact,
                        **base_payload,
                        "provenance_header": fact_header,
                        "point_type": "fact",
                    },
                })

    if not points:
        return 0

    if dry_run:
        logger.info("dry_run: would upsert %d Qdrant points", len(points))
        return len(points)

    url = (
        f"{settings.qdrant_url}/collections/"
        f"{settings.qdrant_conversations_collection}/points"
    )
    try:
        with httpx.Client(timeout=60.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.put(url, json={"points": points}, params={"wait": "true"})
            resp.raise_for_status()
    except Exception as exc:
        logger.error("Qdrant upsert failed: %s", exc)
        raise
    return len(points)


# ── 3. Oxigraph ─────────────────────────────────────────────────────


def _write_oxigraph(
    state_dir: Path,
    conversation_id: str,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
    metadata: dict | None = None,
) -> int:
    """Write relationship signals + facts as RDF triples."""
    if metadata is None:
        metadata = _load_metadata(state_dir)
    triples: list[str] = []

    # Conversation metadata — setting is required for the Foundry
    # candidate-promotion corroboration rule. Emitted once per convo.
    triples.extend(_conversation_to_triples(
        conversation_id, classification, settings
    ))

    # Participant-identity bridge: link the conversation to the
    # JID/handle-keyed Person nodes ostler_fda.pwg_ingest creates, so
    # "who did I talk to" walks pwg:hasParticipant structurally. No-op
    # when metadata lacks resolvable participants.
    triples.extend(
        _participant_identity_triples(conversation_id, metadata, settings)
    )

    # Signals
    signals_dir = state_dir / "03_relationship_signals"
    if signals_dir.exists():
        for sig_file in signals_dir.glob("*.json"):
            sig = read_json(sig_file)
            triples.extend(_signal_to_triples(conversation_id, sig, settings))

    # Facts
    facts_path = state_dir / "05_facts.json"
    if facts_path.exists():
        facts = read_json(facts_path)
        if isinstance(facts, list):
            for fact in facts:
                triples.extend(
                    _fact_to_triples(conversation_id, fact, settings, metadata)
                )

    # Outstanding todos (pre-meeting brief input). Each todo is linked
    # to every non-user participant of the source conversation so the
    # brief subagent (CM041 meeting_syncer/brief.py) can query
    # pwg:OutstandingTodo triples by attendee URI and surface them on
    # the next meeting with that person. Best-effort: missing sidecar
    # is a silent no-op (the extractor warns at run time).
    for todo in _outstanding_todos.load_sidecar(state_dir):
        triples.extend(_todo_to_triples(conversation_id, todo, settings))

    if not triples:
        return 0

    if dry_run:
        logger.info("dry_run: would write %d Oxigraph triples", len(triples))
        return len(triples)

    # Emit prefixes once at the top, then all triple blocks.
    # Individual blocks already include prefixes which causes duplicate
    # @prefix declarations — strip them and emit a single header.
    cleaned = []
    for t in triples:
        lines = [l for l in t.split("\n") if not l.startswith("@prefix ")]
        cleaned.append("\n".join(lines))
    ttl = _turtle_prefixes() + "\n" + "\n\n".join(cleaned)
    # Use a named graph per user so multi-user queries can scope by graph
    graph_uri = f"urn:pwg:user/{settings.user_id}"
    try:
        with httpx.Client(timeout=60.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(
                f"{settings.oxigraph_url}/store",
                content=ttl.encode(),
                headers={"Content-Type": "text/turtle"},
                params={"graph": graph_uri},
            )
            resp.raise_for_status()
    except Exception as exc:
        logger.error("Oxigraph write failed: %s", exc)
        raise
    return len(triples)


def _turtle_prefixes() -> str:
    """Standard Turtle prefix block for all CM048 RDF output.

    Uses a proper IRI base so Oxigraph (and any SPARQL endpoint) can
    resolve terms. The `pwg:` namespace is ours; `xsd:` is standard.
    """
    return (
        '@prefix pwg: <urn:pwg:> .\n'
        '@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n'
    )


def _urn(path: str) -> str:
    """Wrap a path in a full IRI. Turtle doesn't allow '/' in prefixed
    names, so URIs with path segments must use angle-bracket syntax."""
    return f"<urn:pwg:{path}>"


def _conversation_to_triples(
    conversation_id: str,
    classification: Classification,
    settings: Settings,
) -> list[str]:
    """Emit conversation-level metadata triples.

    The setting/shape/stakes values are how the candidate-promotion
    logic tells conversations apart: two facts about the same subject
    extracted from two 'work/one-on-one' conversations with Pierre are
    not corroborated (same source, same channel), but one from
    'work/one-on-one' with Pierre and one from 'social/casual' with
    Sarah-who-mentioned-Pierre are.
    """
    conv_uri = _urn(f"conversation/{conversation_id}")
    # Every literal interpolation goes through the Turtle escape so
    # an LLM-classified value containing a stray quote / newline
    # cannot terminate the literal early and inject extra triples.
    safe_user = escape_turtle_literal(settings.user_id)
    safe_setting = escape_turtle_literal(classification.setting)
    safe_shape = escape_turtle_literal(classification.shape)
    safe_stakes = escape_turtle_literal(classification.stakes)
    t = [
        _turtle_prefixes(),
        f"{conv_uri} a <urn:pwg:Conversation> ;",
        f'  <urn:pwg:userId> "{safe_user}" ;',
        f'  <urn:pwg:setting> "{safe_setting}" ;',
        f'  <urn:pwg:shape> "{safe_shape}" ;',
        f'  <urn:pwg:stakes> "{safe_stakes}" .',
    ]
    return ["\n".join(t)]


def _participant_identity_triples(
    conversation_id: str,
    metadata: dict,
    settings: Settings,
) -> list[str]:
    """Link a conversation to the JID/handle-keyed Person nodes.

    For every non-user participant carrying a resolvable chat identifier
    (WhatsApp JID / iMessage handle), emit:

        <person>  pwg:participatedIn  <conversation> .
        <person>  pwg:hasChatChannel  "whatsapp" .
        <conversation>  pwg:hasParticipant  <person> .

    The ``<person>`` URI is reconstructed to match exactly the node
    ostler_fda.pwg_ingest creates for the same contact, so the
    conversation and the person graph share one node and the assistant
    can answer "who did I talk to" by walking ``pwg:hasParticipant``.

    Participants with no chat identifier (the operator's own ``user``
    row, or an LLM-only slug with no JID/handle) are skipped -- we never
    fabricate a Person node from a name we cannot key.
    """
    channel = (metadata.get("channel") or "").strip().lower()
    participants = metadata.get("participants") or []
    if not isinstance(participants, list):
        return []

    conv_uri = _urn(f"conversation/{conversation_id}")
    safe_user = escape_turtle_literal(settings.user_id)
    safe_channel = escape_turtle_literal(channel or "unknown")

    out: list[str] = []
    seen: set[str] = set()
    for entry in participants:
        raw = _participant_identifier(channel, entry)
        if not raw:
            continue
        # `@lid` is WhatsApp's opaque linked-id, not a phone or a name.
        # pwg_ingest refuses to create a Person node from it (BW-4), so a
        # participant edge keyed off it would dangle. Skip it here too.
        if raw.endswith("@lid"):
            continue
        # The URI key MUST be derived from the SAME string pwg_ingest
        # keys the Person node by (raw JID for WhatsApp), else the edge
        # dangles to a phantom node. The surfaced chatIdentifier literal
        # may stay normalised (e164 phone) for readability.
        uri_key = _participant_uri_key(channel, raw)
        if not uri_key or uri_key in seen:
            continue
        seen.add(uri_key)
        person_id = _person_id_from_identifier(uri_key)
        person_uri = _person_graph_uri(person_id)
        ident = _normalise_chat_identifier(channel, raw)
        # The Person URI is a full http(s) IRI -> valid Turtle in
        # angle brackets. The identifier literal is escaped defensively
        # even though it is phone/email-shaped.
        safe_ident = escape_turtle_literal(ident)
        block = "\n".join([
            _turtle_prefixes(),
            f"<{person_uri}> <urn:pwg:participatedIn> {conv_uri} ;",
            f'  <urn:pwg:hasChatChannel> "{safe_channel}" ;',
            f'  <urn:pwg:chatIdentifier> "{safe_ident}" ;',
            f'  <urn:pwg:userId> "{safe_user}" .',
            f"{conv_uri} <urn:pwg:hasParticipant> <{person_uri}> .",
        ])
        out.append(block)
    return out


def _coerce_signal_field(value: object, inner_key: str, default: str = "unknown") -> object:
    """Extract a scalar from an LLM signal field that may arrive as either a
    nested object (``{inner_key: X}``) or a bare scalar (``X``).

    The model is *supposed* to emit nested objects (``{"score": "high"}``)
    but in practice sometimes returns the bare value (``"high"``). The old
    code did ``sig.get("warmth", {}).get("score", ...)`` which raises
    ``AttributeError`` the moment ``warmth`` is a string. This tolerates both
    shapes: dicts are dug into, bare scalars are used as-is, empty/None falls
    back to ``default``.
    """
    if isinstance(value, dict):
        return value.get(inner_key, default)
    if value in (None, ""):
        return default
    return value


def _signal_to_triples(conversation_id: str, sig: dict, settings: Settings) -> list[str]:
    """Emit a minimal-but-useful triple set for a relationship signal."""
    slug = sig.get("target_participant", "unknown")
    signal_uri = _urn(f"signal/{conversation_id}/{slug}")
    person_uri = _urn(f"person/{slug}")
    conv_uri = _urn(f"conversation/{conversation_id}")
    warmth = _coerce_signal_field(sig.get("warmth"), "score")
    # Trust may be reported under any of three differently-shaped keys; take
    # the first that yields a real value (preserving the original precedence).
    trust: object = "unknown"
    for _src_key, _inner in (
        ("trust_and_rapport", "signal"),
        ("trust_signals", "level"),
        ("trust", "score"),
    ):
        if _src_key in sig:
            _candidate = _coerce_signal_field(sig.get(_src_key), _inner)
            if _candidate not in (None, "", "unknown"):
                trust = _candidate
                break
    confidence = sig.get("overall_confidence", 0.0)
    observed_at = sig.get("observed_at", "")
    # Each interpolated literal sourced from the LLM signal payload
    # goes through the Turtle escape; the previous bare interpolation
    # let an LLM-injected quote / newline break out of the literal.
    safe_user = escape_turtle_literal(settings.user_id)
    safe_warmth = escape_turtle_literal(warmth)
    safe_trust = escape_turtle_literal(trust)
    safe_confidence = escape_turtle_literal(confidence)
    safe_observed_at = escape_turtle_literal(observed_at)
    # Privacy level stamped at write time so the signal is born-tagged.
    # CM041's fact/signal readers are fail-closed: an untagged node is
    # treated as L3/hidden and stays invisible until a reboot re-sweeps
    # it via the startup backfill. This mirrors the sibling Fact node
    # (`_fact_to_triples`) exactly -- read `privacy_level` off the payload
    # with an L1 (visible / personal) default; the extractor may override
    # via the payload. L1, never L3, matches the Fact default.
    safe_privacy = escape_turtle_literal(sig.get("privacy_level", "L1"))
    t = [
        _turtle_prefixes(),
        f"{signal_uri} a <urn:pwg:RelationshipSignal> ;",
        f'  <urn:pwg:observedIn> {conv_uri} ;',
        f'  <urn:pwg:about> {person_uri} ;',
        f'  <urn:pwg:userId> "{safe_user}" ;',
        f'  <urn:pwg:visibility> "private" ;',
        f'  <urn:pwg:privacyLevel> "{safe_privacy}" ;',
        f'  <urn:pwg:warmth> "{safe_warmth}" ;',
        f'  <urn:pwg:trust> "{safe_trust}" ;',
        f'  <urn:pwg:overallConfidence> "{safe_confidence}"^^<http://www.w3.org/2001/XMLSchema#float> ;',
        f'  <urn:pwg:observedAt> "{safe_observed_at}"^^<http://www.w3.org/2001/XMLSchema#dateTime> .',
    ]
    return ["\n".join(t)]


def _todo_to_triples(
    conversation_id: str,
    todo: "_outstanding_todos.OutstandingTodo",
    settings: Settings,
) -> list[str]:
    """Emit pwg:OutstandingTodo triples for one extracted action item.

    Schema (mirrors brief.py's SPARQL on the consumer side):

    - ``<urn:pwg:todo/<todo_id>> a <urn:pwg:OutstandingTodo>``
    - ``pwg:fromConversation`` → the source conversation URI
    - ``pwg:aboutPerson`` → one triple per non-user participant
      (so a 3-person meeting fans out 3 ``aboutPerson`` triples)
    - ``pwg:owner`` → the structured owner id (``"user"`` /
      ``"other:<slug>"`` / ``UNOWNED`` sentinel)
    - ``pwg:ownerDisplay`` → the literal display name from the table
    - ``pwg:todoText`` → the action item verbatim
    - ``pwg:deadline`` → ISO date literal, omitted if null
    - ``pwg:priority`` → ``"high" | "medium" | "low"``, omitted if null
    - ``pwg:status`` → ``"open"`` (future v1.0.1 closes from later convos)
    - ``pwg:todoCreatedAt`` → RFC3339 UTC of extractor run
    - ``pwg:visibility`` → ``"private"`` (always)
    - ``pwg:userId`` → owning operator's id

    All literal interpolations route through ``escape_turtle_literal``
    so an LLM-extracted action text containing a stray quote or newline
    cannot terminate the literal early and inject triples.
    """
    todo_uri = _urn(f"todo/{todo.todo_id}")
    conv_uri = _urn(f"conversation/{conversation_id}")

    safe_user = escape_turtle_literal(settings.user_id)
    safe_owner = escape_turtle_literal(todo.owner)
    safe_owner_display = escape_turtle_literal(todo.owner_display)
    # action_text uses json.dumps for the same reason fact text does
    # (JSON-quoting is a superset of Turtle string-literal quoting).
    action_quoted = json.dumps(todo.action_text)
    safe_status = escape_turtle_literal(todo.status)
    safe_created_at = escape_turtle_literal(todo.created_at)
    safe_source_date = escape_turtle_literal(todo.source_conversation_date)

    lines = [
        _turtle_prefixes(),
        f"{todo_uri} a <urn:pwg:OutstandingTodo> ;",
        f'  <urn:pwg:fromConversation> {conv_uri} ;',
        f'  <urn:pwg:userId> "{safe_user}" ;',
        f'  <urn:pwg:visibility> "private" ;',
        f'  <urn:pwg:owner> "{safe_owner}" ;',
        f'  <urn:pwg:ownerDisplay> "{safe_owner_display}" ;',
        f'  <urn:pwg:todoText> {action_quoted} ;',
        f'  <urn:pwg:status> "{safe_status}" ;',
        f'  <urn:pwg:todoCreatedAt> "{safe_created_at}"^^<http://www.w3.org/2001/XMLSchema#dateTime> ;',
        f'  <urn:pwg:sourceConversationDate> "{safe_source_date}" ;',
    ]
    if todo.deadline:
        safe_deadline = escape_turtle_literal(todo.deadline)
        lines.append(
            f'  <urn:pwg:deadline> "{safe_deadline}"^^<http://www.w3.org/2001/XMLSchema#date> ;'
        )
    if todo.priority:
        safe_priority = escape_turtle_literal(todo.priority)
        lines.append(
            f'  <urn:pwg:priority> "{safe_priority}" ;'
        )
    # aboutPerson fan-out: one triple per non-user participant. Each
    # subject_person_id is the conversation metadata ``id`` (e.g.
    # ``other:alice-chen``) which the brief subagent maps to a
    # ``pwg:person`` URI via _urn(subject.replace(":", "/")) on the
    # consumer side (mirroring _fact_to_triples).
    person_lines = []
    for person_id in todo.subject_person_ids:
        person_uri = _urn(person_id.replace(":", "/"))
        person_lines.append(
            f'  <urn:pwg:aboutPerson> {person_uri} ;'
        )
    if not person_lines:
        # No non-user participants. Skip (brief use case doesn't apply).
        return []
    # Replace the trailing semicolon on the last person line with a
    # period so the Turtle block terminates cleanly.
    lines.extend(person_lines[:-1])
    last = person_lines[-1].rstrip(" ;") + " ."
    lines.append(last)

    return ["\n".join(lines)]


def _slugify_sentinel_value(value: str) -> str:
    """Reduce a value to a single space-free token for a REUSE-5 sentinel.

    The provenance sentinel grammar (``[pwg:src=... id=... date=...
    from=...]``) is whitespace-separated ``key=value`` pairs, so a value
    must never contain a space (or a ``]`` that would close the marker
    early). We lowercase, drop the bracket/equals/whitespace characters
    that would break the grammar, and collapse the rest to hyphens. This
    mirrors the slug shape CM044's ``provenance.parse_header`` expects on
    the consume side.
    """
    if not value:
        return ""
    out = []
    for ch in str(value).strip().lower():
        if ch.isalnum() or ch in ".:_-/":
            out.append(ch)
        elif ch.isspace():
            out.append("-")
        # else: drop '=', '[', ']' and other grammar-breaking chars.
    token = "".join(out).strip("-")
    # Collapse any run of hyphens a drop/space left behind.
    while "--" in token:
        token = token.replace("--", "-")
    return token


def _fact_provenance_header(
    conversation_id: str, fact: dict, metadata: dict | None
) -> str:
    """Build the REUSE-5 provenance sentinel for one extracted fact.

    Produces a single-line marker the CM044 wiki compiler parses with
    ``compiler.provenance.parse_header`` to render an inline source
    citation (``via WhatsApp, Pierre, 20 Jun 2026``) on the person page::

        [pwg:src=whatsapp id=2026-06-20_pierre date=2026-06-20 from=pierre]

    All fields are best-effort: ``src`` from the conversation channel,
    ``id`` from the conversation id, ``date`` from the conversation
    metadata, ``from`` from the fact's subject (the person the fact is
    about, which is the person whose wiki page renders it). Any field we
    cannot source is simply omitted; the consume side renders whatever is
    present and skips the citation entirely when nothing meaningful
    remains. Returns ``""`` when there is no attributable provenance at
    all, so the caller can skip the predicate.
    """
    metadata = metadata or {}

    src = _slugify_sentinel_value(metadata.get("channel") or "")
    conv = _slugify_sentinel_value(conversation_id or "")
    # metadata['date'] is the conversation date (YYYY-MM-DD), the same
    # field the outstanding-todo writer reads for sourceConversationDate.
    date = _slugify_sentinel_value(metadata.get("date") or "")
    # The fact subject is "user" or "other:<slug>"; the person the fact
    # is about is the wiki-page owner, so attribute the citation to them.
    subject = str(fact.get("subject") or "")
    sender = ""
    if subject and subject != "user":
        sender = _slugify_sentinel_value(subject.split(":", 1)[-1])

    # The consume side (CM044 compiler.provenance.render_citation) renders
    # nothing unless there is a source kind or a sender. An id/date-only
    # header would be dead weight on the wire, so we only stamp a header
    # when it will actually drive a visible citation.
    if not src and not sender:
        return ""

    parts: list[str] = []
    if src:
        parts.append(f"src={src}")
    if conv:
        parts.append(f"id={conv}")
    if date:
        parts.append(f"date={date}")
    if sender:
        parts.append(f"from={sender}")

    return "[pwg:" + " ".join(parts) + "]"


def _fact_to_triples(
    conversation_id: str,
    fact: dict,
    settings: Settings,
    metadata: dict | None = None,
) -> list[str]:
    fact_id = _deterministic_id(conversation_id, "fact", fact.get("text", ""))
    fact_uri = _urn(f"fact/{fact_id}")
    conv_uri = _urn(f"conversation/{conversation_id}")
    subject = fact.get("subject", "user")
    subject_uri = (
        _urn(f"user/{settings.user_id}") if subject == "user"
        else _urn(subject.replace(":", "/"))
    )
    # `text_escaped` already comes through json.dumps() which produces
    # a properly-quoted JSON string -- the JSON escape rules cover the
    # same control characters Turtle requires plus more, so the result
    # is a valid Turtle literal too. Every other literal interpolation
    # goes through escape_turtle_literal.
    text_escaped = json.dumps(fact.get("text", ""))
    # Foundry candidate flag: new facts come in as candidates; legacy
    # facts (missing the key in 05_facts.json) are treated as already
    # promoted, matching ExtractedFact.from_dict migration semantics.
    candidate = bool(fact.get("candidate", False))
    candidate_literal = "true" if candidate else "false"
    safe_user = escape_turtle_literal(settings.user_id)
    safe_type = escape_turtle_literal(fact.get("type", "fact"))
    safe_domain = escape_turtle_literal(fact.get("domain", "general"))
    safe_privacy = escape_turtle_literal(fact.get("privacy_level", "L1"))
    safe_strength = escape_turtle_literal(fact.get("signal_strength", "medium"))
    t = [
        _turtle_prefixes(),
        f"{fact_uri} a <urn:pwg:Fact> ;",
        f'  <urn:pwg:fromConversation> {conv_uri} ;',
        f'  <urn:pwg:about> {subject_uri} ;',
        f'  <urn:pwg:userId> "{safe_user}" ;',
        f'  <urn:pwg:visibility> "private" ;',
        f'  <urn:pwg:type> "{safe_type}" ;',
        f'  <urn:pwg:domain> "{safe_domain}" ;',
        f'  <urn:pwg:privacyLevel> "{safe_privacy}" ;',
        f'  <urn:pwg:signalStrength> "{safe_strength}" ;',
        f'  <urn:pwg:candidate> "{candidate_literal}"^^xsd:boolean ;',
    ]
    # REUSE-5 provenance sentinel (consumed by CM044's wiki person-page
    # renderer via compiler.provenance). Emitted as a sibling predicate
    # so the marker never has to live inline in the fact text. Omitted
    # when no provenance is attributable (keeps the triple clean).
    header = _fact_provenance_header(conversation_id, fact, metadata)
    if header:
        safe_header = escape_turtle_literal(header)
        t.append(f'  <urn:pwg:provenanceHeader> "{safe_header}" ;')
    # The text predicate terminates the block.
    t.append(f'  <urn:pwg:text> {text_escaped} .')
    return ["\n".join(t)]


# ── 4. Coach SQLite ─────────────────────────────────────────────────


def _write_coach(
    state_dir: Path,
    conversation_id: str,
    settings: Settings,
    dry_run: bool,
) -> int:
    obs_path = state_dir / "04_coaching.json"
    if not obs_path.exists():
        return 0
    obs = read_json(obs_path)
    if obs.get("skipped"):
        return 0

    if dry_run:
        logger.info("dry_run: would write 1 coach row")
        return 1

    settings.coach_db_path.parent.mkdir(parents=True, exist_ok=True)
    encryption_key = getattr(settings, 'encryption_key_hex', None)
    # ostler_security is guaranteed importable (hard-fails at module
    # load if not). The remaining branch is whether a key is set.
    if encryption_key:
        conn = _secure_connect(settings.coach_db_path, encryption_key)
    else:
        _warn_plaintext_once(str(settings.coach_db_path), encryption_key)
        conn = sqlite3.connect(str(settings.coach_db_path))
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS observations (
                observation_id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                observed_at TEXT NOT NULL,
                conversation_type TEXT,
                tone TEXT,
                what_went_well_json TEXT,
                what_to_work_on_json TEXT,
                tip_json TEXT,
                tags_json TEXT,
                overall_severity INTEGER,
                confidence REAL,
                flags_json TEXT,
                user_id TEXT NOT NULL,
                visibility TEXT NOT NULL,
                retention_tier TEXT NOT NULL,
                created_at TEXT NOT NULL,
                UNIQUE (conversation_id)
            )
        """)
        conn.execute(
            """
            INSERT OR REPLACE INTO observations
              (observation_id, conversation_id, observed_at, conversation_type, tone,
               what_went_well_json, what_to_work_on_json, tip_json, tags_json,
               overall_severity, confidence, flags_json,
               user_id, visibility, retention_tier, created_at)
            VALUES
              (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                _deterministic_id(conversation_id, "coach", "observation"),
                conversation_id,
                obs.get("observed_at") or datetime.now(timezone.utc).isoformat(),
                obs.get("conversation_type"),
                obs.get("tone"),
                json.dumps(obs.get("what_went_well") or obs.get("strengths") or []),
                json.dumps(obs.get("what_to_work_on") or obs.get("areas_for_growth") or []),
                json.dumps(obs.get("tip") or obs.get("coaching_reflection") or obs.get("insights") or {}),
                json.dumps(obs.get("tags") or obs.get("categories") or []),
                int(obs.get("overall_severity") or 1),
                float(obs.get("confidence") or 0.0),
                json.dumps(obs.get("flags") or {}),
                settings.user_id,
                "private",
                "tier-1-forever",
                datetime.now(timezone.utc).isoformat(),
            ),
        )
        conn.commit()
    finally:
        conn.close()
    return 1


# ── 5. Speaker-label feedback ───────────────────────────────────────


def _write_speaker_feedback(
    state_dir: Path,
    conversation_id: str,
    settings: Settings,
    dry_run: bool,
) -> Path | None:
    src = state_dir / "06_speaker_feedback.json"
    if not src.exists():
        return None
    queue_dir = settings.processing_state_dir.parent / "speaker_feedback"
    queue_dir.mkdir(parents=True, exist_ok=True)
    out = queue_dir / f"{conversation_id}.json"
    if dry_run:
        logger.info("dry_run: would queue speaker feedback to %s", out)
        return out
    out.write_text(src.read_text())
    return out


# ── Helpers ─────────────────────────────────────────────────────────


def _deterministic_id(conversation_id: str, kind: str, content: str) -> str:
    """Deterministic UUIDv5 so re-runs upsert same IDs."""
    ns = uuid.NAMESPACE_URL
    seed = f"pwg://cm048/{conversation_id}/{kind}/{hashlib.sha256(content.encode()).hexdigest()}"
    return str(uuid.uuid5(ns, seed))


def _retention_tier_for(classification: Classification) -> str:
    if classification.sensitivity.level in ("sensitive", "highly-sensitive"):
        return "tier-1-forever"
    if classification.stakes == "high":
        return "tier-1-forever"
    if classification.setting == "service":
        return "tier-3-years"
    return "tier-2-decade"
