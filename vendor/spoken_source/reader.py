"""Read finished RemoteCapture (CM042) transcripts from the Hub Mac.

CM042's ``TranscriptWriter`` writes one markdown file per finished
recording session into a year / month tree under the configured
transcripts directory:

    <root>/YYYY/MM/yyyy-MM-dd-HHmm-<source>-call.md

Each file is YAML front matter followed by a ``## Transcript`` body.
The front matter (written by CM042 ``TranscriptBuilder``) carries:

    title:             yyyy-MM-dd-HH-mm-<source>-call
    call_id:           the recording session id (stable key)
    timestamp:         ISO 8601 start time
    duration_seconds:  integer
    source:            zoom | facetime | whatsapp | teams | meet | unknown
    context:           meeting | catch-up | interview | presentation | ...
    privacy_level:     L0 | L1 | L2 | L3  (CM042 default is L2)
    language:          optional BCP-47 language tag
    participants:      list of { speaker_label, person_id?,
                                 display_name, confidence? }
    diarization_method: stream_separation | pyannote | manual
    tags:              optional [a, b, c]

The body is already speaker-labelled (CM042's diarizer maps the raw
USER / SPEAKER_01 labels onto participant display names at write
time), one line per utterance:

    **<DisplayName>** [MM:SS]: <text>

So this reader parses an ALREADY-CLEAN transcript; it does not have to
diarise or map raw labels. It turns the file into a
``CapturedTranscript`` record that the renderer + metadata builder
consume.

Reading the transcript tree needs no special permission beyond normal
access to ``~/Documents/Ostler/Transcripts`` (the user-facing zone).
The default root mirrors CM042 ``OstlerPaths.defaultTranscriptsDir()``
and honours the same env overrides CM042 ``AppConfiguration`` reads
(``OSTLER_TRANSCRIPTS_DIR`` first, then the legacy
``CM042_TRANSCRIPT_DIR``).

No real-person data is hard-coded here. ``transcripts_dir`` is
injectable so tests run against a synthetic fixture tree.
"""
from __future__ import annotations

import logging
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


def _default_transcripts_dir() -> Path:
    """Resolve the RemoteCapture transcripts root.

    Mirrors CM042 ``AppConfiguration``'s override chain so this feed
    and the recorder agree on where finished transcripts live:
    ``OSTLER_TRANSCRIPTS_DIR`` first, then the legacy
    ``CM042_TRANSCRIPT_DIR``, then ``~/Documents/Ostler/Transcripts``.
    """
    override = os.getenv("OSTLER_TRANSCRIPTS_DIR") or os.getenv(
        "CM042_TRANSCRIPT_DIR"
    )
    if override:
        return Path(override).expanduser()
    return Path.home() / "Documents" / "Ostler" / "Transcripts"


@dataclass
class CapturedParticipant:
    """One participant resolved from the transcript front matter."""

    speaker_label: str
    display_name: str
    person_id: Optional[str] = None
    confidence: Optional[float] = None


@dataclass
class CapturedUtterance:
    """One speaker-labelled line from the transcript body."""

    speaker: str       # display name as written by CM042
    timestamp: str     # MM:SS or HH:MM:SS offset string, may be empty
    text: str


@dataclass
class CapturedTranscript:
    """A single finished RemoteCapture session after parsing."""

    call_id: str                       # CM042 session id (stable key)
    source_path: Path
    started_at: Optional[datetime] = None
    duration_seconds: int = 0
    source: str = "unknown"            # zoom | facetime | teams | ...
    context: str = "meeting"
    privacy_level: Optional[str] = None  # L0..L3 if the recorder set it
    language: Optional[str] = None
    diarization_method: str = ""
    tags: list[str] = field(default_factory=list)
    participants: list[CapturedParticipant] = field(default_factory=list)
    utterances: list[CapturedUtterance] = field(default_factory=list)
    raw_front_matter: dict = field(default_factory=dict)

    @property
    def date(self) -> str:
        if self.started_at is None:
            return "0000-00-00"
        return self.started_at.date().isoformat()

    @property
    def is_voice_note(self) -> bool:
        """A voice note is a short single-speaker capture.

        Distinguished from a meeting by having at most one non-user
        participant. Diarisation is absent or trivial. The bundle path
        is identical; this flag is only used to label the rendered
        transcript honestly (and could drive a future renderer badge).
        """
        non_user = [
            p for p in self.participants if p.speaker_label.upper() != "USER"
        ]
        return len(non_user) <= 1 and self.source in (
            "voice_note",
            "voice-note",
            "memo",
            "voicememo",
            "unknown",
        )


# A transcript body line: ``**Name** [MM:SS]: text`` or ``**Name**: text``.
_LINE_RE = re.compile(
    r"^\*\*(?P<speaker>.+?)\*\*\s*(?:\[(?P<ts>[0-9:]+)\])?\s*:\s*(?P<text>.*)$"
)


def _parse_iso(value: str) -> Optional[datetime]:
    raw = (value or "").strip()
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _split_front_matter(text: str) -> tuple[str, str]:
    """Split ``---\\n<yaml>\\n---\\n<body>`` into (yaml, body).

    Returns ("", text) when there is no leading front-matter fence so a
    transcript without front matter still yields a (possibly empty)
    body rather than raising.
    """
    if not text.startswith("---"):
        return "", text
    # Find the closing fence on its own line.
    lines = text.splitlines()
    # lines[0] == "---". Find the next line that is exactly "---".
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            yaml_block = "\n".join(lines[1:idx])
            body = "\n".join(lines[idx + 1:])
            return yaml_block, body
    return "", text


def _parse_front_matter(yaml_block: str) -> dict:
    """Parse the CM042 front matter.

    Prefers PyYAML when available; falls back to a small line parser
    that handles the flat scalars plus the nested ``participants`` list
    and the ``tags: [a, b]`` inline list CM042 emits. The fallback
    keeps the feed working on a venv without PyYAML (the contacts /
    privacy map loader is the only other yaml consumer and degrades
    gracefully there too).
    """
    try:
        import yaml

        data = yaml.safe_load(yaml_block)
        if isinstance(data, dict):
            return data
    except ImportError:
        pass
    except Exception as exc:  # pragma: no cover -- defensive
        logger.warning("PyYAML could not parse front matter: %s", exc)
    return _parse_front_matter_fallback(yaml_block)


def _parse_front_matter_fallback(yaml_block: str) -> dict:
    """Minimal parser for the exact shape CM042 emits.

    Handles top-level ``key: value`` scalars, ``tags: [a, b, c]`` inline
    lists, and the ``participants:`` block of
    ``  - speaker_label: ...`` entries with indented child keys.
    """
    out: dict = {}
    participants: list[dict] = []
    current: Optional[dict] = None
    in_participants = False

    for raw_line in yaml_block.splitlines():
        if not raw_line.strip():
            continue
        stripped = raw_line.strip()

        if stripped == "participants:":
            in_participants = True
            current = None
            continue

        if in_participants and stripped.startswith("- "):
            current = {}
            participants.append(current)
            stripped = stripped[2:].strip()
            # The dash line itself carries the first key.
            if ":" in stripped:
                key, _, value = stripped.partition(":")
                current[key.strip()] = value.strip()
            continue

        if in_participants and current is not None and raw_line.startswith(" "):
            # An indented child key of the current participant.
            if ":" in stripped:
                key, _, value = stripped.partition(":")
                current[key.strip()] = value.strip()
            continue

        # Any non-indented key ends the participants block.
        in_participants = False
        current = None
        if ":" not in stripped:
            continue
        key, _, value = stripped.partition(":")
        key = key.strip()
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            out[key] = [v.strip() for v in inner.split(",") if v.strip()]
        else:
            out[key] = value

    if participants:
        out["participants"] = participants
    return out


def _coerce_int(value: object, default: int = 0) -> int:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def _coerce_float(value: object) -> Optional[float]:
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _parse_participants(raw: object) -> list[CapturedParticipant]:
    out: list[CapturedParticipant] = []
    if not isinstance(raw, list):
        return out
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        label = str(entry.get("speaker_label") or "").strip()
        display = str(entry.get("display_name") or "").strip()
        if not label and not display:
            continue
        person_id = entry.get("person_id")
        out.append(
            CapturedParticipant(
                speaker_label=label or display,
                display_name=display or label,
                person_id=(str(person_id).strip() if person_id else None),
                confidence=_coerce_float(entry.get("confidence")),
            )
        )
    return out


def _parse_body(body: str) -> list[CapturedUtterance]:
    out: list[CapturedUtterance] = []
    # Drop a leading "## Transcript" heading if present.
    for raw_line in body.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            continue
        if line.strip().lower().startswith("## transcript"):
            continue
        match = _LINE_RE.match(line.strip())
        if not match:
            continue
        out.append(
            CapturedUtterance(
                speaker=match.group("speaker").strip(),
                timestamp=(match.group("ts") or "").strip(),
                text=match.group("text").strip(),
            )
        )
    return out


def parse_transcript_file(path: Path) -> Optional[CapturedTranscript]:
    """Parse one finished RemoteCapture markdown transcript.

    Returns ``None`` (and logs a warning) if the file cannot be read or
    carries no usable content, so one corrupt file never aborts a tick.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        logger.warning("Skipping unreadable transcript %s: %s", path, exc)
        return None

    yaml_block, body = _split_front_matter(text)
    front = _parse_front_matter(yaml_block) if yaml_block else {}

    call_id = str(front.get("call_id") or "").strip()
    if not call_id:
        # Without a stable call id we synthesise one from the filename
        # so the session still threads as a singleton rather than being
        # silently dropped.
        call_id = f"no-id-{path.stem}"

    started_at = _parse_iso(str(front.get("timestamp") or ""))
    if started_at is None:
        # Fall back to the file mtime so ordering and the date slug hold.
        try:
            started_at = datetime.fromtimestamp(
                path.stat().st_mtime, tz=timezone.utc
            )
        except OSError:
            started_at = None

    privacy_level = front.get("privacy_level")
    privacy_level = (
        str(privacy_level).strip().upper() if privacy_level else None
    )

    return CapturedTranscript(
        call_id=call_id,
        source_path=path,
        started_at=started_at,
        duration_seconds=_coerce_int(front.get("duration_seconds")),
        source=str(front.get("source") or "unknown").strip() or "unknown",
        context=str(front.get("context") or "meeting").strip() or "meeting",
        privacy_level=privacy_level,
        language=(
            str(front.get("language")).strip()
            if front.get("language")
            else None
        ),
        diarization_method=str(front.get("diarization_method") or "").strip(),
        tags=[str(t).strip() for t in (front.get("tags") or []) if str(t).strip()],
        participants=_parse_participants(front.get("participants")),
        utterances=_parse_body(body),
        raw_front_matter=front,
    )


def read_transcripts(
    transcripts_dir: Optional[Path] = None,
    since_days: int = 30,
    now: Optional[datetime] = None,
) -> list[CapturedTranscript]:
    """Read finished RemoteCapture transcripts into a list.

    Args:
        transcripts_dir: RemoteCapture transcripts root (injectable for
            tests). Defaults to ``OSTLER_TRANSCRIPTS_DIR`` /
            ``CM042_TRANSCRIPT_DIR`` / ``~/Documents/Ostler/Transcripts``.
        since_days: only sessions started within the last N days
            (``0`` disables the cutoff). The fresh-install clamp so the
            first tick does not bundle a year of recordings.
        now: override for "now" (tests).

    A missing transcripts directory is treated as "no transcripts" (the
    walk yields nothing and the function returns ``[]``) so a Mac that
    has never run RemoteCapture does not error. Returns sessions
    newest-first so a tick processes recent conversations first.
    """
    transcripts_dir = transcripts_dir or _default_transcripts_dir()
    now = now or datetime.now(tz=timezone.utc)
    cutoff = None
    if since_days:
        cutoff = now.timestamp() - (since_days * 86400)

    if not transcripts_dir.exists():
        logger.info(
            "No RemoteCapture transcripts directory at %s; nothing to do.",
            transcripts_dir,
        )
        return []

    out: list[CapturedTranscript] = []
    for md_path in sorted(transcripts_dir.rglob("*.md")):
        # Skip CM042's migration sentinel and any non-transcript md.
        if md_path.name.startswith("."):
            continue
        transcript = parse_transcript_file(md_path)
        if transcript is None:
            continue
        if not transcript.utterances:
            # A transcript with front matter but no body is not a
            # conversation worth a bundle (e.g. a recording that
            # produced silence). Skip rather than emit an empty bundle.
            logger.info(
                "Skipping transcript with no utterances: %s", md_path
            )
            continue
        if (
            cutoff is not None
            and transcript.started_at is not None
            and transcript.started_at.timestamp() < cutoff
        ):
            continue
        out.append(transcript)

    out.sort(
        key=lambda t: (t.started_at is None, t.started_at),
        reverse=True,
    )
    logger.info(
        "Read %d finished RemoteCapture transcripts from %s",
        len(out),
        transcripts_dir,
    )
    return out
