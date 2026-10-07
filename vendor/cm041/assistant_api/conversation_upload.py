"""Chunked upload for conversations over the 1 MiB request limit.

``POST /api/v1/conversation/process`` rejects bodies over ``MAX_POST_BYTES``
(1 MiB) and the gateway in front of it caps the same route at 1 MiB, so a long
meeting transcript could not be uploaded at all. This module adds a sibling
route that takes the transcript in parts and reassembles it on the Hub:

    POST /api/v1/conversation/upload-part
    {
      "meeting_id": "<uuid or slug>",     # same id rules as conversation/process
      "part_index": 0,                    # 0-based
      "part_total": 3,                    # same on every part, 1..MAX_PARTS
      "transcript": "<this part's text>", # each part's request body <= 1 MiB
      "metadata": {...}                   # read from part 0 only; optional
    }

Each part is acknowledged with 200 and the list of parts still missing. When the
last missing part lands the transcript is joined in index order and handed to the
normal ``conversation/process`` path under ``metadata.meeting_id = meeting_id``,
so the Hub's response is the usual 202 ``{job_id, status, state_url}``.

Properties:
  * Idempotent: re-sending a part with identical text is a 200 no-op, so a
    client may retry after a timeout. Different text for an index already held
    is 409, never a silent overwrite.
  * Order independent: parts may arrive in any order.
  * Bounded: at most ``MAX_PARTS`` parts and ``MAX_ASSEMBLED_BYTES`` in total.
  * Nothing is half-processed: the pipeline runs only when every part is here.
  * Abandoned uploads are deleted after ``EXPIRY_SECONDS``.
  * ``meeting_id`` is validated before it names a directory, so it cannot
    traverse out of the spool directory.

Pure module: the spool directory and the processing function are parameters.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
from pathlib import Path

MAX_PARTS = 64
MAX_PART_BYTES = 1_048_576
MAX_ASSEMBLED_BYTES = 32 * 1024 * 1024
EXPIRY_SECONDS = 24 * 3600

_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE
)
_SLUG_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

_lock = threading.Lock()


def default_spool_dir() -> Path:
    return Path(
        os.environ.get("OSTLER_UPLOAD_SPOOL_DIR")
        or os.path.join(
            os.environ.get("OSTLER_STATE_DIR") or os.path.expanduser("~/.ostler"),
            "upload_spool",
        )
    )


def safe_meeting_id(value) -> bool:
    return isinstance(value, str) and bool(_UUID_RE.match(value) or _SLUG_RE.match(value))


def _sweep(spool: Path, now: float) -> None:
    try:
        entries = list(spool.iterdir())
    except OSError:
        return
    for d in entries:
        try:
            if d.is_dir() and now - d.stat().st_mtime > EXPIRY_SECONDS:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            continue


def _held_bytes(d: Path) -> int:
    return sum(p.stat().st_size for p in d.glob("part-*.txt"))


def receive_part(payload, process_fn, spool_dir=None, now=None):
    """Handle one upload part. Returns ``(body, status)``.

    ``process_fn(payload_dict) -> (body, status)`` is the normal
    ``api_conversation_process``.
    """
    if not isinstance(payload, dict):
        return {"error": "body must be a JSON object"}, 400
    meeting_id = payload.get("meeting_id")
    if not safe_meeting_id(meeting_id):
        return {"error": "invalid or missing 'meeting_id'"}, 400
    index, total = payload.get("part_index"), payload.get("part_total")
    for name, val in (("part_index", index), ("part_total", total)):
        if isinstance(val, bool) or not isinstance(val, int):
            return {"error": f"'{name}' must be an integer"}, 400
    if not 1 <= total <= MAX_PARTS:
        return {"error": f"'part_total' must be 1..{MAX_PARTS}"}, 400
    if not 0 <= index < total:
        return {"error": "'part_index' must be 0..part_total-1"}, 400
    text = payload.get("transcript")
    if not isinstance(text, str) or not text:
        return {"error": "missing 'transcript'"}, 400
    data = text.encode("utf-8")
    if len(data) > MAX_PART_BYTES:
        return {"error": f"part too large (max {MAX_PART_BYTES} bytes)"}, 413
    metadata = payload.get("metadata")
    if metadata is not None and not isinstance(metadata, dict):
        return {"error": "'metadata' must be an object"}, 400

    spool = Path(spool_dir) if spool_dir else default_spool_dir()
    clock = now if now is not None else time.time()
    with _lock:
        spool.mkdir(parents=True, exist_ok=True)
        os.chmod(spool, 0o700)
        _sweep(spool, clock)
        d = spool / meeting_id
        d.mkdir(exist_ok=True)

        meta_file = d / "meta.json"
        if meta_file.exists():
            held_total = json.loads(meta_file.read_text(encoding="utf-8")).get("part_total")
            if held_total != total:
                return {"error": "part_total differs from earlier parts",
                        "expected_part_total": held_total}, 409
        else:
            meta_file.write_text(json.dumps({"part_total": total}), encoding="utf-8")

        target = d / f"part-{index:06d}.txt"
        if target.exists():
            if target.read_bytes() != data:
                return {"error": f"part {index} already received with different content"}, 409
        else:
            if _held_bytes(d) + len(data) > MAX_ASSEMBLED_BYTES:
                return {"error": f"upload exceeds {MAX_ASSEMBLED_BYTES} bytes in total"}, 413
            tmp = d / f".part-{index:06d}.tmp"
            tmp.write_bytes(data)
            os.replace(tmp, target)
        if index == 0 and metadata is not None:
            (d / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
        os.utime(d, (clock, clock))

        have = sorted(int(p.stem.split("-")[1]) for p in d.glob("part-*.txt"))
        missing = [i for i in range(total) if i not in have]
        if missing:
            return {"status": "part_received", "meeting_id": meeting_id,
                    "received": len(have), "part_total": total, "missing": missing}, 200

        # Complete: claim the directory so a racing duplicate of the last part
        # cannot process the same upload twice, then join and hand off.
        claimed = spool / f".done-{meeting_id}-{int(clock * 1000)}"
        os.replace(d, claimed)
        try:
            transcript = "".join(
                (claimed / f"part-{i:06d}.txt").read_text(encoding="utf-8")
                for i in range(total)
            )
            meta_path = claimed / "metadata.json"
            meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
        finally:
            shutil.rmtree(claimed, ignore_errors=True)

    meta = dict(meta)
    meta["meeting_id"] = meeting_id
    body, status = process_fn({"transcript": transcript, "metadata": meta})
    if isinstance(body, dict) and status < 400:
        body = {**body, "parts": total}
    return body, status
