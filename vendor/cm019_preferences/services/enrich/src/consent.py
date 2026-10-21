"""Owner consent gate for outbound public lookups.

External enrichment (Wikidata, MusicBrainz, TMDB, OpenLibrary, ...) sends the
owner's topic labels, titles and names to third-party hosts. It is allowed
ONLY when the owner accepted enrichment at install, which the installer
records as OSTLER_CONSENT_ENRICHMENT_DECISION=accepted.

Fail closed: declined, absent, empty or unrecognised all mean NO outbound
request. The value is read on every call, never cached at import, so a
decision changed after the process started is honoured.

Both sources must agree: ${OSTLER_DIR}/config/.env, which is where the
installer records the answer, must say accepted, AND the environment
variable, when it is set at all, must also say accepted. Either one saying
anything else refuses. The recurring enrich agent never exports the
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
        text = _env_file().read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    prefix = CONSENT_ENV + "="
    value = ""
    # split on LF only, as sed does: a CRLF line keeps its CR and never matches.
    for line in text.split("\n"):
        if line.startswith(prefix):
            value = line[len(prefix):]
    if value.endswith('"'):
        value = value[:-1]
    if value.startswith('"'):
        value = value[1:]
    return value


def public_lookup_allowed() -> bool:
    """True only when the owner accepted enrichment (read fresh, fail closed)."""
    env = os.environ.get(CONSENT_ENV)
    if env is not None and env != CONSENT_ACCEPTED:
        return False
    return _decision_from_file() == CONSENT_ACCEPTED


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
