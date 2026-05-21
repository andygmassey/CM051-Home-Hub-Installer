"""Per-channel adapter that converts CM048 pipeline state into a
``ConversationBundle`` for the shared writer.

Architecture (HR015 2026-05-09 directive A): all four per-source
lifts (CM042 meetings, CM040 iMessage, CM046 email, CM047 WhatsApp)
land inside CM048 rather than in their respective source repos.
The "shared writer" stays exactly where the existing fact writer
lives and the per-channel cleverness becomes a registry here.

The registry pattern keeps each channel's translation logic
isolated and reviewable in its own PR. This PR (CM042 meetings-
bundle) ships the spoken/meeting adapter; the iMessage / email /
WhatsApp adapters land in their respective follow-up PRs.

Each adapter is a function that receives:

  - the parsed metadata (date, source, participants, channel, etc.)
  - the parsed Classification (output of step 01)
  - the BundleExtraction (output of the new bundle-extract step)
  - an optional explicit privacy_level override

and returns a ``ConversationBundle`` ready to hand to
``conversation_writer.write_conversation``. The bundle's
``conversation_id``, ``source_kind``, ``source_subtype`` etc.
are populated per channel; the privacy level is inferred via
``privacy.infer`` unless overridden.

Channels not yet implemented raise ``NotImplementedError`` with a
pointer to the follow-up PR. The registry-and-NotImplementedError
pattern matches CM052's adapter scaffold (post-launch stubs at
v0.1, real adapters in v0.2) -- contract first, code later.
"""
from __future__ import annotations

import logging
import re
from typing import Optional

from .bundle_extractor import BundleExtraction
from .conversation_writer import (
    ConversationBundle,
    ConversationSummary,
    Todo,
    Topic,
    make_todo_id,
)
from . import privacy as _privacy
from .schemas import Classification


logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Public entry point: registry dispatch
# ---------------------------------------------------------------------------


def make_bundle(
    *,
    metadata: dict,
    classification: Classification,
    extraction: BundleExtraction,
    transcript: str,
    privacy_level: Optional[str] = None,
) -> ConversationBundle:
    """Dispatch to the channel-specific adapter and return the
    resulting bundle.

    ``privacy_level`` overrides any inference (used by tests, the
    metadata-explicit override path, and the L3-already-known
    short-circuit case in ``processor._step_ingest``).

    Raises ``NotImplementedError`` for channels whose adapter
    hasn't been written yet -- per the per-source-PR sequence
    (CM042 -> CM040 -> CM046 -> CM047). Each follow-up PR removes
    one of these stubs.
    """
    channel = (metadata.get("channel") or "spoken").lower()
    adapter = _ADAPTERS.get(channel)
    if adapter is None:
        raise NotImplementedError(
            f"No bundle adapter for channel={channel!r}. "
            "Pending PRs: CM040 (iMessage/im), CM046 (email), "
            "CM047 (whatsapp). See HR015 2026-05-09 brief."
        )
    return adapter(
        metadata=metadata,
        classification=classification,
        extraction=extraction,
        transcript=transcript,
        privacy_level=privacy_level,
    )


# ---------------------------------------------------------------------------
# Spoken / meeting adapter (CM042)
# ---------------------------------------------------------------------------


def _spoken_adapter(
    *,
    metadata: dict,
    classification: Classification,
    extraction: BundleExtraction,
    transcript: str,
    privacy_level: Optional[str],
) -> ConversationBundle:
    """Build the bundle for a spoken-channel conversation.

    Covers CM042 RemoteCapture (Zoom / FaceTime / WhatsApp call
    audio captured via ScreenCaptureKit) plus any other
    Whisper-based capture surface. Future additions like
    in-person CM002 wearable recordings will route through the
    same adapter.

    Privacy default is L2; CM042's recorder lets the user mark a
    meeting as private at recording time which arrives here as
    ``metadata['privacy_level'] = 'L3'`` and overrides the
    classifier inference. The classifier's ``sensitive`` /
    ``highly-sensitive`` levels also escalate, via privacy.infer.
    """
    level = privacy_level or _privacy.infer(
        channel="spoken",
        classification=classification,
        metadata=metadata,
    )
    conversation_id = metadata["conversation_id"]
    started_at, ended_at = _resolve_timestamps(metadata)
    participants = _normalise_participants(metadata)

    return ConversationBundle(
        conversation_id=conversation_id,
        source_kind="spoken",
        source_subtype=str(metadata.get("source") or "meeting"),
        source_session_id=str(
            metadata.get("source_session_id") or conversation_id
        ),
        channel="spoken",
        participants=tuple(participants),
        started_at=started_at,
        ended_at=ended_at,
        privacy_level=level,
        source_app=_resolve_source_app(metadata),
        summary=_build_summary(extraction),
        transcript=transcript or "",
        todos=_build_todos(conversation_id, extraction),
        extra_metadata=_build_extra_metadata(metadata, classification),
    )


# ---------------------------------------------------------------------------
# iMessage / SMS adapter (CM040)
# ---------------------------------------------------------------------------


# Free-form metadata keys an iMessage / SMS metadata payload may
# carry. Pulled into ``extra_metadata`` for the on-disk bundle so
# a future re-process or audit can resolve back to the source
# without re-reading CM040's state. These are additive: missing
# values are simply not populated.
_IMESSAGE_EXTRA_KEYS = (
    "chat_db_rowid",       # macOS Messages.db ROWID for re-fetch
    "chat_identifier",     # iMessage's stable chat id
    "service",             # "iMessage" | "SMS"
    "is_group_chat",       # bool
    "wing_name",           # CM040's contacts.yaml-resolved name
)


def _imessage_adapter(
    *,
    metadata: dict,
    classification: Classification,
    extraction: BundleExtraction,
    transcript: str,
    privacy_level: Optional[str],
) -> ConversationBundle:
    """Build the bundle for an iMessage / SMS conversation.

    CM040 publisher.py tails ZeroClaw-managed JSONL session files;
    ZeroClaw upstream reads ``~/Library/Messages/chat.db`` on the
    Hub Mac. By the time the conversation reaches CM048 here, it
    carries the metadata shape documented in ``schemas.py``
    (``channel="im"``, participants as dicts, ``source`` set to
    ``"imessage"`` or ``"sms"``).

    Privacy default is L2  –  the same baseline as spoken / email
    / whatsapp. iMessage threads are personal-but-not-private by
    default; per-contact L3 escalation is post-launch (a config
    file mapping handle ids to privacy levels). The metadata
    override hook lets CM040 plumb a per-contact decision through
    today if the operator sets it manually via
    ``metadata['privacy_level']``.

    ``source_kind`` is ``"channel"`` (vs spoken's ``"spoken"``);
    the ``source_subtype`` carries the actual service
    (``"imessage"`` or ``"sms"``) so a future renderer can
    disambiguate without touching the channel field. The
    ``source_session_id`` prefers ZeroClaw's stable session id
    over the conversation_id, falling back to the conversation
    id when ZeroClaw didn't supply one.

    iMessage-specific metadata (chat_db_rowid, chat_identifier,
    is_group_chat, wing_name) lands in ``extra_metadata`` so the
    on-disk bundle is self-describing for an audit / re-process
    pass. SMS conversations populate the same keys; the service
    field disambiguates.
    """
    level = privacy_level or _privacy.infer(
        channel="im",
        classification=classification,
        metadata=metadata,
    )
    conversation_id = metadata["conversation_id"]
    started_at, ended_at = _resolve_timestamps(metadata)
    participants = _normalise_participants(metadata)

    extra = _build_extra_metadata(metadata, classification)
    for key in _IMESSAGE_EXTRA_KEYS:
        value = metadata.get(key)
        if value is None or value == "":
            continue
        extra[key] = value

    # iMessage / SMS: source_app defaults to "messages" (the
    # macOS app name) regardless of the source-subtype value.
    # The shared ``_resolve_source_app`` would fall back to the
    # source subtype (``"imessage"`` / ``"sms"``) which is the
    # service, not the app -- a renderer wants both fields, but
    # the convention is service in source_subtype, app in
    # source_app. Explicit override beats the default.
    explicit_source_app = metadata.get("source_app")
    if isinstance(explicit_source_app, str) and explicit_source_app.strip():
        source_app = explicit_source_app.strip()
    else:
        source_app = "messages"

    # Channel: the source's own ``channel`` field disambiguates
    # iMessage ("im") from SMS ("sms"). The adapter is shared
    # but the bundle preserves the distinction so a future
    # renderer can colour-code or filter on it.
    channel_label = "sms" if metadata.get("channel") == "sms" else "im"

    return ConversationBundle(
        conversation_id=conversation_id,
        source_kind="channel",
        source_subtype=str(metadata.get("source") or "imessage"),
        source_session_id=str(
            metadata.get("source_session_id") or conversation_id
        ),
        channel=channel_label,
        participants=tuple(participants),
        started_at=started_at,
        ended_at=ended_at,
        privacy_level=level,
        source_app=source_app,
        summary=_build_summary(extraction),
        transcript=transcript or "",
        todos=_build_todos(conversation_id, extraction),
        extra_metadata=extra,
    )


# ---------------------------------------------------------------------------
# Email adapter (CM046)
# ---------------------------------------------------------------------------


# Free-form metadata keys an email payload may carry. Pulled
# into ``extra_metadata`` so the on-disk bundle is self-
# describing (Spotlight / iCloud-Drive / a future re-process
# can identify the originating thread without re-reading
# CM046's state).
_EMAIL_EXTRA_KEYS = (
    "thread_id",            # root Message-Id of the thread
    "subject",              # current thread subject line
    "message_count",        # number of messages in the thread
    "first_message_at",     # ISO timestamp of the first message
    "last_message_at",      # ISO timestamp of the most recent
    "in_reply_to_chain",    # ordered list of Message-Ids
    "message_ids",          # all Message-Ids in the thread
)


def _email_adapter(
    *,
    metadata: dict,
    classification: Classification,
    extraction: BundleExtraction,
    transcript: str,
    privacy_level: Optional[str],
) -> ConversationBundle:
    """Build the bundle for an email-channel conversation.

    CM046 email-thread fact extraction (mbox / IMAP / Apple Mail
    FDA) feeds CM048 with metadata.channel="email" plus the
    email_thread sidecar fields documented in schemas.py
    (thread_id, subject, message_count, first/last_message_at,
    message_ids, in_reply_to_chain). Per-participant ``email``
    fields land in metadata.participants[*].email so the wiki
    renderer and this adapter can resolve a sender's address.

    Privacy ladder (HR015 brief):
      L2  default
      L1  newsletters / marketing / transactional senders
          (matched on local-part prefix, e.g. noreply@,
          marketing@, receipts@)
      L3  legal / medical / financial / government domains
          (matched on suffix, e.g. ``.law``, ``.health``,
          ``.bank``, ``.gov``)

    The domain-aware ladder is implemented in
    ``privacy.infer_for_email_addresses`` so the rule-list lives
    next to the spoken / im / whatsapp ladders. It returns an
    L1 / L3 hint OR ``None`` (no rule matched). When non-None,
    it OVERRIDES the channel default but is itself overridden
    by:
      1. An explicit ``metadata['privacy_level']`` (operator
         knows best)
      2. A classifier ``sensitive`` / ``highly-sensitive``
         escalation (an automated read of body content)

    Both 1 and 2 already apply via ``privacy.infer``; we only
    consult the email ladder when neither has set a level. The
    explicit ``privacy_level`` kwarg ALSO wins (used by tests
    and the L3-already-known short-circuit path).
    """
    if privacy_level is not None:
        level = privacy_level
    else:
        # Precedence (highest first):
        #   1. Explicit ``metadata['privacy_level']`` -- operator
        #      knows best (CM046 may set this from a settings.yaml
        #      per-thread override).
        #   2. Sensitive / highly-sensitive classifier verdict --
        #      automated read of body content escalates upward.
        #      Always wins over the email-domain ladder because
        #      a sensitive newsletter is still sensitive.
        #   3. Email-domain ladder via
        #      ``infer_for_email_addresses`` -- L3 for legal /
        #      medical / financial / gov domains, L1 for
        #      marketing / transactional senders. Both directions:
        #      L3 escalates ABOVE the L2 default; L1 reduces
        #      BELOW the L2 default (newsletters should be
        #      browseable, not collapsed-by-default).
        #   4. Channel default (L2).
        explicit_meta = metadata.get("privacy_level")
        if isinstance(explicit_meta, str) and explicit_meta:
            level = _privacy.normalise(explicit_meta)
        else:
            sensitivity = (
                classification.sensitivity.level
                if classification.sensitivity is not None
                else "normal"
            )
            if sensitivity in ("sensitive", "highly-sensitive"):
                # Sensitive classifier wins -- delegate to
                # privacy.infer for the established escalation
                # ladder.
                level = _privacy.infer(
                    channel="email",
                    classification=classification,
                    metadata=metadata,
                )
            else:
                email_addresses = _collect_email_addresses(metadata)
                email_hint = _privacy.infer_for_email_addresses(
                    email_addresses
                )
                if email_hint is not None:
                    level = email_hint
                else:
                    level = _privacy.infer(
                        channel="email",
                        classification=classification,
                        metadata=metadata,
                    )

    conversation_id = metadata["conversation_id"]
    started_at, ended_at = _resolve_email_timestamps(metadata)
    participants = _normalise_participants(metadata)

    extra = _build_extra_metadata(metadata, classification)
    thread_meta = metadata.get("email_thread")
    if isinstance(thread_meta, dict):
        for key in _EMAIL_EXTRA_KEYS:
            value = thread_meta.get(key)
            if value is None or value == "":
                continue
            extra[key] = value

    return ConversationBundle(
        conversation_id=conversation_id,
        source_kind="channel",
        source_subtype=str(metadata.get("source") or "email"),
        source_session_id=str(
            metadata.get("source_session_id")
            or (
                isinstance(thread_meta, dict)
                and thread_meta.get("thread_id")
            )
            or conversation_id
        ),
        channel="email",
        participants=tuple(participants),
        started_at=started_at,
        ended_at=ended_at,
        privacy_level=level,
        source_app=_resolve_email_source_app(metadata),
        summary=_build_summary(extraction),
        transcript=transcript or "",
        todos=_build_todos(conversation_id, extraction),
        extra_metadata=extra,
    )


def _collect_email_addresses(metadata: dict) -> list[str]:
    """Collect non-user participant email addresses from CM048
    metadata.

    Per schemas.py, email-channel conversations carry an
    ``email`` field per participant. We exclude the user-side
    participant (whose email is the operator's own and would
    misfire the marketing-prefix matcher if e.g. the operator's
    address starts with ``info@``). Falls back to ``id`` if the
    address looks like an email and ``email`` is missing.
    """
    out: list[str] = []
    for entry in metadata.get("participants") or []:
        if not isinstance(entry, dict):
            continue
        if entry.get("role") == "user":
            continue
        addr = entry.get("email") or ""
        if not addr and "@" in (entry.get("id") or ""):
            addr = entry["id"]
        if isinstance(addr, str) and addr.strip():
            out.append(addr.strip())
    return out


def _resolve_email_timestamps(metadata: dict) -> tuple[str, str]:
    """Email-specific timestamp resolution.

    Prefer ``email_thread.first_message_at`` /
    ``email_thread.last_message_at`` from CM046's sidecar; fall
    back to the shared ``_resolve_timestamps`` helper if the
    sidecar is missing.
    """
    thread = metadata.get("email_thread")
    if isinstance(thread, dict):
        first = (thread.get("first_message_at") or "").strip()
        last = (thread.get("last_message_at") or "").strip()
        if first and last:
            return first, last
    return _resolve_timestamps(metadata)


def _resolve_email_source_app(metadata: dict) -> str:
    """Email source_app default: "mail" (the macOS Mail.app
    name; matches the AI Chats wing's source_app convention).
    Explicit ``metadata['source_app']`` wins."""
    explicit = metadata.get("source_app")
    if isinstance(explicit, str) and explicit.strip():
        return explicit.strip()
    return "mail"


# ---------------------------------------------------------------------------
# WhatsApp adapter (CM047)
# ---------------------------------------------------------------------------


# Free-form metadata keys a WhatsApp payload may carry. Pulled
# into ``extra_metadata`` so the on-disk bundle is self-
# describing for an audit / re-process pass.
_WHATSAPP_EXTRA_KEYS = (
    "chat_jid",            # WhatsApp's stable chat id
                           # ("12345@example.test" / "12345@example.test")
    "chat_type",           # "private" | "group"
    "is_group_chat",       # bool (mirror of chat_type)
    "group_subject",       # group display name
    "group_description",   # group description text
    "group_label",         # operator-applied label
                           # ("Public" / "Work" / "Family" / etc)
    "contact_label",       # operator-applied per-contact label
    "wing_name",           # CM047's resolved wing name
)


# Group-label values that signal a less-private context. Threads
# in groups marked "Public" or "Work" are typically broadcasts
# rather than personal correspondence; the brief reduces them to
# L1 so the wiki can show them browseable rather than collapsed.
_WHATSAPP_L1_GROUP_LABELS = {"public", "work", "broadcast"}


# Contact-label values that signal a high-sensitivity context.
# Threads with the partner / family / a contact marked sensitive
# escalate to L3 so the body never lands in Qdrant. Matches
# case-insensitively. The brief explicitly calls out family /
# partner / sensitive-contact as L3 triggers.
_WHATSAPP_L3_CONTACT_LABELS = {
    "family", "partner", "spouse", "sensitive", "private",
    "intimate", "kids", "children",
}


def _whatsapp_label_normalised(value: object) -> Optional[str]:
    """Return a lower-cased label string for matching, or
    ``None`` if the value is missing / not a string."""
    if isinstance(value, str) and value.strip():
        return value.strip().lower()
    return None


def _whatsapp_adapter(
    *,
    metadata: dict,
    classification: Classification,
    extraction: BundleExtraction,
    transcript: str,
    privacy_level: Optional[str],
) -> ConversationBundle:
    """Build the bundle for a WhatsApp conversation.

    CM047 publishes WhatsApp threads via ZeroClaw's three Rust
    tools (whatsapp_list_chats, whatsapp_read_history,
    whatsapp_get_contact -- task #156 closed 2026-05-09). The
    metadata payload arriving here carries chat_jid, chat_type
    ("private" | "group"), participants (phone numbers),
    group_subject (for groups), and the operator-applied
    group_label / contact_label hints.

    Privacy ladder (HR015 brief):
      L2  default
      L1  group_label in {"Public", "Work", "Broadcast"} --
          group threads that are broadcasts rather than personal
          correspondence; the wiki should show them browseable
      L3  contact_label or group_label in {"Family", "Partner",
          "Spouse", "Sensitive", "Private", "Intimate", ...} --
          the user explicitly flagged the thread as private

    Precedence (highest first):
      1. Explicit privacy_level kwarg (tests + L3-already-known
         short-circuit path)
      2. Explicit metadata['privacy_level'] (operator knows best)
      3. Sensitive / highly-sensitive classifier verdict
      4. WhatsApp label ladder (L3 sensitive contact labels;
         L3 sensitive group labels; L1 broadcast group labels)
      5. Channel default (L2)

    The label ladder is operator-driven (CM047 surfaces the
    labels the user has applied via the WhatsApp app or via the
    settings.yaml override) rather than auto-classified -- the
    brief is explicit that this should ship as a "default-ladder
    per source with a single override hook" and shouldn't try to
    auto-detect partner / family threads from content.
    """
    if privacy_level is not None:
        level = privacy_level
    else:
        level = _whatsapp_resolve_privacy(metadata, classification)

    conversation_id = metadata["conversation_id"]
    started_at, ended_at = _resolve_timestamps(metadata)
    participants = _normalise_participants(metadata)

    extra = _build_extra_metadata(metadata, classification)
    for key in _WHATSAPP_EXTRA_KEYS:
        value = metadata.get(key)
        if value is None or value == "":
            continue
        extra[key] = value

    return ConversationBundle(
        conversation_id=conversation_id,
        source_kind="channel",
        source_subtype=str(metadata.get("source") or "whatsapp"),
        source_session_id=str(
            metadata.get("source_session_id")
            or metadata.get("chat_jid")
            or conversation_id
        ),
        channel="whatsapp",
        participants=tuple(participants),
        started_at=started_at,
        ended_at=ended_at,
        privacy_level=level,
        source_app=_resolve_whatsapp_source_app(metadata),
        summary=_build_summary(extraction),
        transcript=transcript or "",
        todos=_build_todos(conversation_id, extraction),
        extra_metadata=extra,
    )


def _whatsapp_resolve_privacy(
    metadata: dict, classification: Classification
) -> str:
    """Apply the WhatsApp precedence rules.

    Split out so the test suite can poke at individual rungs of
    the ladder without going through the full adapter.
    """
    explicit_meta = metadata.get("privacy_level")
    if isinstance(explicit_meta, str) and explicit_meta:
        return _privacy.normalise(explicit_meta)

    sensitivity = (
        classification.sensitivity.level
        if classification.sensitivity is not None
        else "normal"
    )
    if sensitivity in ("sensitive", "highly-sensitive"):
        return _privacy.infer(
            channel="whatsapp",
            classification=classification,
            metadata=metadata,
        )

    contact_label = _whatsapp_label_normalised(metadata.get("contact_label"))
    group_label = _whatsapp_label_normalised(metadata.get("group_label"))
    if contact_label and contact_label in _WHATSAPP_L3_CONTACT_LABELS:
        return "L3"
    if group_label and group_label in _WHATSAPP_L3_CONTACT_LABELS:
        return "L3"
    if group_label and group_label in _WHATSAPP_L1_GROUP_LABELS:
        return "L1"

    return _privacy.infer(
        channel="whatsapp",
        classification=classification,
        metadata=metadata,
    )


def _resolve_whatsapp_source_app(metadata: dict) -> str:
    """WhatsApp source_app default: "whatsapp" (the app name).
    Explicit ``metadata['source_app']`` wins."""
    explicit = metadata.get("source_app")
    if isinstance(explicit, str) and explicit.strip():
        return explicit.strip()
    return "whatsapp"


# ---------------------------------------------------------------------------
# Helpers shared across adapters (factor out per follow-up PR if any
# adapter wants different behaviour).
# ---------------------------------------------------------------------------


def _resolve_timestamps(metadata: dict) -> tuple[str, str]:
    """Return (started_at, ended_at) ISO strings from metadata.

    CM048 metadata historically uses ``date`` (YYYY-MM-DD) plus
    optional ``started_at`` / ``ended_at`` ISO timestamps. We
    prefer the explicit timestamps; fall back to ``date`` with
    a midnight time and ``date`` + 1h end (so the bundle has a
    valid range without lying about precision).
    """
    started = (metadata.get("started_at") or "").strip()
    ended = (metadata.get("ended_at") or "").strip()
    if started and ended:
        return started, ended
    date_part = (metadata.get("date") or "1970-01-01")[:10]
    if not started:
        started = f"{date_part}T00:00:00Z"
    if not ended:
        # 1h placeholder window when only date is known. Better
        # than reusing started_at (which would mark a 0s
        # conversation) and clearly recoverable downstream
        # because it lands at exactly +1h00:00.
        ended = f"{date_part}T01:00:00Z"
    return started, ended


def _normalise_participants(metadata: dict) -> list[str]:
    """Extract participant ids as a flat list of strings.

    CM048 metadata's ``participants`` is a list of dicts with
    ``id``, ``display``, ``role`` keys. The bundle wants flat
    strings -- prefer ``id``, fall back to ``display``, drop
    anything ungrokkable. Order is preserved so the folder
    slug is deterministic.
    """
    raw = metadata.get("participants") or []
    out: list[str] = []
    for entry in raw:
        if isinstance(entry, dict):
            value = (entry.get("id") or entry.get("display") or "").strip()
            if value:
                out.append(value)
        elif isinstance(entry, str):
            stripped = entry.strip()
            if stripped:
                out.append(stripped)
    return out


def _resolve_source_app(metadata: dict) -> Optional[str]:
    """Pick a ``source_app`` label for the frontmatter.

    Order: explicit ``metadata['source_app']`` > the broader
    ``metadata['source']`` > None. Used by the wiki renderer to
    show a "By assistant: <Name>" / "From: <App>" badge per
    the AI Chats wing pattern.
    """
    explicit = metadata.get("source_app")
    if isinstance(explicit, str) and explicit.strip():
        return explicit.strip()
    source = metadata.get("source")
    if isinstance(source, str) and source.strip():
        return source.strip()
    return None


def _build_summary(extraction: BundleExtraction) -> ConversationSummary:
    """Convert the extractor's loose dicts into the writer's
    frozen dataclass shape. Empty topics/points fall through;
    the renderer copes (per ``test_no_todos_renders_empty_state``
    in the writer tests)."""
    topics: list[Topic] = []
    for topic in extraction.topics:
        if not isinstance(topic, dict):
            continue
        name = str(topic.get("name") or "").strip()
        if not name:
            continue
        points_raw = topic.get("points") or []
        if not isinstance(points_raw, list):
            continue
        points = tuple(
            str(p).strip() for p in points_raw if str(p).strip()
        )
        if points:
            topics.append(Topic(name=name, points=points))
    return ConversationSummary(
        overall=extraction.overall_summary.strip(),
        topics=tuple(topics),
    )


def _build_todos(
    conversation_id: str, extraction: BundleExtraction
) -> tuple[Todo, ...]:
    """Convert the extractor's loose todo dicts into stable
    ``Todo`` objects.

    The id is generated via ``make_todo_id(conversation_id,
    owner, text)`` so re-runs of the same conversation produce
    the same ids -- the Apple Reminders idempotency contract a
    follow-up PR will lean on.

    Malformed entries (no text, no owner) are dropped silently
    rather than raising; the wiki todos wing surfaces "(none
    extracted)" gracefully if everything was malformed.
    """
    out: list[Todo] = []
    for todo in extraction.todos:
        if not isinstance(todo, dict):
            continue
        text = str(todo.get("text") or "").strip()
        if not text:
            continue
        owner = str(todo.get("owner") or "user").strip() or "user"
        deadline = todo.get("deadline")
        deadline_str = (
            str(deadline).strip() if deadline not in (None, "", False) else None
        )
        anchor = todo.get("source_anchor")
        anchor_str = (
            str(anchor).strip() if anchor not in (None, "", False) else None
        )
        todo_id = make_todo_id(conversation_id, owner, text)
        out.append(
            Todo(
                id=todo_id,
                text=text,
                owner=owner,
                deadline=deadline_str,
                source_anchor=anchor_str,
                status="extracted",
            )
        )
    return tuple(out)


def _build_extra_metadata(
    metadata: dict, classification: Classification
) -> dict:
    """Pull a small set of cross-reference fields into the
    bundle's ``extra_metadata`` so the on-disk frontmatter is
    self-describing for an out-of-band consumer (Spotlight,
    iCloud-Drive search, an export).

    Deliberately small: just classification + capture fields,
    not the full pipeline state. The full state stays in
    ``~/.ostler/processing/<id>/`` for re-processing.
    """
    extra: dict = {}
    if classification is not None:
        extra["classification_type_slug"] = classification.suggested_type_slug
        extra["classification_setting"] = classification.setting
        extra["classification_shape"] = classification.shape
        extra["classification_stakes"] = classification.stakes
        if classification.sensitivity is not None:
            extra["sensitivity_level"] = classification.sensitivity.level
    capture_source = metadata.get("capture_source")
    if isinstance(capture_source, str) and capture_source.strip():
        extra["capture_source"] = capture_source.strip()
    location = metadata.get("location")
    if isinstance(location, str) and location.strip():
        extra["location"] = location.strip()
    return extra


# ---------------------------------------------------------------------------
# Channel registry. Filled in incrementally PR by PR.
# ---------------------------------------------------------------------------


_ADAPTERS = {
    "spoken": _spoken_adapter,
    # iMessage and SMS share the adapter -- the service is
    # disambiguated via ``source_subtype`` on the resulting
    # bundle, not via a separate registry entry. The ``sms``
    # alias mirrors the schemas.py channel discriminator
    # (``"spoken" | "email" | "im" | "sms" | "manual"``).
    "im": _imessage_adapter,
    "sms": _imessage_adapter,
    "email": _email_adapter,
    "whatsapp": _whatsapp_adapter,
}


__all__ = ["make_bundle"]
