"""Phase 0 interest-profile compiler.

Pure-ish: the scoring layer (clean / flag / decay / score / aggregate / compile)
is a pure function of (raw preference rows, now, corrections) so it is testable
without a live graph. The I/O layer (fetch_preferences) talks read-only to
Oxigraph; nothing here ever writes to the graph.

Observed data shape on a real PWG (Oxigraph), pwg: = https://pwg.dev/ontology#
  ?s a pwg:LikePreference | pwg:DislikePreference
     pwg:subject            "Web Development"
     pwg:category           "professional"
     pwg:preferenceStrength 0.74...           (float, ~0.11..0.75 observed)
     pwg:dataSource         "linkedin" | "facebook" | "csv" | "meta" | ...
     pwg:observedAt | pwg:createdAt  xsd:dateTime

The hard job in Phase 0 is NOT ranking strengths (the raw strengths are
dominated by noise - Facebook page-likes, recruiter email subject lines
mis-categorised as "food"); it is separating signal from noise and surfacing
the clean interests with honest evidence, correctably.
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import re
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PWG_NS = "https://pwg.dev/ontology#"

# ---------------------------------------------------------------------------
# Taxonomy: how far to trust each source category, and which coarse domain it
# routes to. Trust is the Phase-0 noise lever - low-trust categories still
# appear in the profile but sink, and are flagged for the correction surface.
# Values tuned against the real category distribution on Andy's graph.
# ---------------------------------------------------------------------------

CATEGORY_TRUST = {
    "movie_tv": 0.95,
    "movie": 0.95,
    "tv": 0.95,
    "music": 0.95,
    "book": 0.95,
    "food": 0.85,
    "place": 0.85,
    "education": 0.75,
    "professional": 0.70,
    "interest": 0.55,          # genuine interests but heavily polluted by email subjects
    "inferred_interest": 0.50,
    "shared_link": 0.35,
    "social_media": 0.30,
    "page": 0.25,              # Facebook page-likes - weak signal
    "facebook_content": 0.20,  # Facebook content noise - weakest
}
DEFAULT_TRUST = 0.40

CATEGORY_DOMAIN = {
    "movie_tv": "Film & TV",
    "movie": "Film & TV",
    "tv": "Film & TV",
    "music": "Music",
    "book": "Reading",
    "food": "Food & Drink",
    "place": "Places & Travel",
    "education": "Learning",
    "professional": "Professional",
    "interest": "Interests",
    "inferred_interest": "Interests",
    "shared_link": "Social signals",
    "social_media": "Social signals",
    "page": "Social signals",
    "facebook_content": "Social signals",
}
DEFAULT_DOMAIN = "Other"

# How far to trust each DATA SOURCE - distinct from category trust, and just as
# important. Learned from real data: `csv` is imported email/recruiter subject
# lines (noise dressed up with high strength + recent dates); `linkedin` is
# declared skills/courses; `facebook`/`meta` are declared likes/page-likes
# (real signal, but the writer stamped them with near-zero strength, so we floor
# them - a declared "like" is a genuine signal regardless of that number).
SOURCE_TRUST = {
    "you": 1.0,
    "linkedin": 0.85,
    "facebook": 0.65,
    "meta": 0.40,
    "csv": 0.18,        # email/recruiter import - heavily distrusted
    "email": 0.18,
    "imap": 0.18,
}
DEFAULT_SOURCE_TRUST = 0.45

# Sources that represent an explicit, declared preference (not an activity log).
# For these we floor the strength to a baseline so a real book-like that was
# written with strength 0.001 still ranks as a genuine interest.
DECLARED_SOURCES = {"linkedin", "facebook", "you"}
DECLARED_STRENGTH_FLOOR = 0.45
# ...but only when the category is not itself low-trust noise.
_LOW_TRUST_CATEGORIES = {"facebook_content", "page", "social_media", "shared_link"}

DECAY_FLOOR = 0.35  # a declared favourite does not expire to nothing

# Subjects that look like email threads / recruiter chatter rather than tastes.
_EMAIL_PREFIX_RE = re.compile(r"^\s*(re|fw|fwd|aw|tr)\s*[:\-]", re.IGNORECASE)
_RECRUITER_RE = re.compile(
    r"\b(opportunit(y|ies)|keen to learn|confidential\b|head of |coffee meeting|"
    r"\bintro\b|\brole\b|hiring|recruit|consulting opportunity|new opportunity)\b",
    re.IGNORECASE,
)
_URL_RE = re.compile(r"^(https?://|www\.)", re.IGNORECASE)
_YEAR_TAIL_RE = re.compile(r"\b(19|20)\d{2}\b")

# Sources where free-text subjects are most likely to be email/import noise.
_NOISY_SOURCES = {"csv", "email", "imap"}


# ---------------------------------------------------------------------------
# Scoring layer (pure)
# ---------------------------------------------------------------------------

def clean_subject(subject: str) -> str:
    """Strip email reply/forward prefixes and collapse whitespace."""
    s = (subject or "").strip()
    # peel repeated RE:/FW: prefixes
    prev = None
    while prev != s:
        prev = s
        s = _EMAIL_PREFIX_RE.sub("", s).strip()
    s = re.sub(r"\s+", " ", s)
    return s


def noise_flags(subject: str, category: str, source: str) -> list[str]:
    """Return a list of reasons this row is suspect. Empty == clean."""
    flags: list[str] = []
    raw = (subject or "").strip()
    cleaned = clean_subject(subject)

    if not cleaned:
        flags.append("empty")
    if _URL_RE.match(cleaned):
        flags.append("url_only")
    if len(cleaned) < 3:
        flags.append("too_short")
    if len(cleaned) > 80:
        flags.append("too_long")
    if _EMAIL_PREFIX_RE.match(raw):
        flags.append("email_reply_prefix")
    src = (source or "").lower()
    if src in _NOISY_SOURCES and _RECRUITER_RE.search(cleaned):
        flags.append("email_thread")
    if _YEAR_TAIL_RE.search(cleaned) and src in _NOISY_SOURCES:
        flags.append("dated_subject")
    if (category or "").lower() in ("facebook_content", "page"):
        flags.append("low_trust_category")
    if "CONTENT METADATA NO LONGER EXISTS" in raw or "urn:li" in raw.lower():
        flags.append("dead_reference")
    return flags


# penalty applied to confidence per distinct flag class
_FLAG_PENALTY = {
    "empty": 1.0,
    "url_only": 0.9,
    "too_short": 0.6,
    "too_long": 0.2,
    "email_reply_prefix": 0.5,
    "email_thread": 0.7,
    "dated_subject": 0.3,
    "low_trust_category": 0.3,
    "dead_reference": 0.7,
}


def _parse_dt(value: str | None):
    if not value:
        return None
    v = value.strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(v)
    except ValueError:
        # try date-only or truncated forms
        for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
            try:
                dt = datetime.strptime(value[: len(fmt) + 2], fmt)
                break
            except (ValueError, IndexError):
                continue
        else:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def recency_decay(observed_at, now, half_life_days: float = 540.0) -> float:
    """Exponential decay, floored so a declared favourite never rots to nothing.
    half_life_days=540 (~18mo): an interest last seen 18 months ago is worth
    half a fresh one. Missing date -> neutral 0.6. Floor DECAY_FLOOR."""
    dt = _parse_dt(observed_at) if isinstance(observed_at, str) else observed_at
    if dt is None:
        return 0.6
    age_days = max(0.0, (now - dt).total_seconds() / 86400.0)
    return max(DECAY_FLOOR, 0.5 ** (age_days / half_life_days))


def category_trust(category: str) -> float:
    return CATEGORY_TRUST.get((category or "").lower(), DEFAULT_TRUST)


def source_trust(source: str) -> float:
    return SOURCE_TRUST.get((source or "").lower(), DEFAULT_SOURCE_TRUST)


def effective_strength(strength_raw: float, category: str, source: str) -> float:
    """A declared like from a trusted source is a real signal even if the graph
    stamped it with a near-zero strength, so floor it. Activity/noise sources
    keep their raw strength."""
    src = (source or "").lower()
    cat = (category or "").lower()
    if src in DECLARED_SOURCES and cat not in _LOW_TRUST_CATEGORIES:
        return max(strength_raw, DECLARED_STRENGTH_FLOOR)
    return strength_raw


def category_domain(category: str) -> float:
    return CATEGORY_DOMAIN.get((category or "").lower(), DEFAULT_DOMAIN)


def confidence(flags: list[str], category: str, source: str = "") -> float:
    """How sure are we this is a real interest? 0..1. Product of category trust
    and source trust, discounted by the worst flags (multiplicatively so two
    flags compound). Source trust is what sinks recruiter-email `csv` noise even
    when it is mis-filed under a high-trust category like movie_tv."""
    c = category_trust(category) * source_trust(source)
    for f in flags:
        c *= (1.0 - _FLAG_PENALTY.get(f, 0.1))
    return round(max(0.0, min(1.0, c)), 4)


# --- continuous confidence (de-clusters the flat 60/62/64% band) -----------
# `confidence()` above is the per-row RELIABILITY base - it is a product of two
# lookup tables, so on its own it can only land on a handful of discrete values
# (every Facebook book == 0.95x0.65 == 0.62). Real confidence should also reflect
# HOW MUCH evidence we have and how FRESH it is, which are continuous. So the
# displayed confidence = reliability x evidence_factor x recency_confidence.
# NOTE: with today's thin single-observation data the spread is modest; it widens
# sharply once richer sources (email/conversation mining) give repeated, multi-
# source observations of the same interest. That dependency is the point.

def evidence_factor(observations: int, n_sources: int) -> float:
    """Saturating boost for corroboration. 1 observation from 1 source -> 0.70;
    more observations and (weighted 2x) more distinct sources push toward 1.0."""
    extra = max(0, observations - 1) + 2 * max(0, n_sources - 1)
    return round(0.70 + 0.30 * (1.0 - 2.71828 ** (-extra / 4.0)), 4)


def recency_confidence(last_seen, now, half_life_days: float = 720.0) -> float:
    """Gentle, continuous recency term (distinct from the harsher score decay):
    a fresh sighting reads 1.0, a very old one floors at 0.75. This alone gives
    per-item spread even for single-observation interests with different dates."""
    dt = _parse_dt(last_seen) if isinstance(last_seen, str) else last_seen
    if dt is None:
        return 0.85
    age_days = max(0.0, (now - dt).total_seconds() / 86400.0)
    return round(0.75 + 0.25 * (0.5 ** (age_days / half_life_days)), 4)


def finalise_confidence(it: dict, now: datetime) -> dict:
    """Compute the displayed, continuous confidence from the stored reliability
    base plus evidence + recency. Called AFTER aggregation, when observation
    count and distinct-source count are known."""
    reliability = it.get("reliability", it.get("confidence", 0.0))
    ev = evidence_factor(it.get("observations", 1), len(it.get("sources", [])))
    rec = recency_confidence(it.get("last_seen"), now)
    it["confidence"] = round(max(0.0, min(1.0, reliability * ev * rec)), 4)
    it["evidence_factor"] = ev
    return it


def interest_id(subject: str, domain: str) -> str:
    key = f"{domain}::{clean_subject(subject).lower()}"
    return "int_" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:12]


def build_interest(raw: dict, now: datetime) -> dict:
    """Turn one raw preference row into a scored interest record."""
    subject = clean_subject(raw.get("subject", ""))
    category = (raw.get("category") or "").lower()
    source = (raw.get("source") or "").lower()
    polarity = raw.get("polarity", "like")
    strength_raw = float(raw.get("strength") or 0.0)
    observed = raw.get("observed_at") or raw.get("created_at")

    flags = noise_flags(raw.get("subject", ""), category, source)
    decay = recency_decay(observed, now)
    conf = confidence(flags, category, source)
    domain = category_domain(category)
    eff_strength = effective_strength(strength_raw, category, source)

    # final surfacing score: effective strength x how much we trust it x freshness.
    # polarity does not change magnitude; dislikes rank within their own bucket.
    score = round(eff_strength * conf * decay, 5)

    evidence = _evidence_phrase(source, strength_raw, observed)
    return {
        "id": interest_id(subject, domain),
        "subject": subject,
        "domain": domain,
        "category": category,
        "polarity": polarity,
        "score": score,
        "strength_raw": round(strength_raw, 4),
        "reliability": conf,        # the table-based base; finalise() adds evidence+recency
        "confidence": conf,         # provisional; recomputed continuously after aggregation
        "observations": 1,
        "recency_decay": round(decay, 4),
        "last_seen": _iso(observed),
        "sources": [source] if source else [],
        "evidence": [evidence] if evidence else [],
        "flags": flags,
    }


def _iso(value) -> str | None:
    dt = _parse_dt(value) if isinstance(value, str) else value
    return dt.date().isoformat() if dt else None


def _evidence_phrase(source: str, strength: float, observed) -> str:
    bits = []
    if source:
        bits.append(f"from {source}")
    bits.append(f"strength {strength:.2f}")
    seen = _iso(observed)
    if seen:
        bits.append(f"last seen {seen}")
    return " · ".join(bits)


def aggregate(interests: list[dict]) -> list[dict]:
    """Merge rows that resolve to the same (id) - same subject within a domain
    across sources. Keep the highest score, union evidence/sources/flags, and
    bump the merged score slightly for corroboration across distinct sources."""
    by_id: dict[str, dict] = {}
    for it in interests:
        cur = by_id.get(it["id"])
        if cur is None:
            by_id[it["id"]] = dict(it)
            continue
        cur["sources"] = sorted(set(cur["sources"]) | set(it["sources"]))
        cur["evidence"] = cur["evidence"] + [e for e in it["evidence"] if e not in cur["evidence"]]
        cur["flags"] = sorted(set(cur["flags"]) | set(it["flags"]))
        cur["strength_raw"] = max(cur["strength_raw"], it["strength_raw"])
        cur["reliability"] = max(cur.get("reliability", 0.0), it.get("reliability", 0.0))
        cur["confidence"] = max(cur["confidence"], it["confidence"])
        cur["observations"] = cur.get("observations", 1) + it.get("observations", 1)
        cur["score"] = max(cur["score"], it["score"])
        # most-recent last_seen wins
        if it["last_seen"] and (not cur["last_seen"] or it["last_seen"] > cur["last_seen"]):
            cur["last_seen"] = it["last_seen"]

    # corroboration bonus: +8% per extra distinct source, capped
    for it in by_id.values():
        extra = max(0, len(it["sources"]) - 1)
        it["score"] = round(it["score"] * min(1.0 + 0.08 * extra, 1.4), 5)
    return list(by_id.values())


def apply_corrections(interests: list[dict], corrections: dict | None) -> list[dict]:
    """Corrections always win over inferred signal.

    corrections schema (see corrections.py):
      {"drop": [id_or_subject, ...],
       "strengthen": {id_or_subject: factor, ...},
       "weaken": {id_or_subject: factor, ...},
       "add": [{"subject":..,"domain":..,"category":..}, ...]}
    """
    if not corrections:
        return interests

    def _match(it, key):
        return key == it["id"] or key.lower() == it["subject"].lower()

    drop = set(corrections.get("drop", []))
    strengthen = corrections.get("strengthen", {})
    weaken = corrections.get("weaken", {})

    out = []
    for it in interests:
        if any(_match(it, d) for d in drop):
            continue
        it = dict(it)
        for key, factor in strengthen.items():
            if _match(it, key):
                it["score"] = round(it["score"] * float(factor), 5)
                it["confidence"] = 1.0
                it.setdefault("corrected", []).append("strengthened")
        for key, factor in weaken.items():
            if _match(it, key):
                it["score"] = round(it["score"] * float(factor), 5)
                it.setdefault("corrected", []).append("weakened")
        out.append(it)

    now = datetime.now(timezone.utc)
    for add in corrections.get("add", []):
        subj = clean_subject(add.get("subject", ""))
        if not subj:
            continue
        domain = add.get("domain") or category_domain(add.get("category", ""))
        out.append({
            "id": interest_id(subj, domain),
            "subject": subj,
            "domain": domain,
            "category": add.get("category", "user_added"),
            "polarity": add.get("polarity", "like"),
            "score": float(add.get("score", 1.0)),
            "strength_raw": 1.0,
            "confidence": 1.0,
            "recency_decay": 1.0,
            "last_seen": now.date().isoformat(),
            "sources": ["you"],
            "evidence": ["you told Ostler this"],
            "flags": [],
            "corrected": ["added"],
        })
    return out


def compile_profile(raws: list[dict], now: datetime | None = None,
                    corrections: dict | None = None,
                    min_confidence: float = 0.28) -> dict:
    """Full pipeline: raw rows -> grouped, ranked, corrected profile dict."""
    now = now or datetime.now(timezone.utc)
    interests = [build_interest(r, now) for r in raws]
    interests = aggregate(interests)
    interests = apply_corrections(interests, corrections)
    # recompute confidence continuously now that observation/source counts are known
    for it in interests:
        if not it.get("corrected"):
            finalise_confidence(it, now)

    # split likes / dislikes; group likes by domain; drop sub-threshold unless corrected
    domains: dict[str, list[dict]] = {}
    dislikes: list[dict] = []
    suppressed = 0
    for it in interests:
        corrected = bool(it.get("corrected"))
        if not corrected and it["confidence"] < min_confidence:
            suppressed += 1
            continue
        if it["polarity"] == "dislike":
            dislikes.append(it)
            continue
        domains.setdefault(it["domain"], []).append(it)

    for items in domains.values():
        items.sort(key=lambda x: x["score"], reverse=True)
    dislikes.sort(key=lambda x: x["score"], reverse=True)

    domain_blocks = [
        {"domain": d, "count": len(items), "interests": items}
        for d, items in sorted(domains.items(), key=lambda kv: -sum(i["score"] for i in kv[1]))
    ]

    return {
        "schema_version": "0.1",
        "generated_utc": now.isoformat(),
        "stats": {
            "raw_rows": len(raws),
            "interests": sum(len(b["interests"]) for b in domain_blocks),
            "dislikes": len(dislikes),
            "suppressed_low_confidence": suppressed,
            "domains": len(domain_blocks),
        },
        "domains": domain_blocks,
        "dislikes": dislikes,
    }


# ---------------------------------------------------------------------------
# I/O layer (read-only Oxigraph)
# ---------------------------------------------------------------------------

def _sparql_select(oxigraph_url: str, query: str, timeout: float = 30.0) -> list[dict]:
    url = oxigraph_url.rstrip("/") + "/query"
    data = urllib.parse.urlencode({"query": query}).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST", headers={
        "Accept": "text/csv",
        "Content-Type": "application/x-www-form-urlencoded",
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8")
    rows = list(csv.DictReader(io.StringIO(body)))
    return rows


def _pref_query(node_type: str) -> str:
    return (
        f"PREFIX pwg: <{PWG_NS}>\n"
        "SELECT ?subject ?category ?strength ?source ?observed ?created WHERE {\n"
        f"  ?s a pwg:{node_type} ;\n"
        "     pwg:subject ?subject ;\n"
        "     pwg:category ?category ;\n"
        "     pwg:preferenceStrength ?strength ;\n"
        "     pwg:dataSource ?source .\n"
        "  OPTIONAL { ?s pwg:observedAt ?observed }\n"
        "  OPTIONAL { ?s pwg:createdAt ?created }\n"
        "}"
    )


def fetch_preferences(oxigraph_url: str | None = None) -> list[dict]:
    """Read like/dislike preference rows from Oxigraph. Read-only."""
    oxigraph_url = oxigraph_url or os.environ.get(
        "OSTLER_OXIGRAPH_URL", "http://localhost:7878")
    out: list[dict] = []
    for node_type, polarity in (("LikePreference", "like"), ("DislikePreference", "dislike")):
        for row in _sparql_select(oxigraph_url, _pref_query(node_type)):
            out.append({
                "subject": row.get("subject", ""),
                "category": row.get("category", ""),
                "strength": row.get("strength", "0") or "0",
                "source": row.get("source", ""),
                "observed_at": row.get("observed") or None,
                "created_at": row.get("created") or None,
                "polarity": polarity,
            })
    return out


def build_from_live(oxigraph_url: str | None = None,
                    corrections: dict | None = None) -> dict:
    return compile_profile(fetch_preferences(oxigraph_url), corrections=corrections)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description="Compile the Phase-0 interest profile.")
    p.add_argument("--oxigraph", default=os.environ.get("OSTLER_OXIGRAPH_URL", "http://localhost:7878"))
    p.add_argument("--out", default="interest_profile.json")
    p.add_argument("--corrections", default=None, help="path to corrections JSON")
    p.add_argument("--top", type=int, default=0, help="print top-N per domain to stderr")
    args = p.parse_args(argv)

    corr = None
    if args.corrections and os.path.exists(args.corrections):
        with open(args.corrections) as fh:
            corr = json.load(fh)

    profile = build_from_live(args.oxigraph, corrections=corr)
    with open(args.out, "w") as fh:
        json.dump(profile, fh, indent=2, ensure_ascii=False)

    import sys
    s = profile["stats"]
    print(f"profile: {s['interests']} interests across {s['domains']} domains "
          f"({s['dislikes']} dislikes, {s['suppressed_low_confidence']} suppressed) "
          f"from {s['raw_rows']} raw rows -> {args.out}", file=sys.stderr)
    if args.top:
        for block in profile["domains"]:
            print(f"\n## {block['domain']} ({block['count']})", file=sys.stderr)
            for it in block["interests"][:args.top]:
                flag = f"  [{','.join(it['flags'])}]" if it["flags"] else ""
                print(f"  {it['score']:.3f}  {it['subject']}  ({it['confidence']:.2f} conf){flag}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
