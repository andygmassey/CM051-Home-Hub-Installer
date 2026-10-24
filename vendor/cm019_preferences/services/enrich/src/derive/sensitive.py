"""Sensitive-term gate for Smart Preferences (GDPR Art. 9, diet, minors).

One data file (sensitive_terms.yaml), one module, used at EVERY surfacing
point rather than in one aggregator:

- write side: ``engine.Aggregator`` withholds a sensitive value, withholds an
  evidence item whose source text is about a minor, and keeps a sensitive
  source text out of the "because" titles;
- read side: ``query.DerivedGraphReader`` (the derived endpoint) and the
  QueryClient behind the MCP tools, REST API and gateway filter what they
  return through ``surfaceable`` (defence in depth for anything written before
  the gate, and for literal preferences that never pass through derive);
- stated statements (#428) and say-vs-do contradictions (#429) ask
  ``is_sensitive`` of the statement and ``is_abstention_value`` of the value.

Stdlib plus PyYAML. Importable two ways: as ``derive.sensitive`` and, for the
query service, by file path (it has no package-relative imports).
"""

from __future__ import annotations

import re
import unicodedata
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import yaml

TERMS_FILE = Path(__file__).resolve().parent / "sensitive_terms.yaml"
_CACHE: Dict[str, object] = {}

# CJK ideographs, kana and hangul: these scripts do not put spaces between
# words, so a term in them matches as a substring.
_CJK = re.compile(r"[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]")
_HANGUL = re.compile(r"^[\uac00-\ud7af]+$")
MIN_CJK_TERM = 2


def _norm(text: str) -> str:
    t = unicodedata.normalize("NFKC", str(text or "")).casefold()
    return re.sub(r"[\s\-_./'’]+", " ", t).strip()


def _term_rx(words: Iterable[str]) -> Optional["re.Pattern[str]"]:
    latin, cjk, hangul2 = [], [], []
    for w in words:
        n = _norm(w)
        if not n:
            continue
        if _CJK.search(n):
            if len(n) < MIN_CJK_TERM:
                raise ValueError(f"sensitive term {n!r} is one CJK character: it hides inside ordinary words")
            (hangul2 if (_HANGUL.match(n) and len(n) == 2) else cjk).append(n)
        else:
            latin.append(n)
    parts = []
    if latin:
        alts = "|".join(re.escape(w) for w in sorted(set(latin), key=len, reverse=True))
        # Whole word(s), Unicode-aware, with an optional plural suffix.
        parts.append(r"(?<!\w)(?:%s)(?:e?s)?(?!\w)" % alts)
    if cjk:
        parts.append("|".join(re.escape(w) for w in sorted(set(cjk), key=len, reverse=True)))
    if hangul2:
        # a 2-syllable hangul term must START a word: 기도를 yes, 경기도 no
        parts.append(r"(?<![\uac00-\ud7af])(?:%s)" % "|".join(re.escape(w) for w in sorted(set(hangul2))))
    return re.compile("|".join(parts)) if parts else None


def _load() -> dict:
    if "data" not in _CACHE:
        data = yaml.safe_load(TERMS_FILE.read_text(encoding="utf-8")) or {}
        rx = {}
        for cat, words in (data.get("terms") or {}).items():
            r = _term_rx(words or [])
            if r is not None:
                rx[cat] = r
        exc = sorted({_norm(e) for e in data.get("exceptions") or [] if _norm(e)}, key=len, reverse=True)
        _CACHE["exc"] = (re.compile(r"(?<!\w)(?:%s)(?!\w)" % "|".join(re.escape(e) for e in exc))
                         if exc else None)
        _CACHE["abst"] = _term_rx(data.get("abstention_terms") or [])
        _CACHE["theme"] = _term_rx(data.get("theme_terms") or [])
        _CACHE["exact"] = {_norm(w) for ws in (data.get("terms") or {}).values() for w in ws or []}
        _CACHE["data"], _CACHE["rx"] = data, rx
    return _CACHE["data"]


def data() -> dict:
    return _load()


def _prepared(text: str) -> str:
    low = _norm(text)
    exc = _CACHE.get("exc")
    return exc.sub(" ", low).strip() if (exc is not None and low) else low


def sensitive_category(text: str) -> Optional[str]:
    """The sensitive category a piece of text falls in (contains matching), else None."""
    _load()
    low = _prepared(text)
    if not low:
        return None
    for cat, rx in _CACHE["rx"].items():
        if rx.search(low):
            return cat
    return None


def is_sensitive(text: str) -> bool:
    return sensitive_category(text) is not None


def is_about_minor_text(text: str) -> bool:
    """Text that describes an event or place ABOUT a child (a kids' party, a nursery)."""
    _load()
    rx = _CACHE["rx"].get("minors")
    return bool(rx is not None and rx.search(_prepared(text)))


def is_sensitive_exact(text: str) -> bool:
    """True only when the text IS a sensitive term (or its plural) or a category
    label, not when it merely contains one. For NAMES of people, films and shows
    ("Christian Bale", "The Passion of the Christ"), where a sensitive word is
    part of a legitimate name."""
    _load()
    low = _norm(text)
    if not low:
        return False
    if low.replace(" ", "_") in _CACHE["data"].get("terms", {}):
        return True
    exact = _CACHE["exact"]
    return low in exact or (low.endswith("es") and low[:-2] in exact) or (
        low.endswith("s") and low[:-1] in exact)


def is_abstention_value(text: str) -> bool:
    """A value whose dislike or absence reveals health or religion (alcohol, pork,
    meat). Not withheld when LIKED; withheld from stated negatives and say-vs-do."""
    _load()
    rx = _CACHE.get("abst")
    return bool(rx is not None and rx.search(_prepared(text)))


def never_read_categories() -> List[str]:
    return [str(c).lower() for c in _load().get("never_read_categories", [])]


def name_categories() -> List[str]:
    return [str(c).lower() for c in _load().get("name_categories", [])]


def surfaceable(*texts: str, category: Optional[str] = None) -> bool:
    """The read-out predicate: False when the category is never surfaced
    (dietary...) or any text is sensitive. A NAME category (music, film, book,
    podcast...) uses EXACT matching, as the write side does for media name
    dimensions, so "Black Sabbath" or "Amy Winehouse - Rehab" stays; every
    other or missing category uses contains matching (fail closed)."""
    cat = str(category).strip().lower() if category is not None else ""
    if cat and cat in never_read_categories():
        return False
    check = is_sensitive_exact if cat in name_categories() else is_sensitive
    return not any(check(t) for t in texts if t)


DIMENSIONS_FILE = Path(__file__).resolve().parent / "dimensions.yaml"


def _exact_dimensions() -> frozenset:
    if "exact_dims" not in _CACHE:
        try:
            rows = yaml.safe_load(DIMENSIONS_FILE.read_text(encoding="utf-8")) or []
            dims = frozenset(r["dimension"] for r in rows if str(r.get("sensitive_match", "")) == "exact")
        except (OSError, yaml.YAMLError, KeyError, TypeError):
            dims = frozenset()   # unreadable register: every dimension reads as "contains" (fail closed)
        _CACHE["exact_dims"] = dims
    return _CACHE["exact_dims"]  # type: ignore[return-value]


THEME_PREFIX = "theme."


def is_sensitive_theme(text: str) -> bool:
    """The rule for a BROAD THEME label (dimension theme.*, the thematic rollup):
    a sensitive term, an abstention value (alcohol, pork...) or a broad concept
    in ``theme_terms`` ("disease", "belief system", "childhood"). Contains
    matching. A theme is a generalisation, so it is held to the strictest rule:
    "beverage" is fine, "alcoholic beverage" is not, liked or not."""
    _load()
    if is_sensitive(text) or is_abstention_value(text):
        return True
    rx = _CACHE.get("theme")
    return bool(rx is not None and rx.search(_prepared(text)))


def derived_value_is_sensitive(dimension: str, value: str) -> bool:
    """Read-side twin of the Aggregator's value gate: NAME dimensions marked
    ``sensitive_match: exact`` in dimensions.yaml use exact matching, a theme
    (``theme.*``) uses :func:`is_sensitive_theme`, every other (and every
    unknown) dimension uses contains matching."""
    if str(dimension or "").startswith(THEME_PREFIX):
        return is_sensitive_theme(value)
    if dimension in _exact_dimensions():
        return is_sensitive_exact(value)
    return is_sensitive(value)
