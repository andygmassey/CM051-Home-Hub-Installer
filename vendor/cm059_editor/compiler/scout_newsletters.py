"""The newsletters scout (E3): the first profile -> candidates -> card engine.

Proves the whole scout loop end to end using data the operator **already
ingested** - their own newsletter issues in the local email store. Zero
outbound network (a newsletter subscription is a declared interest; reading
what already arrived needs no fetch). CM059 spec section 5, Phase E3.

The loop:

    issues (local mailbox, trailing window)
      -> story candidates (dedup by normalised title)
      -> relevance rank against the interest profile
         (deterministic keyword-overlap by default; optional local-Ollama
          re-rank behind OSTLER_SCOUT_LLM, always falling back cleanly)
      -> ONE weekly digest card (top stories, honest evidence, 7-day TTL,
         privacy L1)
      -> feedback ("not me" on the digest) lowers the source newsletter's
         affinity weight in the next compile (CorrectionStore keys
         ``newsletter::<slug>``; drop zeroes the source out entirely)

Mailbox reader contract (the seam to the email store)
-----------------------------------------------------

The scout reads ``OSTLER_NEWSLETTERS_DIR`` (default
``~/.ostler/mail/newsletters``): one JSON file per issue, or ``.jsonl`` files
with one issue per line. An issue::

    {
      "newsletter": "The Service Desk Weekly",     # or source/from/sender
      "subject":    "Issue 41: maturity models",
      "date":       "2026-07-10T08:00:00+00:00",   # or received/sent_at
      "stories": [ { "title": "...", "summary": "...", "url": "..." } ]
    }

``stories`` optional - an issue without it contributes its subject + snippet
as a single story. An issue with no parseable date cannot be windowed and is
skipped (honest: no invented recency). Wiring the real email store to this
shape is a small adapter lift on the ingest side (CM046/CM048), tracked in
the E3 design note - the contract lives here so both sides converge on it.

Honesty rules: an empty week, or a week with nothing relevant, emits NO card
(never a padded one, A-E3-3). Evidence says what was actually done ("ranked
against your ... interests from N newsletter issues"). Story titles and the
operator's own newsletter names only - never third-party message content
(everything here is the operator's own subscribed mail: privacy L1).

Determinism: with ``SKIP_LLM`` set (or the LLM unavailable) the ranking is a
pure function of (issues, profile, corrections) - same inputs, same card,
byte for byte. The optional Ollama path is opt-in via ``OSTLER_SCOUT_LLM=1``,
loopback-only, and any failure falls back to the deterministic score.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse

from compiler import card_ledger
from compiler import corrections as corr_mod
from compiler import frontpage as fp
from compiler.scouts import Scout

# ---------------------------------------------------------------------------
# Tunables (spec section 1.3 scout row + E3 scope). Constants, not env knobs;
# adjust only with a failing fixture that needs it.
# ---------------------------------------------------------------------------

WINDOW_DAYS = 7          # weekly digest: the trailing week of issues
DIGEST_STORIES = 2       # "top-2 stories" (spec example + A-E3-1)
DIGEST_TTL_DAYS = 7      # news TTL per the spec ranking table
MIN_RELEVANCE = 0.05     # below this a story is noise vs the profile
RELEVANCE_SCALE = 0.4    # one strong matched interest -> ~0.4 relevance

DEFAULT_NEWSLETTERS_DIR = "~/.ostler/mail/newsletters"

# User-facing copy, centralised as the locale seam (same pattern as
# signals._STRINGS). British English.
_STRINGS = {
    "digest_title": "Stories worth your time this week",
    "digest_title_one": "A story worth your time this week",
    "digest_body": "From your own newsletters: {stories}.",
    "digest_action": "Read the digest",
    "digest_evidence": ("ranked against your {domains} interests from "
                        "{count} newsletter issue{plural}"),
}

_STOPWORDS = frozenset("""
a an and are for from has have how its new not of on or that the this to was
what when where which who why with you your issue weekly daily monthly
newsletter edition
""".split())


# ---------------------------------------------------------------------------
# Small pure helpers
# ---------------------------------------------------------------------------

def _parse_dt(value):
    if value is None or isinstance(value, datetime):
        return value
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _first(d: dict, *keys, default=None):
    for k in keys:
        if isinstance(d, dict) and d.get(k) not in (None, ""):
            return d[k]
    return default


def newsletter_slug(name: str) -> str:
    """Stable per-newsletter key segment: lowercase, non-alphanumeric -> '-'."""
    slug = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    return slug or "unknown"


def affinity_key(name: str) -> str:
    """The CorrectionStore key for a newsletter's affinity weight. Namespaced
    so it can never collide with an interest id or subject in the same store."""
    return f"newsletter::{newsletter_slug(name)}"


def _tokens(text: str) -> set[str]:
    words = re.findall(r"[a-z0-9']+", (text or "").lower())
    return {w for w in words if len(w) >= 3 and w not in _STOPWORDS}


def _norm_title_key(title: str) -> str:
    return hashlib.sha1(" ".join(sorted(_tokens(title))).encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Affinity weights: the feedback -> next-compile loop (A-E3-2)
# ---------------------------------------------------------------------------

def affinity_weights(corrections: dict | None) -> dict:
    """Per-newsletter affinity from the canonical CorrectionStore shape.

    Base weight 1.0. A ``weaken`` entry on ``newsletter::<slug>`` multiplies it
    down (default tap 0.5); ``strengthen`` multiplies up (default 1.5); a slug
    in ``drop`` zeroes the source out entirely (terminal). Non-newsletter keys
    in the store are ignored here, and newsletter keys are ignored by the
    interest-profile matcher - one store, two disjoint namespaces."""
    weights: dict[str, float] = {}
    if not isinstance(corrections, dict):
        return weights
    for key, factor in (corrections.get("strengthen") or {}).items():
        if str(key).startswith("newsletter::"):
            try:
                weights[key] = weights.get(key, 1.0) * float(factor)
            except (TypeError, ValueError):
                continue
    for key, factor in (corrections.get("weaken") or {}).items():
        if str(key).startswith("newsletter::"):
            try:
                weights[key] = weights.get(key, 1.0) * float(factor)
            except (TypeError, ValueError):
                continue
    for key in (corrections.get("drop") or []):
        if str(key).startswith("newsletter::"):
            weights[str(key)] = 0.0
    return weights


def _affinity(weights: dict, name: str) -> float:
    return float(weights.get(affinity_key(name), 1.0))


# ---------------------------------------------------------------------------
# Mailbox reading (tolerant I/O)
# ---------------------------------------------------------------------------

def newsletters_dir() -> str:
    return os.path.expanduser(
        os.environ.get("OSTLER_NEWSLETTERS_DIR", DEFAULT_NEWSLETTERS_DIR))


def _iter_issue_objects(directory: str):
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return
    for name in names:
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            continue
        if name.endswith(".json"):
            try:
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception:  # noqa: BLE001 - one bad file never breaks the scout
                continue
            if isinstance(data, dict):
                yield data
            elif isinstance(data, list):
                yield from (d for d in data if isinstance(d, dict))
        elif name.endswith(".jsonl"):
            try:
                with open(path, encoding="utf-8") as fh:
                    lines = fh.read().splitlines()
            except Exception:  # noqa: BLE001
                continue
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                except ValueError:
                    continue
                if isinstance(data, dict):
                    yield data


def read_issues(directory: str | None, since: datetime, now: datetime) -> list[dict]:
    """Issues in the (since, now] window, normalised to
    ``{"newsletter", "subject", "date", "stories": [{"title", "summary"}]}``.
    An issue with no parseable date is skipped (cannot be windowed honestly)."""
    directory = directory or newsletters_dir()
    out: list[dict] = []
    for raw in _iter_issue_objects(directory):
        when = _parse_dt(_first(raw, "date", "received", "received_at",
                                "sent_at", "sent"))
        if when is None or when <= since or when > now:
            continue
        name = _first(raw, "newsletter", "source", "from_name", "from",
                      "sender", default="")
        subject = str(_first(raw, "subject", "title", default="") or "")
        stories_raw = raw.get("stories")
        stories: list[dict] = []
        if isinstance(stories_raw, list):
            for st in stories_raw:
                if not isinstance(st, dict):
                    continue
                title = str(_first(st, "title", "headline", default="") or "")
                if not title.strip():
                    continue
                stories.append({
                    "title": title.strip(),
                    "summary": str(_first(st, "summary", "snippet",
                                          default="") or ""),
                })
        if not stories and subject.strip():
            # an issue without an item list contributes itself as one story
            stories = [{"title": subject.strip(),
                        "summary": str(_first(raw, "summary", "snippet",
                                              default="") or "")}]
        if not stories:
            continue
        out.append({"newsletter": str(name), "subject": subject,
                    "date": when, "stories": stories})
    return out


# ---------------------------------------------------------------------------
# Candidate extraction + deterministic relevance (pure)
# ---------------------------------------------------------------------------

def _profile_interests(profile: dict) -> list[dict]:
    items: list[dict] = []
    for block in (profile or {}).get("domains", []):
        for it in block.get("interests", []):
            if it.get("polarity") == "dislike":
                continue
            items.append(it)
    return items


def extract_candidates(issues: list[dict]) -> list[dict]:
    """Flatten issues into deduplicated story candidates. Dedup is by
    normalised-title key (token set), first occurrence wins - the same essay
    linked by two newsletters is one candidate, credited to the first."""
    seen: set[str] = set()
    out: list[dict] = []
    for issue in issues:
        for st in issue.get("stories", []):
            key = _norm_title_key(st.get("title", ""))
            if key in seen:
                continue
            seen.add(key)
            out.append({
                "title": st.get("title", ""),
                "summary": st.get("summary", ""),
                "newsletter": issue.get("newsletter", ""),
            })
    return out


def score_candidates(candidates: list[dict], profile: dict,
                     weights: dict | None = None) -> list[dict]:
    """Deterministic keyword-overlap relevance (the SKIP_LLM path, and the
    fallback whenever the optional LLM path is off or fails).

    Per story: interests whose subject tokens overlap the story's
    title+summary tokens each contribute ``min(1.0, score)``; the sum is
    scaled by ``RELEVANCE_SCALE`` and capped at 1.0, then multiplied by the
    source newsletter's affinity weight (base 1.0; feedback moves it). The
    matched interests' domains are kept for the honest evidence line.

    Returns scored candidates sorted by (-relevance, title) - fully
    deterministic. Zero-affinity (dropped) sources are excluded."""
    weights = weights or {}
    interests = _profile_interests(profile)
    prepared = [(it, _tokens(it.get("subject", ""))) for it in interests]
    scored: list[dict] = []
    for cand in candidates:
        affinity = _affinity(weights, cand.get("newsletter", ""))
        if affinity <= 0.0:
            continue  # dropped source: terminal
        story_tokens = _tokens(f"{cand.get('title', '')} {cand.get('summary', '')}")
        base = 0.0
        matched_domains: set[str] = set()
        for it, toks in prepared:
            if toks and toks & story_tokens:
                base += min(1.0, float(it.get("score", 0.0)))
                if it.get("domain"):
                    matched_domains.add(it["domain"])
        relevance = round(min(1.0, RELEVANCE_SCALE * base) * affinity, 4)
        scored.append(dict(cand, relevance=relevance,
                           matched_domains=sorted(matched_domains)))
    scored.sort(key=lambda c: (-c["relevance"], c["title"].lower()))
    return scored


# ---------------------------------------------------------------------------
# Optional LLM re-rank (opt-in, loopback-only, always falls back)
# ---------------------------------------------------------------------------

_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def _llm_enabled() -> bool:
    if os.environ.get("SKIP_LLM"):
        return False
    return bool(os.environ.get("OSTLER_SCOUT_LLM"))


def _llm_relevance(scored: list[dict], profile: dict) -> list[dict] | None:
    """Best-effort re-rank of the deterministic scores via the local Ollama
    (``$OLLAMA_URL``, loopback-only hard guard). Opt-in via
    ``OSTLER_SCOUT_LLM=1`` until proven against a live box; any failure -
    non-loopback URL, connection error, unparseable reply - returns ``None``
    and the deterministic order stands. Sends story titles and interest
    subjects only - never bodies, never operator identifiers."""
    base_url = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
    try:
        host = urlparse(base_url).hostname or ""
    except Exception:  # noqa: BLE001
        return None
    if host not in _LOOPBACK_HOSTS:
        return None
    try:
        import urllib.request
        subjects = [it.get("subject", "") for it in _profile_interests(profile)][:40]
        titles = [c["title"] for c in scored[:20]]
        prompt = (
            "Score each numbered story title 0.0-1.0 for relevance to these "
            f"interests: {json.dumps(subjects)}. Stories: "
            f"{json.dumps(dict(enumerate(titles)))}. "
            "Reply with ONLY a JSON object mapping index to score.")
        payload = json.dumps({
            "model": os.environ.get("OSTLER_SCOUT_LLM_MODEL", "qwen3.5:9b"),
            "prompt": prompt, "stream": False,
            "format": "json",
        }).encode("utf-8")
        req = urllib.request.Request(
            base_url.rstrip("/") + "/api/generate", data=payload,
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310
            body = json.loads(resp.read().decode("utf-8"))
        marks = json.loads(body.get("response", ""))
        if not isinstance(marks, dict):
            return None
        out = []
        for idx, cand in enumerate(scored):
            mark = marks.get(str(idx))
            if isinstance(mark, (int, float)) and 0.0 <= float(mark) <= 1.0:
                blended = round((cand["relevance"] + float(mark)) / 2.0, 4)
                cand = dict(cand, relevance=blended)
            out.append(cand)
        out.sort(key=lambda c: (-c["relevance"], c["title"].lower()))
        return out
    except Exception:  # noqa: BLE001 - the deterministic order stands
        return None


# ---------------------------------------------------------------------------
# The digest card (pure)
# ---------------------------------------------------------------------------

def week_key(now: datetime) -> str:
    iso = now.isocalendar()
    return f"{iso[0]}-W{iso[1]:02d}"


def digest_card(scored: list[dict], issue_count: int, now: datetime,
                ledger=None) -> dict | None:
    """One weekly digest card from the ranked candidates, or ``None`` when
    nothing clears ``MIN_RELEVANCE`` (honest-empty, A-E3-3).

    Identity is stable per ISO week (``card_id("interest",
    "scout_newsletters::digest::<year>-W<week>")``), so re-ticks within the
    week keep the card's ledger age and dismiss state; a new week is a new
    card. TTL is 7 days from first emission; priority is
    ``BAND_SCOUT x mean relevance`` of the chosen stories (spec section 1.3
    scout row - age decay at half-life 3 days is applied centrally)."""
    picks = [c for c in scored if c.get("relevance", 0.0) >= MIN_RELEVANCE]
    picks = picks[:DIGEST_STORIES]
    if not picks:
        return None
    key = f"scout_newsletters::digest::{week_key(now)}"
    cid = fp.card_id("interest", key)
    fe = _parse_dt(card_ledger.first_emitted(ledger, cid))
    created = fe or now
    expires = created + timedelta(days=DIGEST_TTL_DAYS)
    relevance = round(sum(c["relevance"] for c in picks) / len(picks), 4)

    titles = [c["title"] for c in picks]
    stories_text = titles[0] if len(titles) == 1 else " - and - ".join(titles)
    domains = sorted({d for c in picks for d in c.get("matched_domains", [])})
    domains_text = " and ".join(domains[:2]) if domains else "standing"
    title = (_STRINGS["digest_title_one"] if len(picks) == 1
             else _STRINGS["digest_title"])
    sources = sorted({affinity_key(c.get("newsletter", "")) for c in picks})

    card = fp._make_card(
        "interest", key,
        title=title,
        body=_STRINGS["digest_body"].format(stories=stories_text),
        now=now, domain="News",
        priority=fp.BAND_SCOUT * relevance,
        expires_utc=expires,
        action={"label": _STRINGS["digest_action"], "kind": "open_digest"},
        evidence=_STRINGS["digest_evidence"].format(
            domains=domains_text, count=issue_count,
            plural="s" if issue_count != 1 else ""),
        source="ostler:scout_newsletters",
        privacy="L1",
    )
    card["created_utc"] = fp._iso(created)
    card["strength"] = relevance
    card["icon"] = "newspaper"
    # Feedback provenance: which newsletter affinity keys a tap on this card
    # trains (feedback.py resolves these; additive optional field, schema 0.2).
    card["sources"] = sources
    return card


# ---------------------------------------------------------------------------
# The Scout
# ---------------------------------------------------------------------------

class NewslettersScout(Scout):
    domain = "News"
    consent_key = "newsletters"

    def candidates(self, profile: dict, since: datetime,
                   now: datetime) -> list[dict]:
        issues = read_issues(None, since, now)
        corrections = corr_mod.load_corrections()
        weights = affinity_weights(corrections)
        scored = score_candidates(extract_candidates(issues), profile, weights)
        if _llm_enabled():
            reranked = _llm_relevance(scored, profile)
            if reranked is not None:
                return reranked
        return scored

    def build_cards(self, profile: dict, now: datetime, ledger=None) -> list:
        since = now - timedelta(days=WINDOW_DAYS)
        issues = read_issues(None, since, now)
        if not issues:
            return []
        corrections = corr_mod.load_corrections()
        weights = affinity_weights(corrections)
        scored = score_candidates(extract_candidates(issues), profile, weights)
        if _llm_enabled():
            reranked = _llm_relevance(scored, profile)
            if reranked is not None:
                scored = reranked
        card = digest_card(scored, len(issues), now, ledger=ledger)
        return [card] if card else []
