"""Drive RemoteCapture (CM042) transcripts -> CM048 four-artefact bundle.

This is the product-path conversation-memory feed for the SPOKEN leg,
wired by a LaunchAgent tick (mirrors the email-bundle + imessage-bundle
ticks; see ``launchd/com.creativemachines.ostler.spoken-bundle.plist``).
On each tick it:

  1. Reads CM042's finished transcript tree under
     ``~/Documents/Ostler/Transcripts/YYYY/MM/`` (RemoteCapture writes
     one markdown file per finished recording session).
  2. Normalises each finished session into a cleaned speaker-labelled
     transcript + CM048 metadata (``channel="spoken"`` plus
     participants, source, capture timestamp, capture_source).
  3. Invokes ``pwg-convo process <transcript> <metadata>`` so CM048
     emits the four artefacts under
     ``~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/``.

Meetings / calls AND voice notes flow through this one feed; a voice
note is just a short single-speaker spoken capture and needs no
separate plumbing (see ``renderer.build_metadata``).

CM048 owns classification, enrichment, the L3 short-circuit, and the
four-artefact write. This module only produces transcript + metadata
and hands off. It is intentionally subprocess-coupled (not an import)
so the spoken source and CM048 stay independently deployable, exactly
like the email + iMessage feeds. It does NOT do any capture / recording
work; CM042 owns that.

Privacy: a transcript whose CM042 front matter marks it ``L3`` rides
through to ``metadata['privacy_level']`` so CM048's writer
short-circuits the gist arm (no Qdrant / Oxigraph). An optional
operator privacy map (source-or-context -> L3) lets a meeting type or
capture surface be pinned L3 on top of that. Default is unset, leaving
CM048's classifier inference (L2 baseline + sensitive escalation).

State: a watermark file records the call ids already bundled so a tick
only dispatches a session it has not seen before. A re-recorded /
re-transcribed session with a NEW call id is treated as a new
conversation; the same call id is skipped.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Optional

from .reader import CapturedTranscript, read_transcripts
from .renderer import build_metadata, conversation_id_for, render_transcript

logger = logging.getLogger(__name__)


# Engine-zone state under ~/.ostler/ (two-zone architecture). The
# watermark records the set of CM042 call ids already bundled.
def _default_state_dir() -> Path:
    override = os.getenv("OSTLER_STATE_DIR") or os.getenv("STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".ostler" / "workspace"


def _state_path() -> Path:
    return _default_state_dir() / "spoken_source_state.json"


def _load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"call_ids": []}


def _save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def _load_privacy_map(path: Optional[Path]) -> dict[str, str]:
    """Optional ``source``-or-``context`` -> privacy-level map.

    Reuses the contacts.yaml file shape under a ``spoken`` key so the
    operator can pin a capture surface (``source: zoom``) or a meeting
    type (``context: therapy``) to ``L3``. Lets a recurring sensitive
    meeting type land its bundle without reaching Qdrant / Oxigraph, on
    top of CM048's own classifier escalation. Missing file or PyYAML ->
    empty map (no operator overrides; CM048 inference still applies).

    Shape:
        spoken:
          sources:   { zoom: L2, therapy_app: L3 }
          contexts:  { therapy: L3, "1-on-1": L2 }
    """
    if path is None or not path.exists():
        return {}
    try:
        import yaml
    except ImportError:
        logger.warning("PyYAML not installed; spoken privacy map ignored")
        return {}
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        logger.warning("Could not parse privacy map %s: %s", path, exc)
        return {}
    spoken = data.get("spoken") or {}
    out: dict[str, str] = {}
    for bucket in ("sources", "contexts"):
        mapping = spoken.get(bucket) or {}
        if not isinstance(mapping, dict):
            continue
        for key, value in mapping.items():
            if value:
                out[f"{bucket}:{str(key).strip().lower()}"] = str(value).upper()
    return out


def _level_for_transcript(
    transcript: CapturedTranscript, privacy_map: dict[str, str]
) -> Optional[str]:
    """Return an operator-pinned privacy level for this session, or None.

    Checks the source then the context against the operator map. Only
    an explicit ``L3`` is returned (a benign ``L2`` mapping is left to
    CM048's default so the classifier can still escalate). When this
    returns ``None`` the transcript's own L3 front-matter flag (handled
    in ``build_metadata``) and CM048 inference take over.
    """
    source_key = f"sources:{(transcript.source or '').strip().lower()}"
    context_key = f"contexts:{(transcript.context or '').strip().lower()}"
    for key in (source_key, context_key):
        if privacy_map.get(key) == "L3":
            return "L3"
    return None


def _dispatch_to_cm048(
    transcript_md: str,
    metadata: dict,
    *,
    pwg_convo_cmd: list[str],
    dry_run: bool,
) -> int:
    """Write transcript + metadata to temp files and invoke
    ``pwg-convo process``. Returns the subprocess return code (0 ok).

    Temp files live in the engine-zone tmp and are cleaned up after;
    CM048 copies the raw transcript into its own state dir at step 00.
    """
    with tempfile.TemporaryDirectory(prefix="hr015_spoken_") as tmp:
        tdir = Path(tmp)
        tpath = tdir / "transcript.md"
        mpath = tdir / "metadata.json"
        tpath.write_text(transcript_md, encoding="utf-8")
        mpath.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        cmd = list(pwg_convo_cmd) + ["process", str(tpath), str(mpath)]
        if dry_run:
            cmd.append("--dry-run")
        logger.info(
            "Dispatching %s to CM048 (%s)",
            metadata["conversation_id"],
            " ".join(pwg_convo_cmd),
        )
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            logger.error(
                "pwg-convo failed for %s (rc=%d): %s",
                metadata["conversation_id"],
                proc.returncode,
                proc.stderr.strip()[:500],
            )
        return proc.returncode


def process_spoken(
    *,
    transcripts_dir: Optional[Path] = None,
    contacts_path: Optional[Path] = None,
    user_display_name: str = "You",
    since_days: int = 30,
    pwg_convo_cmd: Optional[list[str]] = None,
    state_path: Optional[Path] = None,
    dry_run: bool = False,
) -> dict:
    """Read RemoteCapture transcripts and dispatch new sessions to CM048.

    Returns a summary dict: sessions scanned, dispatched, skipped
    (already bundled), failed.
    """
    pwg_convo_cmd = pwg_convo_cmd or _resolve_pwg_convo_cmd()
    state_file = state_path or _state_path()
    state = _load_state(state_file)
    seen_ids: set[str] = set(state.get("call_ids", []))

    privacy_map = _load_privacy_map(contacts_path)

    transcripts = read_transcripts(
        transcripts_dir=transcripts_dir, since_days=since_days
    )

    scanned = dispatched = skipped = failed = 0
    for transcript in transcripts:
        scanned += 1
        if transcript.call_id in seen_ids:
            skipped += 1
            continue

        level = _level_for_transcript(transcript, privacy_map)
        transcript_md = render_transcript(transcript)
        metadata = build_metadata(
            transcript,
            user_display_name=user_display_name,
            privacy_level=level,
        )
        rc = _dispatch_to_cm048(
            transcript_md,
            metadata,
            pwg_convo_cmd=pwg_convo_cmd,
            dry_run=dry_run,
        )
        if rc == 0:
            dispatched += 1
            if not dry_run:
                seen_ids.add(transcript.call_id)
        else:
            failed += 1
            # Leave the watermark untouched so the next tick retries.

    if not dry_run:
        state["call_ids"] = sorted(seen_ids)
        _save_state(state_file, state)

    summary = {
        "sessions_scanned": scanned,
        "sessions_dispatched": dispatched,
        "sessions_skipped": skipped,
        "sessions_failed": failed,
    }
    logger.info("spoken source tick complete: %s", summary)
    return summary


def _resolve_pwg_convo_cmd() -> list[str]:
    """Resolve how to invoke CM048's CLI.

    Priority:
      1. ``PWG_CONVO_CMD`` env (space-split) -- the installer sets this
         to the absolute venv path on the Hub.
      2. ``pwg-convo`` on PATH (installed console script).
    """
    override = os.getenv("PWG_CONVO_CMD")
    if override:
        return override.split()
    return ["pwg-convo"]


def run(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="hr015-spoken-source",
        description="Feed RemoteCapture transcripts (meetings, calls, "
        "voice notes) into the CM048 four-artefact conversation pipeline.",
    )
    parser.add_argument("--transcripts-dir", type=Path, default=None)
    parser.add_argument("--contacts", type=Path, default=None)
    parser.add_argument(
        "--user-name", default=os.getenv("OSTLER_USER_DISPLAY_NAME", "You")
    )
    parser.add_argument("--since-days", type=int, default=30)
    parser.add_argument("--state-path", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        summary = process_spoken(
            transcripts_dir=args.transcripts_dir,
            contacts_path=args.contacts,
            user_display_name=args.user_name,
            since_days=args.since_days,
            state_path=args.state_path,
            dry_run=args.dry_run,
        )
    except FileNotFoundError as exc:
        logger.error("%s", exc)
        return 1
    except PermissionError as exc:
        logger.error("%s", exc)
        return 2
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(run())
