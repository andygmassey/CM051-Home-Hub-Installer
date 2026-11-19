"""Owner switch for public-data enrichment (R02, CB135-ENRICHMENT-SETTINGS-SWITCH).

Enrichment is ON by default with an install-time opt-out (the owner's ruling, 2026-11-18).
The owner must be able to turn it off and on later, and the choice must
survive upgrades. This module is the Doctor side of that switch.

The consent store is the same one the installer writes and the enricher reads:
``${OSTLER_DIR}/config/.env`` (``OSTLER_DIR``, else ``~/.ostler``), key
``OSTLER_CONSENT_ENRICHMENT_DECISION``, value ``"accepted"`` or ``"declined"``.
The reader is ``services/enrich/src/consent.py`` in CM019 (vendored at
``vendor/cm019_preferences``). Its rules are mirrored here exactly:

* the LAST matching line wins (``sed -n ... | tail -n 1`` in install.sh);
* one leading and one trailing double quote are stripped;
* the match is EXACT on ``accepted``: no trimming, no case folding;
* fail closed: anything else, or no file, means no outbound request;
* when the process environment also carries the variable, it must say
  ``accepted`` too, so an env value of ``declined`` refuses even if the file
  says accepted. ``effective_status`` reports that case so the panel does not
  claim a switch-on that the enricher will still refuse.

Writes touch only the one key. Every other line of config/.env is kept byte
for byte, the file is replaced atomically (temp file in the same directory,
then ``os.replace``), and it stays mode 600.
"""

from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

CONSENT_KEY = "OSTLER_CONSENT_ENRICHMENT_DECISION"
ACCEPTED = "accepted"
DECLINED = "declined"
_PREFIX = CONSENT_KEY + "="


class EnrichmentSwitchError(Exception):
    """A write could not be completed. Carries an HTTP-style status."""

    def __init__(self, detail: str, status: int = 500):
        super().__init__(detail)
        self.detail = detail
        self.status = status


def ostler_dir() -> Path:
    """Same resolution as consent.py: OSTLER_DIR, else ~/.ostler."""
    raw = os.environ.get("OSTLER_DIR")
    return Path(raw) if raw else Path.home() / ".ostler"


def env_file() -> Path:
    return ostler_dir() / "config" / ".env"


def _last_value(text: str) -> str:
    value = ""
    # split on LF only, as sed does: a CRLF line keeps its CR and never matches.
    for line in text.split("\n"):
        if line.startswith(_PREFIX):
            value = line[len(_PREFIX):]
    if value.endswith('"'):
        value = value[:-1]
    if value.startswith('"'):
        value = value[1:]
    return value


def read_file_decision() -> str:
    """The recorded answer in config/.env, or "" when absent or unreadable."""
    try:
        text = env_file().read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    return _last_value(text)


def effective_status() -> dict:
    """What the enricher will actually do, read fresh (never cached)."""
    file_value = read_file_decision()
    env_value: Optional[str] = os.environ.get(CONSENT_KEY)
    file_ok = file_value == ACCEPTED
    env_ok = env_value is None or env_value == ACCEPTED
    enabled = file_ok and env_ok
    if enabled:
        reason = "accepted"
    elif not file_ok:
        reason = "declined" if file_value == DECLINED else "no_recorded_answer"
    else:
        reason = "env_override"
    return {
        "enabled": enabled,
        "recorded": file_value,
        "reason": reason,
        "env_override": env_value is not None and not env_ok,
    }


def set_enabled(enabled: bool) -> dict:
    """Record the owner's choice in config/.env and in the consent record.

    Removes every existing ``OSTLER_CONSENT_ENRICHMENT_DECISION`` line and
    appends one new line at the end, so the owner's latest choice is the last
    line and the one an upgrade reads. Every other line is kept as it was.
    """
    if not isinstance(enabled, bool):
        raise EnrichmentSwitchError("enabled must be true or false", 400)
    value = ACCEPTED if enabled else DECLINED
    path = env_file()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            original = path.read_bytes().decode("utf-8")
        except FileNotFoundError:
            original = ""
        kept = [ln for ln in original.split("\n") if not ln.startswith(_PREFIX)]
        # drop the trailing empty element that a final newline leaves behind
        if kept and kept[-1] == "":
            kept.pop()
        kept.append(f'{_PREFIX}"{value}"')
        body = "\n".join(kept) + "\n"
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".env.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(body)
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except OSError as exc:
        raise EnrichmentSwitchError(f"could not record the choice: {exc.strerror or exc}", 500)
    _write_consent_record(value)
    return status()


def _write_consent_record(value: str) -> None:
    """Best effort: the installer's posture record, kept in step with config/.env."""
    record = ostler_dir() / "posture" / "enrichment-decision.json"
    try:
        record.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "tickbox": "background_enrichment",
            "decision": "accepted" if value == ACCEPTED else "declined",
            "recorded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "source": "doctor_switch",
        }
        fd, tmp = tempfile.mkstemp(dir=str(record.parent), prefix=".decision.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(payload) + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, record)
    except OSError:
        pass


def agent_installed() -> bool:
    """Whether the recurring enrich job exists. The installer installs it only on a yes."""
    return (Path.home() / "Library" / "LaunchAgents" / "com.ostler.enrich.plist").is_file()


def status() -> dict:
    eff = effective_status()
    eff["agent_installed"] = agent_installed()
    if eff["enabled"] and not eff["agent_installed"]:
        eff["note"] = "the recurring enrich job is not installed on this Mac; re-run the installer to install it"
    return eff
