"""The external-scout framework (E4): consent-per-query outbound machinery.

External scouts are the estate's ONE external-call class (CM059 spec section 4
"Outbound"): they may reach a source beyond the local machine - film release
listings, music releases - to rank fresh candidates against the interest
profile. Everything else in the Editor is loopback + local files, and this
module is built so that posture survives contact with a buggy scout:

  * **No transport by default.** An ``ExternalScout`` fetches through an
    *injected* fetcher callable. This build ships NO real HTTP client at all -
    the registered scouts have ``fetcher=None`` and a transport-less scout
    never fetches (and never emits a consent offer: we do not ask permission
    for labour we cannot deliver). The live wiring is a deliberate, separate
    step (see docs/DESIGN_NOTE_e4_scout_framework.md).
  * **Consent-per-query, fail-closed.** Beyond E3's dormant-until-consented
    gate (a scout whose flag is not literally ``true`` is never *called*),
    every individual query re-reads ``scout_consent.json`` immediately before
    dispatch. Revoking consent mid-run halts the run; no consent means zero
    fetch attempts (A-E4-2).
  * **Outbound hygiene (A-E4-3).** Every query is serialised and gated by a
    forbidden-pattern scan (emails, phone-length digit runs, home paths, IPs,
    URL userinfo, person/org name shapes) before dispatch; a dirty query is
    refused, never sent.
    Query builders draw on interest *subjects* only, and only those tagged
    privacy L0/L1 - an L2/L3-tagged, untagged, or unrecognisably-tagged
    profile entry never reaches a query at all (missing tag = L3,
    fail-closed; audit 2026-07-13).
  * **Free-API-only posture.** A scout's ``ExternalSource`` must declare
    ``free_tier=True``; anything else is refused at dispatch (the sport-scout
    budget line is an open product question, spec section 6 Q8).
  * **Frequency + budget.** Per-topic frequency (``daily``/``weekly``,
    overridable per consent entry: ``{"granted": true, "frequency":
    "weekly"}``) throttles how often a scout may *fetch*; a per-run and a
    per-day query budget cap how much it may ask when it does. Between
    fetches, cards rebuild from the local result cache - the feed stays
    fresh-looking without re-fetching. Ledger + cache live under
    ``~/.ostler/editor/`` like every other Editor artefact.

The pieces compose into one dispatch gate, checked in order for every run and
every query::

    transport wired -> free-tier source -> fetch due (frequency) ->
      per-query: consent (re-read) -> hygiene -> budget -> fetcher(query)

Any gate failing degrades to "no fetch" (cache or nothing) - never an error,
never a partial leak. All I/O here is tolerant: a corrupt ledger or cache is
an empty one.
"""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone

from compiler import scouts as sc
from compiler.interest_profile import (names_person_or_org,
                                       subject_names_known_contact)
from compiler.scouts import Scout

# ---------------------------------------------------------------------------
# Tunables (constants, not env knobs - adjust only with a failing fixture)
# ---------------------------------------------------------------------------

MAX_QUERIES_PER_RUN = 8    # one tick may not fan out beyond this
MAX_QUERIES_PER_DAY = 24   # and a day's ticks share this ceiling (per scout)

FREQUENCY_DAYS = {"daily": 1.0, "weekly": 7.0}
DEFAULT_FREQUENCY = "daily"   # the spec's shared daily fetch window
CACHE_TTL_DAYS = 7.0          # stale cached results stop making cards

FETCH_LEDGER_NAME = "scout_fetch_ledger.json"
CACHE_NAME = "scout_cache.json"

# User-facing copy, centralised as the locale seam (same pattern as
# scout_newsletters._STRINGS). British English.
_STRINGS = {
    "consent_title": "Keep you posted on {domain_lc}?",
    "consent_body": ("Ostler can check {source_label} against your taste. "
                     "This sends anonymous topic lookups - nothing about "
                     "you, ever. Opt in per topic; change your mind any "
                     "time."),
    "consent_action": "Yes, keep me posted",
}


# ---------------------------------------------------------------------------
# Outbound hygiene (A-E4-3): what may never appear in a query
# ---------------------------------------------------------------------------

_FORBIDDEN_PATTERNS = [
    re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),  # email
    re.compile(r"(?<!\d)\+?\d[\d\s().-]{6,}\d(?!\d)"),  # phone-length digit run
    re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+"),     # home paths
    re.compile(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)"),  # IPv4
    re.compile(r"[a-z][a-z0-9+.-]*://[^/\s]*@", re.I),  # URL userinfo creds
]


def query_is_clean(text: str, contact_lexicon: frozenset = frozenset()) -> bool:
    """True only when the serialised query carries none of the forbidden
    operator-identifier shapes - nor a person/org name shape (org suffix,
    "at <Employer>", possessive, honorific: audit P3 - the level tag alone
    cannot prove free text is anonymous, so a mis-tagged L1 row that names
    someone is still refused here). This is the same class of gate as the
    PII regex gate on the wiki side: cheap, dumb, and it fails the safe
    way. Proper-noun RUNS are deliberately NOT screened here - that is the
    producer's job (interest_profile.classify_privacy), where an operator's
    explicit L0/L1 correction on a title-case work can override.

    ``contact_lexicon`` (interest_profile.build_contact_lexicon) additionally
    refuses any query containing a KNOWN contact's full name, independent of
    capitalisation - the residual shape the heuristics miss. Empty (the
    default) means the heuristic gate alone, exactly the prior posture. The
    set is INJECTED by whoever wires the scout (like the fetcher itself, see
    ExternalScout) - never fetched here, so the gate stays pure, offline
    and fast."""
    for pat in _FORBIDDEN_PATTERNS:
        if pat.search(text or ""):
            return False
    if names_person_or_org(text):
        return False
    if subject_names_known_contact(text, contact_lexicon):
        return False
    return True


# Privacy levels on profile rows are FAIL-CLOSED on the egress side (audit
# 2026-07-13, same class as signals.py Finding 2 but worse: this path leaves
# the machine). Only a row that PROVES it is safe - an explicit L0 or L1 tag -
# may feed an external query; a missing tag resolves to L3 (an untagged row
# cannot prove it is safe to send anywhere) and an explicit-but-unrecognised
# value is ALSO L3 (a typo must never egress). Producer contract: the profile
# emitter must stamp ``privacy`` on a row for it to be externally queryable.
_KNOWN_LEVELS = {"L0", "L1", "L2", "L3"}
_MOST_RESTRICTIVE = "L3"
QUERYABLE_LEVELS = {"L0", "L1"}


def _interest_privacy(it: dict) -> str:
    """Resolved privacy level of one profile row, fail-closed: a normalised
    known level, else L3 (whether the tag is absent or unrecognised)."""
    raw = it.get("privacy")
    if raw is None:
        return _MOST_RESTRICTIVE
    level = str(raw).strip().upper()
    return level if level in _KNOWN_LEVELS else _MOST_RESTRICTIVE


def l1_interests(profile: dict, domain: str | None = None) -> list[dict]:
    """The only profile rows a query builder may draw on: liked interests
    whose declared privacy level is L0 or L1. Fail-closed on the level: an
    untagged, unrecognised, L2 or L3 row never reaches an outbound query
    (see the producer contract above)."""
    out: list[dict] = []
    for block in (profile or {}).get("domains", []):
        if domain is not None and block.get("domain") != domain:
            continue
        for it in block.get("interests", []):
            if not isinstance(it, dict):
                continue
            if it.get("polarity") == "dislike":
                continue
            if _interest_privacy(it) not in QUERYABLE_LEVELS:
                continue
            out.append(it)
    return out


# ---------------------------------------------------------------------------
# Fetch ledger + result cache (tolerant I/O, editor-dir siblings)
# ---------------------------------------------------------------------------

def _editor_dir() -> str:
    return os.path.expanduser(
        os.environ.get("OSTLER_EDITOR_DIR", sc.DEFAULT_EDITOR_DIR))


def fetch_ledger_path() -> str:
    return os.environ.get("OSTLER_EDITOR_SCOUT_FETCH_LEDGER") or os.path.join(
        _editor_dir(), FETCH_LEDGER_NAME)


def cache_path() -> str:
    return os.environ.get("OSTLER_EDITOR_SCOUT_CACHE") or os.path.join(
        _editor_dir(), CACHE_NAME)


def _read_json_object(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:  # noqa: BLE001 - corrupt/missing degrades to empty
        return {}
    return data if isinstance(data, dict) else {}


def _write_json_atomic(path: str, data: dict) -> str:
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)  # spec section 2: 0600 files under ~/.ostler/editor
    except OSError:
        pass
    return path


def load_fetch_ledger(path: str | None = None) -> dict:
    return _read_json_object(path or fetch_ledger_path())


def save_fetch_ledger(ledger: dict, path: str | None = None) -> str:
    return _write_json_atomic(path or fetch_ledger_path(), ledger)


def load_cache(path: str | None = None) -> dict:
    return _read_json_object(path or cache_path())


def save_cache(cache: dict, path: str | None = None) -> str:
    return _write_json_atomic(path or cache_path(), cache)


# ---------------------------------------------------------------------------
# Frequency + budget (pure)
# ---------------------------------------------------------------------------

def _parse_dt(value):
    if value is None or isinstance(value, datetime):
        return value
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def consent_frequency(consent: dict | None, key: str,
                      default: str = DEFAULT_FREQUENCY) -> float:
    """Per-topic frequency control: the minimum days between fetches. The
    consent entry may carry ``{"granted": true, "frequency": "weekly"}``;
    an unknown/missing frequency falls back to the scout's default. This
    reads the *frequency* only - granting is has_consent's job."""
    entry = (consent or {}).get(key)
    freq = default
    if isinstance(entry, dict) and isinstance(entry.get("frequency"), str):
        freq = entry["frequency"]
    return FREQUENCY_DAYS.get(freq, FREQUENCY_DAYS.get(default, 1.0))


def fetch_due(entry: dict | None, interval_days: float, now: datetime) -> bool:
    """True when the scout's last fetch is older than its interval (or it has
    never fetched). A malformed timestamp counts as never-fetched - the
    budget caps still bound the damage of a corrupt ledger."""
    last = _parse_dt((entry or {}).get("last_fetch_utc"))
    if last is None:
        return True
    return (now - last).total_seconds() >= interval_days * 86400.0


def _day_key(now: datetime) -> str:
    return now.strftime("%Y-%m-%d")


def queries_today(entry: dict | None, now: datetime) -> int:
    counts = (entry or {}).get("queries")
    if not isinstance(counts, dict):
        return 0
    try:
        return int(counts.get(_day_key(now)) or 0)
    except (TypeError, ValueError):
        return 0


# ---------------------------------------------------------------------------
# The external source descriptor + the scout base
# ---------------------------------------------------------------------------

class ExternalSource:
    """What a scout talks to. ``free_tier`` is load-bearing: the invariant is
    free-API-only, and dispatch refuses a source that does not declare it.
    ``label`` is the honest human phrase the consent card uses."""

    def __init__(self, name: str, label: str, free_tier: bool = False):
        self.name = name
        self.label = label
        self.free_tier = bool(free_tier)


class ExternalScout(Scout):
    """Base for every scout that reaches beyond the machine.

    Subclasses supply ``queries(profile, now)`` (built ONLY from
    ``l1_interests`` subjects) and ``cards_from(results, profile, now,
    ledger)``. The base owns the entire outbound path - a subclass cannot
    fetch except through ``_dispatch``'s gates, because the only transport
    is the injected ``self._fetcher`` and only ``_dispatch`` calls it.

    ``fetcher`` is a callable ``(query: dict) -> result`` - in this build
    always a test fixture / stub; the real HTTP transport is the deferred
    live step. ``fetcher=None`` (the shipped default) = no fetch, ever.

    ``contact_lexicon`` rides the same injection seam: the live wiring step
    that supplies a real fetcher must also supply the graph-contact lexicon
    (interest_profile.build_contact_lexicon(fetch_contact_names()) - the
    producer compile already builds one per run), so the hygiene gate can
    refuse a query naming a known contact even when a producer bug mis-tags
    the row L1. ``None``/empty (the shipped default) = the heuristic gate
    alone, never worse than before, and dispatch stays offline: the lexicon
    is refreshed by the injector on its cadence, never fetched mid-run.
    """

    source: ExternalSource | None = None
    default_frequency: str = DEFAULT_FREQUENCY

    def __init__(self, fetcher=None, contact_lexicon=None):
        self._fetcher = fetcher
        self._contact_lexicon = frozenset(contact_lexicon or ())

    # -- subclass surface --------------------------------------------------
    def queries(self, profile: dict, now: datetime) -> list[dict]:  # pragma: no cover
        raise NotImplementedError

    def cards_from(self, results: list, profile: dict, now: datetime,
                   ledger=None) -> list:  # pragma: no cover
        raise NotImplementedError

    def candidates(self, profile: dict, since, now) -> list:
        """The Scout-interface candidate view: the cached results pool."""
        entry = load_cache().get(self.consent_key) or {}
        results = entry.get("results")
        return results if isinstance(results, list) else []

    # -- the outbound path (framework-owned) --------------------------------
    def wired(self) -> bool:
        return self._fetcher is not None

    def build_cards(self, profile: dict, now: datetime, ledger=None) -> list:
        """Fetch if every gate allows it, else fall back to cached results;
        then build cards. Called only when the E3 dormancy gate already saw
        literal-true consent (scouts.run_scouts) - but nothing here trusts
        that: the per-query gate re-reads consent anyway."""
        results = self._fetch_or_cache(profile, now)
        if not results:
            return []
        return self.cards_from(results, profile, now, ledger) or []

    def _fetch_or_cache(self, profile: dict, now: datetime) -> list:
        cache = load_cache()
        cached = cache.get(self.consent_key) or {}

        if not self.wired():
            # No transport in this build: cards may still rebuild from a
            # (test-seeded) cache, but no fetch can ever happen.
            return self._fresh_cached(cached, now)

        if self.source is None or not self.source.free_tier:
            print(f"front-page: scout '{self.consent_key}' refused - source "
                  "does not declare the free-tier posture", file=sys.stderr)
            return self._fresh_cached(cached, now)

        consent = sc.load_consent()
        interval = consent_frequency(consent, self.consent_key,
                                     self.default_frequency)
        led_path = fetch_ledger_path()
        led = load_fetch_ledger(led_path)
        entry = led.get(self.consent_key)
        if not fetch_due(entry, interval, now):
            return self._fresh_cached(cached, now)

        results = self._dispatch(self.queries(profile, now) or [], now,
                                 led, led_path)
        if results is None:  # nothing dispatched (consent gone / budget spent)
            return self._fresh_cached(cached, now)
        cache[self.consent_key] = {"fetched_utc": now.isoformat(),
                                   "results": results}
        try:
            save_cache(cache)
        except Exception as exc:  # noqa: BLE001 - cache write never breaks a feed
            print(f"front-page: scout cache write skipped "
                  f"({type(exc).__name__}: {exc})", file=sys.stderr)
        return results

    def _fresh_cached(self, cached: dict, now: datetime) -> list:
        fetched = _parse_dt(cached.get("fetched_utc"))
        if fetched is None:
            return []
        if (now - fetched).total_seconds() > CACHE_TTL_DAYS * 86400.0:
            return []
        results = cached.get("results")
        return results if isinstance(results, list) else []

    def _dispatch(self, queries: list[dict], now: datetime,
                  led: dict, led_path: str):
        """The per-query gate chain (the heart of E4). Returns the list of
        ``{"query", "result"}`` pairs actually fetched, or ``None`` when
        nothing was dispatched at all. Every query independently re-reads
        the consent file, passes the hygiene scan, and spends budget -
        in that order, all fail-closed."""
        entry = led.get(self.consent_key)
        if not isinstance(entry, dict):
            entry = {}
        day = _day_key(now)
        counts = entry.get("queries") if isinstance(entry.get("queries"), dict) else {}
        spent_today = queries_today(entry, now)

        results: list = []
        dispatched = 0
        for query in queries:
            if dispatched >= MAX_QUERIES_PER_RUN:
                break
            if spent_today >= MAX_QUERIES_PER_DAY:
                break
            # Consent-per-query: the file is re-read immediately before every
            # dispatch, so a revocation lands mid-run, not next tick.
            if not sc.has_consent(sc.load_consent(), self.consent_key):
                print(f"front-page: scout '{self.consent_key}' consent gone "
                      "mid-run - halting", file=sys.stderr)
                break
            payload = json.dumps(query, sort_keys=True, ensure_ascii=False)
            if not query_is_clean(payload, self._contact_lexicon):
                print(f"front-page: scout '{self.consent_key}' refused one "
                      "query (outbound hygiene)", file=sys.stderr)
                continue
            try:
                result = self._fetcher(query)
            except Exception as exc:  # noqa: BLE001 - one bad fetch, one line
                print(f"front-page: scout '{self.consent_key}' fetch failed "
                      f"({type(exc).__name__}: {exc})", file=sys.stderr)
                dispatched += 1
                spent_today += 1
                continue
            dispatched += 1
            spent_today += 1
            results.append({"query": query, "result": result})

        if dispatched == 0:
            return None
        counts = {day: spent_today}  # keep only today's count: natural pruning
        entry.update({"last_fetch_utc": now.isoformat(), "queries": counts})
        led[self.consent_key] = entry
        try:
            save_fetch_ledger(led, led_path)
        except Exception as exc:  # noqa: BLE001 - ledger write never breaks a feed
            print(f"front-page: scout fetch-ledger write skipped "
                  f"({type(exc).__name__}: {exc})", file=sys.stderr)
        return results


# ---------------------------------------------------------------------------
# Consent offer cards (the E3-deferred consent card, spec section 2.1)
# ---------------------------------------------------------------------------

def consent_offer_cards(scouts_list: list, profile: dict,
                        consent: dict | None, now: datetime) -> list:
    """One honest consent card per external scout that could actually deliver:
    wired transport, free-tier source, at least one L1 interest in its domain,
    and NO existing consent entry (a granted scout needs no ask; an explicit
    ``false`` is a "no" we respect - we do not re-nag; a dismissed offer stays
    dismissed via the ordinary card-state store). The card's action carries
    the machine-readable grant verb the feedback wire executes
    (``consent_grant:<key>``)."""
    from compiler import frontpage as fp  # lazy: avoids an import cycle
    cards: list = []
    for scout in scouts_list or []:
        if not isinstance(scout, ExternalScout):
            continue
        if not scout.wired():
            continue  # never ask permission for labour we cannot deliver
        if scout.source is None or not scout.source.free_tier:
            continue
        if not isinstance(consent, dict):
            consent = {}
        if scout.consent_key in consent:
            continue  # granted, declined, or malformed: never re-ask here
        if not l1_interests(profile, scout.domain):
            continue  # no matching taste -> the offer would be noise
        domain = scout.domain or scout.consent_key
        cards.append(fp._make_card(
            "consent", f"scout_consent::{scout.consent_key}",
            title=_STRINGS["consent_title"].format(domain_lc=domain.lower()),
            body=_STRINGS["consent_body"].format(source_label=scout.source.label),
            now=now, domain=domain,
            priority=fp.BAND_CONSENT,
            action={"label": _STRINGS["consent_action"],
                    "kind": f"consent_grant:{scout.consent_key}"},
            source="ostler:editor",
            privacy="L1",
        ))
    return cards
