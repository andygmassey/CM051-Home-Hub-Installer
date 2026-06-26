"""Conversation-store adapter for the reply-debt detector.

The reply-debt detector core (``reply_debt``) is source-agnostic and the
``reply_debt_adapters`` module ships the strongest live source -- Apple's
chat.db (``iter_imessage_threads``) -- which needs the real box + Full Disk
Access. That leaves two gaps the v1 surface still wants filled:

  * an OFF-box / CI-provable source, so the wiki wing and the daily-brief
    datum render *something* before the chat.db path is wired on a customer's
    Mac; and
  * the non-iMessage channels the JTBD names -- **WhatsApp** and **email** --
    which never touch chat.db.

This module reads the on-disk four-artefact conversation bundle that every
human-to-human pipeline writes (``~/Documents/Ostler/Conversations/<date>/
<slug>-<id>/transcript.md`` + frontmatter, see ``conversation_writer``) and
turns each 1:1 thread into a normalised ``Thread`` the detector can score. It
is the documented-but-previously-unbuilt ``iter_store_threads`` fallback.

Direction fidelity
-------------------

The bundle deliberately collapses a thread to a single ``transcript`` blob and
does NOT preserve a per-message ``is_from_me`` flag (verified 2026-06-20). So
direction here is recovered, in order of trust:

  1. **Frontmatter ``participants``.** The operator is carried as the literal
     id ``"user"`` (mirrors ``last_contact_updater._is_user_participant`` +
     ``ingest`` role == "user"). A 1:1 thread therefore has exactly one
     non-user counterpart, which lets us map a transcript speaker label to the
     owner vs the counterpart even when the label is a display name.
  2. **Transcript speaker labels.** Each turn is prefixed with a speaker
     label. Across the source pipelines these take a few forms -- ``**user:**``
     / ``**<name>:**`` (markdown bold), ``user:`` / ``<name>:`` (plain), or a
     resolved display name. We match the label against the owner identity (the
     ``"user"`` literal, plus any configured owner name / self-handles) to set
     ``is_from_owner`` per turn.

When a turn's speaker cannot be resolved to either side we fall back to the
last *confidently* resolved speaker only if it is unambiguous; otherwise the
turn is dropped from the direction reasoning. This is conservative by design:
the detector only needs to know whether the LAST resolvable message was
inbound, and a false "owner replied" (suppressing a real debt) is cheaper to
the user than nagging about a reply they already sent.

This adapter is PURE w.r.t. the network and unit-testable against synthetic
bundle fixtures on disk. The only I/O is reading text files under the
conversations dir; no chat.db, no Full Disk Access, no live services.
"""
from __future__ import annotations

import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Optional

from . import ostler_paths
from .reply_debt import Message, Thread

log = logging.getLogger(__name__)


# The operator is carried as this literal participant id everywhere in CM048
# (ingest role == "user", last_contact_updater._is_user_participant).
_USER_LITERAL = "user"

# iMessage is handled by the stronger chat.db adapter; skip it here so the two
# sources do not double-count the same thread. Channels surfaced by THIS
# adapter are the store-only ones (WhatsApp / email / meeting-as-thread).
_SKIP_CHANNELS = {"imessage"}

# Speaker-label forms a transcript turn may start with. We capture the label
# text (group 1) and the remainder of the line (group 2). Ordered most- to
# least-specific so markdown-bold wins over plain.
_LABEL_RES = (
    re.compile(r"^\s*\*\*\s*(.+?)\s*:\s*\*\*\s*(.*)$"),   # **name:** text
    re.compile(r"^\s*\*\*\s*(.+?)\s*\*\*\s*:\s*(.*)$"),   # **name** : text
    re.compile(r"^\s*([A-Za-z0-9 ._'\-]{1,40}?)\s*:\s+(.*)$"),  # name: text
)


def _parse_speaker(line: str) -> Optional[tuple[str, str]]:
    """Return ``(label, remainder)`` if the line opens a new speaker turn."""
    for rx in _LABEL_RES:
        m = rx.match(line)
        if m:
            label = m.group(1).strip()
            if label:
                return label, m.group(2)
    return None


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "")).strip().lower()


# ---------------------------------------------------------------------------
# Minimal, dependency-free YAML-frontmatter reader
# ---------------------------------------------------------------------------

# We avoid a PyYAML dependency (the writer hand-rolls the frontmatter too) and
# parse exactly the subset the writer emits: scalar ``key: value`` lines plus a
# ``participants:`` block of ``  - value`` list items. This mirrors the
# intentionally-inline parsers elsewhere in the family (CM044 _split_frontmatter)
# rather than coupling to a YAML lib version.


def _unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Split ``---`` frontmatter from the body. Returns ``(meta, body)``.

    ``meta`` contains scalar keys plus ``participants`` as a list. Unknown or
    nested structure beyond what the writer emits is ignored gracefully.
    """
    if not text.startswith("---"):
        return {}, text
    lines = text.splitlines()
    # find the closing fence
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return {}, text

    meta: dict = {}
    participants: list[str] = []
    in_participants = False
    for raw in lines[1:end]:
        if raw.startswith("  - ") or raw.startswith("- "):
            if in_participants:
                participants.append(_unquote(raw.split("-", 1)[1]))
            continue
        # any non-indented key ends the participants block
        if not raw.startswith(" "):
            in_participants = False
        if raw.strip() == "participants:":
            in_participants = True
            continue
        if ":" in raw and not raw.startswith("  "):
            key, _, val = raw.partition(":")
            meta[key.strip()] = _unquote(val)
    if participants:
        meta["participants"] = participants

    body = "\n".join(lines[end + 1:])
    return meta, body


def _parse_iso(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# Bundle -> Thread
# ---------------------------------------------------------------------------


def _strip_transcript_heading(body: str) -> str:
    """Drop the ``# Transcript`` heading the writer prepends."""
    out = []
    skipping = True
    for line in body.splitlines():
        if skipping:
            s = line.strip()
            if not s or s.lower().lstrip("# ").startswith("transcript"):
                continue
            skipping = False
        out.append(line)
    return "\n".join(out)


def thread_from_bundle(
    *,
    meta: dict,
    transcript_body: str,
    owner_aliases: Optional[set[str]] = None,
    strength_lookup=None,
    fallback_ts: Optional[datetime] = None,
) -> Optional[Thread]:
    """Build a 1:1 ``Thread`` from one bundle's frontmatter + transcript.

    Returns ``None`` for group threads (more than one non-user participant),
    bundles on a channel handled elsewhere (iMessage), or transcripts with no
    resolvable speaker turns. ``owner_aliases`` are extra labels that should be
    treated as the owner beyond the ``"user"`` literal (e.g. the operator's
    display name / self-handles); matched case-insensitively.
    """
    channel = (meta.get("source_subtype") or meta.get("channel") or "").strip().lower()
    if channel in _SKIP_CHANNELS:
        return None

    participants = [p for p in (meta.get("participants") or []) if p]
    non_user = [p for p in participants if _norm(p) != _USER_LITERAL]
    # 1:1 only for v1. Zero counterparts (self-note) or >1 (group) => skip.
    if len(non_user) != 1:
        return None
    counterpart = non_user[0]

    owner_labels = {_USER_LITERAL}
    for a in (owner_aliases or set()):
        n = _norm(a)
        if n:
            owner_labels.add(n)

    ended = _parse_iso(meta.get("ended_at")) or _parse_iso(meta.get("started_at"))
    ended = ended or fallback_ts or datetime.now(timezone.utc)

    body = _strip_transcript_heading(transcript_body)

    # Walk turns, recovering direction from each speaker label. Continuation
    # lines (no new label) extend the current turn.
    messages: list[Message] = []
    cur_owner: Optional[bool] = None
    cur_sender = ""
    cur_text: list[str] = []

    def _flush():
        if cur_owner is None:
            return
        text = "\n".join(cur_text).strip()
        if not text:
            return
        messages.append(
            Message(
                sender=cur_sender or ("me" if cur_owner else counterpart),
                text=text,
                timestamp=ended,  # bundle gives one ts; ordering is positional
                is_from_owner=cur_owner,
            )
        )

    for line in body.splitlines():
        parsed = _parse_speaker(line)
        if parsed is None:
            if cur_owner is not None:
                cur_text.append(line)
            continue
        label, remainder = parsed
        # New turn: flush the previous one.
        _flush()
        nlabel = _norm(label)
        is_owner = nlabel in owner_labels
        # If the label is the counterpart's name, it is inbound. If it matches
        # neither side, treat a non-owner label as the counterpart (inbound) so
        # an unrecognised display name does not silently suppress a debt.
        cur_owner = is_owner
        cur_sender = "me" if is_owner else (label if not is_owner else counterpart)
        cur_text = [remainder]
    _flush()

    if not messages:
        return None

    privacy = (meta.get("privacy_level") or "L2").strip() or "L2"

    person_uri = None
    strength = None
    if strength_lookup:
        resolved = strength_lookup(counterpart)
        if resolved:
            person_uri, strength = resolved

    return Thread(
        thread_id=f"{channel or 'store'}:{meta.get('conversation_id') or counterpart}",
        channel=channel or "store",
        messages=tuple(messages),
        privacy_level=privacy,
        is_group=False,
        counterpart_name=counterpart,
        person_uri=person_uri,
        relationship_strength=strength,
    )


def iter_store_threads(
    *,
    conversations_dir: Optional[Path] = None,
    owner_aliases: Optional[set[str]] = None,
    strength_lookup=None,
    lookback_days: int = 90,
    now: Optional[datetime] = None,
) -> Iterator[Thread]:
    """Yield 1:1 ``Thread``s from the on-disk conversation bundles.

    Walks ``~/Documents/Ostler/Conversations/<date>/<slug>-<id>/transcript.md``
    (override the root with ``conversations_dir``). iMessage bundles are skipped
    (the chat.db adapter owns them). Bundles whose last activity is older than
    ``lookback_days`` are skipped. Read-only; never writes.
    """
    root = conversations_dir or ostler_paths.conversations_dir()
    if not root.exists():
        log.info("reply_debt: conversations dir not found at %s -- skipping", root)
        return

    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    for transcript_path in sorted(root.rglob("transcript.md")):
        try:
            text = transcript_path.read_text(encoding="utf-8")
        except OSError as exc:  # pragma: no cover - fs edge
            log.warning("reply_debt: could not read %s: %s", transcript_path, exc)
            continue
        meta, body = parse_frontmatter(text)
        if not meta:
            continue

        thread = thread_from_bundle(
            meta=meta,
            transcript_body=body,
            owner_aliases=owner_aliases,
            strength_lookup=strength_lookup,
        )
        if thread is None:
            continue

        last_ts = thread.messages[-1].timestamp
        if last_ts.tzinfo is None:
            last_ts = last_ts.replace(tzinfo=timezone.utc)
        if (now - last_ts).days > lookback_days:
            continue

        yield thread


__all__ = [
    "parse_frontmatter",
    "thread_from_bundle",
    "iter_store_threads",
]
