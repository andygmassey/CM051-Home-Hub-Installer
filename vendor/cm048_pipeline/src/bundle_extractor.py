"""Bundle-extraction LLM call: turn an enriched transcript into a
summary + topics + todos triple.

The four-artefact human-conversation contract (HR015 2026-05-09)
needs three pieces of structured content beyond the existing
fact/signal extraction:

    overall_summary  3-5 sentence elevator pitch
    topics           1-7 named topic blocks, each with 3-10 points
    todos            extracted commitments with owner/deadline

This module produces those via a single Ollama call against the
existing ``ollama_enrich_model``. Existing fact/signal/coach
extraction is unchanged -- this is an additive step in the
pipeline, not a replacement.

Channel-aware: a single prompt template with source-conditional
sections covers meeting / iMessage / WhatsApp / email. Per the
HR015 brief: "One prompt template with source-conditional
sections is fine; four separate prompts is overkill." The
per-channel adapters (``channel_adapter.py``) decide which
section labels to interpolate, but every channel calls into the
same extractor here.

The extractor returns a structured dict the channel adapter
turns into a ``ConversationBundle``. The dict shape is locked
because it is persisted as ``07a_bundle.json`` in the per-
conversation state dir for resumability -- the LLM call is not
re-run on a partial pipeline restart.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from . import prompts
from .ollama_client import OllamaClient


logger = logging.getLogger(__name__)


# The five channel labels the extractor knows about. The slot is
# free-form so a future adapter can register a new channel without
# re-versioning, but unknown values fall back to "spoken" guidance
# rather than no guidance at all -- a missing channel hint is a
# bug, not a deliberate signal.
_KNOWN_CHANNELS = ("spoken", "im", "email", "whatsapp", "manual")


@dataclass(frozen=True)
class BundleExtraction:
    """Structured output of the bundle-extraction LLM call.

    Plain dicts/lists -- not the channel-adapter's
    ``ConversationSummary`` / ``Todo`` types -- because this layer
    is the parse-and-validate boundary. The adapter converts to
    the shared writer's frozen dataclasses.
    """

    overall_summary: str
    topics: list[dict] = field(default_factory=list)
    todos: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "overall_summary": self.overall_summary,
            "topics": [dict(t) for t in self.topics],
            "todos": [dict(t) for t in self.todos],
        }

    @classmethod
    def from_dict(cls, data: dict) -> "BundleExtraction":
        return cls(
            overall_summary=str(data.get("overall_summary", "")).strip(),
            topics=list(data.get("topics") or []),
            todos=list(data.get("todos") or []),
        )


def extract(
    client: OllamaClient,
    *,
    transcript: str,
    enrichment_md: str,
    channel: str,
    model: str,
    locale: str = "en-GB",
    timeout: float | None = None,
) -> BundleExtraction:
    """Run the LLM call and return parsed ``BundleExtraction``.

    ``transcript`` is the raw cleaned transcript (with speaker
    labels). ``enrichment_md`` is step 02's output, used as a
    seed for topic discovery so the bundle and the existing
    enrichment don't diverge on what the conversation was about.

    Channel guidance is interpolated into the prompt template;
    unknown channels fall back to spoken guidance (the most
    permissive of the four since it doesn't strip channel-
    specific noise the model wouldn't otherwise expect).

    Raises ``RuntimeError`` if the model returns no parseable
    JSON -- the caller (a pipeline step runner) is responsible
    for the auto-retry-once contract.
    """
    if channel not in _KNOWN_CHANNELS:
        logger.warning(
            "Unknown channel %r; falling back to spoken guidance",
            channel,
        )
        channel_for_prompt = "spoken"
    else:
        channel_for_prompt = channel

    template = prompts.load_prompt("09_bundle_extract")
    body = _build_input(
        transcript=transcript,
        enrichment_md=enrichment_md,
        channel=channel_for_prompt,
        locale=locale,
    )
    full_prompt = template + "\n\n---\n\n" + body

    result = client.generate(
        model=model,
        prompt=full_prompt,
        temperature=0.2,
        format_json=True,
        priority="medium",
        timeout=timeout,
    )

    parsed = _parse_json(result.raw_response)
    if parsed is None:
        raise RuntimeError(
            "Bundle extractor returned no parseable JSON; "
            f"raw_response_len={len(result.raw_response)}"
        )

    extraction = BundleExtraction.from_dict(parsed)
    if not extraction.overall_summary:
        # A defensible default rather than crashing -- a 4-artefact
        # bundle without a summary still has the transcript + todos,
        # both of which are recoverable.
        logger.warning(
            "Bundle extractor returned empty overall_summary; "
            "leaving as empty string for fallback rendering"
        )
    return extraction


# ---------------------------------------------------------------------------
# Prompt-input builder
# ---------------------------------------------------------------------------


_CHANNEL_GUIDANCE: dict[str, str] = {
    "spoken": (
        "Source: spoken conversation transcript (meeting, call, voice "
        "memo). Whisper-style transcripts may include filler words "
        "('um', 'uh', repeats); strip them when writing topic points. "
        "Speaker labels look like '**Andrew:**' or '**Speaker 1:**'. "
        "Multiple speakers per topic is normal; attribute todos to "
        "the speaker who committed."
    ),
    "im": (
        "Source: instant-messaging thread (iMessage / SMS). Messages "
        "are short; reactions ('Liked', 'Loved', emoji) are inline "
        "noise; URL previews and 'sent a photo' markers are not "
        "content. Threads can run for days with time gaps -- a topic "
        "shift after a long gap is normal."
    ),
    "email": (
        "Source: email thread. Quoted prior-thread text under '> ' "
        "or below 'On <date>, <name> wrote:' is context, NOT new "
        "content -- summarise only the most recent author's content "
        "unless explicitly asked. Signature blocks below '-- ' or "
        "after '\\n--\\n' are noise."
    ),
    "whatsapp": (
        "Source: WhatsApp chat (one-on-one or group). Group chats "
        "may have many participants -- attribute todos by "
        "participant. '(media omitted)', '<sticker>', "
        "'<voice note>' markers are not content. Quoted-reply "
        "context appears as '> previous message' on its own line."
    ),
    "manual": (
        "Source: manually-pasted conversation (testing fixture or "
        "import). Treat speaker labels as authoritative; no "
        "channel-specific noise patterns expected."
    ),
}


def _build_input(
    *,
    transcript: str,
    enrichment_md: str,
    channel: str,
    locale: str,
) -> str:
    """Render the per-call body that gets appended to the prompt
    template. The template itself is static instructions; this
    function fills in the conversation-specific data and the
    channel guidance."""
    guidance = _CHANNEL_GUIDANCE.get(channel, _CHANNEL_GUIDANCE["spoken"])
    enrichment_excerpt = (enrichment_md or "").strip()
    if len(enrichment_excerpt) > 4000:
        enrichment_excerpt = enrichment_excerpt[:4000] + "\n\n[...truncated]"
    transcript_excerpt = transcript or ""
    if len(transcript_excerpt) > 12000:
        transcript_excerpt = transcript_excerpt[:12000] + "\n\n[...truncated]"

    return (
        f"--- CHANNEL ---\n{channel}\n\n"
        f"--- CHANNEL GUIDANCE ---\n{guidance}\n\n"
        f"--- LOCALE ---\n{locale}\n\n"
        f"--- ENRICHMENT (for topic seeding) ---\n{enrichment_excerpt}\n\n"
        f"--- TRANSCRIPT ---\n{transcript_excerpt}\n"
    )


# ---------------------------------------------------------------------------
# JSON parser (mirrors processor.py's robust pattern)
# ---------------------------------------------------------------------------


def _parse_json(raw: str) -> dict | None:
    """Find and parse the first JSON object in ``raw``.

    Mirrors the Ollama-response cleanup pattern processor.py uses
    elsewhere: strip ``<think>`` blocks the model may emit, then
    locate the first balanced ``{...}`` block and json.loads it.
    Returns ``None`` if no parseable object is found.
    """
    import json as _json
    import re as _re

    # Strip <think>...</think> blocks (qwen3.5 sometimes emits them
    # despite think=False).
    cleaned = _re.sub(
        r"<think>.*?</think>", "", raw, flags=_re.DOTALL
    )

    start = cleaned.find("{")
    if start == -1:
        return None
    depth = 0
    in_string = False
    escape = False
    for idx in range(start, len(cleaned)):
        ch = cleaned[idx]
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                candidate = cleaned[start:idx + 1]
                try:
                    parsed = _json.loads(candidate)
                    if isinstance(parsed, dict):
                        return parsed
                except _json.JSONDecodeError:
                    return None
                return None
    return None


__all__ = ["BundleExtraction", "extract"]
