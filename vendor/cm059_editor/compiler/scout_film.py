"""The Film & TV scout (E4): the first external scout, on the framework.

Checks release listings against the operator's Film & TV taste (spec section
2.1 consent-card example) and emits at most ONE weekly digest card. In this
build it has **no transport**: the real film-database wiring (TMDB free tier,
``region`` from locale) is the deferred live step - the scout is registered
with ``fetcher=None`` so it can neither fetch nor offer consent until the
operator-consented transport ships. Tests inject a fixture fetcher to prove
the whole path.

Query shape (what would leave the machine, and ALL that would leave it)::

    {"kind": "release_lookup", "topic": "<interest subject>", "region": "GB"}

Topics are L0/L1-tagged interest subjects only (``scout_external.
l1_interests``, fail-closed: untagged rows never feed a query);
``region`` is the coarse locale region (env ``OSTLER_LOCALE_REGION``, default
GB) - the spec's "region from locale", not a location signal. The framework's
hygiene gate re-scans every serialised query anyway.

Result shape the fetcher returns per query (fixture or, later, the adapter
over the real API)::

    [ {"title": "...", "overview": "...", "release_date": "YYYY-MM-DD"}, ... ]

Ranking is the same deterministic keyword-overlap the newsletters scout uses
(shared tokens/constants imported from there): interests whose subject tokens
overlap a release's title+overview each contribute ``min(1, score)``; sum
scaled and capped; top picks above the noise floor make the digest. An empty
or irrelevant window emits NO card (honest-empty, same as A-E3-3).
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from compiler import card_ledger
from compiler import frontpage as fp
from compiler.scout_external import ExternalScout, ExternalSource, l1_interests
from compiler.scout_newsletters import (
    DIGEST_TTL_DAYS,
    MIN_RELEVANCE,
    RELEVANCE_SCALE,
    _norm_title_key,
    _parse_dt,
    _tokens,
    week_key,
)

DIGEST_PICKS = 2      # top-2 releases, mirroring the newsletters digest
MAX_TOPICS = 8        # never query more topics than one run's budget anyway

# User-facing copy, centralised as the locale seam. British English.
_STRINGS = {
    "digest_title": "New releases picked for you",
    "digest_title_one": "A new release picked for you",
    "digest_body": "Matched to your taste: {titles}.",
    "digest_action": "See the picks",
    "digest_evidence": ("matched against your Film & TV interests from "
                        "{count} anonymous title lookup{plural} - nothing "
                        "about you was sent"),
}


def _region() -> str:
    return os.environ.get("OSTLER_LOCALE_REGION", "GB")


class FilmTVScout(ExternalScout):
    domain = "Film & TV"
    consent_key = "film_tv"
    source = ExternalSource(
        name="tmdb",
        label="release listings",
        free_tier=True,
    )
    default_frequency = "daily"  # the spec's shared daily fetch window

    def queries(self, profile: dict, now: datetime) -> list[dict]:
        out: list[dict] = []
        for it in l1_interests(profile, self.domain)[:MAX_TOPICS]:
            subject = str(it.get("subject") or "").strip()
            if not subject:
                continue
            out.append({"kind": "release_lookup", "topic": subject,
                        "region": _region()})
        return out

    def cards_from(self, results: list, profile: dict, now: datetime,
                   ledger=None) -> list:
        releases = _flatten(results)
        scored = _score(releases, profile)
        card = _digest_card(scored, len(results), now, ledger=ledger)
        return [card] if card else []


def _flatten(results: list) -> list[dict]:
    """Dedup the per-query result lists into one release pool (a release two
    topics both surfaced is one candidate)."""
    seen: set[str] = set()
    out: list[dict] = []
    for pair in results or []:
        items = pair.get("result") if isinstance(pair, dict) else None
        if not isinstance(items, list):
            continue
        for rel in items:
            if not isinstance(rel, dict):
                continue
            title = str(rel.get("title") or "").strip()
            if not title:
                continue
            key = _norm_title_key(title)
            if key in seen:
                continue
            seen.add(key)
            out.append({"title": title,
                        "overview": str(rel.get("overview") or "")})
    return out


def _score(releases: list[dict], profile: dict) -> list[dict]:
    """Deterministic relevance vs the operator's Film & TV interests - same
    formula as the newsletters scout, so one mental model covers both."""
    interests = l1_interests(profile, FilmTVScout.domain)
    prepared = [(it, _tokens(it.get("subject", ""))) for it in interests]
    scored: list[dict] = []
    for rel in releases:
        rel_tokens = _tokens(f"{rel['title']} {rel['overview']}")
        base = 0.0
        matched_ids: list[str] = []
        for it, toks in prepared:
            if toks and toks & rel_tokens:
                base += min(1.0, float(it.get("score", 0.0)))
                if it.get("id"):
                    matched_ids.append(it["id"])
        relevance = round(min(1.0, RELEVANCE_SCALE * base), 4)
        scored.append(dict(rel, relevance=relevance,
                           matched_ids=sorted(set(matched_ids))))
    scored.sort(key=lambda r: (-r["relevance"], r["title"].lower()))
    return scored


def _digest_card(scored: list[dict], lookup_count: int, now: datetime,
                 ledger=None) -> dict | None:
    picks = [r for r in scored if r.get("relevance", 0.0) >= MIN_RELEVANCE]
    picks = picks[:DIGEST_PICKS]
    if not picks:
        return None
    key = f"scout_film_tv::digest::{week_key(now)}"
    cid = fp.card_id("interest", key)
    fe = _parse_dt(card_ledger.first_emitted(ledger, cid))
    created = fe or now
    relevance = round(sum(r["relevance"] for r in picks) / len(picks), 4)
    titles = [r["title"] for r in picks]
    title = (_STRINGS["digest_title_one"] if len(picks) == 1
             else _STRINGS["digest_title"])
    sources = sorted({i for r in picks for i in r.get("matched_ids", [])})

    card = fp._make_card(
        "interest", key,
        title=title,
        body=_STRINGS["digest_body"].format(
            titles=titles[0] if len(titles) == 1 else " - and - ".join(titles)),
        now=now, domain=FilmTVScout.domain,
        priority=fp.BAND_SCOUT * relevance,
        expires_utc=created + timedelta(days=DIGEST_TTL_DAYS),
        action={"label": _STRINGS["digest_action"], "kind": "open_digest"},
        evidence=_STRINGS["digest_evidence"].format(
            count=lookup_count, plural="s" if lookup_count != 1 else ""),
        source="ostler:scout_film_tv",
        privacy="L1",
    )
    card["created_utc"] = fp._iso(created)
    card["strength"] = relevance
    card["icon"] = "film"
    if sources:
        card["sources"] = sources  # feedback trains the matched interests
    return card
