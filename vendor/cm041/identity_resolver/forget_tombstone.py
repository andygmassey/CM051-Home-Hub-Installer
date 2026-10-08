"""Forget tombstone: a person erased by ``POST /api/v1/people/<slug>/forget``
must STAY erased when a people syncer next runs.

THE DEFECT THIS CLOSES. Forget deletes every triple that touches the person.
That leaves nothing for a syncer to find, so the next sync that still holds
the person in its source (an iCloud card, an iMessage handle, a calendar
attendee, a LinkedIn export row) reads "nobody holds this identifier" and
mints the person again. CM041 #200 recorded it as "a person erased by forget
can be recreated by the next contact sync (no tombstone)". The erasure the
customer asked for would last until the next tick.

THE TOMBSTONE. A small JSON file beside the other Hub state
(``$OSTLER_STATE_DIR`` or ``~/.ostler/state``, ``forgotten_people.json``,
override ``OSTLER_FORGET_TOMBSTONE_FILE``). Every person-creating writer asks
:func:`is_forgotten` before it mints and skips when the answer is yes.

WHAT IT STORES, AND WHY NOT MORE. It exists because a person asked not to be
kept, so it must not become a second copy of them. It holds NO name, phone,
email or any other identifier in clear: only salted SHA-256 digests of the
normalised identifier values, a digest of the display name, and the erased
node's URI (an opaque ``person_<hex>`` or a uuid5). The salt is per-install,
random, in the same 0600 file. HONEST LIMIT: a phone number or an email is
low-entropy, so someone who holds this file AND a candidate identifier can
test it. The file is 0600 under the owner's own home, next to the secrets
the owner already holds, and the digest is the price of making the tombstone
work at all.

MATCHING.
  * any identifier digest in common  -> forgotten;
  * the erased URI                   -> forgotten (ostler_fda mints
    ``uuid5(identifier)`` URIs, so the URI alone catches its re-mint);
  * display-name digest, ONLY when the incoming record carries NO identifier
    at all (a Facebook friend or an Instagram connection is name-only). A
    different person who shares the name and arrives with their own
    identifiers is NOT blocked. KNOWN COST: a name-only record for a
    different human with the same name is skipped too. That is the safe
    direction for an erasure request.

FAIL CLOSED. If the file exists but cannot be read or parsed,
:func:`is_forgotten` answers True and logs an error: a writer that cannot see
the tombstones must not be the one that resurrects somebody.

Stdlib only, so every package that needs it (and CM051's ``ostler_fda`` copy,
which must stay byte-identical) can import it with no new dependency.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import secrets
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional

logger = logging.getLogger(__name__)

FILE_ENV = "OSTLER_FORGET_TOMBSTONE_FILE"
#: ``MatchResult.match_type`` a resolver returns for a tombstoned identity.
MATCH_TYPE = "forgotten"
_FILENAME = "forgotten_people.json"
_PHONEISH = re.compile(r"^[+\d][\d\s().\-]{5,}$")


class ForgottenPersonError(RuntimeError):
    """Raised by a hard backstop when something tries to mint a forgotten person."""


class TombstoneUnreadable(RuntimeError):
    """The tombstone file exists but could not be read or parsed."""


def tombstone_path() -> Path:
    override = (os.environ.get(FILE_ENV) or "").strip()
    if override:
        return Path(override)
    state = os.environ.get("OSTLER_STATE_DIR") or os.path.expanduser("~/.ostler/state")
    return Path(state) / _FILENAME


def normalise_value(value: str) -> str:
    """One canonical spelling per identifier value, kind-agnostic.

    Phone-looking values collapse to ``+digits`` (or bare digits when no
    leading ``+``), everything else (email, LID, iCloud UID, URL, handle) is
    stripped and lowercased.
    """
    v = (value or "").strip()
    if not v:
        return ""
    if _PHONEISH.match(v):
        digits = re.sub(r"\D", "", v)
        return ("+" if v.startswith("+") else "") + digits
    return v.lower()


def normalise_name(name: str) -> str:
    return " ".join((name or "").lower().split())


def _digest(salt: str, text: str) -> str:
    return hashlib.sha256(f"{salt}\x00{text}".encode("utf-8")).hexdigest()


def _load(path: Path) -> dict:
    """Parsed file, or an empty skeleton when it does not exist.

    Raises :class:`TombstoneUnreadable` when it exists and is unusable.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {"v": 1, "salt": "", "entries": []}
    except OSError as exc:
        raise TombstoneUnreadable(f"{path}: {exc}") from exc
    try:
        data = json.loads(raw)
        if (
            not isinstance(data, dict)
            or not isinstance(data.get("entries"), list)
            or not isinstance(data.get("salt"), str)
        ):
            raise ValueError("unexpected shape")
        return data
    except ValueError as exc:
        raise TombstoneUnreadable(f"{path}: {exc}") from exc


def _write(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tombstone-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def record(
    person_uri: str,
    identifier_values: Iterable[str],
    display_name: Optional[str] = None,
    path: Optional[Path] = None,
) -> bool:
    """Write the tombstone for an erased person. Returns True when it is durable.

    Never raises: forget must still erase when the tombstone cannot be
    written, and report that honestly (the caller surfaces the False).
    """
    path = path or tombstone_path()
    try:
        data = _load(path)
    except TombstoneUnreadable:
        logger.error("forget tombstone unreadable; starting a new one", exc_info=True)
        data = {"v": 1, "salt": "", "entries": []}
    try:
        if not data["salt"]:
            data["salt"] = secrets.token_hex(16)
        salt = data["salt"]
        ids = sorted(
            {
                _digest(salt, n)
                for n in (normalise_value(v) for v in identifier_values)
                if n
            }
        )
        name = normalise_name(display_name or "")
        data["entries"].append(
            {
                "forgotten_at": datetime.now(timezone.utc).isoformat(),
                "uri": person_uri,
                "ids": ids,
                "name": _digest(salt, "name:" + name) if name else None,
            }
        )
        _write(path, data)
        return True
    except OSError:
        logger.error("forget tombstone could not be written", exc_info=True)
        return False


def is_forgotten(
    values: Iterable[str] = (),
    uri: Optional[str] = None,
    name: Optional[str] = None,
    path: Optional[Path] = None,
) -> bool:
    """Has the person these identifiers / this URI / this name-only record
    describes been forgotten?  Fails CLOSED on an unreadable file."""
    path = path or tombstone_path()
    try:
        data = _load(path)
    except TombstoneUnreadable:
        logger.error(
            "forget tombstone unreadable; refusing to create people until it is "
            "repaired or removed (%s)", path, exc_info=True,
        )
        return True
    entries = data["entries"]
    if not entries:
        return False
    salt = data["salt"]
    norm = [n for n in (normalise_value(v) for v in values) if n]
    digests = {_digest(salt, n) for n in norm}
    for e in entries:
        if uri and e.get("uri") == uri:
            return True
        if digests and digests.intersection(e.get("ids") or ()):
            return True
    if not norm and name:
        nm = normalise_name(name)
        if nm:
            nd = _digest(salt, "name:" + nm)
            if any(e.get("name") == nd for e in entries):
                return True
    return False


def identity_values(identity) -> list:
    """Every identifier value a ``PersonIdentity`` (duck-typed) carries."""
    vals = []
    for attr in ("phones", "emails", "whatsapp_lids"):
        vals.extend(getattr(identity, attr, None) or [])
    for attr in ("icloud_uid", "linkedin_url"):
        v = getattr(identity, attr, None)
        if v:
            vals.append(v)
    return vals


def guard(values: Iterable[str] = (), name: Optional[str] = None,
          uri: Optional[str] = None, path: Optional[Path] = None) -> None:
    """Hard backstop for a create function: raise rather than mint a
    forgotten person. Callers should have branched on the resolver's
    ``"forgotten"`` match type first; this is for the one that did not."""
    if is_forgotten(values=values, uri=uri, name=name, path=path):
        raise ForgottenPersonError("refusing to create a person who was forgotten")


def lift(values: Iterable[str], path: Optional[Path] = None) -> int:
    """Remove every tombstone that shares an identifier with ``values``.

    For the owner who forgot someone and later, deliberately, adds them back.
    Returns how many entries were removed. There is no UI for this yet (see
    the Lane 18 report); it is the supported way to undo a tombstone.
    """
    path = path or tombstone_path()
    data = _load(path)
    digests = {_digest(data["salt"], n) for n in (normalise_value(v) for v in values) if n}
    keep = [e for e in data["entries"] if not digests.intersection(e.get("ids") or ())]
    removed = len(data["entries"]) - len(keep)
    if removed:
        data["entries"] = keep
        _write(path, data)
    return removed
