"""Phase 0 interest-profile compiler.

Pure-ish: the scoring layer (clean / flag / decay / score / aggregate / compile)
is a pure function of (raw preference rows, now, corrections) so it is testable
without a live graph. The I/O layer (fetch_preferences) talks read-only to
Oxigraph; nothing here ever writes to the graph.

Observed data shape on a real PWG (Oxigraph), pwg: = https://schema.ostler.ai/ontology#
  ?s a pwg:LikePreference | pwg:DislikePreference
     pwg:subject            "Web Development"
     pwg:category           "professional"
     pwg:preferenceStrength 0.74...           (float, ~0.11..0.75 observed)
     pwg:dataSource         "linkedin" | "facebook" | "csv" | "meta" | ...
     pwg:observedAt | pwg:createdAt  xsd:dateTime

The hard job in Phase 0 is NOT ranking strengths (the raw strengths are
dominated by noise - Facebook page-likes, recruiter email subject lines
mis-categorised as "food"); it is separating signal from noise and surfacing
the clean interests with honest evidence, correctably.
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PWG_NS = "https://schema.ostler.ai/ontology#"

# ---------------------------------------------------------------------------
# Taxonomy: how far to trust each source category, and which coarse domain it
# routes to. Trust is the Phase-0 noise lever - low-trust categories still
# appear in the profile but sink, and are flagged for the correction surface.
# Values tuned against the real category distribution on Andy's graph.
# ---------------------------------------------------------------------------

CATEGORY_TRUST = {
    "movie_tv": 0.95,
    "movie": 0.95,
    "tv": 0.95,
    "music": 0.95,
    "book": 0.95,
    "food": 0.85,
    "place": 0.85,
    "education": 0.75,
    "professional": 0.70,
    "interest": 0.55,          # genuine interests but heavily polluted by email subjects
    "inferred_interest": 0.50,
    "shared_link": 0.35,
    "social_media": 0.30,
    "page": 0.25,              # Facebook page-likes - weak signal
    "facebook_content": 0.20,  # Facebook content noise - weakest
}
DEFAULT_TRUST = 0.40

CATEGORY_DOMAIN = {
    "movie_tv": "Film & TV",
    "movie": "Film & TV",
    "tv": "Film & TV",
    "music": "Music",
    "book": "Reading",
    "food": "Food & Drink",
    "place": "Places & Travel",
    "education": "Learning",
    "professional": "Professional",
    "interest": "Interests",
    "inferred_interest": "Interests",
    "shared_link": "Social signals",
    "social_media": "Social signals",
    "page": "Social signals",
    "facebook_content": "Social signals",
}
DEFAULT_DOMAIN = "Other"

# How far to trust each DATA SOURCE - distinct from category trust, and just as
# important. Learned from real data: `csv` is imported email/recruiter subject
# lines (noise dressed up with high strength + recent dates); `linkedin` is
# declared skills/courses; `facebook`/`meta` are declared likes/page-likes
# (real signal, but the writer stamped them with near-zero strength, so we floor
# them - a declared "like" is a genuine signal regardless of that number).
SOURCE_TRUST = {
    "you": 1.0,
    "linkedin": 0.85,
    "facebook": 0.65,
    "meta": 0.40,
    "csv": 0.18,        # email/recruiter import - heavily distrusted
    "email": 0.18,
    "imap": 0.18,
}
DEFAULT_SOURCE_TRUST = 0.45

# Sources that represent an explicit, declared preference (not an activity log).
# For these we floor the strength to a baseline so a real book-like that was
# written with strength 0.001 still ranks as a genuine interest.
DECLARED_SOURCES = {"linkedin", "facebook", "you"}
DECLARED_STRENGTH_FLOOR = 0.45
# ...but only when the category is not itself low-trust noise.
_LOW_TRUST_CATEGORIES = {"facebook_content", "page", "social_media", "shared_link"}

DECAY_FLOOR = 0.35  # a declared favourite does not expire to nothing

# ---------------------------------------------------------------------------
# Privacy classification - the PRODUCER half of the external-scout egress
# contract (scout_external.l1_interests fail-closes on the consumer side,
# audit 2026-07-13: an interest without an explicit L0/L1 tag never feeds an
# outbound query). Every emitted interest therefore carries a ``privacy``
# level, classified conservatively:
#
#   L1  liked, non-sensitive cultural taste (film/TV/music/book/education):
#       an anonymous genre lookup against a release API says nothing about
#       the operator beyond the taste itself. Externally queryable.
#   L2  usable locally, NEVER externally queryable - categories that reveal
#       more than taste: food (diet -> health/religion inference), place
#       (movement patterns), professional (CV fingerprint - see the operator
#       PII leak class), and every free-text category polluted by email
#       subjects or social noise. Unknown categories land here too: a
#       category this module has never seen cannot prove it is safe.
#   L3  sensitive classes (health, relationships, religion, politics,
#       finance, sexuality, ...). No current writer emits these categories;
#       the set is here so a future writer that does gets fail-closed
#       treatment on day one, not after an audit.
#
# Two caps tighten the category verdict, never loosen it: a noisy source
# (csv/email/imap - real correspondence subject lines) and any noise flag
# each cap the level at L2. Merging duplicate rows keeps the MOST
# restrictive level. Unsure always means more restrictive.
# ---------------------------------------------------------------------------

PRIVACY_LEVELS = ("L0", "L1", "L2", "L3")
_PRIVACY_RANK = {level: rank for rank, level in enumerate(PRIVACY_LEVELS)}
DEFAULT_PRIVACY = "L2"          # unknown category: local-only, never egress
SENSITIVE_PRIVACY = "L3"
_MAX_NOISY_PRIVACY = "L2"       # noisy source / flagged row can do no better

CATEGORY_PRIVACY = {
    # cultural taste - the archetypal safe, anonymous topic lookup
    "movie_tv": "L1",
    "movie": "L1",
    "tv": "L1",
    "music": "L1",
    "book": "L1",
    "education": "L1",
    # reveals more than taste - local use only
    "food": "L2",               # diet -> health/religion inference
    "place": "L2",              # movement/location patterns
    "professional": "L2",       # employer/CV fingerprint
    "interest": "L2",           # heavily polluted by email subject lines
    "inferred_interest": "L2",
    "shared_link": "L2",
    "social_media": "L2",
    "page": "L2",
    "facebook_content": "L2",
}

# Category names that signal a sensitive class regardless of trust/domain.
SENSITIVE_CATEGORIES = {
    "health", "medical", "mental_health", "medication", "wellbeing",
    "relationship", "relationships", "dating", "family", "parenting",
    "religion", "religious", "spirituality",
    "politics", "political",
    "sexuality", "sexual_orientation", "gender_identity",
    "finance", "financial", "money", "legal", "addiction",
}


def normalise_privacy(value) -> str | None:
    """A recognised privacy level from an arbitrary value, else None.
    Mirrors the consumer-side normalisation in scout_external."""
    if value is None:
        return None
    level = str(value).strip().upper()
    return level if level in _PRIVACY_RANK else None


def more_restrictive(a, b) -> str:
    """The stricter of two levels; anything unrecognised counts as L3."""
    ra = _PRIVACY_RANK.get(a, _PRIVACY_RANK["L3"])
    rb = _PRIVACY_RANK.get(b, _PRIVACY_RANK["L3"])
    return PRIVACY_LEVELS[max(ra, rb)]


# ---------------------------------------------------------------------------
# Subject-text name/org screen (audit P3, 2026-07-13). The category can prove
# a TOPIC CLASS is safe; it can never prove the free subject TEXT is
# anonymous. Pre-fix, a movie_tv row reading "Priya Basu Retrospectives" or
# an education row reading "Machine Learning at Acme Corp" classified L1 off
# the category name alone and egressed a contact name / employer through the
# external-scout query path. Deterministic shapes only - no model, no lexicon:
#
#   * unambiguous person/org shapes (_ORG_PERSON_PATTERNS) - an org suffix,
#     an "at <Employer>" attachment, a possessive proper noun, an honorific.
#     These also back the egress hygiene gate (scout_external.query_is_clean).
#   * a proper-noun RUN (_PROPER_RUN_RE) - three+ consecutive capitalised
#     words ("Priya Basu Retrospectives"). Producer-side only: plain TWO-word
#     title case ("Film Noir", "Jazz Piano") is the archetypal legitimate
#     taste subject and stays L1, and the hygiene gate must not veto an
#     operator's explicit L0/L1 correction on a title-case work.
#
# The documented residual of the heuristics - a BARE two-word person name
# ("Priya Basu") in an L1 category is structurally indistinguishable from
# "Film Noir" - is closed by the GRAPH-CONTACT LEXICON below (2026-07-14):
# subjects are additionally screened against the set of known contact names
# from the PWG graph, independent of capitalisation. The heuristics stay as
# the belt-and-braces layer; the lexicon is additive and injectable, and an
# EMPTY lexicon (graph down, caller passed nothing) degrades to exactly the
# heuristic posture - never worse than before, never a loosened verdict.
# ---------------------------------------------------------------------------

_ORG_PERSON_PATTERNS = [
    # org suffixes: "Acme Corp", "Initech Ltd", "Globex Inc."
    re.compile(r"\b(?:Corp|Corporation|Inc|Incorporated|Ltd|Limited|LLC|LLP"
               r"|PLC|Plc|GmbH|Pty|Holdings|Ventures)\b|\bCo\.(?!\w)"),
    # "<x> at <Cap...>": employer/venue attachment - "ML at Acme Corp"
    re.compile(r"\bat\s+[A-Z]"),
    # possessive proper noun: "Priya's Favourite Films"
    re.compile(r"\b[A-Z][a-z]+[’']s\b"),
    # honorific + capital: "Dr Basu Retrospectives"
    re.compile(r"\b(?:Mr|Mrs|Ms|Mx|Dr|Prof|Sir|Dame|Lord|Lady)\.?\s+[A-Z]"),
]

# three+ consecutive capitalised words; hyphen-compounds ("Sci-Fi") do not
# count as capitalised words, so "Sci-Fi Films" never trips this
_PROPER_RUN_RE = re.compile(
    r"(?<![A-Za-z-])[A-Z][a-z]+(?:\s+[A-Z][a-z]+){2,}(?![a-z-])")


def names_person_or_org(text: str) -> bool:
    """True when free text carries an unambiguous person/org shape (org
    suffix, "at <Employer>", possessive, honorific). Shared with the egress
    hygiene gate in scout_external."""
    t = text or ""
    return any(p.search(t) for p in _ORG_PERSON_PATTERNS)


def has_proper_noun_run(text: str) -> bool:
    """True on a multi-word proper-noun run (3+ consecutive capitalised
    words) - producer-side signal only, see the block comment above."""
    return bool(_PROPER_RUN_RE.search(text or ""))


# --- graph-contact lexicon (closes the heuristic residual) ------------------
# The lexicon is a frozenset of normalised name token-tuples built from the
# graph's ``pwg:Person pwg:displayName`` values (fetch_contact_names, I/O
# layer). It is INJECTED through the pure layer - compile_profile ->
# build_interest -> classify_privacy - so scoring stays a pure function of
# its inputs: no network, no globals, no wall-clock on the hot path. The
# live wiring is one bounded read-only SPARQL SELECT per compile in
# build_from_live, the same cost class as fetch_preferences beside it.

# token split keeps word characters of any script (diacritics are stripped
# separately); underscores and all punctuation/whitespace become boundaries
_TOKEN_BOUNDARY_RE = re.compile(r"[\W_]+", re.UNICODE)


class _LexiconUnavailable:
    """Sentinel: the contact lexicon could NOT be loaded (graph unreachable,
    query failed/timed out). Distinct from an empty-but-loaded lexicon (a
    genuinely fresh graph). The screen source is the ONLY thing that proves a
    subject is free of a contact name, so when it is unavailable we cannot
    prove anything is safe: FAIL-CLOSED - every non-empty subject is treated
    as if it might name a contact and is capped out of L1. A dead graph slows
    a compile to local-only; it never leaks a name."""

    __slots__ = ()

    def __bool__(self) -> bool:  # truthy: "a screen decision is present"
        return True

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return "LEXICON_UNAVAILABLE"


# The one shared sentinel instance. Compare with `is`.
LEXICON_UNAVAILABLE = _LexiconUnavailable()


def _normalise_name_tokens(text) -> tuple:
    """Case-, whitespace-, punctuation- and diacritics-insensitive token
    tuple of a name or subject: NFKD-decompose, drop combining marks,
    casefold, split on non-word runs. 'Renée  Fauré' and 'renee-faure'
    both normalise to ('renee', 'faure')."""
    t = unicodedata.normalize("NFKD", str(text or ""))
    t = "".join(ch for ch in t if not unicodedata.combining(ch))
    return tuple(tok for tok in _TOKEN_BOUNDARY_RE.split(t.casefold()) if tok)


def _lexicon_variants(toks: tuple) -> set:
    """Every screen form ONE contact name should catch. Invariant: any known
    contact name, in any form, must be screened. So from the canonical
    token tuple we derive:
      * the tuple itself - INCLUDING single-token names ("Robin"). A one-word
        contact ("Robin", "Jazz") is now screened even though it can collide
        with a one-word taste: the deliberate fail-closed trade (miss a leak
        vs. miss a taste -> never miss the leak).
      * initials + surname / given + initial: "R. Carter" and "Robin C." both
        normalise off "Robin Carter".
      * the unseparated concatenation: "@robincarter", "robincarter",
        "robincarter_films" all carry the token "robincarter"."""
    variants: set = set()
    if not toks:
        return variants
    variants.add(toks)                                 # incl. single-token
    if len(toks) >= 2:
        variants.add((toks[0][0],) + tuple(toks[1:]))   # "R. Carter"
        variants.add(tuple(toks[:-1]) + (toks[-1][0],))  # "Robin C."
        variants.add(("".join(toks),))                   # "robincarter"
    return variants


def build_contact_lexicon(names) -> frozenset:
    """The injectable screen set: normalised token-tuples of known contact
    names PLUS their initial and unseparated-handle variants (see
    _lexicon_variants). Single-token names are INCLUDED - the fail-closed
    posture: a bare first name ("Robin") must be screened."""
    out: set = set()
    for name in names or ():
        out |= _lexicon_variants(_normalise_name_tokens(name))
    return frozenset(out)


def subject_names_known_contact(subject, contact_lexicon) -> bool:
    """True when the subject text contains any lexicon name as a CONTIGUOUS
    token run ('the priya basu collection' matches ('priya', 'basu')).

    FAIL-CLOSED: if the lexicon could not be loaded (LEXICON_UNAVAILABLE),
    we cannot prove the subject is name-free, so any non-empty subject is
    treated as naming a contact. An empty-but-LOADED lexicon (frozenset()) is
    a genuinely fresh graph -> False, falling back to the shape heuristics -
    exactly the pre-lexicon posture."""
    if contact_lexicon is LEXICON_UNAVAILABLE:
        return bool(_normalise_name_tokens(subject))
    if not contact_lexicon:
        return False
    toks = _normalise_name_tokens(subject)
    if not toks:
        return False
    for n in {len(entry) for entry in contact_lexicon}:
        if n > len(toks):
            continue
        for i in range(len(toks) - n + 1):
            if toks[i:i + n] in contact_lexicon:
                return True
    return False


def classify_privacy(category: str, source: str, flags: list[str],
                     subject: str = "",
                     contact_lexicon: frozenset = frozenset()) -> str:
    """The privacy level one raw preference row earns. Category decides the
    base; a sensitive category is L3 outright; a noisy source or any noise
    flag caps the result at L2 (suspect free text must never egress); and the
    subject TEXT itself is screened (audit P3) - free text that names a
    person or organisation caps at L2 regardless of how safe the category
    is, because the category cannot prove the text is anonymous. The screen
    is two additive layers: the deterministic shape heuristics, plus the
    graph-contact lexicon (a subject containing a KNOWN contact's full name
    is personal no matter how it is capitalised)."""
    cat = (category or "").lower()
    if cat in SENSITIVE_CATEGORIES:
        return SENSITIVE_PRIVACY
    level = CATEGORY_PRIVACY.get(cat, DEFAULT_PRIVACY)
    if (source or "").lower() in _NOISY_SOURCES:
        level = more_restrictive(level, _MAX_NOISY_PRIVACY)
    if flags:
        level = more_restrictive(level, _MAX_NOISY_PRIVACY)
    if (names_person_or_org(subject) or has_proper_noun_run(subject)
            or subject_names_known_contact(subject, contact_lexicon)):
        level = more_restrictive(level, _MAX_NOISY_PRIVACY)
    return level

# Subjects that look like email threads / recruiter chatter rather than tastes.
_EMAIL_PREFIX_RE = re.compile(r"^\s*(re|fw|fwd|aw|tr)\s*[:\-]", re.IGNORECASE)
_RECRUITER_RE = re.compile(
    r"\b(opportunit(y|ies)|keen to learn|confidential\b|head of |coffee meeting|"
    r"\bintro\b|\brole\b|hiring|recruit|consulting opportunity|new opportunity)\b",
    re.IGNORECASE,
)
_URL_RE = re.compile(r"^(https?://|www\.)", re.IGNORECASE)
_YEAR_TAIL_RE = re.compile(r"\b(19|20)\d{2}\b")

# Sources where free-text subjects are most likely to be email/import noise.
_NOISY_SOURCES = {"csv", "email", "imap"}


# 🔴 AN IDENTIFIER IS NOT A TASTE, AND NOTHING WAS SAYING SO.
#
# Found by looking at the page a person sees rather than at the counts. With
# the unreachable 0.28 floor lowered, the v1.0.100 box's front page rendered
# four interest cards and every one was a contact identifier:
#
#     [interest] c…@icloud.com   "One of the things Ostler reckons you're into."
#     [interest] +85 … 77        "One of the things Ostler reckons you're into."
#     [interest] +85 … 67
#     [interest] +44 … 07
#
# That is worse than the empty page it replaced: it is nonsense, and it is
# nonsense built out of the customer's contacts. The floor had been masking it.
#
# The existing screens could not catch this. subject_privacy() CAPS THE PRIVACY
# LEVEL of a personal-looking subject; it never rejects the row, so the
# interest still reaches the page wearing an L2 badge. The noise table applies
# score PENALTIES for shapes like email_thread and dated_subject, and a penalty
# only reorders. Neither is a refusal, and a refusal is what an identifier
# needs.
#
# Deliberately narrow: an email address or a telephone number, anchored whole.
# A subject that merely CONTAINS an address (the words "thoughts on" followed
# by one) is left
# to the existing person-or-org screen, because that one is arguably about
# something. This rejects only subjects that ARE an identifier and nothing else.
_IDENTIFIER_SUBJECT_RE = re.compile(
    r"""^\s*(?:
        [^\s@]+@[^\s@]+\.[^\s@]+          # an email address, whole
      | \+?[\d][\d\s().\-]{6,}[\d]          # a phone number, 8+ digits with separators
    )\s*$""",
    re.VERBOSE,
)


def subject_is_identifier(subject: str) -> bool:
    """True when the subject IS an email address or telephone number.

    Such a row can never be an interest: it names a way to reach a person, not
    something the person likes. Returns False for empty input so an absent
    subject is handled by the existing emptiness checks rather than here.
    """
    s = (subject or "").strip()
    if not s:
        return False
    if _IDENTIFIER_SUBJECT_RE.match(s):
        return True
    # 🔴 AND THE MASKED FORM, which is what actually reaches here. The subject
    # is stored ALREADY REDACTED by the writer upstream: measured on the box,
    # the top interests were literally '+85 … 77' and '+44 … 07' -- a country
    # code, a U+2026 ellipsis and two digits. The full-identifier regex above
    # needs 8+ digits and matched none of them, so the first version of this
    # screen removed the one email address and left every phone number on the
    # page. I only caught that by reading the rendered cards again instead of
    # trusting the count going 4671 -> 4656.
    #
    # A TASTE HAS LETTERS IN IT. "jazz", "K-pop", "Formula 1", "Tokyo 2020" all
    # do. A subject with no alphabetic character at all is a number, a
    # redaction, or punctuation, and none of those is something a person is
    # into. This is deliberately a property of the SUBJECT rather than a
    # pattern list, so it survives the redaction format changing.
    if not any(ch.isalpha() for ch in s):
        return True
    return False


# ---------------------------------------------------------------------------
# Scoring layer (pure)
# ---------------------------------------------------------------------------

# A bookmark title is a HEADLINE PLUS A PUBLISHER, and the publisher is not
# part of what anyone is interested in. Measured on the rendered cards from a
# real box:
#
#     "Creating an innovation culture | McKinsey & Company"
#     "Spending patterns shift in China| warc.com"
#     "Demystifying the hackathon | McKinsey & Company"
#
# The trailing site name is noise on every one, and it also splits what should
# be one interest: the same topic saved from two outlets aggregates as two
# separate interests because the subjects differ only in their suffix.
#
# Conservative by construction. It peels ONE trailing segment, only after a
# recognised separator, only when what remains is still substantial (>= 12
# chars, so "AI | MIT" keeps its whole title rather than becoming "AI"), and
# only when the peeled part is short enough to be a masthead rather than half
# the sentence. Everything else is returned untouched.
_PUBLISHER_TAIL_RE = re.compile(
    r"^(?P<head>.+?)\s*[|\u2013\u2014]\s*(?P<tail>[^|\u2013\u2014]{1,40})$"
)


def strip_publisher_tail(subject: str) -> str:
    """Remove a trailing ' | Publisher' from a saved-article title.

    Returns the input unchanged when the shape does not clearly match, because
    a wrong peel silently changes what an interest IS, which is worse than a
    slightly noisy card.
    """
    s = (subject or "").strip()
    m = _PUBLISHER_TAIL_RE.match(s)
    if not m:
        return s
    head = m.group("head").strip()
    tail = m.group("tail").strip()
    # The head must survive as something readable, and the tail must look like
    # a masthead rather than the second half of a thought.
    if len(head) < 12 or not tail or len(tail) > len(head):
        return s
    return head


def clean_subject(subject: str) -> str:
    """Strip email reply/forward prefixes, peel a publisher tail, collapse
    whitespace."""
    s = (subject or "").strip()
    # peel repeated RE:/FW: prefixes
    prev = None
    while prev != s:
        prev = s
        s = _EMAIL_PREFIX_RE.sub("", s).strip()
    s = strip_publisher_tail(s)
    s = re.sub(r"\s+", " ", s)
    return s


def noise_flags(subject: str, category: str, source: str) -> list[str]:
    """Return a list of reasons this row is suspect. Empty == clean."""
    flags: list[str] = []
    raw = (subject or "").strip()
    cleaned = clean_subject(subject)

    if not cleaned:
        flags.append("empty")
    if _URL_RE.match(cleaned):
        flags.append("url_only")
    if len(cleaned) < 3:
        flags.append("too_short")
    if len(cleaned) > 80:
        flags.append("too_long")
    if _EMAIL_PREFIX_RE.match(raw):
        flags.append("email_reply_prefix")
    src = (source or "").lower()
    if src in _NOISY_SOURCES and _RECRUITER_RE.search(cleaned):
        flags.append("email_thread")
    if _YEAR_TAIL_RE.search(cleaned) and src in _NOISY_SOURCES:
        flags.append("dated_subject")
    if (category or "").lower() in ("facebook_content", "page"):
        flags.append("low_trust_category")
    if "CONTENT METADATA NO LONGER EXISTS" in raw or "urn:li" in raw.lower():
        flags.append("dead_reference")
    return flags


# penalty applied to confidence per distinct flag class
_FLAG_PENALTY = {
    "empty": 1.0,
    "url_only": 0.9,
    "too_short": 0.6,
    "too_long": 0.2,
    "email_reply_prefix": 0.5,
    "email_thread": 0.7,
    "dated_subject": 0.3,
    "low_trust_category": 0.3,
    "dead_reference": 0.7,
}


def _parse_dt(value: str | None):
    if not value:
        return None
    v = value.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(v)
    except ValueError:
        # try date-only or truncated forms
        for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
            try:
                dt = datetime.strptime(value[: len(fmt) + 2], fmt)
                break
            except (ValueError, IndexError):
                continue
        else:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def recency_decay(observed_at, now, half_life_days: float = 540.0) -> float:
    """Exponential decay, floored so a declared favourite never rots to nothing.
    half_life_days=540 (~18mo): an interest last seen 18 months ago is worth
    half a fresh one. Missing date -> neutral 0.6. Floor DECAY_FLOOR."""
    dt = _parse_dt(observed_at) if isinstance(observed_at, str) else observed_at
    if dt is None:
        return 0.6
    age_days = max(0.0, (now - dt).total_seconds() / 86400.0)
    return max(DECAY_FLOOR, 0.5 ** (age_days / half_life_days))


def category_trust(category: str) -> float:
    return CATEGORY_TRUST.get((category or "").lower(), DEFAULT_TRUST)


def source_trust(source: str) -> float:
    return SOURCE_TRUST.get((source or "").lower(), DEFAULT_SOURCE_TRUST)


def effective_strength(strength_raw: float, category: str, source: str) -> float:
    """A declared like from a trusted source is a real signal even if the graph
    stamped it with a near-zero strength, so floor it. Activity/noise sources
    keep their raw strength."""
    src = (source or "").lower()
    cat = (category or "").lower()
    if src in DECLARED_SOURCES and cat not in _LOW_TRUST_CATEGORIES:
        return max(strength_raw, DECLARED_STRENGTH_FLOOR)
    return strength_raw


def category_domain(category: str) -> float:
    return CATEGORY_DOMAIN.get((category or "").lower(), DEFAULT_DOMAIN)


def confidence(flags: list[str], category: str, source: str = "") -> float:
    """How sure are we this is a real interest? 0..1. Product of category trust
    and source trust, discounted by the worst flags (multiplicatively so two
    flags compound). Source trust is what sinks recruiter-email `csv` noise even
    when it is mis-filed under a high-trust category like movie_tv."""
    c = category_trust(category) * source_trust(source)
    for f in flags:
        c *= (1.0 - _FLAG_PENALTY.get(f, 0.1))
    return round(max(0.0, min(1.0, c)), 4)


# --- continuous confidence (de-clusters the flat 60/62/64% band) -----------
# `confidence()` above is the per-row RELIABILITY base - it is a product of two
# lookup tables, so on its own it can only land on a handful of discrete values
# (every Facebook book == 0.95x0.65 == 0.62). Real confidence should also reflect
# HOW MUCH evidence we have and how FRESH it is, which are continuous. So the
# displayed confidence = reliability x evidence_factor x recency_confidence.
# NOTE: with today's thin single-observation data the spread is modest; it widens
# sharply once richer sources (email/conversation mining) give repeated, multi-
# source observations of the same interest. That dependency is the point.

def evidence_factor(observations: int, n_sources: int) -> float:
    """Saturating boost for corroboration. 1 observation from 1 source -> 0.70;
    more observations and (weighted 2x) more distinct sources push toward 1.0."""
    extra = max(0, observations - 1) + 2 * max(0, n_sources - 1)
    return round(0.70 + 0.30 * (1.0 - 2.71828 ** (-extra / 4.0)), 4)


def recency_confidence(last_seen, now, half_life_days: float = 720.0) -> float:
    """Gentle, continuous recency term (distinct from the harsher score decay):
    a fresh sighting reads 1.0, a very old one floors at 0.75. This alone gives
    per-item spread even for single-observation interests with different dates."""
    dt = _parse_dt(last_seen) if isinstance(last_seen, str) else last_seen
    if dt is None:
        return 0.85
    age_days = max(0.0, (now - dt).total_seconds() / 86400.0)
    return round(0.75 + 0.25 * (0.5 ** (age_days / half_life_days)), 4)


def finalise_confidence(it: dict, now: datetime) -> dict:
    """Compute the displayed, continuous confidence from the stored reliability
    base plus evidence + recency. Called AFTER aggregation, when observation
    count and distinct-source count are known."""
    reliability = it.get("reliability", it.get("confidence", 0.0))
    ev = evidence_factor(it.get("observations", 1), len(it.get("sources", [])))
    rec = recency_confidence(it.get("last_seen"), now)
    it["confidence"] = round(max(0.0, min(1.0, reliability * ev * rec)), 4)
    it["evidence_factor"] = ev
    return it


def interest_id(subject: str, domain: str) -> str:
    key = f"{domain}::{clean_subject(subject).lower()}"
    return "int_" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:12]


def build_interest(raw: dict, now: datetime,
                   contact_lexicon: frozenset = frozenset()) -> dict:
    """Turn one raw preference row into a scored interest record."""
    subject = clean_subject(raw.get("subject", ""))
    category = (raw.get("category") or "").lower()
    source = (raw.get("source") or "").lower()
    polarity = raw.get("polarity", "like")
    strength_raw = float(raw.get("strength") or 0.0)
    observed = raw.get("observed_at") or raw.get("created_at")

    flags = noise_flags(raw.get("subject", ""), category, source)
    decay = recency_decay(observed, now)
    conf = confidence(flags, category, source)
    domain = category_domain(category)
    eff_strength = effective_strength(strength_raw, category, source)

    # final surfacing score: effective strength x how much we trust it x freshness.
    # polarity does not change magnitude; dislikes rank within their own bucket.
    score = round(eff_strength * conf * decay, 5)

    evidence = _evidence_phrase(source, strength_raw, observed)
    return {
        "id": interest_id(subject, domain),
        "subject": subject,
        "domain": domain,
        "category": category,
        "polarity": polarity,
        "privacy": classify_privacy(category, source, flags, subject,
                                    contact_lexicon=contact_lexicon),
        "score": score,
        "strength_raw": round(strength_raw, 4),
        "reliability": conf,        # the table-based base; finalise() adds evidence+recency
        "confidence": conf,         # provisional; recomputed continuously after aggregation
        "observations": 1,
        "recency_decay": round(decay, 4),
        "last_seen": _iso(observed),
        "sources": [source] if source else [],
        "evidence": [evidence] if evidence else [],
        "flags": flags,
    }


def _iso(value) -> str | None:
    dt = _parse_dt(value) if isinstance(value, str) else value
    return dt.date().isoformat() if dt else None


def _evidence_phrase(source: str, strength: float, observed) -> str:
    bits = []
    if source:
        bits.append(f"from {source}")
    bits.append(f"strength {strength:.2f}")
    seen = _iso(observed)
    if seen:
        bits.append(f"last seen {seen}")
    return " · ".join(bits)


def aggregate(interests: list[dict]) -> list[dict]:
    """Merge rows that resolve to the same (id) - same subject within a domain
    across sources. Keep the highest score, union evidence/sources/flags, and
    bump the merged score slightly for corroboration across distinct sources."""
    by_id: dict[str, dict] = {}
    for it in interests:
        cur = by_id.get(it["id"])
        if cur is None:
            by_id[it["id"]] = dict(it)
            continue
        cur["sources"] = sorted(set(cur["sources"]) | set(it["sources"]))
        cur["evidence"] = cur["evidence"] + [e for e in it["evidence"] if e not in cur["evidence"]]
        cur["flags"] = sorted(set(cur["flags"]) | set(it["flags"]))
        # privacy merges fail-closed: the most restrictive contributor wins
        # (a missing/unrecognised level on either side counts as L3)
        cur["privacy"] = more_restrictive(cur.get("privacy"), it.get("privacy"))
        cur["strength_raw"] = max(cur["strength_raw"], it["strength_raw"])
        cur["reliability"] = max(cur.get("reliability", 0.0), it.get("reliability", 0.0))
        cur["confidence"] = max(cur["confidence"], it["confidence"])
        cur["observations"] = cur.get("observations", 1) + it.get("observations", 1)
        cur["score"] = max(cur["score"], it["score"])
        # most-recent last_seen wins
        if it["last_seen"] and (not cur["last_seen"] or it["last_seen"] > cur["last_seen"]):
            cur["last_seen"] = it["last_seen"]

    # corroboration bonus: +8% per extra distinct source, capped
    for it in by_id.values():
        extra = max(0, len(it["sources"]) - 1)
        it["score"] = round(it["score"] * min(1.0 + 0.08 * extra, 1.4), 5)
    return list(by_id.values())


def apply_corrections(interests: list[dict], corrections: dict | None,
                      contact_lexicon: frozenset = frozenset()) -> list[dict]:
    """Corrections always win over inferred signal.

    corrections schema (see corrections.py):
      {"drop": [id_or_subject, ...],
       "strengthen": {id_or_subject: factor, ...},
       "weaken": {id_or_subject: factor, ...},
       "add": [{"subject":..,"domain":..,"category":..}, ...]}
    """
    if not corrections:
        return interests

    def _match(it, key):
        return key == it["id"] or key.lower() == it["subject"].lower()

    drop = set(corrections.get("drop", []))
    strengthen = corrections.get("strengthen", {})
    weaken = corrections.get("weaken", {})

    out = []
    for it in interests:
        if any(_match(it, d) for d in drop):
            continue
        it = dict(it)
        for key, factor in strengthen.items():
            if _match(it, key):
                it["score"] = round(it["score"] * float(factor), 5)
                it["confidence"] = 1.0
                it.setdefault("corrected", []).append("strengthened")
        for key, factor in weaken.items():
            if _match(it, key):
                it["score"] = round(it["score"] * float(factor), 5)
                it.setdefault("corrected", []).append("weakened")
        out.append(it)

    now = datetime.now(timezone.utc)
    for add in corrections.get("add", []):
        subj = clean_subject(add.get("subject", ""))
        if not subj:
            continue
        domain = add.get("domain") or category_domain(add.get("category", ""))
        category = add.get("category", "user_added")
        # corrections always win: an explicit, RECOGNISED privacy level on the
        # correction is the operator's voice (the documented route to L0/L1
        # opt-in). Anything else - absent, typo, unknown - falls back to the
        # classifier, whose unknown-category default is L2 (never egress).
        privacy = normalise_privacy(add.get("privacy")) or classify_privacy(
            category, "you", [], subj, contact_lexicon=contact_lexicon)
        out.append({
            "id": interest_id(subj, domain),
            "subject": subj,
            "domain": domain,
            "category": category,
            "privacy": privacy,
            "polarity": add.get("polarity", "like"),
            "score": float(add.get("score", 1.0)),
            "strength_raw": 1.0,
            "confidence": 1.0,
            "recency_decay": 1.0,
            "last_seen": now.date().isoformat(),
            "sources": ["you"],
            "evidence": ["you told Ostler this"],
            "flags": [],
            "corrected": ["added"],
        })
    return out


def compile_profile(raws: list[dict], now: datetime | None = None,
                    corrections: dict | None = None,
                    # 🔴 0.28 WAS UNREACHABLE BY EVERY SOURCE THAT SHIPS, so
                    # this filter could only ever return nothing. Measured on a
                    # real v1.0.100 box with 4792 projected rows:
                    #
                    #   safari_bookmarks / bookmark  4716 rows  reliability 0.0334
                    #   imessage         / social      76 rows  reliability 0.0775
                    #
                    # confidence = reliability x evidence_factor x recency, and
                    # both factors are capped at 1.0, so confidence can never
                    # EXCEED reliability. The best real interest on that box
                    # scored 0.1601 -- with five corroborating observations.
                    # 0.28 is 1.75x the best value the corpus can produce, so
                    # every row was suppressed and the customer's front page
                    # read "Ostler has spotted 0 interests from what it has read
                    # so far". Measured at several floors on the same rows:
                    #
                    #   0.28 -> 0 interests,    4701 suppressed
                    #   0.10 -> 4671 interests,   30 suppressed
                    #   0.00 -> 4701 interests,    0 suppressed
                    #
                    # 0.10 is chosen because it is REACHABLE by a shipped source
                    # and still DISCRIMINATES: it rejects 30 rows rather than
                    # waving everything through, which a floor of 0 would.
                    #
                    # ⚠️ THIS IS NOT THE FRONT PAGE'S NOISE CONTROL AND MUST NOT
                    # BE TUNED AS IF IT WERE. frontpage.py caps the page at
                    # MAX_INTEREST_CARDS = 12 and MAX_PER_DOMAIN = 4, ranked by
                    # score. 4671 interests in the artefact therefore produce at
                    # most 12 cards. This floor exists to keep genuine garbage
                    # out of the artefact and out of /api/v1/preferences, not to
                    # decide what a person sees.
                    #
                    # THE DEEPER SHAPE, recorded because it will come back: no
                    # amount of corroboration can lift a weak source, since
                    # evidence_factor saturates at 1.0. A topic bookmarked once
                    # and one bookmarked fifty times across three sources both
                    # ceiling at the source's own reliability. If richer sources
                    # (email, conversation mining) land and the table is not
                    # revisited, this floor will need revisiting with it.
                    min_confidence: float = 0.10,
                    contact_lexicon: frozenset = frozenset()) -> dict:
    """Full pipeline: raw rows -> grouped, ranked, corrected profile dict.
    ``contact_lexicon`` (see build_contact_lexicon) screens every subject
    against known contact names; empty = heuristics-only, the safe default."""
    now = now or datetime.now(timezone.utc)
    interests = [build_interest(r, now, contact_lexicon=contact_lexicon)
                 for r in raws]
    interests = aggregate(interests)
    interests = apply_corrections(interests, corrections,
                                  contact_lexicon=contact_lexicon)
    # recompute confidence continuously now that observation/source counts are known
    for it in interests:
        if not it.get("corrected"):
            finalise_confidence(it, now)

    # split likes / dislikes; group likes by domain; drop sub-threshold unless corrected
    domains: dict[str, list[dict]] = {}
    dislikes: list[dict] = []
    suppressed = 0
    suppressed_identifier = 0
    for it in interests:
        corrected = bool(it.get("corrected"))
        # An identifier is refused BEFORE the confidence floor and REGARDLESS
        # of `corrected`. A phone number does not become a taste because
        # someone confirmed it, and letting a correction override this is how
        # the nonsense would come back one feedback click later.
        if subject_is_identifier(it.get("subject", "")):
            suppressed_identifier += 1
            continue
        if not corrected and it["confidence"] < min_confidence:
            suppressed += 1
            continue
        if it["polarity"] == "dislike":
            dislikes.append(it)
            continue
        domains.setdefault(it["domain"], []).append(it)

    for items in domains.values():
        items.sort(key=lambda x: x["score"], reverse=True)
    dislikes.sort(key=lambda x: x["score"], reverse=True)

    domain_blocks = [
        {"domain": d, "count": len(items), "interests": items}
        for d, items in sorted(domains.items(), key=lambda kv: -sum(i["score"] for i in kv[1]))
    ]

    return {
        "schema_version": "0.1",
        "generated_utc": now.isoformat(),
        "stats": {
            "raw_rows": len(raws),
            "interests": sum(len(b["interests"]) for b in domain_blocks),
            "dislikes": len(dislikes),
            "suppressed_low_confidence": suppressed,
            # Counted separately: "below the bar" and "not a taste at all" are
            # different findings and a single number would hide the second.
            "suppressed_identifier": suppressed_identifier,
            "domains": len(domain_blocks),
        },
        "domains": domain_blocks,
        "dislikes": dislikes,
    }


# ---------------------------------------------------------------------------
# I/O layer (read-only Oxigraph)
# ---------------------------------------------------------------------------

def _oxigraph_credential() -> tuple[str, str] | None:
    """The Oxigraph loopback credential, or None when none is configured.

    NOT A SECOND MECHANISM. lib/ostler_store_auth.py is the estate's single
    decider for which credential belongs to which store port, and this reads
    the SAME env var and the SAME 0600 file it does:

        7878 -> ("Authorization", "Bearer ", "OXIGRAPH_TOKEN", "oxigraph_token")

    WHY THIS FUNCTION EXISTS AT ALL, rather than importing that shim. The shim
    is delivered as a .pth inside each SERVICE'S VENV, so it patches urllib
    automatically for anything running in one. THE EDITOR HAS NO VENV: its
    LaunchAgent runs `PYTHONPATH=<src> python3 -m compiler.emit_frontpage`
    against the system interpreter. So the blanket fix cannot reach this call
    site, and this is the one consumer it was never able to cover.
    """
    val = (os.environ.get("OXIGRAPH_TOKEN") or "").strip()
    if not val:
        secrets_dir = os.environ.get(
            "OSTLER_SECRETS_DIR", os.path.expanduser("~/.ostler/secrets"))
        try:
            with open(os.path.join(secrets_dir, "oxigraph_token"),
                      encoding="utf-8") as fh:
                val = fh.read().strip()
        except OSError:
            val = ""
    return ("Authorization", "Bearer " + val) if val else None


def _sparql_select(oxigraph_url: str, query: str, timeout: float = 30.0) -> list[dict]:
    """Read-only SPARQL SELECT against Oxigraph.

    THE DEFECT THIS FIXES, measured on a v1.0.98 box 2026-09-16:
        curl 127.0.0.1:7878/query with no credential  -> HTTP 401
        curl 127.0.0.1:7878/query with the credential -> 111,289 triples
    This function sent Accept and Content-Type and nothing else, so every
    query 401ed, every read returned zero rows, and the compiler wrote
    {"stats": {"raw_rows": 0, "interests": 0}} AND EXITED 0. The customer's
    front page read "0 interests inferred so far" for at least three builds
    and no gate went red, because an empty graph and a refused query are the
    same branch in every caller above this one.

    A 401 is now RAISED rather than swallowed. An unreadable store must be a
    loud failure, not a quiet zero: a zero that could not be measured is the
    exact shape that hid this for three builds.
    """
    url = oxigraph_url.rstrip("/") + "/query"
    data = urllib.parse.urlencode({"query": query}).encode("utf-8")
    headers = {
        "Accept": "text/csv",
        "Content-Type": "application/x-www-form-urlencoded",
    }
    cred = _oxigraph_credential()
    if cred is not None:
        headers[cred[0]] = cred[1]
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise RuntimeError(
                f"Oxigraph refused the query with HTTP {exc.code}. The store "
                "requires a credential and none was presented or it was "
                "rejected. Expected OXIGRAPH_TOKEN in the environment or a "
                "readable ~/.ostler/secrets/oxigraph_token. Refusing to report "
                "an empty profile, which is indistinguishable from an empty "
                "graph."
            ) from exc
        raise
    rows = list(csv.DictReader(io.StringIO(body)))
    return rows


def _pref_query(node_type: str) -> str:
    return (
        f"PREFIX pwg: <{PWG_NS}>\n"
        "SELECT ?subject ?category ?strength ?source ?observed ?created WHERE {\n"
        f"  ?s a pwg:{node_type} ;\n"
        "     pwg:subject ?subject ;\n"
        "     pwg:category ?category ;\n"
        "     pwg:preferenceStrength ?strength ;\n"
        "     pwg:dataSource ?source .\n"
        "  OPTIONAL { ?s pwg:observedAt ?observed }\n"
        "  OPTIONAL { ?s pwg:createdAt ?created }\n"
        "}"
    )


def fetch_preferences(oxigraph_url: str | None = None) -> list[dict]:
    """Read like/dislike preference rows from Oxigraph. Read-only."""
    oxigraph_url = oxigraph_url or os.environ.get(
        "OSTLER_OXIGRAPH_URL", "http://localhost:7878")
    out: list[dict] = []
    for node_type, polarity in (("LikePreference", "like"), ("DislikePreference", "dislike")):
        for row in _sparql_select(oxigraph_url, _pref_query(node_type)):
            out.append({
                "subject": row.get("subject", ""),
                "category": row.get("category", ""),
                "strength": row.get("strength", "0") or "0",
                "source": row.get("source", ""),
                "observed_at": row.get("observed") or None,
                "created_at": row.get("created") or None,
                "polarity": polarity,
            })
    return out


# Bound on the contact-name read: big enough for any personal graph (Andy's
# holds ~4.6k people), small enough that the SELECT stays trivially cheap.
_CONTACT_NAME_LIMIT = 20000


# Every name-bearing predicate the screen must read. Invariant: EVERY name
# from EVERY source. No node-type restriction - a subject of ANY
# of these predicates is a name-bearer (a calendar attendee, an iMessage
# handle, an email correspondent not yet hoisted to a pwg:Person), which is
# exactly what the denylist must catch. Over-inclusion is safe here: a denylist
# that screens too much only costs a taste, never a leak.
_CONTACT_NAME_PREDICATES = (
    "pwg:displayName", "pwg:givenName", "pwg:familyName",
    "pwg:nickname", "pwg:alternateName", "pwg:name",
)


def fetch_contact_names(oxigraph_url: str | None = None,
                        limit: int = _CONTACT_NAME_LIMIT,
                        timeout: float = 30.0) -> list[str]:
    """Known contact names from the local graph (read-only, bounded, one
    SELECT over EVERY name-bearing predicate - display/given/family/nick/alt
    names on any node type, not just pwg:Person). This is the lexicon's live
    source - the same local Oxigraph round-trip fetch_preferences already makes.

    FAIL-CLOSED: a failed/timed-out fetch RAISES. It must NOT be swallowed into
    an empty list - an empty list reads as "graph has no contacts" and silently
    disables the screen (invariant: a load failure must never let a
    name through). Callers degrade to LEXICON_UNAVAILABLE, not to []."""
    oxigraph_url = oxigraph_url or os.environ.get(
        "OSTLER_OXIGRAPH_URL", "http://localhost:7878")
    union = " UNION ".join(
        f"{{ ?p {pred} ?name }}" for pred in _CONTACT_NAME_PREDICATES)
    query = (
        f"PREFIX pwg: <{PWG_NS}>\n"
        "SELECT DISTINCT ?name WHERE {\n"
        f"  {union}\n"
        f"}} LIMIT {int(limit)}"
    )
    rows = _sparql_select(oxigraph_url, query, timeout=timeout)
    return [r.get("name", "") for r in rows if r.get("name")]


def build_from_live(oxigraph_url: str | None = None,
                    corrections: dict | None = None) -> dict:
    # Refresh cadence of the lexicon == every compile: it is rebuilt from the
    # graph on each run, alongside the preference fetch it sits next to.
    #
    # FAIL-CLOSED: if the lexicon source cannot be read, the screen degrades to
    # LEXICON_UNAVAILABLE (cap everything out of L1 for this compile), NOT to an
    # empty lexicon (which would silently un-screen every subject).
    try:
        lexicon: frozenset | _LexiconUnavailable = build_contact_lexicon(
            fetch_contact_names(oxigraph_url))
    except Exception as exc:  # noqa: BLE001 - fail CLOSED, never open
        print(f"interest-profile: contact-name fetch failed "
              f"({type(exc).__name__}: {exc}) - FAIL-CLOSED: every subject "
              "capped out of L1 for this compile", file=sys.stderr)
        lexicon = LEXICON_UNAVAILABLE
    return compile_profile(fetch_preferences(oxigraph_url),
                           corrections=corrections,
                           contact_lexicon=lexicon)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description="Compile the Phase-0 interest profile.")
    p.add_argument("--oxigraph", default=os.environ.get("OSTLER_OXIGRAPH_URL", "http://localhost:7878"))
    p.add_argument("--out", default="interest_profile.json")
    p.add_argument("--corrections", default=None, help="path to corrections JSON")
    p.add_argument("--top", type=int, default=0, help="print top-N per domain to stderr")
    args = p.parse_args(argv)

    corr = None
    if args.corrections and os.path.exists(args.corrections):
        with open(args.corrections) as fh:
            corr = json.load(fh)

    profile = build_from_live(args.oxigraph, corrections=corr)
    with open(args.out, "w") as fh:
        json.dump(profile, fh, indent=2, ensure_ascii=False)

    import sys
    s = profile["stats"]
    print(f"profile: {s['interests']} interests across {s['domains']} domains "
          f"({s['dislikes']} dislikes, {s['suppressed_low_confidence']} suppressed) "
          f"from {s['raw_rows']} raw rows -> {args.out}", file=sys.stderr)
    if args.top:
        for block in profile["domains"]:
            print(f"\n## {block['domain']} ({block['count']})", file=sys.stderr)
            for it in block["interests"][:args.top]:
                flag = f"  [{','.join(it['flags'])}]" if it["flags"] else ""
                print(f"  {it['score']:.3f}  {it['subject']}  ({it['confidence']:.2f} conf){flag}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
