"""One shape for ``metadata["participants"]``, whatever the producer sent.

The pipeline's readers expect a list of dicts (``id`` / ``display`` /
``role``). Not every producer sends that: CM031's iPhone / Watch envelope
(``APIClient.processEnvelope``) sends ``[String]``, the sorted speaker
labels, and ical-server passes it straight through. A bare string reaching
``p.get(...)`` raised AttributeError at 01_classify and failed every
iPhone / Watch conversation (v1.0.107 #12).

Every reader goes through :func:`normalise_participants`, so a string is
read as ``{"display": s}`` and anything that is neither a non-empty string
nor a dict is dropped rather than crashing a step.
"""
from __future__ import annotations

from typing import Any


def normalise_participants(raw: Any) -> list[dict]:
    """Return ``raw`` as a list of participant dicts.

    - dict entries pass through unchanged (same object),
    - a non-empty string ``s`` becomes ``{"display": s.strip()}``,
    - blank strings and any other type are dropped,
    - a non-list ``raw`` (None, a bare string, a dict) yields ``[]``.
    """
    if not isinstance(raw, (list, tuple)):
        return []
    out: list[dict] = []
    for entry in raw:
        if isinstance(entry, dict):
            out.append(entry)
        elif isinstance(entry, str):
            label = entry.strip()
            if label:
                out.append({"display": label})
    return out
