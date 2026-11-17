"""Positive supplier selection. A supplier is one of four candidates, or there is none (Check).

(a) the top-band line from the layout reader (or the first header lines of plain text);
(b) the sender domain's organisation, only if the text carries that name;
(c) a line next to a VAT, company or registration number;
(d) a remembered supplier name found in the text.
The model chooses AMONG these; `qualifies` refuses any answer that is not one of them. The
blocklist in supplier_guard is a backstop only.
"""
from __future__ import annotations

import re
from typing import Iterable, List, Optional, Sequence

from .memory import sender_domain
from .names import normalise_supplier
from .supplier_guard import is_boilerplate, is_owner_or_processor

_REG = re.compile(r"\b(VAT|GST|ABN|UEN|Company\s+(No|Number|Reg)|Co\.?\s*No|Reg(istration)?\.?\s*(No|Number)|Tax\s+ID)\b.{0,30}?\d", re.I)


def _key(s: str) -> str:
    return normalise_supplier(s)


def _add(out: List[str], name: Optional[str], owner_terms: Sequence[str]) -> None:
    if not name or len(_key(name)) < 3 or is_boilerplate(name) or is_owner_or_processor(name, owner_terms):
        return
    if name not in out:
        out.append(name.strip())


def supplier_candidates(text: str, boxes=None, sender: Optional[str] = None,
                        remembered: Iterable[str] = (), owner_terms: Sequence[str] = ()) -> List[str]:
    out: List[str] = []
    lines = [x.strip() for x in (text or "").splitlines() if x.strip()]
    # (a) top band
    if boxes:
        from .layout import layout_supplier
        _add(out, layout_supplier(boxes, owner_terms), owner_terms)
    else:
        for ln in lines[:3]:
            _add(out, ln, owner_terms)
    # (b) sender domain organisation, grounded in the text
    dom = sender_domain(sender)
    if dom:
        stem = dom.split(".")[0]
        if len(stem) >= 4 and stem.lower() in (text or "").lower():
            _add(out, stem.capitalize(), owner_terms)
    # (c) the line before a VAT / company / registration number
    for i, ln in enumerate(lines):
        if _REG.search(ln):
            for j in range(i - 1, max(-1, i - 3), -1):
                if not is_boilerplate(lines[j]) and re.search(r"[A-Za-z]{3}", lines[j]):
                    _add(out, lines[j], owner_terms)
                    break
    # (d) remembered names found in the text
    norm_text = _key(text or "")
    for name in remembered:
        k = _key(name)
        if k and len(k) >= 3 and k in norm_text:
            _add(out, name, owner_terms)
    return out


def qualifies(answer: Optional[str], candidates: Sequence[str]) -> bool:
    """The model's answer must be one of the candidates (same merchant after normalising)."""
    ka = _key(answer or "")
    if not ka:
        return False
    for c in candidates:
        kc = _key(c)
        if kc and (ka == kc or (min(len(ka), len(kc)) >= 4 and (ka in kc or kc in ka))):
            return True
    return False
