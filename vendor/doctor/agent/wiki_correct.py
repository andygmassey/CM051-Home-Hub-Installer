"""Wiki correction gateway endpoint logic (#277).

Sister piece to CM044's compiler/oxigraph_corrections.py
(commit 015736c). The CM044 compiler reads `pwg:Correction` triples
on each rebuild and prefers ``correctedValue`` over the original
fact text when both exist. This module is the write side: a
``POST /api/v1/wiki/correct`` endpoint that the inline pencil
overlay, the Doctor "Corrections" tab, and the CM031 assistant
chat tool all hit.

The fact-hash function is byte-identical to
``compiler.oxigraph_corrections.fact_hash`` so a hash computed on
either side resolves to the same correction key; the gateway
recomputes server-side as a defence-in-depth check.

Schema (per CM044 PR #26):

.. code-block:: turtle

    @prefix pwg: <https://pwg.dev/ontology#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .

    <correction:UUID> a pwg:Correction ;
        pwg:correctionSubject       <subject_uri> ;
        pwg:correctionFactHash      "<hash>" ;
        pwg:originalValue           "<text>" ;
        pwg:correctedValue          "<text>" ;
        pwg:correctedAt             "<iso>"^^xsd:dateTime ;
        pwg:correctionSource        "<enum>" ;
        pwg:correctionStatus        "<enum>" ;
        pwg:correctionReason        "<text>" .  # optional

Status default by source (per the brief):
    user-inline, user-doctor -> applied
    assistant                -> pending
"""
from __future__ import annotations

import hashlib
import os
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Optional, Tuple

import httpx

PWG_PREFIX_URL = "https://pwg.dev/ontology#"

# Source enum - keep in sync with the CM044 PR #26 contract and the
# correction_overlay.js / CM031 client.
SOURCE_USER_INLINE = "user-inline"
SOURCE_USER_DOCTOR = "user-doctor"
SOURCE_ASSISTANT = "assistant"
ALLOWED_SOURCES = frozenset({
    SOURCE_USER_INLINE,
    SOURCE_USER_DOCTOR,
    SOURCE_ASSISTANT,
})

# Status enum - same triple of values consumed by CM044's compiler.
STATUS_APPLIED = "applied"
STATUS_PENDING = "pending"
STATUS_REJECTED = "rejected"

# Required JSON fields the gateway accepts. Missing -> 415.
# Wrong type -> 400.
_REQUIRED_FIELDS: Tuple[str, ...] = (
    "subject_uri",
    "fact_hash",
    "original_value",
    "corrected_value",
    "source",
)
# Optional fields. Wrong type -> 400.
_OPTIONAL_FIELDS: Tuple[str, ...] = ("reason",)


# ---------------------------------------------------------------------------
# fact_hash (must match compiler.oxigraph_corrections.fact_hash exactly)
# ---------------------------------------------------------------------------

def fact_hash(subject_uri: str, fact_text: str) -> str:
    """16 hex chars of SHA-256 over ``subject_uri + "\\n" + fact_text``.

    Byte-identical to ``compiler.oxigraph_corrections.fact_hash`` in
    CM044 (commit 015736c). Don't reimplement -- if the algorithm
    moves, both sides move together.
    """
    payload = f"{subject_uri}\n{fact_text}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:16]


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

@dataclass
class ValidationError(Exception):
    """Carries an HTTP status code so the FastAPI handler can map it
    cleanly. ``status`` 415 = missing required field, 400 = bad type
    or out-of-range value, 422 = client-supplied fact_hash disagrees
    with what we recompute server-side."""

    status: int
    detail: str

    def __str__(self) -> str:
        return self.detail


def validate_payload(body: Any) -> Dict[str, Any]:
    """Validate the JSON request body, returning a normalised dict.

    Per CM044 #26's contract:
    - ``subject_uri``: str, must be a URI (http(s) scheme tolerated)
    - ``fact_hash``: str, 16 lowercase hex chars
    - ``original_value``: str, non-empty
    - ``corrected_value``: str, non-empty, must differ from original
    - ``source``: str, one of ALLOWED_SOURCES
    - ``reason``: str, optional

    Server-side recomputes ``fact_hash`` over
    ``subject_uri + "\\n" + original_value`` and rejects with 422 if
    the client's hash disagrees -- defence-in-depth against stale
    or forged hashes.
    """
    if not isinstance(body, dict):
        raise ValidationError(400, "body must be a JSON object")

    for field in _REQUIRED_FIELDS:
        if field not in body:
            raise ValidationError(415, f"missing required field: {field}")

    for field in _REQUIRED_FIELDS + _OPTIONAL_FIELDS:
        if field in body and not isinstance(body[field], str):
            raise ValidationError(
                400, f"field {field!r} must be a string",
            )

    subject_uri = body["subject_uri"].strip()
    if not subject_uri or " " in subject_uri:
        raise ValidationError(400, "subject_uri must be a non-empty URI")

    client_hash = body["fact_hash"].strip().lower()
    if not re.fullmatch(r"[0-9a-f]{16}", client_hash):
        raise ValidationError(
            400, "fact_hash must be 16 lowercase hex chars",
        )

    original = body["original_value"]
    corrected = body["corrected_value"]
    if not original.strip():
        raise ValidationError(400, "original_value must be non-empty")
    if not corrected.strip():
        raise ValidationError(400, "corrected_value must be non-empty")
    if original == corrected:
        raise ValidationError(
            400, "corrected_value must differ from original_value",
        )

    source = body["source"]
    if source not in ALLOWED_SOURCES:
        raise ValidationError(
            400,
            f"source must be one of {sorted(ALLOWED_SOURCES)} (got {source!r})",
        )

    expected_hash = fact_hash(subject_uri, original)
    if expected_hash != client_hash:
        # The client computed the hash over different bytes than the
        # server. Reject so the assistant or overlay can refresh and
        # try again with current state. 422 = unprocessable entity.
        raise ValidationError(
            422,
            f"fact_hash mismatch: expected {expected_hash}, got {client_hash}",
        )

    return {
        "subject_uri": subject_uri,
        "fact_hash": client_hash,
        "original": original,
        "corrected": corrected,
        "source": source,
        "reason": body.get("reason", ""),
    }


# ---------------------------------------------------------------------------
# Status defaults
# ---------------------------------------------------------------------------

def default_status_for_source(source: str) -> str:
    """Per the brief: assistant-proposed corrections land in pending
    so a human reviews them on the Doctor tab before they swap fact
    text. Inline + doctor sources land applied because they ARE the
    review surface."""
    if source == SOURCE_ASSISTANT:
        return STATUS_PENDING
    return STATUS_APPLIED


# ---------------------------------------------------------------------------
# SPARQL escaping + UPDATE construction
# ---------------------------------------------------------------------------

def _sparql_string(s: str) -> str:
    """Escape a string for safe inclusion in a SPARQL string literal.

    Escapes the backslash, double-quote, newline, and carriage-return
    characters. Mirrors the pattern used in ``contact_syncer/syncer.py``
    so we don't drift from the in-tree SPARQL escaper.
    """
    return (
        s.replace("\\", "\\\\")
         .replace('"', '\\"')
         .replace("\n", "\\n")
         .replace("\r", "\\r")
    )


def build_correction_insert(
    *,
    subject_uri: str,
    fact_hash_value: str,
    original: str,
    corrected: str,
    source: str,
    status: str,
    reason: str = "",
    correction_uri: Optional[str] = None,
    now: Optional[datetime] = None,
) -> Tuple[str, str]:
    """Build the SPARQL UPDATE that inserts one ``pwg:Correction`` record.

    Returns ``(correction_uri, sparql)`` so the caller can echo the
    URI back to the client (useful for the Doctor tab to link
    directly to the audit row, and for the assistant tool to surface
    "your correction is recorded as <id>").

    Idempotency: ``correction_uri`` is freshly minted on every call.
    Two corrections on the same ``(subject_uri, fact_hash)`` produce
    two distinct ``pwg:Correction`` records; CM044's compiler picks
    the most recent applied one by ``pwg:correctedAt`` so the read
    side stays deterministic.
    """
    when = (now or datetime.now(timezone.utc)).isoformat()
    if correction_uri is None:
        correction_uri = (
            f"{PWG_PREFIX_URL}correction_{uuid.uuid4().hex}"
        )

    triples = [
        f"<{correction_uri}> a pwg:Correction",
        f"<{correction_uri}> pwg:correctionSubject <{subject_uri}>",
        f'<{correction_uri}> pwg:correctionFactHash "{_sparql_string(fact_hash_value)}"',
        f'<{correction_uri}> pwg:originalValue "{_sparql_string(original)}"',
        f'<{correction_uri}> pwg:correctedValue "{_sparql_string(corrected)}"',
        f'<{correction_uri}> pwg:correctedAt "{when}"^^xsd:dateTime',
        f'<{correction_uri}> pwg:correctionSource "{_sparql_string(source)}"',
        f'<{correction_uri}> pwg:correctionStatus "{_sparql_string(status)}"',
    ]
    if reason:
        triples.append(
            f'<{correction_uri}> pwg:correctionReason "{_sparql_string(reason)}"'
        )

    body = " .\n  ".join(triples) + " ."
    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "INSERT DATA {\n"
        f"  {body}\n"
        "}\n"
    )
    return correction_uri, sparql


# ---------------------------------------------------------------------------
# Oxigraph driver
# ---------------------------------------------------------------------------

def _oxigraph_url() -> str:
    """Return ``OXIGRAPH_URL`` env var or the canonical localhost default.
    Trailing slash trimmed so callers can do plain `f"{url}/update"`."""
    raw = os.environ.get("OXIGRAPH_URL", "http://localhost:7878")
    return raw.rstrip("/")


def write_correction(
    payload: Dict[str, Any],
    *,
    oxigraph_url: Optional[str] = None,
    http_client: Optional[httpx.Client] = None,
    now: Optional[datetime] = None,
) -> Dict[str, Any]:
    """Persist a validated correction to Oxigraph and return the
    summary the FastAPI handler echoes back to the client.

    ``http_client`` lets tests inject an in-memory transport without
    touching the network. The default behaviour spins up a fresh
    short-lived ``httpx.Client`` per call -- correction writes are
    rare and the connection overhead is negligible compared to the
    SPARQL UPDATE round-trip itself.
    """
    base = (oxigraph_url or _oxigraph_url()).rstrip("/")
    status = default_status_for_source(payload["source"])

    correction_uri, sparql = build_correction_insert(
        subject_uri=payload["subject_uri"],
        fact_hash_value=payload["fact_hash"],
        original=payload["original"],
        corrected=payload["corrected"],
        source=payload["source"],
        status=status,
        reason=payload.get("reason", ""),
        now=now,
    )

    own_client = http_client is None
    client = http_client or httpx.Client(timeout=30.0)
    try:
        resp = client.post(
            f"{base}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()
    finally:
        if own_client:
            client.close()

    when = (now or datetime.now(timezone.utc)).isoformat()
    return {
        "correction_uri": correction_uri,
        "subject_uri": payload["subject_uri"],
        "fact_hash": payload["fact_hash"],
        "status": status,
        "source": payload["source"],
        "corrected_at": when,
    }
