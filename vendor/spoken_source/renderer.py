"""Render a RemoteCapture session into a CM048 transcript + metadata.

Two outputs per finished session:

  - A cleaned, speaker-labelled markdown transcript. The CM042 body is
    already speaker-labelled (``**Name** [MM:SS]: text``); this
    renderer normalises it into the shape the other feeds emit (a
    ``# <title>`` heading then ``**Speaker** (offset):\\n<text>``
    blocks) so all four-artefact transcripts read consistently in the
    wiki regardless of source.

  - A CM048 metadata dict matching the ``_spoken_adapter`` expectations
    in CM048 ``channel_adapter.py`` (``channel="spoken"``, participants
    as ``id`` / ``display`` / ``role`` dicts, ``source`` /
    ``source_app`` / ``source_session_id`` / ``capture_source`` set,
    ISO ``started_at`` / ``ended_at``, optional ``privacy_level``).

VOICE NOTES ride this exact path. A voice note is a short
single-speaker capture, so its rendered transcript has one speaker and
its metadata carries one (or zero) non-user participants. No separate
plumbing: the only observable difference is the participant count and
the ``source`` value (``voice_note``), which the wiki can badge later.

No real-person data is hard-coded here. Display names come from the
parsed transcript front matter.
"""
from __future__ import annotations

import hashlib
import re
from typing import Optional

from .reader import CapturedTranscript, CapturedParticipant

# CM048 ``SpeakerLabelFeedback.capture_source`` enforces a closed set;
# RemoteCapture on the Mac is ``cm042_mac``.
CAPTURE_SOURCE = "cm042_mac"

_SLUG_RE = re.compile(r"[^a-z0-9]+")

# Front-matter speaker_label that denotes the operator (the local
# side of the call). CM042's diarizer emits "USER" for the local
# microphone stream.
_USER_LABEL = "USER"


def _slug(text: str, max_len: int = 40) -> str:
    cleaned = _SLUG_RE.sub("-", (text or "").lower()).strip("-")
    return cleaned[:max_len].rstrip("-") or "conversation"


def _short_hash(*parts: str) -> str:
    payload = "\x1f".join(parts)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:8]


def conversation_id_for(transcript: CapturedTranscript) -> str:
    """Build a stable ``YYYY-MM-DD_<slug>_<short-hash>`` id.

    Deterministic in the call id + start time so a re-read of the same
    transcript file produces the same conversation id (and therefore
    the same CM048 state dir + bundle folder), which keeps re-processing
    idempotent.
    """
    started_iso = (
        transcript.started_at.isoformat().replace("+00:00", "Z")
        if transcript.started_at
        else ""
    )
    slug_source = _title_for(transcript)
    return (
        f"{transcript.date}_{_slug(slug_source)}_"
        f"{_short_hash(transcript.call_id, started_iso)}"
    )


def _title_for(transcript: CapturedTranscript) -> str:
    """A human title for the transcript heading + slug.

    Prefers the most confident non-user participant's display name plus
    the context (e.g. "Project Sync with Alex"); falls back to the
    source + context.
    """
    others = [
        p for p in transcript.participants
        if p.speaker_label.upper() != _USER_LABEL and p.display_name
    ]
    if others:
        # Highest-confidence name first (None confidence sorts last).
        others.sort(key=lambda p: (p.confidence is None, -(p.confidence or 0)))
        name = others[0].display_name
        if transcript.context and transcript.context not in ("meeting", ""):
            return f"{transcript.context.title()} with {name}"
        return f"Call with {name}"
    context = transcript.context.title() if transcript.context else "Recording"
    source = transcript.source.replace("_", " ").title()
    return f"{context} ({source})"


def render_transcript(transcript: CapturedTranscript) -> str:
    """Render a cleaned, speaker-labelled markdown transcript.

    Opens with a ``# <title>`` heading so the bundle is
    self-describing, then one block per utterance:

        **<Speaker>** (MM:SS):
        <text>

    The offset is dropped when CM042 did not supply one (e.g. a
    manual-diarisation transcript). A voice note renders identically
    with a single speaker.
    """
    lines: list[str] = []
    lines.append(f"# {_title_for(transcript)}")
    lines.append("")
    for utt in transcript.utterances:
        speaker = utt.speaker or "Unknown"
        text = utt.text.strip() or "[no text]"
        header = f"**{speaker}** ({utt.timestamp})" if utt.timestamp else f"**{speaker}**"
        lines.append(f"{header}:")
        lines.append(text)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _participants_metadata(
    transcript: CapturedTranscript,
    user_display_name: str,
) -> list[dict]:
    """Build the CM048 participants list.

    The operator (CM042 ``USER`` label) becomes role ``"user"`` with id
    ``"user"``. Every other speaker becomes role ``"other"`` with a
    slugged id, carrying through the resolved ``person_id`` when CM042
    identified the speaker against the people graph so CM048 / the wiki
    can link to the existing person.
    """
    participants: list[dict] = []
    user_seen = False
    others_seen: set[str] = set()

    for p in transcript.participants:
        if p.speaker_label.upper() == _USER_LABEL:
            if user_seen:
                continue
            user_seen = True
            participants.append(
                {"id": "user", "display": user_display_name, "role": "user"}
            )
            continue
        display = p.display_name or p.speaker_label
        pid = p.person_id or _slug(display)
        if pid in others_seen:
            continue
        others_seen.add(pid)
        entry: dict = {"id": pid, "display": display, "role": "other"}
        if p.person_id:
            entry["person_id"] = p.person_id
        participants.append(entry)

    # Always guarantee a user participant so the bundle has a coherent
    # "you" side even on a transcript that only labelled the remote
    # speaker (e.g. a one-sided voice note recorded from system audio).
    if not user_seen:
        participants.insert(
            0, {"id": "user", "display": user_display_name, "role": "user"}
        )
    return participants


def build_metadata(
    transcript: CapturedTranscript,
    *,
    user_display_name: str = "You",
    privacy_level: Optional[str] = None,
) -> dict:
    """Assemble the CM048 metadata dict for a spoken session.

    Shape matches the CM048 ``_spoken_adapter`` (``channel="spoken"``,
    ``source`` carrying the capture surface, ``source_session_id`` set
    to the CM042 call id, ``capture_source="cm042_mac"``, participants
    as ``id`` / ``display`` / ``role`` dicts).

    Privacy precedence (highest first):
      1. ``privacy_level`` argument (operator privacy map in pipeline,
         or a test override).
      2. The transcript's own ``privacy_level`` front-matter value when
         it is L3 (the recorder marked the meeting private). We only
         honour an explicit L3 here so a benign L2 default in the front
         matter does not pin every meeting to L2 and stop CM048's
         classifier from escalating a sensitive one. Any explicit value
         passed via the argument always wins over the front matter.
      3. Unset, leaving CM048's classifier inference (L2 baseline,
         sensitive / highly-sensitive escalation) to decide.
    """
    started_iso = (
        transcript.started_at.isoformat().replace("+00:00", "Z")
        if transcript.started_at
        else ""
    )
    # ended_at = started + duration when we know the duration.
    ended_iso = started_iso
    if transcript.started_at and transcript.duration_seconds > 0:
        from datetime import timedelta

        ended = transcript.started_at + timedelta(
            seconds=transcript.duration_seconds
        )
        ended_iso = ended.isoformat().replace("+00:00", "Z")

    conv_id = conversation_id_for(transcript)
    participants = _participants_metadata(transcript, user_display_name)

    metadata: dict = {
        "conversation_id": conv_id,
        "date": transcript.date,
        "source": transcript.source,
        "channel": "spoken",
        "context": transcript.context,
        "source_app": transcript.source,
        "source_session_id": transcript.call_id,
        "capture_source": CAPTURE_SOURCE,
        "diarization_method": transcript.diarization_method,
        "duration_seconds": transcript.duration_seconds,
        "is_voice_note": transcript.is_voice_note,
        "participants": participants,
    }
    if started_iso:
        metadata["started_at"] = started_iso
        metadata["ended_at"] = ended_iso
    if transcript.language:
        metadata["language"] = transcript.language
    if transcript.tags:
        metadata["tags"] = transcript.tags

    # Privacy resolution.
    resolved_level = None
    if privacy_level:
        resolved_level = str(privacy_level).strip().upper()
    elif transcript.privacy_level == "L3":
        resolved_level = "L3"
    if resolved_level:
        metadata["privacy_level"] = resolved_level

    return metadata
