"""Spoken source for the four-artefact conversation pipeline (HR015).

This package is the customer-install feed for the SPOKEN leg of the
human-conversation four-artefact spec (HR015 locked directive,
2026-05-09). It watches the Hub Mac's RemoteCapture (CM042) transcript
tree, normalises each FINISHED transcript into a cleaned
speaker-labelled transcript plus CM048 metadata, and hands each session
to the CM048 ConversationBundle processor (``pwg-convo process``).
CM048 then emits the four artefacts under
``~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/``.

It covers BOTH source types the brief calls out:

  - MEETING / CALL: a multi-speaker RemoteCapture session (Zoom,
    FaceTime, Teams, Meet, WhatsApp call audio).
  - VOICE NOTE: a short single-speaker capture. A voice note rides
    the exact same path (``channel="spoken"``) with no separate
    plumbing. The only difference is a single participant and no
    diarisation, which falls out naturally: the renderer copes with a
    one-participant transcript and the metadata simply carries one
    non-user participant (or none, for a pure self-memo).

This feed does NO capture / recording work. CM042 (the RemoteCapture
macOS app) owns recording + Whisper transcription and writes finished
markdown transcripts. This feed only READS those finished transcripts,
normalises them, and dispatches to CM048. It is intentionally
subprocess-coupled to CM048 (not an import) so the two stay
independently deployable, exactly like the email + iMessage feeds.

No real-person data is hard-coded anywhere in this package. The
RemoteCapture root is injectable so tests run against a synthetic
transcript fixture with no real names / transcripts.
"""

from .reader import CapturedTranscript, read_transcripts
from .renderer import build_metadata, render_transcript
from .pipeline import process_spoken, run as run_pipeline

__all__ = [
    "CapturedTranscript",
    "read_transcripts",
    "render_transcript",
    "build_metadata",
    "process_spoken",
    "run_pipeline",
]
