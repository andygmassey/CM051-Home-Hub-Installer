"""Category presets and book defaults, loaded from the sourced file category_presets.json.

Every category carries tax_box_ref, allowable (yes | partial | no), source_url and note, as the source file
states them. `verify` is True only where the source marks a category partial: those, and only those, still
need an accountant's check before customer launch. The owner may rename or add categories.

UNCATEGORISED is the id a receipt carries until the owner chooses a category. It is not a listed category.
Tax-year starts: UK 6 April, HK 1 April, US 1 January (see the file's tax_year_basis for the years covered).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List

UNCATEGORISED = "other"
# Categories the research guide (section 8, "Needs a professional before launch") names: capital vs expense,
# UK Ltd director and company car benefits (P11D), Hong Kong entertaining, and foreign VAT/GST. The owner
# sees an accountant note on these. Set in code, not in the sourced file, because it is the guide's call.
PROFESSIONAL_IDS = frozenset({
    "uk_se_capital_equipment", "uk_ltd_capital_equipment", "hk_capital_equipment", "gen_capital_equipment",
    "uk_ltd_company_car", "uk_ltd_directors_personal", "hk_client_entertaining", "hk_overseas_vat_gst",
})
_SOURCE = Path(__file__).with_name("category_presets.json")


def _load() -> Dict[str, List[Dict[str, object]]]:
    raw = json.loads(_SOURCE.read_text(encoding="utf-8"))["presets"]
    out: Dict[str, List[Dict[str, object]]] = {}
    for pid, items in raw.items():
        cats = []
        for i in items:
            cats.append({
                "id": i["id"],
                "label": i["label"],
                "box": i.get("tax_box_ref", ""),
                "tax_box_ref": i.get("tax_box_ref", ""),
                "allowable": i["allowable"],
                "source_url": i["source_url"],
                "note": i.get("note", ""),
                "verify": i["allowable"] == "partial",
                "professional": i["id"] in PROFESSIONAL_IDS,
            })
        out[pid] = cats
    return out


PRESETS: Dict[str, List[Dict[str, object]]] = _load()
_PERSONAL_BASE = [
    {"id": "groceries", "label": "Groceries", "box": "", "tax_box_ref": "", "allowable": "no",
     "source_url": "", "note": "Personal book, owner-set labels.", "verify": False},
    {"id": "eating_out", "label": "Eating out", "box": "", "tax_box_ref": "", "allowable": "no",
     "source_url": "", "note": "", "verify": False},
    {"id": "transport", "label": "Transport", "box": "", "tax_box_ref": "", "allowable": "no",
     "source_url": "", "note": "", "verify": False},
    {"id": "health", "label": "Health", "box": "", "tax_box_ref": "", "allowable": "no",
     "source_url": "", "note": "", "verify": False},
    {"id": "entertainment", "label": "Entertainment", "box": "", "tax_box_ref": "", "allowable": "no",
     "source_url": "", "note": "", "verify": False},
    {"id": "shopping", "label": "Shopping", "box": "", "tax_box_ref": "", "allowable": "no",
     "source_url": "", "note": "", "verify": False},
    {"id": "other", "label": "Other", "box": "", "tax_box_ref": "", "allowable": "no",
     "source_url": "", "note": "", "verify": False},
]
PERSONAL: List[Dict[str, object]] = [dict(c, professional=False) for c in _PERSONAL_BASE]

# Not part of the sourced set. Owner-set, and not used for any tax box.
TAX_YEAR_START = {
    "uk_self_employed": "04-06",
    "uk_ltd": "04-06",
    "us_schedule_c": "01-01",
    "hk_profits_tax": "04-01",
    "general": "01-01",
}
# Tax-registered (VAT/GST) is never set silently: it is an owner prompt, and UK/HK default to no.
DEFAULT_CURRENCY = {"uk_self_employed": "GBP", "uk_ltd": "GBP", "us_schedule_c": "USD",
                    "hk_profits_tax": "HKD", "general": "GBP"}


# The uncategorised bucket shown in exports: not a listed category, so not sourced, and never professional.
UNCATEGORISED_ENTRY: Dict[str, object] = {
    "id": UNCATEGORISED, "label": "Uncategorised", "box": "", "tax_box_ref": "", "allowable": "partial",
    "source_url": "", "note": "The owner has not chosen a category yet.", "verify": True, "professional": False,
}


def categories_for(preset: str) -> List[Dict[str, object]]:
    if preset not in PRESETS:
        raise KeyError(preset)
    return list(PRESETS[preset])
