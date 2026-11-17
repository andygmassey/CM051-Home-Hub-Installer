"""Layout-aware reading. Pure functions over boxes (x, y, w, h, text); y is from the TOP of the page, 0..1.

Apple Vision gives line boxes on this Mac; PDFs give word positions (pdftotext -bbox-layout). Supplier
is read from the top band; the total is the amount on the same row as a total label, in the bottom band.
"""
from __future__ import annotations

import re
from typing import List, Optional, Sequence, Tuple

from .supplier_guard import is_boilerplate, is_owner_or_processor

Box = Tuple[float, float, float, float, str]
TOP_BAND = 0.30
BOTTOM_BAND = 0.55
_TOTAL_LABEL = re.compile(r"\b(total|amount\s+due|balance\s+due|balance|grand\s+total|order\s+total|amount\s+paid)\b", re.I)
_NOT_TOTAL = re.compile(r"\b(sub\s*total|subtotal|tax\s+total|vat\s+total)\b", re.I)
_AMOUNT = re.compile(r"(?:[A-Z]{3}|HK\$|US\$|£|\$|€)?\s*([0-9]{1,3}(?:,[0-9]{3})*\.[0-9]{2})\b")


def _rows(boxes: Sequence[Box]) -> List[List[Box]]:
    """Group boxes whose vertical centres are within half a line height into one row, left to right."""
    rows: List[List[Box]] = []
    for b in sorted(boxes, key=lambda b: b[1]):
        cy = b[1] + b[3] / 2
        for r in rows:
            r_cy = r[0][1] + r[0][3] / 2
            if abs(cy - r_cy) < max(b[3], r[0][3]) / 2:
                r.append(b)
                break
        else:
            rows.append([b])
    for r in rows:
        r.sort(key=lambda b: b[0])
    return rows


def layout_supplier(boxes: Sequence[Box], owner_terms=()) -> Optional[str]:
    """First non-boilerplate, non-processor, non-owner line in the top band that carries letters."""
    for row in _rows([b for b in boxes if b[1] < TOP_BAND]):
        text = " ".join(b[4] for b in row).strip()
        if re.search(r"[A-Za-z]{3}", text) and not is_boilerplate(text) and not is_owner_or_processor(text, owner_terms):
            return text
    return None


def layout_total(boxes: Sequence[Box]) -> Optional[Tuple[str, float]]:
    """The amount on a total-labelled row in the bottom band. Subtotals are not totals. Last one wins."""
    found = None
    for row in _rows([b for b in boxes if b[1] >= BOTTOM_BAND]):
        label = " ".join(b[4] for b in row if b[0] < 0.6)
        if not _TOTAL_LABEL.search(label) or _NOT_TOTAL.search(label):
            continue
        amounts = [b for b in row if b[0] >= 0.6]
        for b in amounts:
            m = _AMOUNT.search(b[4])
            if m:
                found = (b[4].strip(), float(m.group(1).replace(",", "")))
    return found
