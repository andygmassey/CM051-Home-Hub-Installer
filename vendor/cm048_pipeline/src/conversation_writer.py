"""Shared writer for the four-artefact human-conversation bundle.

Every human-to-human conversation (iMessage / WhatsApp / email
thread / meeting transcript / voice note) lands as a folder under
``~/Documents/Ostler/Conversations/<YYYY-MM-DD>/<slug>-<short-id>/``
with three markdown artefacts inside:

    summary.md      Overall summary + per-topic breakdown.
    transcript.md   Cleaned transcript with speaker labels.
    todos.md        Extracted commitments with owner / deadline /
                    source-anchor / status.

Frontmatter on every artefact carries the cross-reference
metadata (``conversation_id``, ``source_kind``, ``channel``,
``participants``, ``started_at`` / ``ended_at``, ``privacy_level``,
``source_session_id``, ``source_app``). The fourth "artefact" --
metadata -- is folded into the per-file frontmatter rather than a
separate file, so any single artefact is self-describing for an
out-of-band consumer (Spotlight, iCloud-Drive search, an export).

L3 short-circuit (mirrors CM052 wire 2026-05-08 PR #3): a bundle
with ``privacy_level == "L3"`` writes the markdown artefacts to
disk but does NOT call the gist callback. Embedding L3 facts into
Qdrant / Oxigraph would defeat the "private by default" contract:
the only way to read back an L3 fact would still be via the gist
tools, the same surface a casual browse hits. Episodic markdown
still lands so the user can browse it and PWG MCP
``get_conversation`` can opt in via ``request_unredacted=True``.

Decoupling: the writer does NOT know how to call the gist arm.
The caller injects ``gist_post_fn`` -- typically a small adapter
that POSTs to CM048's existing endpoint or invokes the in-process
``ingest.write_all`` path. Tests can pass a stub. Per-source
pipelines (CM040 / CM046 / CM047 / CM042) wire their own
gist callbacks in their respective lift PRs.

EventKit / Apple Reminders push: out of scope for this module;
covered in a follow-up PR. The ``Todo.status`` field is set to
``"extracted"`` here and the next PR adds a Reminders-pushing
helper that flips it to ``"pushed-to-reminders"`` once
``EKEventStore`` confirms the save.
"""
from __future__ import annotations

import dataclasses
import hashlib
import logging
import os
import re
import textwrap
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

from . import copy as _copy
from . import ostler_paths
from . import reminders_push


log = logging.getLogger(__name__)


_VALID_PRIVACY_LEVELS = ("L0", "L1", "L2", "L3")


# ---------------------------------------------------------------------------
# Bundle dataclasses
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Topic:
    """One topic block inside the per-conversation summary.

    Each topic groups 3-10 points extracted from the transcript.
    Points are short prose bullets, not raw quotes -- the
    ``transcript.md`` file is where quotes live.
    """

    name: str
    points: tuple[str, ...]


@dataclass(frozen=True)
class Todo:
    """One extracted commitment from the conversation.

    ``owner`` is whose responsibility the action is. Free-form to
    cope with multi-party conversations; convention is the
    participant id from ``ConversationBundle.participants`` or one
    of the literals ``"user"`` / ``"other"`` / ``"both"``.

    ``deadline`` is ISO-8601 if explicitly stated or confidently
    inferred (e.g. "by Friday"). ``None`` when no deadline can be
    extracted -- the wiki todos wing surfaces these as "no
    deadline" rather than fabricating one.

    ``source_anchor`` is a free-form string that points back to
    the originating moment in the transcript. Format depends on
    source: ``"L42"`` for line offsets, ``"2026-05-08T14:32:00Z"``
    for timestamped capture, ``"msg:abc123"`` for a stable message
    id. The wiki renderer treats it as opaque.

    ``status`` flips through:
        ``extracted``         -- writer's default; on disk only
        ``pushed-to-reminders`` -- EventKit save confirmed
        ``dismissed``         -- user marked irrelevant

    The id is stable across re-runs of the same conversation
    (derived from owner + text hash) so an Apple Reminders push
    can be idempotent.
    """

    id: str
    text: str
    owner: str
    deadline: Optional[str] = None
    source_anchor: Optional[str] = None
    status: str = "extracted"


@dataclass(frozen=True)
class ConversationSummary:
    """Structured summary that becomes ``summary.md``.

    ``overall`` is 3-5 sentences -- the elevator pitch a human
    skims. ``topics`` is the deeper read; 1-7 topics typically,
    each with its own bullet list of points.
    """

    overall: str
    topics: tuple[Topic, ...]


@dataclass(frozen=True)
class ConversationBundle:
    """Everything a per-source pipeline needs to hand the writer.

    The four-artefact spec is emitted from this single bundle:
    summary -> ``summary.md``, raw rendered transcript ->
    ``transcript.md``, todos -> ``todos.md``, the rest of the
    fields land as YAML frontmatter on every file.

    ``conversation_id`` MUST be stable across re-runs of the same
    conversation -- the writer keys idempotency off it (folder
    slug, todo ids if they fall back to the conversation id).
    Source pipelines typically derive it from the source's own
    stable session id (iMessage chat id + first-message
    timestamp; email Message-Id; meeting recording uuid; etc.).

    ``privacy_level`` defaults to ``"L2"`` (personal but not all-
    private) which is the right choice for the bulk of human
    conversations. iMessage / WhatsApp / email pipelines should
    override per-message-context (e.g. legal sender domain ->
    L3, marketing -> L1) per the brief. A typo or unrecognised
    value here falls back to L3 at write time so a malformed
    bundle cannot silently downgrade to public.
    """

    conversation_id: str
    source_kind: str  # "channel" | "external_llm" | "spoken" | etc
    source_subtype: str  # "imessage" | "whatsapp" | "email" | "meeting"
    source_session_id: str
    channel: str  # "im" | "email" | "spoken" | "manual" | etc
    participants: tuple[str, ...]
    started_at: str  # ISO 8601
    ended_at: str
    summary: ConversationSummary
    transcript: str
    todos: tuple[Todo, ...] = ()
    privacy_level: str = "L2"
    source_app: Optional[str] = None  # "messages" | "mail" | "whatsapp" | etc
    extra_metadata: dict = field(default_factory=dict)


@dataclass(frozen=True)
class ConversationOutput:
    """Result of a write. Returned to the caller so it can log,
    feed downstream consumers, or pass to a follow-up Reminders
    push.

    ``gist_status`` is one of:
        ``queued``     gist callback was invoked successfully
        ``skipped``    gist callback was not called (L3 or no
                       callback supplied)
        ``error``      gist callback raised; the markdown bundle
                       is still on disk -- gist failures must
                       NOT abort the episodic side
    """

    folder: Path
    summary_path: Path
    transcript_path: Path
    todos_path: Path
    privacy_level: str
    gist_status: str
    gist_reason: Optional[str] = None
    gist_response: Optional[dict] = None


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------


GistPostFn = Callable[[ConversationBundle, "ConversationOutput"], dict]


def write_conversation(
    bundle: ConversationBundle,
    *,
    root: Optional[Path] = None,
    gist_post_fn: Optional[GistPostFn] = None,
    demo_mode: bool = False,
    user_id: str = "user",
    reminders_db_path: Optional[Path] = None,
) -> ConversationOutput:
    """Produce the four-artefact bundle on disk and (for non-L3)
    invoke the gist callback.

    ``root`` defaults to ``~/Documents/Ostler/Conversations`` via
    ``ostler_paths.conversations_dir()``. Tests should pass a
    ``tmp_path`` to keep filesystem effects sandboxed.

    ``gist_post_fn`` is the per-source pipeline's adapter: takes
    the bundle and the partially-built output (folder + paths
    populated, gist_status not yet set) and returns the gist
    arm's response dict. It is NOT called when:

      - ``privacy_level`` is ``"L3"`` (L3 privacy contract)
      - ``gist_post_fn`` is ``None`` (e.g. unit tests, manual
        ingests, dry-runs)

    When the callback raises, the markdown bundle stays on disk
    (it's already written by then) and the returned
    ``ConversationOutput`` reports ``gist_status="error"`` with
    the exception class name as ``gist_reason``. The writer
    deliberately does NOT re-raise -- the episodic arm is the
    reliable side downstream consumers depend on, mirroring
    CM052 wire's exception broadening.

    EventKit / Apple Reminders push (writer side, 2026-05-09):
    todos that pass the privacy + owner gate are upserted into the
    reminders mapping DB at ``reminders_db_path`` (default
    ``~/.ostler/reminders_map.db``). The actual EKEventStore call
    lives in ``ostler-assistant`` (signed Apple Silicon binary,
    follow-up PR). On re-runs, todos already pushed by the
    assistant get their in-memory ``status`` flipped to
    ``"pushed-to-reminders"`` so the rendered ``todos.md``
    reflects the real state and the CM044 wiki "Reminders" pill
    shows correctly. ``demo_mode=True`` short-circuits the entire
    push pipeline.
    """
    privacy_level = _normalise_privacy_level(bundle.privacy_level)
    folder = _resolve_folder(bundle, root=root)
    folder.mkdir(parents=True, exist_ok=True)

    summary_path = folder / "summary.md"
    transcript_path = folder / "transcript.md"
    todos_path = folder / "todos.md"

    frontmatter = _render_frontmatter(bundle, privacy_level)

    _atomic_write(
        summary_path,
        frontmatter + _render_summary_body(bundle.summary),
    )
    _atomic_write(
        transcript_path,
        frontmatter + _render_transcript_body(bundle),
    )

    # Run the push gate just before todos.md is rendered so any
    # ``pushed-to-reminders`` flips that the assistant performed on
    # a previous sweep land in the rendered file. Demo mode skips
    # this step (and never opens the mapping DB).
    todos_for_render = reminders_push.apply_push_status_to_todos(
        bundle.todos,
        bundle,
        summary_path=summary_path,
        demo_mode=demo_mode,
        user_id=user_id,
        db_path=reminders_db_path,
    )
    _atomic_write(
        todos_path,
        frontmatter + _render_todos_body(todos_for_render),
    )

    output = ConversationOutput(
        folder=folder,
        summary_path=summary_path,
        transcript_path=transcript_path,
        todos_path=todos_path,
        privacy_level=privacy_level,
        gist_status="skipped",
        gist_reason=None,
        gist_response=None,
    )

    if privacy_level == "L3":
        log.info(
            "L3 short-circuit: skipping gist arm for %s (episodic "
            "artefacts at %s)",
            bundle.conversation_id,
            folder,
        )
        return dataclasses.replace(
            output, gist_status="skipped", gist_reason="privacy_level_l3"
        )

    if gist_post_fn is None:
        log.debug(
            "No gist_post_fn supplied for %s; episodic-only write",
            bundle.conversation_id,
        )
        return dataclasses.replace(
            output, gist_status="skipped", gist_reason="no_gist_callback"
        )

    try:
        response = gist_post_fn(bundle, output)
    except Exception as exc:  # noqa: BLE001 -- broad-except by design
        log.warning(
            "Gist callback failed for %s: %s",
            bundle.conversation_id,
            exc,
            exc_info=True,
        )
        return dataclasses.replace(
            output,
            gist_status="error",
            gist_reason=type(exc).__name__,
        )

    return dataclasses.replace(
        output,
        gist_status="queued",
        gist_reason=None,
        gist_response=response,
    )


# ---------------------------------------------------------------------------
# Privacy level + folder resolution
# ---------------------------------------------------------------------------


def _normalise_privacy_level(value: str) -> str:
    """Coerce the bundle's privacy_level to a known L0..L3.

    A typo / unknown value falls back to L3 -- defence in depth
    so a malformed bundle cannot silently downgrade to public.
    Mirrors the same pattern in CM052 wire and PWG MCP
    get_conversation.
    """
    if isinstance(value, str) and value.upper() in _VALID_PRIVACY_LEVELS:
        return value.upper()
    log.warning(
        "Unknown privacy_level %r; defaulting to L3", value
    )
    return "L3"


_SLUG_KEEP_RE = re.compile(r"[^a-z0-9]+")


def _slug_segment(text: str, max_len: int = 32) -> str:
    """Filesystem-safe slug from free-form text.

    Lower-case, hyphen-separated, no path separators, capped to
    ``max_len`` chars to keep folder names readable. Returns
    ``"conversation"`` for empty / all-symbol inputs so the
    caller never has to handle ``""``.
    """
    cleaned = _SLUG_KEEP_RE.sub("-", text.lower()).strip("-")
    if not cleaned:
        return "conversation"
    return cleaned[:max_len].rstrip("-") or "conversation"


def _short_id(conversation_id: str, length: int = 8) -> str:
    """Stable short hex id derived from ``conversation_id``.

    Used as the disambiguator suffix in ``<slug>-<short-id>/``.
    Two conversations with the same human slug (e.g. two iMessage
    threads with the same participant) get distinct folders.
    """
    digest = hashlib.sha1(conversation_id.encode("utf-8")).hexdigest()
    return digest[:length]


def _resolve_folder(
    bundle: ConversationBundle, *, root: Optional[Path]
) -> Path:
    """Return ``<root>/<YYYY-MM-DD>/<slug>-<short-id>/``.

    ``root`` defaults to the user-facing
    ``~/Documents/Ostler/Conversations`` path. The slug is
    derived from the FULL participant list (including the user-
    side label) so multi-user installs -- e.g. a Hub Mac shared
    by two iCloud accounts -- preserve the user axis in the
    path. The short id keeps it unique even when two
    conversations have identical participants. (2026-05-09 PR
    review feedback: do not strip ``user`` from the slug.)
    """
    base = root if root is not None else ostler_paths.conversations_dir()
    date_part = (bundle.started_at or "")[:10] or "unknown"
    slug_source = "-".join(p for p in bundle.participants if p) or "conversation"
    slug = _slug_segment(slug_source)
    folder_name = f"{slug}-{_short_id(bundle.conversation_id)}"
    return base / date_part / folder_name


# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------


def _atomic_write(path: Path, text: str) -> None:
    """Write ``text`` to ``path`` atomically.

    Sequence: write body to ``<path>.tmp``, ``fsync`` the temp
    file's contents, then ``rename`` over the destination.
    A crash between any of those steps leaves either the prior
    contents intact (no temp file written or the rename never
    fired) or the new contents fully on disk -- never a half-
    written ``summary.md`` that callers would parse and then
    error on.
    """
    tmp = path.with_name(path.name + ".tmp")
    encoded = text.encode("utf-8")
    fd = os.open(
        tmp,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        0o644,
    )
    try:
        os.write(fd, encoded)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, path)


# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------


def _yaml_quote(value: str) -> str:
    """Quote a YAML scalar that may contain awkward characters.

    Mirrors CM052 wire's helper -- we keep the output to plain
    double-quoted strings rather than introducing a YAML
    dependency. The two parsers (CM048 here, CM052 wire, PWG MCP
    get_conversation, CM044 ai_conversation_pages) are
    intentionally independent so a version drift in one repo
    cannot silently break the others.
    """
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _render_frontmatter(
    bundle: ConversationBundle, privacy_level: str
) -> str:
    """YAML frontmatter shared by all three artefacts.

    Folding metadata in here (rather than a separate
    ``metadata.md``) means each file is self-describing: an
    out-of-band consumer (Spotlight, an export, a future agent
    that finds one of the files in isolation) can identify the
    conversation without needing the sibling files.
    """
    lines: list[str] = ["---"]
    lines.append(f"conversation_id: {_yaml_quote(bundle.conversation_id)}")
    lines.append(f"source_kind: {_yaml_quote(bundle.source_kind)}")
    lines.append(f"source_subtype: {_yaml_quote(bundle.source_subtype)}")
    lines.append(
        f"source_session_id: {_yaml_quote(bundle.source_session_id)}"
    )
    if bundle.source_app:
        lines.append(f"source_app: {_yaml_quote(bundle.source_app)}")
    lines.append(f"channel: {_yaml_quote(bundle.channel)}")
    lines.append(f"started_at: {_yaml_quote(bundle.started_at)}")
    lines.append(f"ended_at: {_yaml_quote(bundle.ended_at)}")
    lines.append(f"privacy_level: {privacy_level}")
    lines.append("participants:")
    for participant in bundle.participants:
        lines.append(f"  - {_yaml_quote(participant)}")
    if bundle.extra_metadata:
        lines.append("extra:")
        for key, value in sorted(bundle.extra_metadata.items()):
            if value is None:
                lines.append(f"  {key}: null")
            elif isinstance(value, bool):
                lines.append(
                    f"  {key}: {'true' if value else 'false'}"
                )
            elif isinstance(value, (int, float)):
                lines.append(f"  {key}: {value}")
            else:
                lines.append(f"  {key}: {_yaml_quote(str(value))}")
    lines.append("---")
    lines.append("")
    return "\n".join(lines) + "\n"


def _render_summary_body(summary: ConversationSummary) -> str:
    lines: list[str] = [_copy.SUMMARY_HEADING, ""]
    overall = summary.overall.strip()
    if overall:
        lines.append(overall)
        lines.append("")
    if summary.topics:
        lines.append(_copy.TOPICS_HEADING)
        lines.append("")
        for topic in summary.topics:
            heading = topic.name.strip() or _copy.TOPIC_FALLBACK_NAME
            lines.append(f"### {heading}")
            lines.append("")
            for point in topic.points:
                point_clean = point.strip()
                if point_clean:
                    lines.append(f"- {point_clean}")
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _render_transcript_body(bundle: ConversationBundle) -> str:
    transcript = bundle.transcript.rstrip()
    if not transcript:
        return (
            f"{_copy.TRANSCRIPT_HEADING}\n\n"
            f"{_copy.TRANSCRIPT_EMPTY_PLACEHOLDER}\n"
        )
    return f"{_copy.TRANSCRIPT_HEADING}\n\n" + transcript + "\n"


def _render_todos_body(todos: tuple[Todo, ...]) -> str:
    if not todos:
        return (
            f"{_copy.TODOS_HEADING}\n\n"
            f"{_copy.TODOS_EMPTY_PLACEHOLDER}\n"
        )
    lines: list[str] = [_copy.TODOS_HEADING, ""]
    for todo in todos:
        bits: list[str] = [todo.text.strip() or _copy.TODO_EMPTY_TEXT_PLACEHOLDER]
        bits.append(f"owner: {todo.owner}")
        if todo.deadline:
            bits.append(f"deadline: {todo.deadline}")
        if todo.source_anchor:
            bits.append(f"anchor: {todo.source_anchor}")
        bits.append(f"status: {todo.status}")
        bits.append(f"id: {todo.id}")
        lines.append("- " + " | ".join(bits))
    return "\n".join(lines).rstrip() + "\n"


# ---------------------------------------------------------------------------
# Stable todo id helper (re-exported for source pipelines that build
# Todo objects on extraction)
# ---------------------------------------------------------------------------


def make_todo_id(conversation_id: str, owner: str, text: str) -> str:
    """Derive a stable, idempotent todo id.

    Re-runs of the same conversation produce the same id for the
    same (conversation, owner, text) triple, so a future Apple
    Reminders push won't create duplicate reminders.
    """
    payload = f"{conversation_id}\x1f{owner}\x1f{text.strip()}"
    digest = hashlib.sha1(payload.encode("utf-8")).hexdigest()
    return f"todo-{digest[:12]}"


__all__ = [
    "ConversationBundle",
    "ConversationOutput",
    "ConversationSummary",
    "Topic",
    "Todo",
    "GistPostFn",
    "make_todo_id",
    "write_conversation",
]
