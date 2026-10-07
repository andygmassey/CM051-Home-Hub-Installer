"""Speaker naming for the Hub: identify and correct.

Two routes in ``ical-server.py`` call into this module:

  POST /api/v1/speakers/identify
      Caller: CM042 RemoteCapture ``SpeakersIdentifyService.swift`` (the Mac
      app). Request ``{transcript, attendees, timestamp, duration, source}``,
      response ``{speakers: [{label, person_id, display_name, confidence,
      reasoning}]}`` (a LIST, per ``SpeakerResolution.swift``).

  POST /api/v1/speakers/correct
      Accepts a user's correction ("Remote was actually Jane Doe") and stores
      it so LATER transcripts get the real name. Takes either
      ``{meeting_id?, attendees?, corrections: [{label, display_name,
      person_id?}]}`` or the CM031 ``SpeakerUpdateRequest`` shape
      ``{meeting_id, identifications: [{speaker_label, person_id,
      display_name, confidence, status}]}``.

How a label is resolved, in priority order:

  1. A stored correction (confidence 0.97). A correction for a GENERIC label
     ("Remote", "Speaker 2") is only applied when the corrected name is among
     this meeting's attendees, so "Remote = Jane" from last week's call never
     names a stranger on today's.
  2. The operator, for the "User" / "You" / "Me" label, when the operator's
     name is configured.
  3. A named label that matches a calendar attendee or a contact.
  4. A generic remote label with exactly ONE non-operator attendee.
  5. Otherwise unresolved: ``person_id`` and ``display_name`` are null and the
     confidence is 0. We never guess between several attendees.

NO VOICE DATA. The Hub holds no voiceprint registry by design (see
``api_conversation_speakers`` in ``ical-server.py``: the biometric never
crosses the wire in either direction), so there is nothing to match audio
against here. "Existing voice data" is limited to the text identity hints
CM048 already writes, and those arrive through the corrections store.

This module is pure: the contact directory and the operator names are passed
in, and the store path is a parameter, so it is testable with no Oxigraph.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
import threading
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

MAX_ATTENDEES = 200
MAX_NAME_CHARS = 200
MAX_LABELS = 32
MAX_CORRECTIONS_PER_REQUEST = 64
MAX_STORED_CORRECTIONS = 5000
MAX_TRANSCRIPT_CHARS = 4 * 1024 * 1024

CORRECTION_CONFIDENCE = 0.97
OPERATOR_CONFIDENCE = 0.90
EXACT_ATTENDEE_CONFIDENCE = 0.92
DIRECTORY_CONFIDENCE = 0.85
SOLE_REMOTE_CONFIDENCE = 0.80
FIRST_NAME_CONFIDENCE = 0.75
NOT_IN_CONTACTS_CAP = 0.60
AMBIGUOUS_CONTACT_CAP = 0.40

_LABEL_LINE = re.compile(r"^\s*[\[\(]?([A-Za-z][\w .'\-]{0,39}?)[\]\)]?\s*:\s", re.MULTILINE)
_OPERATOR_LABELS = {"user", "you", "me", "self", "host"}
_GENERIC_RE = re.compile(
    r"^(user|you|me|self|host|remote|other|others|unknown|guest|caller|"
    r"speaker ?\d+|spk ?\d+|s\d+|participant ?\d*)$"
)

_lock = threading.Lock()


def default_store_path() -> Path:
    return Path(
        os.environ.get("OSTLER_SPEAKER_CORRECTIONS")
        or os.path.join(
            os.environ.get("OSTLER_STATE_DIR") or os.path.expanduser("~/.ostler/state"),
            "speaker_corrections.json",
        )
    )


def norm(value) -> str:
    """Casefolded, accent-folded, whitespace-collapsed form for matching."""
    if not isinstance(value, str):
        return ""
    folded = unicodedata.normalize("NFKD", value)
    folded = "".join(c for c in folded if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^\w\s']", " ", folded.casefold()).split())


def is_generic(label_norm: str) -> bool:
    return bool(_GENERIC_RE.match(label_norm))


def clean_attendee(raw) -> str:
    """Display name from a calendar attendee string. ``"Jane Doe <j@x.com>"``
    -> ``"Jane Doe"``; a bare address -> its local part with separators turned
    into spaces; anything not a string -> empty."""
    if not isinstance(raw, str):
        return ""
    text = raw.strip()
    text = re.sub(r"<[^>]*>", "", text).strip().strip("\"'")
    if "@" in text:
        text = text.split("@", 1)[0].replace(".", " ").replace("_", " ").strip()
    return " ".join(text.split())[:MAX_NAME_CHARS]


def parse_labels(transcript: str) -> list[str]:
    """Distinct speaker labels in order of first appearance."""
    seen: list[str] = []
    keys: set[str] = set()
    for match in _LABEL_LINE.finditer(transcript):
        label = " ".join(match.group(1).split())
        key = norm(label)
        if key and key not in keys:
            keys.add(key)
            seen.append(label)
            if len(seen) >= MAX_LABELS:
                break
    return seen


def _slug(name: str, slug_fn) -> str | None:
    try:
        return slug_fn(name) if slug_fn else None
    except Exception:
        return None


class _Directory:
    """Contact lookup over ``[{"name": ...}]`` rows (built once per request)."""

    def __init__(self, rows, slug_fn):
        self._by_norm: dict[str, list[str]] = {}
        self._by_first: dict[str, set[str]] = {}
        self._slug_fn = slug_fn
        for row in rows or []:
            name = row.get("name") if isinstance(row, dict) else None
            key = norm(name)
            if not key:
                continue
            self._by_norm.setdefault(key, []).append(name)
            self._by_first.setdefault(key.split(" ")[0], set()).add(key)

    def exact(self, name: str):
        """(person_id, display_name, ambiguous) for an exact-name contact."""
        hits = self._by_norm.get(norm(name), [])
        if not hits:
            return None
        if len(hits) > 1:
            return None, hits[0], True
        return _slug(hits[0], self._slug_fn), hits[0], False

    def unique_first(self, first: str):
        keys = self._by_first.get(norm(first).split(" ")[0] if first else "", set())
        if len(keys) != 1:
            return None
        return self.exact(next(iter(keys)))


def load_corrections(store: Path) -> list[dict]:
    try:
        data = json.loads(Path(store).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    items = data.get("corrections") if isinstance(data, dict) else None
    return [c for c in items or [] if isinstance(c, dict)]


def _save(store: Path, corrections: list[dict]) -> None:
    store = Path(store)
    store.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=store.parent, prefix=".speaker_corrections.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "corrections": corrections}, fh, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, store)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _validate_attendees(raw):
    if raw is None:
        return [], None
    if not isinstance(raw, list) or len(raw) > MAX_ATTENDEES:
        return None, f"'attendees' must be a list of at most {MAX_ATTENDEES} strings"
    if any(not isinstance(a, str) for a in raw):
        return None, "'attendees' must be a list of strings"
    names, seen = [], set()
    for a in raw:
        name = clean_attendee(a)
        key = norm(name)
        if key and key not in seen:
            seen.add(key)
            names.append(name)
    return names, None


def identify(payload, directory_rows, operator_names=(), slug_fn=None, store=None):
    """Handle POST /api/v1/speakers/identify. Returns ``(body, status)``."""
    if not isinstance(payload, dict):
        return {"error": "body must be a JSON object"}, 400
    transcript = payload.get("transcript")
    if not isinstance(transcript, str) or not transcript.strip():
        return {"error": "missing 'transcript'"}, 400
    if len(transcript) > MAX_TRANSCRIPT_CHARS:
        return {"error": "'transcript' too long"}, 413
    attendees, err = _validate_attendees(payload.get("attendees"))
    if err:
        return {"error": err}, 400
    for key in ("timestamp", "source"):
        if payload.get(key) is not None and not isinstance(payload.get(key), str):
            return {"error": f"'{key}' must be a string"}, 400
    duration = payload.get("duration")
    if duration is not None and (isinstance(duration, bool) or not isinstance(duration, (int, float))):
        return {"error": "'duration' must be a number"}, 400

    labels = parse_labels(transcript)
    directory = _Directory(directory_rows, slug_fn)
    corrections = load_corrections(store or default_store_path())
    operator_norms = {norm(n) for n in operator_names if norm(n)}
    operator_name = next((n for n in operator_names if norm(n)), None)

    remote_pool = [a for a in attendees if norm(a) not in operator_norms]
    attendee_norms = {norm(a): a for a in attendees}
    generic_remote_labels = [
        l for l in labels
        if is_generic(norm(l)) and norm(l) not in _OPERATOR_LABELS
    ]

    def from_name(name, base, why):
        hit = directory.exact(name)
        if hit is None:
            return {
                "person_id": None, "display_name": name,
                "confidence": min(base, NOT_IN_CONTACTS_CAP),
                "reasoning": f"{why}; no matching contact",
            }
        pid, shown, ambiguous = hit
        if ambiguous:
            return {
                "person_id": None, "display_name": shown,
                "confidence": min(base, AMBIGUOUS_CONTACT_CAP),
                "reasoning": f"{why}; several contacts share this name",
            }
        return {"person_id": pid, "display_name": shown, "confidence": base, "reasoning": why}

    out = []
    for label in labels:
        lkey = norm(label)
        result = None

        # 1. stored corrections, newest first
        for c in reversed(corrections):
            if c.get("label_norm") != lkey:
                continue
            cname = c.get("display_name") or ""
            if is_generic(lkey) and norm(cname) not in attendee_norms:
                continue
            result = {
                "person_id": c.get("person_id") or None,
                "display_name": cname,
                "confidence": CORRECTION_CONFIDENCE,
                "reasoning": "user correction",
            }
            break

        # 2. the operator
        if result is None and lkey in _OPERATOR_LABELS:
            if operator_name:
                result = from_name(operator_name, OPERATOR_CONFIDENCE, "operator label")
            else:
                result = {"person_id": None, "display_name": None, "confidence": 0.0,
                          "reasoning": "operator name not configured"}

        # 3. named label
        if result is None and not is_generic(lkey):
            if lkey in attendee_norms:
                result = from_name(attendee_norms[lkey], EXACT_ATTENDEE_CONFIDENCE,
                                   "label matches a calendar attendee")
            else:
                first = [a for a in remote_pool if norm(a).split(" ")[0] == lkey.split(" ")[0]]
                if len(first) == 1 and " " not in lkey:
                    result = from_name(first[0], FIRST_NAME_CONFIDENCE,
                                       "label matches one attendee's first name")
                else:
                    hit = directory.exact(label)
                    if hit is not None:
                        result = from_name(label, DIRECTORY_CONFIDENCE, "label matches a contact")

        # 4. the only other person in the room
        if result is None and lkey in {norm(l) for l in generic_remote_labels}:
            if len(remote_pool) == 1 and len(generic_remote_labels) == 1:
                result = from_name(remote_pool[0], SOLE_REMOTE_CONFIDENCE,
                                   "only one non-operator attendee")
            elif len(remote_pool) > 1:
                result = {"person_id": None, "display_name": None, "confidence": 0.0,
                          "reasoning": f"{len(remote_pool)} possible attendees; "
                                       "a correction is needed to choose"}

        if result is None:
            result = {"person_id": None, "display_name": None, "confidence": 0.0,
                      "reasoning": "no attendee or contact matched"}
        out.append({"label": label, **result})

    return {"speakers": out}, 200


def record_corrections(payload, slug_fn=None, store=None, now=None):
    """Handle POST /api/v1/speakers/correct. Returns ``(body, status)``."""
    if not isinstance(payload, dict):
        return {"error": "body must be a JSON object"}, 400
    attendees, err = _validate_attendees(payload.get("attendees"))
    if err:
        return {"error": err}, 400
    meeting_id = payload.get("meeting_id")
    if meeting_id is not None and (not isinstance(meeting_id, str)
                                   or not re.match(r"^[A-Za-z0-9_-]{1,128}$", meeting_id)):
        return {"error": "invalid 'meeting_id'"}, 400

    raw = payload.get("corrections")
    shape = "corrections"
    if raw is None:
        raw = payload.get("identifications")
        shape = "identifications"
    if not isinstance(raw, list) or not raw:
        return {"error": "need a non-empty 'corrections' or 'identifications' list"}, 400
    if len(raw) > MAX_CORRECTIONS_PER_REQUEST:
        return {"error": f"at most {MAX_CORRECTIONS_PER_REQUEST} corrections per request"}, 413

    entries, skipped = [], 0
    stamp = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    for item in raw:
        if not isinstance(item, dict):
            return {"error": "each correction must be an object"}, 400
        label = item.get("label") if shape == "corrections" else item.get("speaker_label")
        name = item.get("display_name")
        pid = item.get("person_id")
        for field, val in (("label", label), ("display_name", name)):
            if val is not None and (not isinstance(val, str) or len(val) > MAX_NAME_CHARS):
                return {"error": f"invalid '{field}'"}, 400
        if pid is not None and (not isinstance(pid, str) or len(pid) > 200):
            return {"error": "invalid 'person_id'"}, 400
        status = item.get("status")
        if shape == "identifications" and status not in (None, "confirmed", "corrected", "named"):
            skipped += 1  # unknown / rejected / pending: nothing to learn
            continue
        if not label or not norm(label):
            return {"error": "missing 'label'"}, 400
        if not name or not norm(name):
            if shape == "identifications":
                skipped += 1
                continue
            return {"error": "missing 'display_name'"}, 400
        entries.append({
            "label_norm": norm(label), "label": " ".join(label.split()),
            "display_name": " ".join(name.split()),
            "person_id": pid or _slug(name, slug_fn),
            "attendees_norm": sorted(norm(a) for a in attendees),
            "meeting_id": meeting_id, "created_at": stamp,
        })

    if not entries:
        return {"ok": True, "stored": 0, "skipped": skipped}, 200

    path = store or default_store_path()
    with _lock:
        existing = load_corrections(path)
        for e in entries:
            existing = [c for c in existing
                        if not (c.get("label_norm") == e["label_norm"]
                                and norm(c.get("display_name")) == norm(e["display_name"]))]
            existing.append(e)
        existing = existing[-MAX_STORED_CORRECTIONS:]
        try:
            _save(path, existing)
        except OSError as exc:
            return {"error": f"could not store corrections: {exc.__class__.__name__}"}, 503
    return {"ok": True, "stored": len(entries), "skipped": skipped}, 200
