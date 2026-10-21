"""Owner consent gate for outbound public lookups.

External enrichment (Wikidata, MusicBrainz, TMDB, OpenLibrary, ...) sends the
owner's topic labels, titles and names to third-party hosts. It is allowed
ONLY when the owner accepted enrichment at install, which the installer
records as OSTLER_CONSENT_ENRICHMENT_DECISION=accepted.

Fail closed: declined, absent, empty or unrecognised all mean NO outbound
request. The value is read on every call, never cached at import, so a
decision changed after the process started is honoured.

Sources, in order: the environment variable (if set and non-empty it wins,
whatever it says), then ${OSTLER_DIR}/config/.env, which is where the
installer records the answer. The recurring enrich agent never exports the
variable, so the file is the real source there. The file is read exactly as
the shell gates in install.sh do: last matching line, one trailing and one
leading double quote stripped, then an EXACT match on "accepted" (no
trimming, no case folding).
"""

import os
from pathlib import Path

import click

CONSENT_ENV = "OSTLER_CONSENT_ENRICHMENT_DECISION"
CONSENT_ACCEPTED = "accepted"


def _env_file() -> Path:
    ostler_dir = os.environ.get("OSTLER_DIR") or str(Path.home() / ".ostler")
    return Path(ostler_dir) / "config" / ".env"


def _decision_from_file() -> str:
    """Mirror of: sed -n 's/^KEY=//p' | tail -n 1, then strip one pair of quotes."""
    try:
        text = _env_file().read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    prefix = CONSENT_ENV + "="
    value = ""
    for line in text.splitlines():
        if line.startswith(prefix):
            value = line[len(prefix):]
    if value.endswith('"'):
        value = value[:-1]
    if value.startswith('"'):
        value = value[1:]
    return value


def public_lookup_allowed() -> bool:
    """True only when the owner accepted enrichment (read fresh, fail closed)."""
    decision = os.environ.get(CONSENT_ENV) or _decision_from_file()
    return decision == CONSENT_ACCEPTED


class ConsentRequired(click.ClickException):
    """Raised by a command that has no local-only mode when consent is missing."""


def require_public_lookup_consent(command: str) -> None:
    """Abort `command` unless the owner accepted enrichment at install."""
    if not public_lookup_allowed():
        raise ConsentRequired(
            f"'{command}' sends data to public lookup services and the owner "
            f"has not accepted enrichment ({CONSENT_ENV} is not 'accepted'). "
            "No request was made."
        )
