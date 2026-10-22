"""Cuisine words for the food evidence writers: one vocabulary, read from the
SHARED file ``vocab/cuisine.yaml`` that the derive readers also use.

There is no second list here. Every writer of food.cuisine evidence
(reservations, delivery orders, calendar meals, OSM tags, the local model,
stated likes from conversation) maps into the labels of that file, so one
cuisine is one value: Sichuan, Sichuanese, Szechuan and Szechwan all land on
``chinese``, whichever source spelled it.

Stdlib only, on purpose: the ingest service has no PyYAML on the Hub, so this
reads the file with a small parser for its fixed shape (``label: [word, "two
words"]``). A test proves it returns exactly what ``yaml.safe_load`` does.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

VOCAB_FILE = Path(__file__).resolve().parent / "vocab" / "cuisine.yaml"
_LINE = re.compile(r'^\s*(?P<label>"[^"]+"|\'[^\']+\'|[^\s#:][^:#]*?)\s*:\s*\[(?P<body>.*)\]\s*(?:#.*)?$')
_ITEM = re.compile(r'"([^"]*)"|\'([^\']*)\'|([^,\s][^,]*)')
_SPLIT = re.compile(r"[;,/|]+")


def parse_vocab(text: str) -> Dict[str, List[str]]:
    out: Dict[str, List[str]] = {}
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = _LINE.match(raw)
        if not m:
            continue
        label = m["label"].strip().strip("\"'")
        out[label] = [(a or b or c).strip() for a, b, c in _ITEM.findall(m["body"]) if (a or b or c).strip()]
    return out


def _compile(vocab: Dict[str, List[str]]) -> List[Tuple[str, "re.Pattern[str]"]]:
    rows = []
    for label, words in vocab.items():
        alts = "|".join(re.escape(w.lower()) for w in sorted(words, key=len, reverse=True))
        rows.append((label, re.compile(r"(?<![a-z0-9])(?:%s)(?![a-z0-9])" % alts)))
    return rows


_CACHE: Dict[str, list] = {}


def _rows() -> List[Tuple[str, "re.Pattern[str]"]]:
    if "rows" not in _CACHE:
        _CACHE["rows"] = _compile(parse_vocab(VOCAB_FILE.read_text(encoding="utf-8")))
    return _CACHE["rows"]


def labels() -> Tuple[str, ...]:
    return tuple(label for label, _ in _rows())


# Labels that describe a kind of venue or an eating style, not a regional cuisine.
# The local model is not asked to guess these.
VENUE_LABELS = ("cafe", "dessert", "fast food", "vegetarian")


def normalise_cuisines(value) -> List[str]:
    """Every canonical label a value (or list of values) names, order kept."""
    if value is None:
        return []
    parts: Iterable[str] = value if isinstance(value, (list, tuple)) else _SPLIT.split(str(value))
    out: List[str] = []
    for part in parts:
        low = str(part).strip().lower().replace("_", " ")
        if not low:
            continue
        for label, rx in _rows():
            if label not in out and rx.search(low):
                out.append(label)
    return out


def normalise_cuisine(value) -> Optional[str]:
    """The first canonical label a value names, else None. None for an unknown
    word: an unknown word is not a cuisine."""
    got = normalise_cuisines(value)
    return got[0] if got else None


def infer_cuisine(*texts: str) -> Optional[Tuple[str, int]]:
    """Local rule arm: (label, distinct keyword hits) from a name, menu words and
    dishes. The label with most hits wins; a tie returns None (a name that reads
    as two cuisines is evidence of neither)."""
    hay = " | ".join(t.lower() for t in texts if t)
    if not hay:
        return None
    score: Dict[str, int] = {}
    for label, rx in _rows():
        n = len({m.group(0) for m in rx.finditer(hay)})
        if n:
            score[label] = n
    if not score:
        return None
    ranked = sorted(score.items(), key=lambda kv: -kv[1])
    if len(ranked) > 1 and ranked[0][1] == ranked[1][1]:
        return None
    return ranked[0]
