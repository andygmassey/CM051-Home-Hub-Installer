"""Content preference extractor.

Derives likes/dislikes/interests from free-text conversational content (chat
messages, conversation transcripts) so the system learns tastes from what the
user actually *says*, not only from structured exports.

This is deliberately conservative and high-precision. A taste signal is only
emitted when a clear, first-person cue is present:

  * positive cues  -- "I love X", "I really like X", "my favourite X is Y",
                       "X is my favourite", "I'm a big fan of X", "I'm into X"
  * negative cues  -- "I hate X", "I can't stand X", "I'm not a fan of X",
                       "I don't like X", "I dislike X"

Weak / ambiguous mentions ("we talked about X", "X is on tonight", a bare
noun) produce NOTHING. A preference extractor that hallucinates tastes is
worse than one that extracts fewer, so the bar for emitting is high.

Output shape matches the house ``ParsedPreference`` dataclass exactly:
  * ``preference_type``  -- "Love" / "Like" for positives, "Hate" / "Dislike"
                            for negatives (polarity is carried by the type and
                            by the sign of ``strength``)
  * ``strength``         -- bipolar (-1.0 .. +1.0); negative for dislikes
  * ``source``           -- "conversation_content"
  * deterministic ``id`` -- derived in ``ParsedPreference.__post_init__`` from
                            (source, preference_type, subject, category,
                            context); the same utterance always maps to the
                            same id, so re-ingesting is idempotent.

The deterministic rule-based core runs with no model and is what the tests
exercise. An optional LLM lift can be enabled with
``CONTENT_PREF_LLM_ENABLED=1`` (default OFF); when disabled, or when the model
is unreachable, the extractor falls back to the deterministic core so tests
and offline installs behave identically.
"""

from __future__ import annotations

import logging
import os
import re
import uuid
from pathlib import Path
from typing import AsyncIterator, Iterator, List, Optional, Tuple

import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)


# Canonical source tag for everything this extractor emits.
SOURCE_NAME = "conversation_content"


# Stable namespace for deterministic preference ids. Derived once from a fixed
# DNS name so the value never changes between runs or processes. We derive the
# id in this extractor and pass it explicitly via ``id=`` so the result is
# idempotent on ``origin/main`` too, where ``ParsedPreference.id`` still
# defaults to a per-call ``uuid4`` (the deterministic-id base change, tracker
# #526, is not yet merged). When #526 does land, this explicit id still wins.
_PREFERENCE_ID_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_DNS, "preference.pwg.ostler")


def _derive_id(source: str, preference_type: str, subject: str,
               category: Optional[str]) -> str:
    """Stable, content-based id per (source, polarity, subject, category).

    Same utterance -> same id, so re-ingesting upserts in place rather than
    creating duplicate Qdrant points. Polarity is carried by ``preference_type``
    (Love/Like vs Dislike/Hate), so "I love sushi" and "I hate sushi" get
    distinct ids. Returns a valid UUID string (Qdrant point id / pwg IRI
    requirement).
    """
    key = "|".join((
        source,
        preference_type,
        (subject or "").strip().lower(),
        category or "",
    ))
    return str(uuid.uuid5(_PREFERENCE_ID_NAMESPACE, key))


# ---------------------------------------------------------------------------
# Strength model (bipolar -1.0 .. +1.0, matching base.classify_strength)
# ---------------------------------------------------------------------------
# Modest strengths: a single conversational utterance is weaker evidence than
# an explicit platform rating. The cross-file filter aggregates repeats.
_STRENGTH = {
    "Love": 0.55,
    "Like": 0.35,
    "Dislike": -0.35,
    "Hate": -0.55,
}


# ---------------------------------------------------------------------------
# Cue patterns.
#
# Each entry is (compiled_regex, preference_type). The regex must capture the
# preference subject in group "subj". Patterns are anchored on first-person
# cues ("I ...", "my favourite ...") so that third-person or topical mentions
# do not match. The subject capture is intentionally greedy-stopped at clause
# boundaries (see _SUBJECT_STOP) and cleaned in _clean_subject.
# ---------------------------------------------------------------------------

# Trailing fragment that ends a subject capture: clause/sentence punctuation
# or a conjunction that starts a new clause. Keeps "I love sushi but hate
# olives" from swallowing the whole tail into one subject.
_SUBJECT = r"(?P<subj>[A-Za-z0-9][^,.;!?\n]*?)"
_END = r"(?=$|[,.;!?\n]|\s+(?:but|and|though|although|however|because)\b)"

_PATTERNS: List[Tuple[re.Pattern, str]] = [
    # --- strong positive ("love", "absolutely love", "favourite") ----------
    (re.compile(
        r"\bi\s+(?:absolutely\s+|really\s+|totally\s+)?love\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Love"),
    (re.compile(
        r"\bi'?m\s+(?:a\s+)?(?:really\s+)?big\s+fan\s+of\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Love"),
    # "my favourite X is Y"  -> subject Y
    (re.compile(
        r"\bmy\s+favou?rite\s+[A-Za-z ]+?\s+(?:is|are|has\s+to\s+be|would\s+be)\s+"
        + _SUBJECT + _END,
        re.IGNORECASE), "Love"),
    # "X is my favourite" / "X is my all-time favourite" -> subject X
    (re.compile(
        r"\b(?P<subj>[A-Za-z0-9][^,.;!?\n]*?)\s+(?:is|are)\s+my\s+"
        r"(?:all[- ]time\s+)?favou?rite\b",
        re.IGNORECASE), "Love"),

    # --- moderate positive ("like", "into", "fan of") ----------------------
    (re.compile(
        r"\bi\s+(?:really\s+|quite\s+)?like\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Like"),
    (re.compile(
        r"\bi'?m\s+(?:really\s+)?into\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Like"),
    (re.compile(
        r"\bi'?m\s+a\s+fan\s+of\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Like"),
    (re.compile(
        r"\bi\s+enjoy\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Like"),

    # --- strong negative ("hate", "can't stand", "loathe") -----------------
    (re.compile(
        r"\bi\s+(?:absolutely\s+|really\s+)?hate\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Hate"),
    (re.compile(
        r"\bi\s+can'?t\s+stand\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Hate"),
    (re.compile(
        r"\bi\s+loathe\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Hate"),

    # --- moderate negative ("don't like", "dislike", "not a fan") ----------
    (re.compile(
        r"\bi\s+(?:really\s+)?(?:do\s*n'?t|don'?t)\s+(?:really\s+)?like\s+"
        + _SUBJECT + _END,
        re.IGNORECASE), "Dislike"),
    (re.compile(
        r"\bi\s+dislike\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Dislike"),
    (re.compile(
        r"\bi'?m\s+not\s+(?:a\s+)?(?:really\s+)?(?:big\s+)?fan\s+of\s+"
        + _SUBJECT + _END,
        re.IGNORECASE), "Dislike"),
    (re.compile(
        r"\bi'?m\s+not\s+(?:really\s+)?into\s+" + _SUBJECT + _END,
        re.IGNORECASE), "Dislike"),
]


# Leading filler words to strip off the front of a captured subject. These are
# determiners / intensifiers that precede the real noun ("a lot of jazz" ->
# "jazz"). Kept short and conservative.
_LEADING_FILLER = {
    "a", "an", "the", "some", "any", "all", "lot", "lots", "of", "really",
    "quite", "very", "so", "much", "to",
}

# A captured subject made up *only* of these tokens is not a taste -- it is a
# pronoun / filler reference ("I love it", "I like you"). Reject outright.
_PRONOUN_ONLY = {
    "it", "that", "this", "them", "you", "him", "her", "us", "me", "those",
    "these", "things", "stuff", "everything", "anything", "something", "him",
    "she", "he", "they", "we",
}

# Max words a subject may have before we treat it as a run-on clause rather
# than a taste target. "I love how the sunset looked over the harbour ..." is
# not a preference for a named thing.
_MAX_SUBJECT_WORDS = 6


# ---------------------------------------------------------------------------
# Category inference (reuses the canonical vocabulary the wiki readers expect).
# Conservative: a confident keyword hit maps to a specific category, else the
# generic "interest" category (which still renders a Topic page) -- never None.
# ---------------------------------------------------------------------------
_CATEGORY_KEYWORDS = {
    "music": (
        "music", "song", "album", "artist", "band", "jazz", "techno", "rock",
        "hip hop", "hip-hop", "classical", "metal", "pop", "guitar", "vinyl",
        "playlist", "gig", "concert", "coldplay", "beatles", "radiohead",
    ),
    "food": (
        "food", "cuisine", "restaurant", "dish", "pizza", "sushi", "ramen",
        "curry", "burger", "pasta", "thai", "italian", "japanese", "indian",
        "korean", "mexican", "vegan", "coffee", "tea", "wine", "beer",
        "whisky", "whiskey", "gin", "cocktail", "chocolate", "cheese",
        "olives", "coriander", "seafood", "steak", "noodles", "dumplings",
    ),
    "movie": ("movie", "film", "cinema", "director", "documentary"),
    "tv": ("tv show", "tv series", "series", "netflix", "sitcom"),
    "book": ("book", "novel", "author", "reading", "audiobook", "fiction"),
    "podcast": ("podcast",),
    "place": (
        "travel", "city", "country", "hotel", "holiday", "beach", "mountains",
        "japan", "italy", "france", "thailand", "spain", "portugal", "iceland",
    ),
    "sport": (
        "football", "rugby", "tennis", "cricket", "running", "cycling",
        "climbing", "yoga", "gym", "surfing", "skiing", "hiking", "golf",
    ),
    "technology": (
        "coding", "programming", "python", "rust", "ai", "robotics", "drones",
        "gadgets", "linux", "machine learning",
    ),
    "professional": (
        "design", "ux", "marketing", "startups", "entrepreneurship",
    ),
}


def _infer_category(subject: str) -> str:
    """Best-effort canonical category from the subject text.

    Returns a specific category on a confident keyword hit, else "interest"
    (a real category that renders a Topic page) -- never None, so the point
    is never invisible to the wiki readers.
    """
    text = (subject or "").lower()
    for category, keywords in _CATEGORY_KEYWORDS.items():
        for kw in keywords:
            # Word-ish boundary check to avoid "ai" matching "said".
            if re.search(r"(?<![a-z])" + re.escape(kw) + r"(?![a-z])", text):
                return category
    return "interest"


def _clean_subject(raw: str) -> Optional[str]:
    """Normalise a captured subject; return None if it is not a real taste.

    * strips leading determiners / intensifiers ("a lot of jazz" -> "jazz")
    * strips surrounding whitespace and trailing filler punctuation
    * rejects pronoun-only / empty / over-long captures
    """
    if not raw:
        return None

    text = raw.strip().strip("\"'").strip()
    # Drop a trailing possessive/auxiliary that can leak in from "X is my..."
    text = re.sub(r"\s+", " ", text)

    words = text.split()
    # Strip leading filler tokens.
    while words and words[0].lower() in _LEADING_FILLER:
        words = words[1:]
    if not words:
        return None

    # Reject pronoun-only references.
    lowered = [w.lower().strip(".,;!?") for w in words]
    if all(w in _PRONOUN_ONLY or not w for w in lowered):
        return None

    # Reject run-on clauses.
    if len(words) > _MAX_SUBJECT_WORDS:
        return None

    cleaned = " ".join(words).strip(".,;!?-").strip()
    if len(cleaned) < 2:
        return None
    return cleaned


def _strength_for(pref_type: str) -> float:
    return _STRENGTH.get(pref_type, 0.0)


def _llm_enabled() -> bool:
    """Whether the optional LLM lift is enabled. Default OFF.

    Read at call time (not import time) so tests can toggle it without
    reloading the module.
    """
    return os.environ.get("CONTENT_PREF_LLM_ENABLED", "").strip().lower() in (
        "1", "true", "yes", "on",
    )


def extract_preferences(
    text: str,
    *,
    compartment_level: int = 1,
    observed_at=None,
) -> List[ParsedPreference]:
    """Extract taste preferences from a block of conversational text.

    This is the deterministic, model-free core -- the function the tests
    exercise and the function any live wiring should call. It is pure: same
    input, same output (including deterministic ids), no I/O.

    Args:
        text: free-text conversational content (one or many messages).
        compartment_level: privacy level for emitted preferences. Defaults to
            L1 (Family) -- conversational content is personal.
        observed_at: optional datetime the content was observed.

    Returns:
        A list of ``ParsedPreference`` objects, de-duplicated by id within this
        call (so one transcript repeating "I love sushi" twice yields one
        record, idempotently).
    """
    if not text or not text.strip():
        return []

    seen_ids = set()
    out: List[ParsedPreference] = []

    for pref in _extract_deterministic(
        text, compartment_level=compartment_level, observed_at=observed_at
    ):
        if pref.id in seen_ids:
            continue
        seen_ids.add(pref.id)
        out.append(pref)

    # Optional LLM lift -- default OFF, never required for correctness. The
    # deterministic core above is always the floor; the lift can only *add*
    # records, and on any error we keep the deterministic result.
    if _llm_enabled():
        try:
            for pref in _extract_llm(
                text, compartment_level=compartment_level, observed_at=observed_at
            ):
                if pref.id in seen_ids:
                    continue
                seen_ids.add(pref.id)
                out.append(pref)
        except Exception as exc:  # pragma: no cover - defensive
            logger.warning(
                "Content preference LLM lift failed, using deterministic "
                "result only: %s", exc
            )

    return out


def _extract_deterministic(
    text: str, *, compartment_level: int, observed_at
) -> Iterator[ParsedPreference]:
    """Rule-based cue extraction. Yields one ParsedPreference per clear cue."""
    for pattern, pref_type in _PATTERNS:
        for match in pattern.finditer(text):
            subject = _clean_subject(match.group("subj"))
            if subject is None:
                continue
            category = _infer_category(subject)
            yield ParsedPreference(
                id=_derive_id(SOURCE_NAME, pref_type, subject, category),
                subject=subject,
                preference_type=pref_type,
                strength=_strength_for(pref_type),
                compartment_level=compartment_level,
                source=SOURCE_NAME,
                category=category,
                observed_at=observed_at,
                size="Medium",
                extra={
                    "type": "stated_preference",
                    "cue": match.group(0).strip()[:160],
                    "extraction_method": "deterministic_cue",
                },
            )


def _extract_llm(
    text: str, *, compartment_level: int, observed_at
) -> Iterator[ParsedPreference]:
    """Optional model-based lift. Gated behind CONTENT_PREF_LLM_ENABLED.

    Intentionally a stub in this draft: there is no LLM client wired into the
    ingest service, and wiring one is an explicit follow-up. The contract is
    fixed here so the deterministic path is never blocked: when enabled but no
    client is configured, this yields nothing (the deterministic result
    stands). A future implementation should call the local model, parse a
    structured response, and yield the same conservative ParsedPreference
    shape with extra["extraction_method"] == "llm".
    """
    logger.debug(
        "Content preference LLM lift enabled but no client configured; "
        "deterministic result stands (follow-up: wire local model)."
    )
    return iter(())


class ContentPreferenceParser(BaseParser):
    """File-facing adapter around :func:`extract_preferences`.

    Lets the extractor sit in the file-driven ingest pipeline for plain-text
    conversation transcripts (``*.txt``) while keeping ``extract_preferences``
    as the wiring-free core. Conservative ``can_parse``: only ``.txt`` files
    whose name marks them as a conversation/transcript, so it never competes
    with the platform-specific parsers.
    """

    source_name = SOURCE_NAME

    _NAME_HINTS = ("conversation", "transcript", "chat", "messages", "dialogue")

    def can_parse(self, file_path: Path) -> bool:
        if file_path.suffix.lower() != ".txt":
            return False
        name = file_path.name.lower()
        return any(hint in name for hint in self._NAME_HINTS)

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs,
    ) -> AsyncIterator[ParsedPreference]:
        if default_compartment is None:
            default_compartment = 1  # L1 Family - conversational content

        async with aiofiles.open(file_path, mode="r", encoding="utf-8") as f:
            content = await f.read()

        prefs = extract_preferences(
            content, compartment_level=default_compartment
        )
        logger.info(
            "Extracted %d stated preferences from %s", len(prefs), file_path
        )
        for pref in prefs:
            yield pref
