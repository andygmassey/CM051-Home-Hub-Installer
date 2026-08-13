"""Zero-model-call first pass: get a conversation into the wiki NOW.

v1018-D021. The full pipeline costs six serialised model calls per email
thread, and the artefact the customer actually reads -- the four-artefact
bundle -- is produced by the LAST of those six. So a thread is invisible
in the wiki until every one of classify, enrich, relationship, coaching
and fact extraction has finished decoding on the single Ollama slot. On a
mailbox of any size that is weeks of nothing, inside the refund window.

This module writes the SAME four artefacts, through the SAME channel
adapter and the SAME writer, from information the source pipeline already
has for free: the threaded transcript, the participants, the subject and
the timestamps. No model is called. A seed costs milliseconds.

The bundle is stamped ``enrichment_pending: true``. The full pipeline
runs afterwards on its own schedule and rewrites the same folder (the
folder is derived from the conversation_id, so the enriched bundle
replaces the seed in place rather than forking a second copy).

What a seed deliberately does NOT do:

  * It does not invent todos. A regex that guesses commitments out of
    correspondence produces confident, wrong obligations on a person's
    page, which is worse than an empty list that says it is waiting.
  * It does not write the gist arm (Qdrant / Oxigraph), extract facts,
    or emit a relationship signal. Those are model judgements. Seeding
    them with heuristics would put unearned claims in the graph, and
    the graph has no "provisional" state to walk them back from.
  * It does not mark any LLM pipeline step complete, so the later full
    pass runs every step exactly as it would have.

British English.
"""
from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Optional

from . import channel_adapter as _channel_adapter
from . import conversation_writer as _conversation_writer
from .bundle_extractor import BundleExtraction
from .schemas import Classification
from .settings import Settings

logger = logging.getLogger(__name__)

# Cap the per-message digest so one long message cannot crowd out the
# rest of the thread in the seeded summary.
_POINT_CHARS = 240
_MAX_POINTS = 40

# A transcript line that opens a message, as the source pipelines render
# it: a bold speaker label, optionally followed by a bracketed timestamp.
# Matches "**Name:**", "**Name** (2026-01-01 09:00):" and "**Name:** text".
_SPEAKER_RE = re.compile(
    r"^\*\*(?P<who>[^*]{1,120}?)\*\*\s*(?:\((?P<when>[^)]{0,64})\))?\s*:?\s*"
    r"(?P<rest>.*)$"
)

_PENDING_NOTE = (
    "_Written without a model so this thread is browseable immediately. "
    "The assistant rewrites this page with a proper summary, topics and "
    "todos when enrichment reaches it._"
)


def deterministic_extraction(
    transcript: str,
    metadata: dict,
) -> BundleExtraction:
    """Build a BundleExtraction from the transcript alone.

    The result is honest about being provisional: the summary states what
    the thread IS (subject, who, how many messages, over what span) rather
    than what it MEANS, because meaning is the model's job. Topic points
    are one per message, each the message's opening line, which is the
    single most useful thing a skim-reader wants and the one thing an
    extractive pass can get right.
    """
    thread = metadata.get("email_thread")
    thread = thread if isinstance(thread, dict) else {}

    subject = str(thread.get("subject") or "").strip()
    people = _participant_names(metadata)
    messages = _split_messages(transcript)

    count = thread.get("message_count")
    if not isinstance(count, int) or count <= 0:
        count = len(messages) or 1

    opening = subject or str(metadata.get("title") or "").strip()
    bits: list[str] = []
    if opening:
        bits.append(f'Thread "{opening}".')
    if people:
        bits.append(f"Between {_join_names(people)}.")
    bits.append(f"{count} message{'s' if count != 1 else ''}.")
    span = _span(thread, metadata)
    if span:
        bits.append(span)

    topics: list[dict] = []
    points = [p for p in (_point(m) for m in messages) if p][:_MAX_POINTS]
    if points:
        topics.append({"name": "Messages", "points": points})

    return BundleExtraction(
        overall_summary=" ".join(bits) + "\n\n" + _PENDING_NOTE,
        topics=topics,
        todos=[],
    )


def seed_conversation(
    conversation_id: str,
    transcript: str,
    metadata: dict,
    settings: Settings,
    *,
    privacy_level: Optional[str] = None,
) -> Optional[Path]:
    """Write the four artefacts for one conversation, with no model call.

    Returns the folder written, or None when the channel has no adapter
    yet (the full pass will produce the bundle when it runs).

    Never raises for a per-conversation problem: a seed is an optimisation
    on top of the durable pipeline, and a seed that fails must not stop
    the enrichment pass that follows it.
    """
    # A seed must NEVER overwrite model output. A thread that already has
    # a real bundle gets re-dispatched whenever a new reply lands; without
    # this guard the seed pass would replace a good summary with a
    # placeholder, and if the enrichment that follows then timed out or
    # failed, the customer would be left holding the downgrade.
    if already_enriched(conversation_id, settings):
        logger.debug(
            "%s already has a model-written bundle; not seeding over it",
            conversation_id,
        )
        return None

    # Privacy level. The seed keeps the two DETERMINISTIC arms of the
    # ladder -- the operator's explicit ``metadata['privacy_level']`` and
    # the email-domain rules -- because it can evaluate both exactly as
    # well as the full pass can. It cannot evaluate the third arm: a
    # classifier escalation to sensitive / highly-sensitive is a read of
    # the body, and reading the body is the thing a seed does not do.
    #
    # So a thread the classifier WOULD have escalated sits at the
    # ladder's answer (L2 by default) until enrichment reaches it, rather
    # than at L3. It is never lower than the full pass would give for a
    # ``normal`` verdict, and the seed writes no gist arm at all -- no
    # Qdrant point, no triple -- so nothing crosses into the graph early.
    # The exposure is that the local wiki may render a sensitive thread
    # at L2 for the gap. ``enrichment_pending: true`` is in the
    # frontmatter precisely so a level-aware renderer can choose to
    # withhold a provisional bundle rather than trust its level.
    classification = _provisional_classification(metadata)
    extraction = deterministic_extraction(transcript, metadata)
    seeded_metadata = dict(metadata)
    seeded_metadata["enrichment_pending"] = True

    level = privacy_level or metadata.get("privacy_level")
    try:
        bundle = _channel_adapter.make_bundle(
            metadata=seeded_metadata,
            classification=classification,
            extraction=extraction,
            transcript=transcript,
            privacy_level=level if isinstance(level, str) else None,
        )
    except NotImplementedError:
        logger.info(
            "No bundle adapter for channel=%r; skipping seed for %s",
            metadata.get("channel"),
            conversation_id,
        )
        return None

    output = _conversation_writer.write_conversation(
        bundle,
        root=settings.output_conversations_dir,
        gist_post_fn=None,
    )
    logger.info(
        "Seeded %s at %s (no model call; enrichment pending)",
        conversation_id,
        output.folder,
    )
    return output.folder


def already_enriched(conversation_id: str, settings: Settings) -> bool:
    """True when the full pipeline has already produced a real bundle.

    Reads the pipeline's own state file rather than looking for the
    written folder: the folder exists after a SEED too, so its presence
    proves nothing. ``09_bundle`` in ``completed_steps`` is the only
    record that a model wrote the summary.
    """
    state_path = (
        settings.processing_state_dir / conversation_id / "state.json"
    )
    try:
        state = json.loads(state_path.read_text())
    except (OSError, json.JSONDecodeError):
        return False
    return "09_bundle" in (state.get("completed_steps") or [])


# ── helpers ──────────────────────────────────────────────────────────


def _provisional_classification(metadata: dict) -> Classification:
    """The minimum classification the adapter + writer need.

    Explicitly ``processing_depth="none"`` and low confidence: nothing
    downstream should read a seed's classification as a judgement. The
    real classifier overwrites it on the full pass.
    """
    channel = str(metadata.get("channel") or "spoken").lower()
    setting = "correspondence" if channel == "email" else "unknown"
    return Classification.from_dict({
        "setting": setting,
        "shape": "one-on-one",
        "stakes": "unknown",
        "confidence": 0.0,
        "reasoning": "seeded without a model (v1018-D021 fast first pass)",
        "sensitivity": {
            "level": "normal",
            "categories": [],
            "reasoning": "not assessed; enrichment pending",
        },
        "review_before_ingest": False,
        "processing_depth": "none",
        "hints_used": "none",
        "suggested_type_slug": f"{setting}_one-on-one_unknown",
    })


def _participant_names(metadata: dict) -> list[str]:
    out: list[str] = []
    for p in metadata.get("participants") or []:
        if not isinstance(p, dict):
            continue
        if p.get("role") == "user":
            continue
        name = str(p.get("display") or p.get("id") or "").strip()
        if name and name not in out:
            out.append(name)
    return out


def _join_names(names: list[str]) -> str:
    if len(names) == 1:
        return names[0]
    if len(names) == 2:
        return f"{names[0]} and {names[1]}"
    return ", ".join(names[:-1]) + f" and {names[-1]}"


def _span(thread: dict, metadata: dict) -> str:
    first = str(thread.get("first_message_at") or metadata.get("started_at") or "")
    last = str(thread.get("last_message_at") or metadata.get("ended_at") or "")
    first, last = first[:10], last[:10]
    if first and last and first != last:
        return f"{first} to {last}."
    if first:
        return f"{first}."
    return ""


def _split_messages(transcript: str) -> list[tuple[str, str, str]]:
    """Split a rendered transcript into (who, when, first-line) triples."""
    out: list[tuple[str, str, str]] = []
    current: Optional[list] = None
    for line in (transcript or "").splitlines():
        m = _SPEAKER_RE.match(line.strip())
        if m:
            if current:
                out.append(tuple(current))  # type: ignore[arg-type]
            current = [
                (m.group("who") or "").strip().rstrip(":"),
                (m.group("when") or "").strip(),
                (m.group("rest") or "").strip(),
            ]
            continue
        if current is not None and not current[2] and line.strip():
            current[2] = line.strip()
    if current:
        out.append(tuple(current))  # type: ignore[arg-type]
    return out


def _point(message: tuple[str, str, str]) -> str:
    who, when, body = message
    body = re.sub(r"\s+", " ", body).strip()
    if len(body) > _POINT_CHARS:
        body = body[:_POINT_CHARS].rstrip() + "..."
    head = who or "Unknown"
    if when:
        head = f"{head} ({when[:16]})"
    if not body:
        return ""
    return f"{head}: {body}"


def seed_from_manifest(manifest: Path, settings: Settings) -> tuple[int, int]:
    """Seed every (transcript, metadata) pair listed in a JSONL manifest.

    One line per conversation: ``{"transcript": <path>, "metadata": <path>}``.

    Batched deliberately. A seed costs milliseconds of real work, so
    spawning one interpreter per conversation would make process start-up
    the dominant cost of the very pass that exists to be cheap.

    Returns ``(seeded, skipped_or_failed)``. A single bad line never stops
    the batch.
    """
    seeded = 0
    other = 0
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
            transcript = Path(entry["transcript"]).read_text(encoding="utf-8")
            metadata = json.loads(
                Path(entry["metadata"]).read_text(encoding="utf-8")
            )
            conversation_id = metadata["conversation_id"]
        except Exception as exc:
            logger.warning("Unusable seed manifest entry: %s", exc)
            other += 1
            continue
        try:
            folder = seed_conversation(
                conversation_id, transcript, metadata, settings
            )
        except Exception as exc:
            # A seed is best-effort by construction. Log the type, never
            # the content: this handler sees real correspondence.
            logger.warning(
                "Seed failed for %s (%s); the full pass will still run it",
                conversation_id,
                type(exc).__name__,
            )
            other += 1
            continue
        if folder is None:
            other += 1
        else:
            seeded += 1
    return seeded, other


__all__ = [
    "already_enriched",
    "deterministic_extraction",
    "seed_conversation",
    "seed_from_manifest",
]
