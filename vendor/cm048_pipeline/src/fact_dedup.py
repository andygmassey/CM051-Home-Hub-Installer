"""Cross-conversation fact deduplication (CM048).

Ideas Register T12, the cross-conversation half. ``src/fact_quality.py``
already de-dupes EXACT ``(subject, text)`` repeats *within a single
conversation*. The gap this module closes: the same fact extracted from
several different conversations ("Sam works at Acme", stated across five
chats) mints five near-identical Qdrant points and five Oxigraph triples,
cluttering the graph and the wiki even though they say the same thing.

What this is, precisely
-----------------------
A DETERMINISTIC, EXACT-match guard. The dedup key is
``(subject, normalise_fact_text(text))`` -- the same key
``fact_quality.fact_dedup_key`` builds, so within- and cross-conversation
dedup never disagree. It is subject-scoped (the same text about two
different subjects is kept) and it is exact on normalised text only:
"works at Acme" and "worked at Acme until 2020" are DIFFERENT facts and
are both kept. Semantic / near-duplicate merging (embeddings + a
similarity threshold) is a separate product decision and is explicitly
NOT done here -- see ``candidates.py`` for the existing semantic
corroboration path, which is complementary, not a replacement.

How it works
------------
At write time, before a conversation's facts are written, we query the
sinks for facts ALREADY stored for each subject in this batch (from any
PRIOR conversation), normalise their text, and build a set of
``(subject, normalised_text)`` keys that already exist. Any fact in the
new batch whose key is in that set is skipped -- its point is never
embedded/upserted and its triple is never written.

Feasibility
-----------
Write-time querying is the established pattern in this repo: ``ingest``'s
writers and ``candidates``' corroboration path both hold live ``httpx``
clients to the same Qdrant / Oxigraph endpoints. We reuse the Oxigraph
SPARQL endpoint (the authoritative fact store) as the existence oracle.

Safety posture (all deliberate)
--------------------------------
* **Opt-in.** Off unless ``OSTLER_FACT_CROSS_DEDUP`` is truthy. The
  shipping pipeline is byte-for-byte unchanged until an operator opts in.
* **Fail-open.** Any query error returns an EMPTY existing-set, so a
  transient Oxigraph hiccup makes us WRITE the fact (a harmless
  duplicate) rather than DROP a real one. We never lose a fact because a
  dedup query failed.
* **Dry-run safe.** The writers pass ``dry_run`` straight through; in
  dry-run we never touch the network and never skip (the dry-run count
  stays a faithful upper bound).
* **Idempotent.** A re-run finds the fact it wrote last time and skips
  it, so re-processing a conversation does not re-add duplicates.

Residual gap (documented, not a bug)
------------------------------------
This guard dedupes a NEW conversation's facts against facts ALREADY in
the store. It does not retroactively collapse duplicates that predate the
guard, and within a single ``write_all`` call the two sinks are queried
independently. A periodic graph-hygiene pass that collapses historical
duplicates is the natural follow-up and is left for a separate task.
"""

from __future__ import annotations

import logging
import os
from typing import Any

import httpx

from .fact_quality import fact_dedup_key, normalise_fact_text
from .settings import Settings

logger = logging.getLogger(__name__)


def cross_dedup_enabled() -> bool:
    """True when cross-conversation dedup is opted in via the environment.

    Accepts ``1 / true / yes / on`` (case-insensitive). Default OFF so a
    shipping pipeline is unchanged until an operator turns it on.
    """
    raw = os.environ.get("OSTLER_FACT_CROSS_DEDUP")
    if raw is None:
        return False
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _subjects_in_batch(facts: list) -> set[str]:
    """The distinct raw subject strings present in a fact batch.

    Raw (not lower-cased) because the subject is interpolated into a
    SPARQL IRI exactly as ``_fact_to_triples`` writes it. Dedup
    comparison still happens on the lower-cased key via
    ``fact_dedup_key``.
    """
    out: set[str] = set()
    for f in facts:
        if not isinstance(f, dict):
            continue
        subj = str(f.get("subject") or "").strip()
        if subj:
            out.add(subj)
    return out


def _subject_to_uri(subject: str, settings: Settings) -> str:
    """Mirror ``ingest._fact_to_triples``'s subject -> URI mapping.

    Kept in lock-step by construction: "user" maps to the operator URI,
    everything else replaces the first ``:`` with ``/`` (so
    ``other:alex`` -> ``urn:pwg:other/alex``).
    """
    if subject == "user":
        return f"urn:pwg:user/{settings.user_id}"
    return "urn:pwg:" + subject.replace(":", "/")


def existing_keys_for_facts(
    facts: list,
    conversation_id: str,
    settings: Settings,
) -> set[tuple[str, str]]:
    """Return the set of ``(subject, normalised_text)`` keys that already
    exist in Oxigraph for the subjects in ``facts``, from conversations
    OTHER than ``conversation_id``.

    One SPARQL query per distinct subject in the batch (subjects per
    conversation are few). Fails open: on any error for a subject, that
    subject contributes nothing (we will write its facts).
    """
    existing: set[tuple[str, str]] = set()
    for subject in _subjects_in_batch(facts):
        subject_uri = _subject_to_uri(subject, settings)
        subject_key = subject.strip().lower()
        try:
            texts = _existing_texts_for_subject(
                subject_uri, conversation_id, settings
            )
        except Exception as exc:
            # Defence in depth: _existing_texts_for_subject already fails
            # open internally, but a future refactor must never turn a
            # query error into a dropped real fact. Skip this subject.
            logger.warning(
                "fact_dedup: existing-key lookup failed for %s "
                "(fail-open): %s",
                subject_uri,
                exc,
            )
            continue
        for text in texts:
            norm = normalise_fact_text(text)
            if norm:
                existing.add((subject_key, norm))
    return existing


def _existing_texts_for_subject(
    subject_uri: str,
    conversation_id: str,
    settings: Settings,
) -> list[str]:
    """Fetch the text of every stored fact about ``subject_uri`` that
    came from a conversation other than ``conversation_id``.

    Returns [] on any error (fail-open). Scopes to the user's named graph,
    matching ``candidates._sparql_select``.
    """
    # IRIs are constructed from our own deterministic mapping, never from
    # free text, so they cannot carry an injection. conversation_id is a
    # slug from upstream; we compare it with a string FILTER rather than
    # splicing it into an IRI, and it is sanitised at its source.
    conv_uri = f"urn:pwg:conversation/{conversation_id}"
    sparql = f"""
PREFIX pwg: <urn:pwg:>
SELECT DISTINCT ?text WHERE {{
  ?fact a pwg:Fact ;
        pwg:about <{subject_uri}> ;
        pwg:fromConversation ?conv ;
        pwg:text ?text .
  FILTER ( STR(?conv) != "{conv_uri}" )
}}
"""
    graph_uri = f"urn:pwg:user/{settings.user_id}"
    try:
        with httpx.Client(
            timeout=30.0, transport=httpx.HTTPTransport(proxy=None)
        ) as hc:
            resp = hc.post(
                f"{settings.oxigraph_url}/query",
                content=sparql,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json",
                },
                params={"default-graph-uri": graph_uri},
            )
            resp.raise_for_status()
            data = resp.json()
    except Exception as exc:
        logger.warning(
            "fact_dedup: existing-fact query failed for %s (fail-open, "
            "facts will be written): %s",
            subject_uri,
            exc,
        )
        return []

    out: list[str] = []
    for binding in data.get("results", {}).get("bindings", []):
        val = binding.get("text", {}).get("value", "")
        if val:
            out.append(val)
    return out


def drop_cross_conversation_duplicates(
    facts: list,
    *,
    conversation_id: str,
    settings: Settings,
    dry_run: bool,
) -> tuple[list, int]:
    """Drop facts already present for the same subject from a PRIOR
    conversation.

    Returns ``(kept, dropped_count)``. A no-op (returns the input
    unchanged, ``dropped=0``) when:

    * cross-dedup is not opted in (``OSTLER_FACT_CROSS_DEDUP`` unset), or
    * ``dry_run`` is set (never touch the network in dry-run), or
    * ``facts`` is not a list.

    The input list order is preserved for the survivors.
    """
    if dry_run or not cross_dedup_enabled():
        return facts, 0
    if not isinstance(facts, list) or not facts:
        return facts, 0

    existing = existing_keys_for_facts(facts, conversation_id, settings)
    if not existing:
        return facts, 0

    kept: list = []
    dropped = 0
    for fact in facts:
        key = fact_dedup_key(fact)
        if key is not None and key in existing:
            dropped += 1
            continue
        kept.append(fact)

    if dropped:
        logger.info(
            "fact_dedup: dropped %d cross-conversation duplicate fact(s) "
            "[conversation=%s]",
            dropped,
            conversation_id,
        )
    return kept, dropped
