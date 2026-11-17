"""Supplier name normalisation. A legal suffix is a naming form, not a different supplier.

"X, PBC" and "X" are the same merchant; so are "Foo Ltd" and "Foo Limited" and "Foo Co., Ltd.".
Only TRAILING legal suffix tokens are stripped, repeatedly, so "Limited Edition Cafe" keeps its
word and a name made only of a suffix is kept whole. Used for the supplier score and for dedupe.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Optional

# Lower-case, punctuation-free tokens. "co" and "company" are included because "Foo Co Ltd" is one name.
LEGAL_SUFFIXES = frozenset({
    "ltd", "limited", "inc", "incorporated", "pbc", "llc", "llp", "lp", "plc", "gmbh", "ag", "co",
    "company", "corp", "corporation", "pte", "pty", "bv", "nv", "sa", "srl", "sarl", "kk", "ltda", "oy",
    "as", "ab", "spa", "sas", "lda",
})
_NON_ALNUM = re.compile(r"[^a-z0-9]+")


def _fold(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return s.replace("&", " and ")


def normalise_supplier(name: Optional[str]) -> str:
    """Canonical form for comparison: ASCII, lower case, no punctuation, no trailing legal suffix."""
    tokens = [t for t in _NON_ALNUM.split(_fold(name)) if t]
    while len(tokens) > 1 and tokens[-1] in LEGAL_SUFFIXES:
        tokens.pop()
    return "".join(tokens)


def same_supplier_name(a: Optional[str], b: Optional[str]) -> bool:
    """True when both names normalise to the same non-empty form."""
    ka, kb = normalise_supplier(a), normalise_supplier(b)
    return bool(ka) and ka == kb
