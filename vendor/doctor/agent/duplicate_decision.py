"""Record a duplicate-contact decision (merge / distinct) to duplicates.yaml.

The wiki's "Possible duplicate contacts" page (CM044) renders Combine /
Not-the-same buttons that POST to ``/api/v1/wiki/duplicates/decision`` on the
Doctor. We append the decision to ``<corrections_dir>/duplicates.yaml`` in the
exact schema the CM041 resolver (``identity_resolver/decisions.py``) reads:

    decisions:
      - merge: [abc123, def456]
      - distinct: [ghi789, jkl012]

IDs are short-ids (the hex tail of ``person_<hex>``) -- the same key both sides
use. ``distinct`` = permanent never-merge; ``merge`` = forced union. The
resolver applies them on the next sweep, and the page reads the file back to
stop re-nagging. This module owns the schema + the write; the web_ui route is
thin HTTP plumbing (sister to ``wiki_correct.py``).
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any, Dict, List

import yaml

_VALID_ACTIONS = {"merge", "distinct"}
# short-id shape: hex tails plus a safe alphanumeric set. Crucially this rejects
# path separators and dots, so a malformed/hostile id can never escape the
# corrections dir or poison the YAML.
_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class ValidationError(Exception):
    """Mirror of wiki_correct.ValidationError: carries an HTTP status."""

    def __init__(self, detail: str, status: int = 400):
        super().__init__(detail)
        self.detail = detail
        self.status = status


def corrections_dir() -> Path:
    return Path(
        os.path.expanduser(os.getenv("WIKI_CORRECTIONS_DIR", "~/.ostler/corrections"))
    )


def decisions_path() -> Path:
    return corrections_dir() / "duplicates.yaml"


def validate_payload(body: Any) -> Dict[str, Any]:
    """Normalise ``{"action": "merge"|"distinct", "ids": [short_id, ...]}``."""
    if not isinstance(body, dict):
        raise ValidationError("body must be a JSON object")

    action = body.get("action")
    if action not in _VALID_ACTIONS:
        raise ValidationError(
            f"action must be one of {sorted(_VALID_ACTIONS)}"
        )

    ids = body.get("ids")
    if not isinstance(ids, list) or len(ids) < 2:
        raise ValidationError("ids must be a list of at least 2 short-ids")

    seen: set = set()
    uniq: List[str] = []
    for x in ids:
        if not isinstance(x, str) or not _ID_RE.match(x):
            raise ValidationError(f"invalid short-id: {x!r}")
        if x not in seen:
            seen.add(x)
            uniq.append(x)
    if len(uniq) < 2:
        raise ValidationError("need at least 2 distinct short-ids")

    return {"action": action, "ids": uniq}


def _entries_for(normalised: Dict[str, Any]) -> List[Dict[str, List[str]]]:
    action, ids = normalised["action"], normalised["ids"]
    if action == "merge":
        return [{"merge": list(ids)}]
    # distinct: record every pair so the resolver vetoes each one independently.
    return [
        {"distinct": [ids[i], ids[j]]}
        for i in range(len(ids))
        for j in range(i + 1, len(ids))
    ]


def _same_set(a: Any, b: Any) -> bool:
    return isinstance(a, list) and isinstance(b, list) and set(a) == set(b)


def _load(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {"decisions": []}
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        raise ValidationError(
            f"existing duplicates.yaml is not valid YAML: {exc}", status=500
        )
    if not isinstance(data, dict):
        data = {}
    if not isinstance(data.get("decisions"), list):
        data["decisions"] = []
    return data


def write_decision(normalised: Dict[str, Any], *, path: Path | None = None) -> Dict[str, Any]:
    """Append the decision to duplicates.yaml, idempotently. Returns a result."""
    path = path or decisions_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _load(path)
    existing = data["decisions"]

    added: List[Dict[str, List[str]]] = []
    for entry in _entries_for(normalised):
        (key, value), = entry.items()
        already = any(
            isinstance(e, dict) and key in e and _same_set(e.get(key), value)
            for e in existing
        )
        if not already:
            existing.append(entry)
            added.append(entry)

    if added:
        path.write_text(
            yaml.safe_dump(data, sort_keys=False, default_flow_style=False),
            encoding="utf-8",
        )

    return {
        "status": "recorded",
        "action": normalised["action"],
        "ids": normalised["ids"],
        "added": added,
        "path": str(path),
    }
