"""The one-off import taster, next to the G7 gate.

Andy + coordinator, 19 Oct: the FIRST import of an export file is free for
each source, with or without Pro, once per source, ever. Re-imports, later
export files for the same source, and every token or ongoing sync are Pro
(G7, ``subscription_gate.is_active_or_grace``, the single source of Pro).

PARITY NOTE. ostler_fda needs the same contract (Google Chat, Messenger,
Instagram, Telegram exports go through it). Rule 0.5 forbids a cross-repo
import, so this module is the reference copy and ostler_fda's must be a copy
of it: same function names and signatures, same ledger path and JSON shape,
same copy text. If either changes, change both. At the time of writing NO
ostler_fda copy exists yet (searched CM051 origin/main and every recently
pushed branch for a first-import helper: none).

Contract:

    entry_gate(source: str, *, export_import: bool) -> GateDecision
        Call at the entry point, before reading the export or the API.
        allowed + reason "pro"               Pro is active (any route)
        allowed + reason "first_import_free" export_import and this source
                                             has never used its free import
        refused + reason "pro_required"      everything else
        refused + reason "could_not_check"   the ledger could not be read.
                                             NEVER shown as a refusal: the
                                             caller says "Try again" (Andy).
    mark_first_import(source: str) -> None
        Call ONLY after a successful hand-off of a free import, so a failed
        first try does not burn the taster.
    pre_import_notice(source_label) / refusal_text(source_label)
        Andy's shared copy, verbatim (CONNECTORS_BUILD_BRIEF, 19 Oct).

Ledger: ``~/.ostler/state/first_imports.json``
(``{"sources": {"<source>": {"used_at": "<ISO8601 Z>"}}}``), override with
``OSTLER_FIRST_IMPORT_LEDGER``. Same directory as the G7 state file.

KNOWN GAP (for a ruling): Andy asked that a fresh reinstall cannot loop the
taster. A file under ``~/.ostler`` is removed by the uninstaller, so a
reinstall resets it. Surviving a reinstall needs a location the uninstaller
deliberately keeps (a Keychain item, for example). Not decided here.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .subscription_gate import is_active_or_grace


# ONE shared exit-code contract (coordinator, 19 Oct). 4 already means bad
# input in universal_import, and install.sh treats an unknown non-zero code
# as a failed step, so a Pro refusal is its own code.
EXIT_PAUSED_NOT_PRO = 5
# "Could not check" is never a refusal: it is CANNOT-RUN, offer "Try again".
EXIT_COULD_NOT_CHECK = 3


PRE_IMPORT_TEMPLATE = (
    "Your first import from each app is free. To bring in newer history "
    "later, or keep {source} up to date automatically, you'll need Ostler Pro."
)
REFUSAL_TEMPLATE = (
    "You've already imported your {source} history once, free. Bringing in "
    "newer exports, and keeping {source} up to date automatically, is part "
    "of Ostler Pro.\n"
    "Everything you've already imported stays here, and you can still "
    "search it."
)
COULD_NOT_CHECK_TEXT = (
    "Ostler couldn't check whether your free import has been used. "
    "Nothing was imported. Try again."
)


def pre_import_notice(source_label: str) -> str:
    return PRE_IMPORT_TEMPLATE.format(source=source_label)


def refusal_text(source_label: str) -> str:
    return REFUSAL_TEMPLATE.format(source=source_label)


@dataclass(frozen=True)
class GateDecision:
    allowed: bool
    reason: str  # "pro" | "first_import_free" | "pro_required" | "could_not_check"

    @property
    def is_free_import(self) -> bool:
        return self.allowed and self.reason == "first_import_free"


class LedgerUnreadable(Exception):
    pass


def ledger_path() -> Path:
    raw = os.environ.get("OSTLER_FIRST_IMPORT_LEDGER")
    if raw:
        return Path(raw).expanduser()
    return Path.home() / ".ostler" / "state" / "first_imports.json"


def _load() -> dict:
    path = ledger_path()
    if not path.exists():
        return {"sources": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise LedgerUnreadable(type(exc).__name__) from exc
    if not isinstance(data, dict) or not isinstance(data.get("sources"), dict):
        raise LedgerUnreadable("bad shape")
    return data


def first_import_allowed(source: str) -> bool:
    """True when ``source`` has never used its free import. Raises
    ``LedgerUnreadable`` rather than guessing either way."""
    return source not in _load()["sources"]


def mark_first_import(source: str) -> None:
    try:
        data = _load()
    except LedgerUnreadable:
        data = {"sources": {}}
    stamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    data["sources"].setdefault(source, {"used_at": stamp})
    path = ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def entry_gate(source: str, *, export_import: bool) -> GateDecision:
    if is_active_or_grace():
        return GateDecision(True, "pro")
    if not export_import:
        return GateDecision(False, "pro_required")
    try:
        if first_import_allowed(source):
            return GateDecision(True, "first_import_free")
    except LedgerUnreadable:
        return GateDecision(False, "could_not_check")
    return GateDecision(False, "pro_required")
