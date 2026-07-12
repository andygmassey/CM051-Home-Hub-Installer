"""Post-extraction quality gate for extracted facts (CM048).

Ideas Register T12. Raises the PRECISION of the facts that reach the
sinks (Qdrant embeddings + Oxigraph triples) so the wiki/graph surfaces
fewer junk or wrong facts. Serves the product promise "it actually
knows you, accurately".

This is a DETERMINISTIC gate. It does not call an LLM and it does not
invent a confidence number that the extractor never produced. It runs
once, between ``05_facts.json`` and the sink-write step, and is applied
identically to both sinks (the single call site below guarantees the
Qdrant point and the Oxigraph triple for a given fact are never out of
step).

What it drops, and why:

1. **Degenerate text** - empty / whitespace-only / too-short fact text.
   A fact whose ``text`` is "" or "x" cannot be retrieved usefully and
   pollutes the graph. (CM040 EXTRACTION_IMPROVEMENTS.md:171 "reject
   very short extractions".)

2. **AI self-referential facts** - facts whose *subject* is the AI
   assistant, or whose *text* is an unmistakable first-person AI
   self-description ("I am an AI", "as an AI language model", ...).
   This matters because of CM044's AI Conversations wing: the
   assistant's own turns get fed to the same extractor, and we must
   NOT mint "facts about Ostler" into the user's personal graph.
   (CM040 EXTRACTION_IMPROVEMENTS.md:159 "reject extractions about the
   AI assistant".) The predicate is deliberately CONSERVATIVE: it keys
   on the subject field and on first-person AI idioms, never on a bare
   personal name, so a real contact called "Marvin" or "Samantha" is
   never wrongly dropped.

3. **Within-conversation duplicates** - the exact same (subject, text)
   pair extracted twice from one conversation. The sinks already use a
   deterministic point/triple id keyed on text, so a duplicate would
   collapse on write anyway; dropping it here makes the count honest
   and the log truthful.

4. **Sub-floor signal strength** - OPT-IN. Facts carry an ordinal
   ``signal_strength`` (``strong`` | ``medium`` | ``weak``), NOT a
   numeric confidence. When ``OSTLER_FACT_SIGNAL_FLOOR`` is set to one
   of those values, facts below the floor are dropped. The DEFAULT is
   no floor (every strength is kept) so this change is behaviour-neutral
   on a shipping pipeline until an operator opts in. See module-level
   note: a numeric confidence score is a meaningful follow-up.

The first three gates are always on and are conservative enough to be
safe by default (they only remove facts that are unusable or
self-referential). The signal floor is the only behaviour-changing
gate and it is off unless explicitly configured.
"""

from __future__ import annotations

import logging
import os
from typing import Any

logger = logging.getLogger(__name__)


# Minimum useful fact-text length. Mirrors CM040
# EXTRACTION_IMPROVEMENTS.md:171 (`len(text) < 15`). A fact shorter than
# this cannot carry a retrievable claim.
_MIN_TEXT_LEN = 15

# Ordinal signal strengths, weakest first. Index = rank.
_SIGNAL_RANK: dict[str, int] = {"weak": 0, "medium": 1, "strong": 2}

# Subject-field prefixes / values that denote the AI assistant itself
# rather than the user or a real person. The extractor's subject grammar
# is `user | other:{slug} | person:{slug} | org:{slug} | household:{id}`;
# none of those legitimately point at the assistant, so any of these
# markers in the subject is an extraction error from the AI Conversations
# wing.
_AI_SUBJECT_VALUES: frozenset[str] = frozenset(
    {
        "ai",
        "assistant",
        "self",
        "ostler",
        "samantha",
        "marvin",
        "model",
        "the assistant",
        "the ai",
    }
)
_AI_SUBJECT_PREFIXES: tuple[str, ...] = (
    "ai:",
    "assistant:",
    "self:",
    "bot:",
)

# First-person AI self-description idioms. These are matched against the
# fact text and are deliberately phrase-level (not single words) so a
# real person's name or an ordinary sentence is never caught. Lower-cased
# substring match. Adapted from CM040 EXTRACTION_IMPROVEMENTS.md:160-166.
_AI_TEXT_PHRASES: tuple[str, ...] = (
    "i am an ai",
    "i'm an ai",
    "as an ai",
    "i am a language model",
    "i'm a language model",
    "as a language model",
    "i am an assistant",
    "i'm an assistant",
    "as your assistant",
    "i am here to help",
    "i'm here to help",
    "i do not have personal",
    "i don't have personal",
    "i cannot have opinions",
    "i can't have opinions",
    "i am an artificial intelligence",
    "as an artificial intelligence",
)


def normalise_fact_text(text: str) -> str:
    """Normalise fact text for EXACT-match duplicate detection.

    Conservative on purpose. This is used both for the within-conversation
    duplicate guard (below) and for the cross-conversation duplicate guard
    (``src/fact_dedup.py``), so the two paths can never disagree on what
    "the same fact" means. It must NOT do semantic merging -- "works at
    Acme" and "worked at Acme until 2020" MUST normalise to different
    strings. We therefore only:

    * lower-case (case is not a meaningful difference for a claim),
    * collapse internal whitespace runs to a single space,
    * strip leading/trailing whitespace,
    * strip a trailing run of trivial sentence punctuation (``. , ; :``)
      and surrounding quotes, so "Sam works at Acme." and
      "Sam works at Acme" collapse.

    We deliberately do NOT strip internal punctuation, stem words, drop
    stop-words or reorder tokens -- any of those would risk merging two
    genuinely different facts, which is a product/semantic decision that
    belongs to an embedding-similarity pass, not this deterministic gate.
    """
    if not isinstance(text, str):
        return ""
    # Collapse all whitespace (incl. newlines/tabs) to single spaces.
    collapsed = " ".join(text.split())
    lowered = collapsed.lower()
    # Strip surrounding quotes/whitespace and trailing trivial punctuation.
    return lowered.strip().strip("\"'").strip(" .,;:").strip()


def fact_dedup_key(fact: Any) -> tuple[str, str] | None:
    """Return the ``(subject, normalised_text)`` dedup key for a fact.

    Subject is lower-cased and stripped so it scopes the dedup; the same
    text about two different subjects is NOT a duplicate. Returns ``None``
    when the fact is malformed or carries no usable text, so callers can
    skip dedup for it (and let the normal write path handle it).
    """
    if not isinstance(fact, dict):
        return None
    norm_text = normalise_fact_text(fact.get("text") or "")
    if not norm_text:
        return None
    subject = str(fact.get("subject") or "").strip().lower()
    return (subject, norm_text)


def _signal_floor() -> str | None:
    """Read the opt-in signal floor from the environment.

    Returns the floor name (``weak`` | ``medium`` | ``strong``) or
    ``None`` when unset / invalid. An invalid value is ignored (logged)
    rather than raising, so a typo never wedges the ingest.
    """
    raw = os.environ.get("OSTLER_FACT_SIGNAL_FLOOR")
    if raw is None:
        return None
    val = raw.strip().lower()
    if val == "":
        return None
    if val not in _SIGNAL_RANK:
        logger.warning(
            "Ignoring OSTLER_FACT_SIGNAL_FLOOR=%r: expected one of "
            "weak|medium|strong",
            raw,
        )
        return None
    return val


def _subject_is_ai(subject: str) -> bool:
    s = subject.strip().lower()
    if s in _AI_SUBJECT_VALUES:
        return True
    return any(s.startswith(p) for p in _AI_SUBJECT_PREFIXES)


def _text_is_ai_self_ref(text: str) -> bool:
    t = text.strip().lower()
    return any(phrase in t for phrase in _AI_TEXT_PHRASES)


def classify_drop(fact: Any, floor: str | None) -> str | None:
    """Return a drop-reason string if the fact should be dropped, else
    ``None`` (keep).

    ``floor`` is the resolved signal floor (or ``None`` for no floor),
    passed in so a batch resolves the env once.

    Order matters only for which reason gets attributed; a fact is
    dropped on the first failing gate.
    """
    if not isinstance(fact, dict):
        return "not_a_dict"

    text = (fact.get("text") or "")
    if not isinstance(text, str):
        return "text_not_string"
    stripped = text.strip()
    if not stripped:
        return "empty_text"
    if len(stripped) < _MIN_TEXT_LEN:
        return "text_too_short"

    subject = fact.get("subject") or ""
    if isinstance(subject, str) and _subject_is_ai(subject):
        return "ai_subject"
    if _text_is_ai_self_ref(stripped):
        return "ai_self_reference"

    if floor is not None:
        strength = (fact.get("signal_strength") or "medium")
        rank = _SIGNAL_RANK.get(str(strength).strip().lower())
        # Unknown strength is treated as 'medium' rank (the schema
        # default) so a malformed value is not silently dropped by the
        # floor.
        if rank is None:
            rank = _SIGNAL_RANK["medium"]
        if rank < _SIGNAL_RANK[floor]:
            return "below_signal_floor"

    return None


def filter_facts(
    facts: list,
    *,
    conversation_id: str = "",
) -> tuple[list, dict]:
    """Filter a list of extracted-fact dicts.

    Returns ``(kept, drops)`` where ``kept`` is the surviving facts in
    input order and ``drops`` maps each drop-reason to a count. Also
    de-duplicates exact ``(subject, text)`` repeats within the batch
    (reason ``duplicate``).

    Backward-compatible: a fact list with no problems returns unchanged
    and an empty ``drops`` dict. Never raises on a malformed entry; a
    non-dict entry is dropped with reason ``not_a_dict``.
    """
    if not isinstance(facts, list):
        return [], {}

    floor = _signal_floor()
    kept: list = []
    drops: dict[str, int] = {}
    seen: set[tuple[str, str]] = set()

    for fact in facts:
        reason = classify_drop(fact, floor)
        if reason is None:
            # Within-conversation exact-duplicate guard. Uses the shared
            # normalised (subject, text) key so the within-conversation
            # and cross-conversation (src/fact_dedup.py) guards agree on
            # what "the same fact" means.
            key = fact_dedup_key(fact)
            if key is not None:
                if key in seen:
                    reason = "duplicate"
                else:
                    seen.add(key)
        if reason is None:
            kept.append(fact)
        else:
            drops[reason] = drops.get(reason, 0) + 1

    if drops:
        total = sum(drops.values())
        logger.info(
            "fact_quality: kept %d, dropped %d (%s)%s",
            len(kept),
            total,
            ", ".join(f"{k}={v}" for k, v in sorted(drops.items())),
            f" [conversation={conversation_id}]" if conversation_id else "",
        )
    return kept, drops
