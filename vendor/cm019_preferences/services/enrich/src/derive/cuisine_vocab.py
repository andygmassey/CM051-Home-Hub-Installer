"""Cuisine words for the food evidence writers: one vocabulary, read from the
SHARED file ``vocab/cuisine.yaml`` that the derive readers also use.

There is no second list here. Every writer of food.cuisine evidence
(reservations, delivery orders, calendar meals, OSM tags, the local model,
stated likes from conversation) maps into the labels of that file, so one
cuisine is one value: Sichuan, Sichuanese, Szechuan and Szechwan all land on
``chinese``, whichever source spelled it.

Stdlib only, on purpose: the ingest service has no PyYAML on the Hub, so this
reads the file with a small parser for its two row shapes (``label: [word, "two
words"]`` and ``label: {parent: x, words: [...]}``). A test proves it returns exactly what ``yaml.safe_load`` does.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

VOCAB_FILE = Path(__file__).resolve().parent / "vocab" / "cuisine.yaml"
_LINE = re.compile(r'^\s*(?P<label>"[^"]+"|\'[^\']+\'|[^\s#:][^:#]*?)\s*:\s*(?P<rest>\[.*\]|\{.*\})\s*(?:#.*)?$')
_ITEM = re.compile(r'"([^"]*)"|\'([^\']*)\'|([^,\s][^,]*)')
_DICT = re.compile(r'^\{\s*parent:\s*(?P<parent>[^,}\s]+)\s*,\s*words:\s*\[(?P<body>.*)\]\s*\}$')
_SPLIT = re.compile(r"[;,/|]+")


def _words(body: str) -> List[str]:
    return [(a or b or c).strip() for a, b, c in _ITEM.findall(body) if (a or b or c).strip()]


def parse_vocab(text: str) -> Dict[str, object]:
    """The vocabulary exactly as ``yaml.safe_load`` returns it: label -> [words]
    or label -> {"parent": label, "words": [words]}."""
    out: Dict[str, object] = {}
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = _LINE.match(raw)
        if not m:
            continue
        label = m["label"].strip().strip("\"'")
        rest = m["rest"].strip()
        if rest.startswith("{"):
            d = _DICT.match(rest)
            if d:
                out[label] = {"parent": d["parent"], "words": _words(d["body"])}
        else:
            out[label] = _words(rest[1:-1])
    return out


_CACHE: Dict[str, object] = {}


def _rows() -> List[Tuple[str, "re.Pattern[str]"]]:
    if "rows" not in _CACHE:
        parents: Dict[str, str] = {}
        rows = []
        for label, v in parse_vocab(VOCAB_FILE.read_text(encoding="utf-8")).items():
            words = v["words"] if isinstance(v, dict) else v
            if isinstance(v, dict):
                parents[label] = v["parent"]
            alts = "|".join(re.escape(w.lower()) for w in sorted(words, key=len, reverse=True))
            rows.append((label, re.compile(r"(?<![a-z0-9])(?:%s)(?![a-z0-9])" % alts)))
        _CACHE["rows"], _CACHE["parents"] = rows, parents
    return _CACHE["rows"]


def parents() -> Dict[str, str]:
    """{regional label: parent label}, e.g. sichuan -> chinese."""
    _rows()
    return _CACHE["parents"]


def labels() -> Tuple[str, ...]:
    return tuple(label for label, _ in _rows())


# Labels that describe a kind of venue or an eating style, not a regional cuisine.
# The local model is not asked to guess these.
VENUE_LABELS = ("cafe", "dessert", "fast food")


def normalise_cuisines(value) -> List[str]:
    """Every canonical label a value (or list of values) names, order kept. A
    regional spelling gives the REGIONAL label only (szechuan -> sichuan); the
    parent is added by the derive readers' roll-up, never here."""
    if value is None:
        return []
    parts: Iterable[str] = value if isinstance(value, (list, tuple)) else _SPLIT.split(str(value))
    out: List[str] = []
    for part in parts:
        low = str(part).strip().lower().replace("_", " ")
        if not low:
            continue
        for label, rx in _rows():
            if label not in out and (rx.search(low) or rx.search(low.replace("-", " "))):
                out.append(label)
    return out


def normalise_cuisine(value) -> Optional[str]:
    """The first canonical label a value names, else None. None for an unknown
    word: an unknown word is not a cuisine."""
    got = normalise_cuisines(value)
    return got[0] if got else None


def infer_cuisine(*texts: str) -> Optional[Tuple[str, int]]:
    """Local rule arm: (label, distinct keyword hits) from a name, menu words and
    dishes. The label with most hits wins. On a tie a regional label beats its
    own parent (kung pao in a Chinese restaurant is sichuan); a tie between
    unrelated cuisines returns None (evidence of neither)."""
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
    par = parents()
    # a parent hit and a child hit are one cuisine family: count the family's best
    ranked = sorted(score.items(), key=lambda kv: (-kv[1], 0 if kv[0] in par else 1))
    best = ranked[0]
    tied = [lab for lab, n in ranked if n == best[1]]
    if len(tied) > 1 and not all(par.get(t) in tied or t in par.values() for t in tied):
        return None
    if len(tied) > 1:
        tied.sort(key=lambda t: 0 if t in par else 1)
        return tied[0], best[1]
    return best
