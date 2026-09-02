"""Report the browser-extension bearer token to Doctor, for the customer.

WHY THIS MODULE EXISTS

The browser extension (CM020, Safari + Chrome) has always posted captured
browsing to the Hub. Three defects stood between that and a customer being able
to use it, and the first two are fixed elsewhere:

  * the Doctor proxy rejected the extension's bearer outright, because the only
    accepted credential was the PWG service token (B3a);
  * nothing minted or delivered an extension token at all, so there was no value
    for the extension to send (B3b: install.sh now mints
    ``${OSTLER_DIR}/secrets/extension_token`` and passes it to the Doctor
    LaunchAgent as ``OSTLER_EXTENSION_TOKEN``).

This is the third. A token that exists in a 0600 file and in a daemon's
environment is not a token a customer can put into an extension popup. Without a
surface that shows it, browsing capture ships dark: every part works and nobody
can turn it on.

WHY THE ENVIRONMENT IS THE AUTHORITY AND THE FILE IS NOT

``proxy.py`` authenticates the extension against ``os.environ`` and nothing
else. Doctor and the proxy are the same process, so whatever this module reads
out of ``os.environ`` is, by construction, the exact value the extension will be
checked against. The file on disk is the installer's record of what it minted;
it is the same value in the ordinary case and it is NOT authoritative.

That distinction is the whole point of the taxonomy below. If the installer
rewrote the file after the LaunchAgent was loaded, the file holds the new token
and the running process still checks the old one. Showing the customer the file
value there would hand them a string that is guaranteed to fail, and the failure
would surface as a silent 401 inside a browser extension, which is close to
undiagnosable from the customer's side.

THE STATES, each a different problem with a different next action:

    ready              env token present, and the file agrees or is absent
    not_provisioned    neither: this Hub predates B3b, or the mint step failed
    daemon_not_reloaded  file has a token, the running Doctor has none
    mismatch           both present and different: the running Doctor would
                       reject the token the installer last wrote
    unreadable         the file exists and cannot be read

``whatsapp_pair.py`` established this shape (explicit ``error_kind`` rather than
a bare ``Optional``) for the pairing panel; this mirrors it rather than
inventing a second vocabulary.

NOTHING HERE LOGS THE TOKEN. It is credential-equivalent for the lifetime of the
install, and this logger's output lands in ``doctor.err``, which the support
diagnostics bundle tails.
"""

from __future__ import annotations

import hmac
import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

log = logging.getLogger(__name__)


# Mirrors install.sh: SECRETS_DIR="${OSTLER_DIR}/secrets", and the extension
# token file inside it. Named here as two parts so a future move of the secrets
# directory shows up as one edit rather than a string search.
_SECRETS_DIRNAME = "secrets"
_TOKEN_FILENAME = "extension_token"

# The single path the proxy will accept an extension bearer on. Kept in step
# with ``_EXTENSION_ONLY_PATH`` in proxy.py; the page shows it to the customer
# so a support call can compare what the extension is configured with against
# what the Hub will actually answer.
INGEST_PATH = "/api/safari/ingest"

# The environment variable the Doctor LaunchAgent carries and the proxy reads.
_ENV_VAR = "OSTLER_EXTENSION_TOKEN"


@dataclass
class ExtensionTokenStatus:
    """Structured result a Doctor route can JSON-serialise directly."""

    available: bool
    token: Optional[str]
    ingest_path: str
    error: Optional[str]
    error_kind: Optional[str]

    def to_dict(self) -> dict:
        return {
            "available": self.available,
            "token": self.token,
            "ingest_path": self.ingest_path,
            "error": self.error,
            "error_kind": self.error_kind,
        }


def token_path() -> Path:
    """Resolve the installer's extension-token file.

    Honours ``OSTLER_HOME`` then ``OSTLER_DIR`` (the installer sets
    ``OSTLER_DIR=~/.ostler``), falling back to ``~/.ostler``. Mirrors
    ``whatsapp_pair.state_path`` so the two cannot drift onto different roots.
    """
    base = os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR")
    root = Path(base) if base else Path.home() / ".ostler"
    return root / _SECRETS_DIRNAME / _TOKEN_FILENAME


def _unavailable(kind: str, message: str) -> ExtensionTokenStatus:
    return ExtensionTokenStatus(
        available=False,
        token=None,
        ingest_path=INGEST_PATH,
        error=message,
        error_kind=kind,
    )


def _env_token() -> str:
    """The value the proxy will actually compare against, in this process."""
    return os.environ.get(_ENV_VAR, "").strip()


def _file_token(path: Path) -> tuple[Optional[str], Optional[str]]:
    """Read the installer's record. Returns ``(token, error_kind)``.

    ``(None, None)`` means the file is genuinely absent, which is not an error
    on its own. ``(None, "unreadable")`` means we could not look, which is a
    different answer and must never be collapsed into the first.
    """
    try:
        if not path.is_file():
            return (None, None)
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        # Deliberately does NOT log the path's contents.
        log.warning("extension token file unreadable at %s: %s", path, exc)
        return (None, "unreadable")
    value = raw.strip()
    if not value:
        return (None, "unreadable")
    return (value, None)


def fetch_token_status(path: Optional[Path] = None) -> ExtensionTokenStatus:
    """Report whether browsing capture can be turned on, and with what value.

    Never raises. This runs on a dashboard route, where an exception would blank
    the card and tell the customer less than any of the named states below.
    """
    target = path if path is not None else token_path()
    env_value = _env_token()
    file_value, file_error = _file_token(target)

    if not env_value:
        if file_error == "unreadable":
            return _unavailable(
                "unreadable",
                "Ostler could not read its browser-extension key.",
            )
        if file_value:
            # The installer minted one and this Doctor was started before it
            # existed. The value on disk is real and will work, but not until
            # Doctor is restarted with it in the environment, so do NOT show it.
            return _unavailable(
                "daemon_not_reloaded",
                "Ostler has a browser-extension key but has not picked it up "
                "yet. Close and reopen Ostler to load it.",
            )
        return _unavailable(
            "not_provisioned",
            "This Hub has no browser-extension key. Re-run the Ostler "
            "installer to create one.",
        )

    if file_error == "unreadable":
        # The running process has a usable token; the record on disk is what we
        # cannot read. Report the token, and say so, rather than block on a
        # secondary surface.
        return ExtensionTokenStatus(
            available=True,
            token=env_value,
            ingest_path=INGEST_PATH,
            error="Ostler could not read its own copy of this key on disk. "
            "The key below is the one Ostler is using now.",
            error_kind="unreadable_backing_file",
        )

    if file_value and not hmac.compare_digest(file_value, env_value):
        # Showing either value would be a guess about which one wins, and the
        # loser fails as a silent 401 inside a browser extension. Name it.
        return _unavailable(
            "mismatch",
            "Ostler's browser-extension key does not match the one saved on "
            "this Mac. Close and reopen Ostler, and re-run the installer if that "
            "does not clear it.",
        )

    return ExtensionTokenStatus(
        available=True,
        token=env_value,
        ingest_path=INGEST_PATH,
        error=None,
        error_kind=None,
    )
