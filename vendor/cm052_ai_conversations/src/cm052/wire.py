"""CM048 wire: convert a unified ``Conversation`` into the
``transcript.md + metadata.json`` pair CM048 expects, write them, and
POST the paths to the processing endpoint.

CM048's endpoint accepts paths rather than inline content. Files are
staged under ``CM052_OUTBOX_DIR`` (default
``~/.pwg/cm052/outbox/<conversation_id>/``), then the POST hands CM048
the paths. CM048 keeps the files for its own per-step state directory
under ``~/.pwg/processing/``.

The metadata payload includes the cross-repo schema additions
coordinated with CM046 Phase 3:

- ``channel``: one of ``spoken | email | im | sms | manual``
- ``provenance``: full ``ConversationProvenance`` dict – preserves
  the source-of-truth route for the (post-launch) continuation router

These fields are additive to CM048's existing metadata schema and the
endpoint already passes through unknown keys.

Dual-storage (v0.2)
-------------------

For external-LLM conversations (``provenance.source_kind ==
"external_llm"``) the wire also writes a durable, human-readable
**episodic** markdown artefact under
``OSTLER_AI_CONVERSATIONS_DIR`` (default
``~/Documents/Ostler/AI Conversations/<YYYY-MM-DD>/<conversation_id>.md``).

The mental model is semantic memory ("the fact that...") versus
episodic memory ("the conversation in which it was said"). The CM048
gist path serves the first; this artefact serves the second. The PWG
MCP ``get_conversation`` tool reads it back so any AI client with MCP
access can recover the unabridged source after a vector hit.

Human-channel conversations (iMessage / WhatsApp / email) keep the
existing CM048-tier-1 markdown under ``~/.pwg/conversations/`` and do
not pass through this episodic path. Splitting the two stores is
deliberate: different mental model, different privacy posture,
different search semantics.
"""
from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path

import httpx
import yaml

from .schemas import Conversation
from .subscription_gate import is_active_or_grace


log = logging.getLogger(__name__)


def _outbox_root() -> Path:
    raw = os.environ.get("CM052_OUTBOX_DIR") or "~/.pwg/cm052/outbox"
    return Path(raw).expanduser()


def _assistant_name() -> str:
    return os.environ.get("CM052_ASSISTANT_NAME") or "Assistant"


def _user_email() -> str:
    """Required env var; fail-fast with a config-key hint if missing.

    The hint is the env var name itself so an installer or operator
    sees exactly what to set without having to grep the codebase.
    """
    value = os.environ.get("CM052_USER_EMAIL")
    if not value:
        raise RuntimeError(
            "CM052_USER_EMAIL is not set. Set it in your environment "
            "or .env file before invoking the wire."
        )
    return value


def _cm048_endpoint() -> str:
    return (
        os.environ.get("CM052_CM048_ENDPOINT")
        or "http://localhost:8089/api/v1/conversation/process"
    )


_DEFAULT_AI_CONVERSATIONS_DIR = "~/Documents/Ostler/AI Conversations"


def _ai_conversations_root() -> Path:
    """Episodic store for AI conversations.

    Lives under ``~/Documents/`` (the user-facing zone) by default so
    Time Machine, iCloud Drive and Spotlight reach it. That visibility
    is the point -- the user can browse their AI history with Finder
    or Obsidian -- but it also means an audit pass needs to confirm
    the privacy posture matches the visible-zone expectations. Flagged
    in the v0.2 PR for Lester's next review.
    """
    raw = (
        os.environ.get("OSTLER_AI_CONVERSATIONS_DIR")
        or _DEFAULT_AI_CONVERSATIONS_DIR
    )
    return Path(raw).expanduser()


def _safe_id(value: str) -> str:
    """Make ``value`` safe to use as a filesystem name. Conversation
    ids are already short hash-like slugs, but the helper exists so a
    future adapter cannot accidentally inject a path separator.
    """
    return re.sub(r"[^A-Za-z0-9._-]", "_", value)


def _format_started_at(conv: Conversation) -> str:
    """ISO timestamp for the *first* message of the conversation, or
    ``Conversation.created_at`` if no per-message stamps exist, or
    ``last_activity`` as final fallback.
    """
    for msg in conv.messages:
        if msg.timestamp:
            return msg.timestamp
    return conv.created_at or conv.last_activity


def _format_ended_at(conv: Conversation) -> str:
    """ISO timestamp for the *last* message of the conversation, or
    ``Conversation.last_activity`` if no per-message stamps exist.
    """
    for msg in reversed(conv.messages):
        if msg.timestamp:
            return msg.timestamp
    return conv.last_activity


_VALID_LEVELS = ("L0", "L1", "L2", "L3")

# Per-artefact default privacy levels for AI conversations.
#
# AI conversations are dual-stored: a browsable episodic *transcript* artefact
# (the markdown file under the AI Conversations tree, whose level drives the
# CM044 wiki body rendering) and a *gist* (facts CM048 extracts and embeds for
# search + assistant answers, whose level drives the CM048 embed gate). Privacy
# is per-artefact so the v1.0.1 -> Option-B move is a config flip, not a
# re-plumb:
#   - Option A (v1.0.1, default): transcript=L2, gist=L2. AI conversations
#     behave like every other v1.0 source -- searchable, assistant-answerable,
#     rendered in the wiki. On a single-Mac product all L2 data is local-only.
#   - Option B (next): set transcript=L3 (file-only, body withheld in the wiki)
#     while gist stays L2 (a conservative extract stays searchable; the
#     assistant links to the private transcript). Flip the two env defaults
#     below -- no write-plumbing change.
#
# A per-conversation override (``privacy_level`` in metadata) is the user's
# escape hatch and applies to BOTH artefacts: marking a conversation L3 makes
# the transcript file-only AND short-circuits the gist, so it is invisible to
# search/assistant/wiki body while remaining a file on disk.
_ARTEFACT_DEFAULT_ENV = {
    "transcript": ("OSTLER_AI_CONV_TRANSCRIPT_PRIVACY", "L2"),
    "gist": ("OSTLER_AI_CONV_GIST_PRIVACY", "L2"),
}


def _default_privacy_level(artefact: str) -> str:
    """Configured default level for an artefact when a conversation carries no
    explicit ``privacy_level`` override.

    Reads a per-artefact env var so Option B (transcript=L3, gist=L2) is a
    config flip. Unrecognised env values fall back to the built-in default
    rather than the lowest level, so a misconfiguration cannot accidentally
    publish content that should stay private.
    """
    env_name, builtin = _ARTEFACT_DEFAULT_ENV[artefact]
    raw = os.environ.get(env_name, builtin)
    if isinstance(raw, str) and raw.upper() in _VALID_LEVELS:
        return raw.upper()
    return builtin


def _privacy_level(conv: Conversation, artefact: str = "transcript") -> str:
    """Resolve the privacy classification for one artefact of a conversation.

    Resolution order:
    1. A per-conversation override (``privacy_level`` in ``conv.metadata``)
       applies to every artefact -- this is the user's escape hatch to mark a
       sensitive conversation private (file-only).
    2. Otherwise the configured per-artefact default (``_default_privacy_level``,
       L2 for both in Option A).

    Unrecognised override values fall back to the artefact default rather than
    the lowest level, so a typo cannot accidentally publish private content.

    ``L0..L3`` are all emitted; the consumer side (CM044 renderer, MCP clients,
    CM048 embed gate) decides what to do with each level.
    """
    if artefact not in _ARTEFACT_DEFAULT_ENV:
        raise ValueError(f"unknown artefact {artefact!r}")
    raw = (
        conv.metadata.get("privacy_level")
        if isinstance(conv.metadata, dict)
        else None
    )
    if isinstance(raw, str) and raw.upper() in _VALID_LEVELS:
        return raw.upper()
    return _default_privacy_level(artefact)


def _dump_frontmatter(fm: dict) -> str:
    """Serialise the frontmatter dict to a YAML block using PyYAML's
    ``safe_dump``.

    Using the library serialiser (rather than the previous bespoke
    ``_yaml_quote`` helper) is the security-critical change: PyYAML
    escapes control characters, quotes any scalar that would otherwise
    break parsing, and produces output that round-trips identically
    under ``safe_load``. The bespoke quoter only escaped ``\\`` and
    ``"``, so an attacker-controlled string containing ``\\n`` could
    in principle inject additional YAML keys (notably overriding
    ``privacy_level``) - the "L3 newline-injection bypass" called out
    in the 2026-05-11 launch sweep. ``safe_dump`` closes that gate.

    ``sort_keys=False`` preserves the insertion-ordered keys the
    artefact contract pins (conversation_id, channel, source_app,
    privacy_level, started_at, ended_at, participants, provenance,
    name); ``allow_unicode=True`` keeps non-ASCII names readable
    rather than ``\\u`` escaped (still safe, just nicer for humans);
    ``default_flow_style=False`` forces block style for the nested
    ``provenance`` mapping and ``participants`` list.
    """
    return yaml.safe_dump(
        fm,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
    )


def render_episodic(conv: Conversation, *, user_display: str | None = None) -> str:
    """Render an external-LLM Conversation into a durable, human-
    readable markdown artefact.

    Frontmatter fields (per the dual-storage rule):

    - ``conversation_id``
    - ``provenance`` (full ConversationProvenance dict)
    - ``channel``
    - ``participants``
    - ``started_at`` / ``ended_at``
    - ``source_app`` (provenance.source_subtype)
    - ``privacy_level`` (L3 default; L0/L1/L2 also accepted via
      per-conversation metadata override)

    Body: cleaned transcript with speaker labels and per-message ISO
    timestamps when available.

    The frontmatter is serialised via PyYAML's ``safe_dump`` so any
    attacker-controlled string (notably ``Conversation.name`` from a
    shared ChatGPT export ``title``) cannot inject additional YAML
    keys. See ``_dump_frontmatter`` for the security context.
    """
    user_label = user_display or _user_email()
    assistant_label = _assistant_name()

    # Build the frontmatter as a plain dict in the contract-pinned
    # order, then hand it to safe_dump. Keys missing on the source
    # (e.g. ``name`` for conversations that did not pick up a title)
    # are simply not added so the rendered output stays tidy.
    fm: dict = {
        "conversation_id": conv.conversation_id,
        "channel": conv.channel,
        "source_app": conv.provenance.source_subtype,
        # The episodic markdown IS the transcript artefact; its level drives the
        # CM044 wiki body rendering (L3 -> body withheld).
        "privacy_level": _privacy_level(conv, "transcript"),
        "started_at": _format_started_at(conv),
        "ended_at": _format_ended_at(conv),
        "participants": list(conv.participants),
        "provenance": conv.provenance.to_dict(),
    }
    if conv.name:
        fm["name"] = conv.name

    fm_block = _dump_frontmatter(fm)
    # safe_dump always terminates the document with a newline; we
    # wrap it with the ``---`` fences a Markdown frontmatter consumer
    # expects.
    fm_text = f"---\n{fm_block}---\n"

    body_lines: list[str] = [""]
    for msg in conv.messages:
        speaker = _speaker_label(msg.role, user_label, assistant_label)
        ts_suffix = f" _({msg.timestamp})_" if msg.timestamp else ""
        body_lines.append(f"**{speaker}:**{ts_suffix} {msg.content}".rstrip())
        body_lines.append("")

    return fm_text + "\n".join(body_lines)


def episodic_path(conv: Conversation, root: Path | None = None) -> Path:
    """Return the path the episodic artefact for ``conv`` would (or
    does) live at, without writing.

    Used both by ``stage_episodic`` (writer) and the PWG MCP
    ``get_conversation`` reader so the two sides agree on layout.
    """
    base = root or _ai_conversations_root()
    date_part = _format_started_at(conv)[:10] or "unknown"
    return base / date_part / f"{_safe_id(conv.conversation_id)}.md"


def stage_episodic(
    conv: Conversation, root: Path | None = None
) -> Path:
    """Write the episodic markdown artefact for an external-LLM
    Conversation.

    Returns the artefact path. Idempotent: re-running for the same
    ``conversation_id`` overwrites the file; the directory layout
    (``<YYYY-MM-DD>/<conversation_id>.md``) is deterministic from
    the conversation's first-message timestamp.

    Raises ``ValueError`` if the conversation is not an external-LLM
    source -- human-channel conversations live in CM048's tier-1
    markdown store, not here.
    """
    if conv.provenance.source_kind != "external_llm":
        raise ValueError(
            "stage_episodic only persists external_llm conversations; "
            f"got source_kind={conv.provenance.source_kind!r}"
        )
    target = episodic_path(conv, root=root)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(render_episodic(conv), encoding="utf-8")
    return target


def _speaker_label(role: str, user_display: str, assistant_display: str) -> str:
    if role == "user":
        return user_display
    if role == "assistant":
        return assistant_display
    return role.capitalize()


def render_transcript(conv: Conversation, user_display: str | None = None) -> str:
    """Render a Conversation into a CM048-compatible transcript.md.

    The body is a flat speaker-labelled list – CM048's classifier and
    enrichment prompts already work against this shape from the
    in-person fixtures. ``user_display`` defaults to the configured
    user email since that's the most reliable identifier we have at
    launch; the Companion can refine when speaker resolution lands.
    """
    user_label = user_display or _user_email()
    assistant_label = _assistant_name()

    fm_lines = [
        "---",
        f"conversation_id: {conv.conversation_id}",
        f"date: {(conv.created_at or conv.last_activity)[:10]}",
        f"source: {conv.provenance.source_subtype}",
        f"channel: {conv.channel}",
    ]
    if conv.name:
        fm_lines.append(f"name: {json.dumps(conv.name)}")
    fm_lines.append("---")
    fm_lines.append("")

    body_lines: list[str] = []
    for msg in conv.messages:
        speaker = _speaker_label(msg.role, user_label, assistant_label)
        body_lines.append(f"**{speaker}:** {msg.content}")
        body_lines.append("")

    return "\n".join(fm_lines + body_lines)


def render_metadata(conv: Conversation) -> dict:
    """Render a Conversation into the metadata.json CM048 expects.

    Adds the seven-field cross-repo additions:

    - ``channel`` (CM046 Phase 3 + CM052)
    - ``provenance`` (CM052 only; CM046 sets it to a no-op for email)
    - ``participant_kind`` derived from
      ``provenance.source_kind``: ``external_llm`` -> ``"ai"``,
      anything else -> ``"human"``. Lets CM048's downstream
      classifier and confidence-floor logic differentiate AI vs
      human conversations without re-parsing provenance.
    """
    participant_kind = (
        "ai" if conv.provenance.source_kind == "external_llm" else "human"
    )
    return {
        "conversation_id": conv.conversation_id,
        "date": (conv.created_at or conv.last_activity)[:10],
        "source": conv.provenance.source_subtype,
        "channel": conv.channel,
        "participant_kind": participant_kind,
        # The CM048-bound metadata carries the *gist* level: CM048 embeds the
        # extracted facts at this level (L2 -> searchable + assistant-answerable;
        # L3 is short-circuited before POST so it never reaches here).
        "privacy_level": _privacy_level(conv, "gist"),
        "participants": [
            {"id": p, "display": p, "role": "other"} for p in conv.participants
        ],
        "provenance": conv.provenance.to_dict(),
        "extra": dict(conv.metadata),
    }


def stage(conv: Conversation, outbox_root: Path | None = None) -> tuple[Path, Path]:
    """Write transcript.md + metadata.json to the outbox and return
    their paths."""
    root = (outbox_root or _outbox_root()) / conv.conversation_id
    root.mkdir(parents=True, exist_ok=True)
    transcript_path = root / "transcript.md"
    metadata_path = root / "metadata.json"
    transcript_path.write_text(render_transcript(conv), encoding="utf-8")
    metadata_path.write_text(
        json.dumps(render_metadata(conv), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return transcript_path, metadata_path


def post(
    conv: Conversation,
    *,
    outbox_root: Path | None = None,
    endpoint: str | None = None,
    timeout: float = 30.0,
    episodic_root: Path | None = None,
) -> dict:
    """Stage the CM048 transcript pair, optionally persist the episodic
    artefact, and POST the paths to CM048.

    Dual-storage rule: for ``external_llm`` provenance the wire writes
    a second copy under ``OSTLER_AI_CONVERSATIONS_DIR`` so PWG MCP
    ``get_conversation`` can return the unabridged source after a
    vector hit. Episodic write failures are logged but do not block
    the CM048 fact-extraction path -- the gist path is still the
    reliable one downstream consumers depend on.

    L3 short-circuit (Lester audit lift, 2026-05-08): a conversation
    classified ``privacy_level: L3`` does NOT POST to CM048. CM048's
    pipeline embeds extracted facts into Qdrant for vector search;
    embedding L3 content would defeat the "private by default"
    contract -- the only way to read back an L3 fact would still be
    via the gist tools, which is exactly what we don't want for
    private content. Episodic still lands (so the user can browse
    and the MCP boundary can re-fetch with explicit opt-in).

    Returns CM048's JSON response when the gist arm runs (typically
    ``{"job_id": "...", "status": "queued"}``), or a synthesised
    short-circuit dict ``{"status": "skipped", "reason":
    "privacy_level_l3", ...}`` when L3 prevents the POST. Raises
    ``httpx.HTTPError`` on transport failure; the caller decides
    retry policy.

    Subscription gate (G7): conversation-memory processing pauses when
    the customer's subscription is neither ``active`` nor within either
    grace window (live 14-day post-lapse grace, or 30-day offline-
    validation grace). The wire short-circuits with a synthesised
    ``{"status": "paused", "reason": "subscription_inactive", ...}``
    response before staging any files. The episodic artefact is also
    held back: dual-storage is part of ongoing intelligence and pauses
    with the rest. The conversation itself is not lost -- the source
    JSONL / leveldb / export still exists on disk, and the next
    invocation after reactivation will re-process it. The Apple-
    restraint posture is enforced upstream by
    ``subscription_gate.is_active_or_grace`` (fail-open on offline
    validation, never lock the customer out on infrastructure failure
    we cannot observe).
    """
    if not is_active_or_grace():
        log.info(
            "Subscription inactive -- pausing conversation-memory "
            "processing. New conversations will resume on "
            "reactivation. conversation_id=%s",
            conv.conversation_id,
        )
        return {
            "status": "paused",
            "reason": "subscription_inactive",
            "conversation_id": conv.conversation_id,
        }
    transcript_path, metadata_path = stage(conv, outbox_root=outbox_root)
    episodic_target: Path | None = None
    if conv.provenance.source_kind == "external_llm":
        try:
            episodic_target = stage_episodic(conv, root=episodic_root)
        except Exception as exc:
            # The gist path (CM048 POST below) is the reliable one
            # downstream consumers depend on. The episodic artefact
            # is "best-effort durable" -- a render bug, a permission
            # surprise on the visible-zone path, an unexpected
            # frontmatter shape, anything at all -- must not block
            # fact extraction. Broad except + exc_info so the
            # operator gets a real traceback to diagnose without
            # losing the conversation in CM048.
            log.warning(
                "Episodic write failed for %s: %s",
                conv.conversation_id,
                exc,
                exc_info=True,
            )
    # The CM048 POST embeds the *gist* (extracted facts) for vector search, so
    # the gist level gates it. Option A: gist defaults L2 -> POST happens. A
    # per-conversation L3 override (or Option B keeping gist L2) is respected
    # here. Episodic (the transcript artefact) still landed above regardless.
    gist_level = _privacy_level(conv, "gist")
    if gist_level == "L3":
        log.info(
            "L3 short-circuit: skipping CM048 POST for %s "
            "(episodic artefact still landed at %s)",
            conv.conversation_id,
            episodic_target if episodic_target else "<not external_llm>",
        )
        return {
            "status": "skipped",
            "reason": "privacy_level_l3",
            "conversation_id": conv.conversation_id,
            "episodic_path": (
                str(episodic_target) if episodic_target else None
            ),
        }
    payload = {
        "transcript_path": str(transcript_path),
        "metadata_path": str(metadata_path),
    }
    url = endpoint or _cm048_endpoint()
    with httpx.Client(timeout=timeout) as client:
        response = client.post(url, json=payload)
        response.raise_for_status()
        return response.json()
