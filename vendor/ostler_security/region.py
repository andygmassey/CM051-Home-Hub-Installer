"""Region detection for the A8 Article 9 / voice-consent gate.

Decides whether the running install is in the EU/EEA, UK, US, or
"rest of world" (RoW). The result drives whether the Hub installer
shows the Article 9 EU consent screen and the EU voice-gate, or the
shorter US/UK INSTALL/CANCEL flow.

Defensive default: when signals conflict or are missing, we lean
``eu``. Per the brief, the lawyer-friend prefers a "false positive
on EU" (we ask the EU question to a US user) over a "false negative"
(we DO NOT ask an EU user). This is acceptable UX cost for legal
safety.

Signals (in priority order):

1. Manual override – the user typed an ISO-3166 code into the
   installer prompt (``install.sh`` line ~755). Wins outright.
2. Apple Contacts ``myCard`` country (``install.sh`` line ~605).
3. Phone-country (``install.sh`` line ~711).
4. Locale (``LANG`` / ``LC_ALL``). Used as tie-breaker only.
5. Default – ``eu`` if nothing usable, with ``source ==
   "default_eu"`` so Doctor / Settings can show "we couldn't tell,
   you're in the EU lane until you tell us otherwise."

There is NO IP geolocation. Adding one would be a privacy own-goal.

Persisted to ``~/.ostler/posture/region.json`` so subsequent
launches don't re-detect; the user can override in Settings.
"""
from __future__ import annotations

import json
import logging
import os
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal, Optional

logger = logging.getLogger(__name__)

REGION_SCHEMA_VERSION = 1

Region = Literal["eu", "uk", "us", "row"]

# EEA + Switzerland. Switzerland is treated as EU because the Swiss
# DPA mirrors GDPR and the lawyer-friend asked us to be defensive.
# Iceland / Liechtenstein / Norway are EEA. UK is its OWN region
# because UK GDPR diverges from EU GDPR going forward.
EU_EEA_COUNTRIES: frozenset[str] = frozenset({
    # EU member states
    "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR",
    "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL",
    "PL", "PT", "RO", "SK", "SI", "ES", "SE",
    # EEA non-EU
    "IS", "LI", "NO",
    # Treat-as-EU per defensive policy
    "CH",
})

UK_COUNTRIES: frozenset[str] = frozenset({"GB", "UK"})  # GB is canon
US_COUNTRIES: frozenset[str] = frozenset({"US"})


@dataclass(frozen=True)
class RegionResult:
    region: Region
    iso_country: str
    source: str  # "manual" | "contacts" | "phone" | "locale" | "default_eu"
    timestamp: str
    schema_version: int = REGION_SCHEMA_VERSION


# Country-name → ISO-3166 mappings. install.sh today has a small
# ``_country_to_code()`` helper at line ~672; we mirror its inputs
# (Apple Contacts emits localised English country names) and extend
# to full coverage for EU/EEA. RoW countries are not enumerated –
# anything not in this table that falls through to ``RoW`` lands as
# ``ZZ`` (ISO reserved for "unknown") with ``source = "default_eu"``.
COUNTRY_NAME_TO_ISO: dict[str, str] = {
    # UK / US first because they are the high-traffic cases.
    "united kingdom": "GB",
    "great britain": "GB",
    "england": "GB",
    "scotland": "GB",
    "wales": "GB",
    "northern ireland": "GB",
    "uk": "GB",
    "united states": "US",
    "united states of america": "US",
    "usa": "US",
    "america": "US",
    # EU + EEA
    "austria": "AT", "belgium": "BE", "bulgaria": "BG",
    "croatia": "HR", "cyprus": "CY", "czechia": "CZ",
    "czech republic": "CZ", "denmark": "DK", "estonia": "EE",
    "finland": "FI", "france": "FR", "germany": "DE",
    "greece": "GR", "hungary": "HU", "ireland": "IE",
    "republic of ireland": "IE", "italy": "IT", "latvia": "LV",
    "lithuania": "LT", "luxembourg": "LU", "malta": "MT",
    "netherlands": "NL", "the netherlands": "NL", "holland": "NL",
    "poland": "PL", "portugal": "PT", "romania": "RO",
    "slovakia": "SK", "slovenia": "SI", "spain": "ES",
    "sweden": "SE",
    "iceland": "IS", "liechtenstein": "LI", "norway": "NO",
    "switzerland": "CH",
}


def _normalise_country_input(value: str) -> Optional[str]:
    """Map a user-entered country name OR ISO code to a 2-letter ISO.

    Returns ``None`` when the input is empty or unrecognised. Caller
    decides whether to fall through to the next signal or default
    to EU.
    """
    if not value:
        return None
    cleaned = value.strip()
    if not cleaned:
        return None
    # Already a 2-letter code?
    if len(cleaned) == 2 and cleaned.isalpha():
        return cleaned.upper()
    return COUNTRY_NAME_TO_ISO.get(cleaned.lower())


def _classify(iso: str) -> Region:
    if iso in UK_COUNTRIES:
        return "uk"
    if iso in US_COUNTRIES:
        return "us"
    if iso in EU_EEA_COUNTRIES:
        return "eu"
    return "row"


def _locale_iso() -> Optional[str]:
    """Best-effort ISO from ``LC_ALL`` / ``LANG``. Returns ``None``
    when nothing useful is set.
    """
    raw = os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
    # Forms: ``en_GB.UTF-8``, ``de_DE.UTF-8``, ``C``, ``POSIX``,
    # ``fr_FR``. We need the country half after the underscore.
    if "_" not in raw:
        return None
    after = raw.split("_", 1)[1]
    # Country code is the next 2 letters; tolerate ``de_DE.UTF-8``.
    code = after[:2]
    if len(code) == 2 and code.isalpha():
        return code.upper()
    return None


def detect_region(
    *,
    manual_country: Optional[str] = None,
    contacts_country: Optional[str] = None,
    phone_country: Optional[str] = None,
) -> RegionResult:
    """Apply the priority chain and return the best guess.

    ``LANG`` / ``LC_ALL`` are read implicitly from ``os.environ``
    so the caller does not have to plumb them. Tests can monkeypatch
    those env vars.

    Per the brief §2 algorithm:

    - Manual wins outright.
    - Then Apple Contacts country.
    - Then phone country code.
    - Then locale, but ONLY as a tie-breaker if higher-priority
      signals exist. With NO higher signal, locale is taken on its
      own (so ``LANG=de_DE`` on a fresh Mac → EU).
    - If we have NOTHING, default ``eu`` with ``source =
      "default_eu"``.
    """
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    iso = _normalise_country_input(manual_country or "")
    if iso:
        return RegionResult(
            region=_classify(iso),
            iso_country=iso,
            source="manual",
            timestamp=now,
        )

    iso = _normalise_country_input(contacts_country or "")
    if iso:
        return RegionResult(
            region=_classify(iso),
            iso_country=iso,
            source="contacts",
            timestamp=now,
        )

    iso = _normalise_country_input(phone_country or "")
    if iso:
        return RegionResult(
            region=_classify(iso),
            iso_country=iso,
            source="phone",
            timestamp=now,
        )

    iso = _locale_iso()
    if iso:
        return RegionResult(
            region=_classify(iso),
            iso_country=iso,
            source="locale",
            timestamp=now,
        )

    # Nothing usable – defensive default.
    return RegionResult(
        region="eu",
        iso_country="ZZ",
        source="default_eu",
        timestamp=now,
    )


# ── Persistence ─────────────────────────────────────────────────────


def _region_dir() -> Path:
    base = Path(os.environ.get("OSTLER_HOME", os.path.expanduser("~/.ostler")))
    posture = base / "posture"
    posture.mkdir(parents=True, exist_ok=True)
    return posture


def _region_file() -> Path:
    return _region_dir() / "region.json"


def save_region(result: RegionResult) -> Path:
    """Persist ``result`` to ``~/.ostler/posture/region.json``.

    Atomic ``tmp + rename``. Returns the file path.
    """
    path = _region_file()
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(asdict(result), indent=2) + "\n")
    tmp.replace(path)
    return path


def load_region() -> Optional[RegionResult]:
    """Read the persisted region, or ``None`` when no file exists."""
    path = _region_file()
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        logger.warning("Could not read region file %s: %s", path, exc)
        return None
    try:
        return RegionResult(
            region=data["region"],
            iso_country=data["iso_country"],
            source=data["source"],
            timestamp=data["timestamp"],
            schema_version=data.get("schema_version", REGION_SCHEMA_VERSION),
        )
    except (KeyError, TypeError) as exc:
        logger.warning("Region file %s malformed: %s", path, exc)
        return None
