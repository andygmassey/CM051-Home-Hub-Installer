"""The Scout substrate (E3): consent-gated candidate miners for the Front Page.

Standing interests say what the user is into; live signals say what needs them
now. **Scouts** are the third engine: they *generate* new proactive cards by
ranking fresh candidate items against the interest profile (CM059 spec
section 5, Phase E3+). The first scout (``scout_newsletters.py``) reads data
the operator already ingested - no outbound network at all; later scouts (E4:
film/TV, music) will fetch externally and inherit this same consent machinery.

Consent posture (spec section 4, load-bearing):

  * A scout is **dormant until its consent flag exists** in
    ``~/.ostler/editor/scout_consent.json`` - and "exists" means the value is
    literally ``true`` (or ``{"granted": true}``). Missing file, malformed
    JSON, ``"yes"``, ``1``, ``null`` - all fail closed to dormant. A dormant
    scout is never *called*, not merely filtered afterwards, so a buggy scout
    cannot run (or fetch, in E4) without consent (A-E3-4 / A-E4-2).
  * With every consent absent the feed is byte-identical to the pre-scout
    (E2) output on the same inputs - proven by test.

Isolation: one scout blowing up must never break the feed or its sibling
scouts. Each scout runs inside its own try/except; a failure is one stderr
line and an empty contribution, mirroring the E2 signal-adapter posture.

Shape on disk (``scout_consent.json``)::

    { "newsletters": true }

Pure + I/O split as everywhere else in the compiler: ``run_scouts`` is pure
given (scouts, profile, now, ledger, consent); ``load_consent`` does the
tolerant file read.
"""

from __future__ import annotations

import json
import os
import sys

CONSENT_NAME = "scout_consent.json"
DEFAULT_EDITOR_DIR = "~/.ostler/editor"


def consent_path() -> str:
    override = os.environ.get("OSTLER_EDITOR_SCOUT_CONSENT")
    if override:
        return os.path.expanduser(override)
    editor_dir = os.path.expanduser(
        os.environ.get("OSTLER_EDITOR_DIR", DEFAULT_EDITOR_DIR))
    return os.path.join(editor_dir, CONSENT_NAME)


def load_consent(path: str | None = None) -> dict:
    """Tolerant consent read. Missing / unreadable / malformed / not an object
    all degrade to ``{}`` - i.e. no consent for anything. Never raises."""
    try:
        with open(path or consent_path(), encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:  # noqa: BLE001 - any read failure is "no consent"
        return {}
    return data if isinstance(data, dict) else {}


def has_consent(consent: dict | None, key: str) -> bool:
    """Fail-closed consent check: ``True`` ONLY for a literal ``true`` value
    (or ``{"granted": true}``). Every other shape - truthy strings, numbers,
    missing key, malformed entry - denies."""
    if not isinstance(consent, dict):
        return False
    value = consent.get(key)
    if value is True:
        return True
    if isinstance(value, dict) and value.get("granted") is True:
        return True
    return False


class Scout:
    """Interface every scout implements (spec section 5, E3).

    Attributes:
        domain       - the card domain this scout feeds (e.g. "News").
        consent_key  - the per-domain flag in scout_consent.json that must be
                       literally true before this scout is ever called.

    Methods:
        candidates(profile, since, now) - the raw candidate items this scout
            mined for the window (already deduplicated). Exposed separately
            from card-building so tests (and later the exploration slot) can
            inspect the pool.
        build_cards(profile, now, ledger) - the finished card dicts (possibly
            empty - honest-empty beats a padded card). Cards flow through the
            central feed assembly (ledger age, TTL, privacy gate, Pro gate,
            caps) exactly like every other card family.
    """

    domain: str = ""
    consent_key: str = ""

    def candidates(self, profile: dict, since, now) -> list:  # pragma: no cover
        raise NotImplementedError

    def build_cards(self, profile: dict, now, ledger=None) -> list:  # pragma: no cover
        raise NotImplementedError


def write_consent(key: str, granted: bool, path: str | None = None) -> str:
    """Persist one consent decision - the write half of the E4 consent card.

    Merges into the existing file (tolerant read), stores a **literal**
    ``True``/``False`` (the only shapes ``has_consent`` ever grants on), and
    writes atomically with 0600 permissions. The key must be a plain
    ``[a-z0-9_]+`` slug - anything else raises ``ValueError`` so a malformed
    action string can never write a stray entry."""
    import re as _re
    if not _re.fullmatch(r"[a-z0-9_]+", key or ""):
        raise ValueError(f"invalid consent key: {key!r}")
    target = path or consent_path()
    consent = load_consent(target)
    consent[key] = bool(granted)
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    tmp = f"{target}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(consent, fh, indent=2, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, target)
    try:
        os.chmod(target, 0o600)
    except OSError:
        pass
    return target


def default_scouts() -> list[Scout]:
    """The registered scouts. E3 ships newsletters; E4 adds the Film & TV
    external scout **with no transport** (``fetcher=None``): dormant without
    consent like everything else, and even with consent it can neither fetch
    nor offer a consent card until the live wiring ships (the deferred step
    in docs/DESIGN_NOTE_e4_scout_framework.md)."""
    from compiler.scout_film import FilmTVScout
    from compiler.scout_newsletters import NewslettersScout
    return [NewslettersScout(), FilmTVScout(fetcher=None)]


def run_scouts(scouts: list[Scout], profile: dict, now, ledger=None,
               consent: dict | None = None) -> list:
    """Run every *consented* scout, isolated, and pool their cards.

    A scout whose consent flag is not literally true is never called at all
    (dormant, spec section 4). A scout that raises contributes nothing and
    logs one stderr line - the feed and the other scouts are unaffected."""
    cards: list = []
    for scout in scouts or []:
        if not has_consent(consent, scout.consent_key):
            continue  # dormant: not called, not just filtered
        try:
            cards.extend(scout.build_cards(profile, now, ledger=ledger) or [])
        except Exception as exc:  # noqa: BLE001 - one scout never breaks the feed
            print(f"front-page: scout '{scout.consent_key}' failed "
                  f"({type(exc).__name__}: {exc})", file=sys.stderr)
    return cards
