"""Contradiction DETECTION primitives, vendored from CM044.

VENDORED VERBATIM from CM044 ``compiler/contradictions.py`` at commit
``55af7cfcf6d4ba3c6cb9e8b8c2ef468808728135`` (2026-06-25). Per
MEMORY_HYGIENE_SPEC.md section 3.1: "Reuse it verbatim; do not fork the
regex." CM044 and CM041 are separate repos with no shared package, so
the detection half is copied here byte-identically; the render half
(``render_contradictions_page``) is NOT vendored because it depends on
CM044's ``compiler.locale`` and the wiki remains its owner.

If a pattern needs to change, change it in CM044 first and re-vendor --
the two copies must not drift.

Original module notes (CM044): the Personal World Graph accumulates
facts from many sources and sources disagree. Detection is
high-precision over recall -- only single-valued attribute conflicts
(residence / employer / nationality) and explicit affirm/negate pairs
are flagged; free-text facts that merely differ are NOT contradictions.
"""
from __future__ import annotations

import logging
import re
from collections import defaultdict
from typing import Any, Dict, List, Optional, Tuple

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Attribute extraction
# ---------------------------------------------------------------------------

# Single-valued attributes: a person can sensibly have only ONE current value.
# Each entry maps an attribute key to a list of (regex, value-group) patterns
# that pull the value out of a free-text fact subject. Patterns are anchored
# loosely and matched case-insensitively. Keep these conservative -- a loose
# pattern produces false positives, which is the one thing we must avoid.
_ATTRIBUTE_PATTERNS: Dict[str, List[str]] = {
    "residence": [
        r"\blives?\s+in\s+(?P<value>.+)",
        r"\bbased\s+in\s+(?P<value>.+)",
        r"\bresides?\s+in\s+(?P<value>.+)",
        r"\blocated\s+in\s+(?P<value>.+)",
    ],
    "employer": [
        r"\bworks?\s+(?:at|for)\s+(?P<value>.+)",
        r"\bemployed\s+(?:at|by)\s+(?P<value>.+)",
    ],
    "nationality": [
        r"\bis\s+(?P<value>[A-Z][a-z]+)\s*$",  # "is British" (single word)
    ],
}

# Words that, when they begin a value, mean the attribute is being NEGATED or
# made historic rather than asserted, so the value should not be compared as a
# current single value (e.g. "no longer works at Acme").
_HISTORIC_PREFIXES = (
    "no longer",
    "formerly",
    "previously",
    "used to",
    "ex-",
    "former",
)

# Tokens that strip trailing clauses from an extracted value so
# "London since 2019" and "London" compare equal.
_VALUE_TRAILERS = re.compile(
    r"\s+(?:since|from|until|as of|in)\s+\d.*$", re.IGNORECASE
)


def _normalise_value(value: str) -> str:
    """Lower-case, strip punctuation/trailing clauses for value comparison."""
    v = value.strip().rstrip(".;,")
    v = _VALUE_TRAILERS.sub("", v)
    v = re.sub(r"\s+", " ", v)
    return v.strip().lower()


def _extract_attribute(subject: str) -> Optional[Tuple[str, str]]:
    """Return ``(attribute_key, normalised_value)`` if the fact asserts a
    single-valued attribute, else ``None``.

    Skips historic/negated phrasings so "no longer works at Acme" is not
    treated as a current employer claim.
    """
    s = (subject or "").strip()
    if not s:
        return None
    low = s.lower()
    for prefix in _HISTORIC_PREFIXES:
        if prefix in low:
            return None
    for attr, patterns in _ATTRIBUTE_PATTERNS.items():
        for pat in patterns:
            m = re.search(pat, s, re.IGNORECASE)
            if m:
                value = _normalise_value(m.group("value"))
                if value:
                    return attr, value
    return None


# ---------------------------------------------------------------------------
# Negation pairs
# ---------------------------------------------------------------------------

# Explicit affirm/negate detection: a fact and its direct negation. We strip a
# leading negator and compare the remainder; if one fact negates another that
# is otherwise identical, that is a contradiction (e.g. "vegetarian" vs "not
# vegetarian").
_NEGATORS = re.compile(
    r"^\s*(?:not|never|no longer|doesn't|does not|isn't|is not|"
    r"can't|cannot|won't|will not)\s+",
    re.IGNORECASE,
)


def _strip_negation(subject: str) -> Tuple[bool, str]:
    """Return ``(was_negated, core_phrase)`` for a fact subject."""
    s = (subject or "").strip().rstrip(".;,")
    m = _NEGATORS.match(s)
    if m:
        return True, s[m.end():].strip().lower()
    return False, s.lower()


# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

def find_contradictions(
    facts_by_uri: Dict[str, List[Dict[str, Any]]],
    people: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """Find people with internally contradicting facts.

    Returns a list of conflict records, one per (person, attribute) pair that
    disagrees, sorted by display name. Each record:

    .. code-block:: python

        {
            "uri": "...",
            "display_name": "Jane Doe",
            "attribute": "employer",          # or "negation:<phrase>"
            "values": ["acme", "globex"],     # the conflicting values/facts
            "facts": ["Works at Acme", "Works for Globex"],
        }
    """
    name_by_uri = {p.get("uri"): (p.get("display_name") or "") for p in people}
    conflicts: List[Dict[str, Any]] = []

    for uri, facts in facts_by_uri.items():
        if not facts:
            continue

        # 1. Single-valued attribute conflicts.
        by_attr: Dict[str, Dict[str, str]] = defaultdict(dict)
        for f in facts:
            subject = f.get("subject") or ""
            extracted = _extract_attribute(subject)
            if extracted is None:
                continue
            attr, value = extracted
            # Map each distinct value to a representative original fact.
            by_attr[attr].setdefault(value, subject)

        for attr, value_to_fact in by_attr.items():
            if len(value_to_fact) > 1:
                conflicts.append({
                    "uri": uri,
                    "display_name": name_by_uri.get(uri, ""),
                    "attribute": attr,
                    "values": sorted(value_to_fact.keys()),
                    "facts": [value_to_fact[v] for v in sorted(value_to_fact)],
                })

        # 2. Affirm/negate pairs.
        affirmed: Dict[str, str] = {}
        negated: Dict[str, str] = {}
        for f in facts:
            subject = f.get("subject") or ""
            if not subject.strip():
                continue
            was_neg, core = _strip_negation(subject)
            if not core:
                continue
            (negated if was_neg else affirmed)[core] = subject
        for core, neg_fact in negated.items():
            if core in affirmed:
                conflicts.append({
                    "uri": uri,
                    "display_name": name_by_uri.get(uri, ""),
                    "attribute": f"negation:{core}",
                    "values": [affirmed[core], neg_fact],
                    "facts": [affirmed[core], neg_fact],
                })

    conflicts.sort(key=lambda c: ((c["display_name"] or "").lower(), c["attribute"]))
    return conflicts
