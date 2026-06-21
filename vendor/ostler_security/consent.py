"""Consent-record registry under ``~/.ostler/posture/consent.json``.

This is the SIBLING of ``ostler_security/posture.py`` – different
lifetime, different writer, different reader, different consumer. Do
NOT co-locate consent records with security-posture markers. The
brief at ``/tmp/plan_legal_position_implementation_2026-05-02.md`` §4
makes this distinction load-bearing.

Marker contract: a single JSON file at
``~/.ostler/posture/consent.json`` (note the directory: ``posture/``,
NOT ``security-posture/``) shaped as a registry keyed by
``tickbox_id``::

    {
        "schema_version": 1,
        "records": {
            "article_9_special_category_consent": {
                "tickbox_id": "...",
                "wording_hash": "<sha256-hex>",
                "wording_text": "<full verbatim>",
                "wording_version": "v1.0-2026-05-02",
                "decision": "accepted" | "declined",
                "timestamp": "<ISO-8601 UTC>",
                "region_at_capture": "eu" | "uk" | "us" | "row",
                "hub_version_at_capture": "0.1.0",
                "user_id": "<from install.sh>",
                "scope": null | "speaker_identification_only"
            },
            ...
        }
    }

Writes are atomic (``tmp + rename``), mode ``0600``. The file is
created on first write; consumers must handle missing-file as "no
records yet". Read paths return ``None`` when a tickbox has never
been recorded.

Public API:

- :func:`record_consent` – persist a decision for one tickbox.
- :func:`read_consent` – fetch the current record for one tickbox.
- :func:`all_consents` – fetch the full registry.
- :func:`is_current` – does the stored record's wording match a
  given expected hash? (Used by Doctor and the Rust startup gates
  to decide whether a re-prompt is needed.)
"""
from __future__ import annotations

import json
import logging
import os
import stat
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

CONSENT_SCHEMA_VERSION = 1


def _consent_dir() -> Path:
    """Return ``~/.ostler/posture/``, creating it if missing.

    Honours ``$OSTLER_HOME`` for tests and non-default deployments;
    defaults to ``~/.ostler/``. Note: ``posture`` (consent records),
    NOT ``security-posture`` (which is for runtime encryption
    attestation).
    """
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    posture = base / "posture"
    posture.mkdir(parents=True, exist_ok=True)
    return posture


def _consent_file() -> Path:
    return _consent_dir() / "consent.json"


def _load_registry() -> dict:
    path = _consent_file()
    if not path.exists():
        return {"schema_version": CONSENT_SCHEMA_VERSION, "records": {}}
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        logger.warning(
            "Could not read consent registry at %s: %s; treating as empty.",
            path, exc,
        )
        return {"schema_version": CONSENT_SCHEMA_VERSION, "records": {}}
    if not isinstance(data, dict) or "records" not in data:
        logger.warning(
            "Consent registry at %s is malformed (missing 'records'); "
            "treating as empty.", path,
        )
        return {"schema_version": CONSENT_SCHEMA_VERSION, "records": {}}
    if not isinstance(data["records"], dict):
        logger.warning(
            "Consent registry 'records' field is not an object at %s; "
            "treating as empty.", path,
        )
        return {"schema_version": CONSENT_SCHEMA_VERSION, "records": {}}
    return data


def _atomic_write(path: Path, payload: dict) -> None:
    """Write ``payload`` to ``path`` atomically with mode 0600.

    Mirrors ``ostler_security.posture._atomic_write`` semantics
    (tmp + rename). Mode is forced to 0600 BEFORE the rename so a
    racing process never sees a world-readable file.
    """
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n")
    try:
        os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    except OSError as exc:
        # Best-effort chmod; rename anyway. Doctor may surface mode
        # mismatch separately.
        logger.warning("Could not chmod 0600 %s: %s", tmp, exc)
    tmp.replace(path)


def record_consent(
    tickbox_id: str,
    wording_text: str,
    wording_version: str,
    decision: str,
    region: str,
    *,
    wording_hash: Optional[str] = None,
    hub_version: Optional[str] = None,
    user_id: Optional[str] = None,
    scope: Optional[str] = None,
) -> Path:
    """Persist a consent record for ``tickbox_id``.

    Args:
        tickbox_id: Stable identifier (e.g.
            ``"article_9_special_category_consent"``). Existing
            record under the same id is overwritten.
        wording_text: Full verbatim wording the user saw on screen.
        wording_version: Version string from the
            :class:`legal.consent_strings.ConsentString`.
        decision: ``"accepted"`` or ``"declined"``.
        region: ``"eu"`` | ``"uk"`` | ``"us"`` | ``"row"`` per
            ``region.detect_region``. Captured at the moment of
            consent so a later region change is visible.
        wording_hash: Optional pre-computed SHA-256 of ``wording_text``.
            If omitted, computed here. Provide explicitly when the
            caller has already invoked ``ConsentString.sha256()``
            so we never disagree about which hash was stored.
        hub_version: Version of the Hub that captured the consent.
            Recommended ``"0.1.0"`` at v0.1; reads from env
            ``OSTLER_HUB_VERSION`` if not provided.
        user_id: Stable user identifier from ``install.sh``
            (currently used for the LaunchAgent label suffix etc.).
        scope: Optional sub-scope (e.g.
            ``"speaker_identification_only"``). Forward-compat for
            EU AI Act Annex III: a future emotion-recognition feature
            requires a NEW tickbox, never silent expansion of an
            existing record.

    Returns:
        Path to the consent file (single registry, not per-tickbox).

    Raises:
        ValueError: ``decision`` is not ``"accepted"``/``"declined"``,
            ``region`` is not one of the four allowed values, or
            ``tickbox_id``/``wording_text`` is empty.
    """
    if decision not in ("accepted", "declined"):
        raise ValueError(
            f"decision must be 'accepted' or 'declined', got {decision!r}"
        )
    if region not in ("eu", "uk", "us", "row"):
        raise ValueError(
            f"region must be one of eu/uk/us/row, got {region!r}"
        )
    if not tickbox_id:
        raise ValueError("tickbox_id is required")
    if not wording_text:
        raise ValueError("wording_text is required")

    if wording_hash is None:
        import hashlib
        wording_hash = hashlib.sha256(wording_text.encode("utf-8")).hexdigest()

    if hub_version is None:
        hub_version = os.environ.get("OSTLER_HUB_VERSION", "0.1.0")

    record = {
        "tickbox_id": tickbox_id,
        "wording_hash": wording_hash,
        "wording_text": wording_text,
        "wording_version": wording_version,
        "decision": decision,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "region_at_capture": region,
        "hub_version_at_capture": hub_version,
        "user_id": user_id,
        "scope": scope,
    }

    registry = _load_registry()
    registry["schema_version"] = CONSENT_SCHEMA_VERSION
    registry["records"][tickbox_id] = record

    path = _consent_file()
    _atomic_write(path, registry)
    return path


def read_consent(tickbox_id: str) -> Optional[dict]:
    """Return the stored consent record for ``tickbox_id`` or ``None``."""
    registry = _load_registry()
    return registry["records"].get(tickbox_id)


def all_consents() -> dict[str, dict]:
    """Return the full registry as ``{tickbox_id: record}``."""
    return dict(_load_registry()["records"])


def is_current(tickbox_id: str, expected_wording_hash: str) -> bool:
    """True if the stored record's hash matches ``expected_wording_hash``.

    Used by:

    - The Rust ``whatsapp-bridge`` startup gate – refuses to start
      when ``False``.
    - The iOS Companion (CM031) speaker-ID feature - does not enrol or
      match voice fingerprints (stored only on the iPhone) when
      ``voice_speaker_id_eu`` is ``False`` in EU. There is no Hub-side
      gate: the Hub never holds a voiceprint, only text speaker labels.
    - Doctor's "Consent" tile – flags amber on mismatch
      (renewal needed).

    Returns ``False`` when no record exists – treat missing as
    "consent not given".
    """
    record = read_consent(tickbox_id)
    if record is None:
        return False
    if record.get("decision") != "accepted":
        return False
    return record.get("wording_hash") == expected_wording_hash


def remove_all() -> None:
    """Wipe the consent registry. Used by install.sh on a "decline"
    abort, to satisfy the Article 9 invariant "leaves no
    ``~/.ostler/`` residue if the user declines".

    Safe to call even when no registry exists.
    """
    path = _consent_file()
    if path.exists():
        try:
            path.unlink()
        except OSError as exc:
            logger.warning("Could not unlink consent registry %s: %s", path, exc)
