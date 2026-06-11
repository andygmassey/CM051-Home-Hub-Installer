"""Batch identity resolver — detects and merges duplicate person nodes.

Scans all person nodes in Oxigraph (and optionally Qdrant), applies multiple
detection strategies with confidence scoring, and merges confirmed duplicates.

Usage:
    python -m identity_resolver.batch_resolver --dry-run --verbose
    python -m identity_resolver.batch_resolver --execute --threshold 0.8

Environment variables:
    OXIGRAPH_URL   (default: http://localhost:7878)
    QDRANT_URL     (default: http://localhost:6333)
    QDRANT_COLLECTION (default: people)
"""
from __future__ import annotations

import argparse
import hashlib
import logging
import os
import sys
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

import httpx

# Ensure the parent directory is importable
_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from identity_resolver.normalise import _jaro_winkler, normalise_email, normalise_phone
from identity_resolver.decisions import apply_user_decisions, load_duplicate_decisions

logger = logging.getLogger(__name__)

PWG = "https://pwg.dev/ontology#"

# ── Configuration ────────────────────────────────────────────────────────────

DEFAULT_CONFIG: Dict[str, Any] = {
    # Confidence thresholds
    "auto_merge_threshold": 0.8,
    "review_threshold": 0.5,
    # Detection weights
    "exact_name_confidence": 0.9,
    "email_match_confidence": 1.0,
    "phone_match_confidence": 0.95,
    "phone_name_mismatch_confidence": 0.6,  # shared phone but very different names
    "email_name_mismatch_confidence": 0.7,  # shared email but very different names (inherited/shared account)
    "fuzzy_base_confidence": 0.6,
    "fuzzy_same_org_bonus": 0.1,
    "fuzzy_same_domain_bonus": 0.1,
    # Name+org auto-merge (2026-06-10): a same-org match whose names are a
    # strong variant (Jaro-Winkler >= name_org_auto_merge_jw_threshold, i.e.
    # NOT a first-name-prefix collision) and which has cleared the hard-conflict
    # veto is auto-merged at this confidence instead of nagging the user.
    "name_org_auto_merge_confidence": 0.85,
    "name_org_auto_merge_jw_threshold": 0.93,
    "name_subset_confidence": 0.5,
    # Fuzzy thresholds
    "fuzzy_jaro_winkler_threshold": 0.85,
    "fuzzy_levenshtein_max_distance": 2,
    # Phone normalisation
    "default_country_code": 852,
    # Common free email domains — too generic to count as a signal for fuzzy matching
    "common_email_domains": {
        "gmail.com", "googlemail.com", "hotmail.com", "hotmail.co.uk",
        "outlook.com", "live.com", "yahoo.com", "yahoo.co.uk",
        "icloud.com", "me.com", "mac.com", "aol.com", "mail.com",
        "protonmail.com", "proton.me", "163.com", "qq.com",
    },
    # Minimum Jaro-Winkler score between names for phone match to be high-confidence.
    # Below this, shared phone is likely an office switchboard — downgrade to review.
    "phone_name_similarity_threshold": 0.6,
    # Minimum Jaro-Winkler score between names for email match to stay high-confidence.
    # Below this, shared email is likely an inherited/shared account — downgrade to review.
    "email_name_similarity_threshold": 0.7,
    # BW-2 correction loop: operator merge/distinct decisions live here as
    # duplicates.yaml. distinct pairs are a permanent never-merge block;
    # merge pairs are forced. Shared contract with the CM044 review page.
    "corrections_dir": os.path.expanduser(
        os.environ.get("WIKI_CORRECTIONS_DIR", "~/.ostler/corrections")
    ),
}


# ── Data classes ─────────────────────────────────────────────────────────────

@dataclass
class PersonRecord:
    """A person node pulled from Oxigraph with all its identifiers."""

    uri: str
    display_name: str
    given_name: str = ""
    family_name: str = ""
    organization: str = ""
    job_title: str = ""
    phones: Set[str] = field(default_factory=set)
    emails: Set[str] = field(default_factory=set)
    email_domains: Set[str] = field(default_factory=set)
    linkedin_urls: Set[str] = field(default_factory=set)
    triple_count: int = 0


@dataclass
class DuplicateMatch:
    """A detected duplicate pair with confidence and reasoning."""

    uri_a: str
    name_a: str
    uri_b: str
    name_b: str
    confidence: float
    strategy: str
    details: str


@dataclass
class MergeAction:
    """A planned or executed merge operation."""

    keep_uri: str
    keep_name: str
    discard_uri: str
    discard_name: str
    confidence: float
    strategy: str
    details: str
    executed: bool = False


@dataclass
class ResolverReport:
    """Full report from a batch resolution run."""

    auto_merges: List[MergeAction] = field(default_factory=list)
    needs_review: List[DuplicateMatch] = field(default_factory=list)
    total_persons: int = 0
    duplicate_groups: int = 0


# ── Detection strategies ────────────────────────────────────────────────────

def _normalise_name(name: str) -> str:
    """Normalise a display name for comparison: lowercase, collapse whitespace,
    replace hyphens with spaces."""
    return " ".join(name.lower().replace("-", " ").split())


def _levenshtein(s1: str, s2: str) -> int:
    """Compute Levenshtein edit distance between two strings."""
    if len(s1) < len(s2):
        return _levenshtein(s2, s1)
    if len(s2) == 0:
        return len(s1)
    prev = list(range(len(s2) + 1))
    for i, c1 in enumerate(s1):
        curr = [i + 1]
        for j, c2 in enumerate(s2):
            # Insertion, deletion, substitution
            curr.append(min(curr[j] + 1, prev[j + 1] + 1, prev[j] + (c1 != c2)))
        prev = curr
    return prev[-1]


def has_hard_conflict(
    a: PersonRecord, b: PersonRecord, config: Dict[str, Any]
) -> Optional[str]:
    """BW-2 hard-conflict veto (spec §3b). A single conflicting *verified*
    identifier means two records are different people no matter how well their
    names match – this is the two-Stuart-Baileys guard.

    Vetoes when the two records each carry a value of the same kind and the
    values are disjoint:
      - different LinkedIn URLs (one human, one LinkedIn identity => two people),
      - different phone numbers (normalised E.164),
      - different *corporate* email domains (free webmail like gmail is too
        generic to count, so it is excluded).

    Returns the conflicting kind ("linkedin"/"phone"/"email") or None. Only
    meaningful for name-based strategies; shared-identifier strategies
    (email_match/phone_match) are the opposite signal and must not call this.
    """
    if a.linkedin_urls and b.linkedin_urls and not (a.linkedin_urls & b.linkedin_urls):
        return "linkedin"
    if a.phones and b.phones and not (a.phones & b.phones):
        return "phone"
    common = config.get("common_email_domains", set())
    a_corp = a.email_domains - common
    b_corp = b.email_domains - common
    if a_corp and b_corp and not (a_corp & b_corp):
        return "email"
    return None


def detect_exact_name_matches(
    persons: Dict[str, PersonRecord], config: Dict[str, Any]
) -> List[DuplicateMatch]:
    """Strategy 1: Exact display name match (confidence 0.9).

    Hard-conflict veto applies (spec §3b): two records with an identical name
    but a conflicting verified identifier are different people (the two real
    Stuart Baileys), so they are never matched.
    """
    by_name: Dict[str, List[str]] = defaultdict(list)
    for uri, p in persons.items():
        norm = _normalise_name(p.display_name)
        if norm:
            by_name[norm].append(uri)

    matches = []
    for name, uris in by_name.items():
        if len(uris) < 2:
            continue
        for i in range(len(uris)):
            for j in range(i + 1, len(uris)):
                a = persons[uris[i]]
                b = persons[uris[j]]
                # Hard-conflict veto: different LinkedIn / phone / corporate
                # email = different people, even with identical names.
                if has_hard_conflict(a, b, config):
                    continue
                matches.append(DuplicateMatch(
                    uri_a=uris[i],
                    name_a=a.display_name,
                    uri_b=uris[j],
                    name_b=b.display_name,
                    confidence=config["exact_name_confidence"],
                    strategy="exact_name",
                    details=f"Identical normalised name: {name!r}",
                ))
    return matches


def detect_email_matches(
    persons: Dict[str, PersonRecord], config: Dict[str, Any]
) -> List[DuplicateMatch]:
    """Strategy 2: Shared email address (confidence 1.0).

    If the display names are very different (JW < threshold), this may be an
    inherited or shared email account (e.g. deceased spouse's email used by
    surviving partner) — downgrade confidence to send to review instead of
    auto-merge.
    """
    email_index: Dict[str, List[str]] = defaultdict(list)
    for uri, p in persons.items():
        for email in p.emails:
            email_index[email].append(uri)

    name_threshold = config.get("email_name_similarity_threshold", 0.7)
    high_conf = config["email_match_confidence"]
    low_conf = config.get("email_name_mismatch_confidence", 0.7)

    matches = []
    for email, uris in email_index.items():
        if len(uris) < 2:
            continue
        for i in range(len(uris)):
            for j in range(i + 1, len(uris)):
                name_a = _normalise_name(persons[uris[i]].display_name)
                name_b = _normalise_name(persons[uris[j]].display_name)
                name_sim = _jaro_winkler(name_a, name_b) if name_a and name_b else 0.0

                if name_sim >= name_threshold:
                    confidence = high_conf
                    detail = f"Shared email: {email} (names similar: {name_sim:.2f})"
                else:
                    confidence = low_conf
                    detail = f"Shared email: {email} (names differ: {name_sim:.2f}, possible shared/inherited account)"

                matches.append(DuplicateMatch(
                    uri_a=uris[i],
                    name_a=persons[uris[i]].display_name,
                    uri_b=uris[j],
                    name_b=persons[uris[j]].display_name,
                    confidence=confidence,
                    strategy="email_match",
                    details=detail,
                ))
    return matches


def detect_phone_matches(
    persons: Dict[str, PersonRecord], config: Dict[str, Any]
) -> List[DuplicateMatch]:
    """Strategy 3: Shared phone number after normalisation (confidence 0.95).

    If the names are very different (JW < threshold), this is likely a shared
    office/switchboard number — downgrade confidence to send to review instead
    of auto-merge.
    """
    phone_index: Dict[str, List[str]] = defaultdict(list)
    for uri, p in persons.items():
        for phone in p.phones:
            phone_index[phone].append(uri)

    name_threshold = config.get("phone_name_similarity_threshold", 0.5)
    high_conf = config["phone_match_confidence"]
    low_conf = config.get("phone_name_mismatch_confidence", 0.6)

    matches = []
    for phone, uris in phone_index.items():
        if len(uris) < 2:
            continue
        for i in range(len(uris)):
            for j in range(i + 1, len(uris)):
                name_a = _normalise_name(persons[uris[i]].display_name)
                name_b = _normalise_name(persons[uris[j]].display_name)
                name_sim = _jaro_winkler(name_a, name_b) if name_a and name_b else 0.0

                if name_sim >= name_threshold:
                    confidence = high_conf
                    detail = f"Shared phone: {phone} (names similar: {name_sim:.2f})"
                else:
                    confidence = low_conf
                    detail = f"Shared phone: {phone} (names differ: {name_sim:.2f}, likely office number)"

                matches.append(DuplicateMatch(
                    uri_a=uris[i],
                    name_a=persons[uris[i]].display_name,
                    uri_b=uris[j],
                    name_b=persons[uris[j]].display_name,
                    confidence=confidence,
                    strategy="phone_match",
                    details=detail,
                ))
    return matches


def detect_fuzzy_name_matches(
    persons: Dict[str, PersonRecord], config: Dict[str, Any]
) -> List[DuplicateMatch]:
    """Strategy 4: Fuzzy name match via Jaro-Winkler + Levenshtein (confidence 0.6-0.8).

    Base confidence 0.6, +0.1 if same org, +0.1 if same corporate email domain.

    To avoid first-name prefix collisions (JW gives "David Freer" ~ "David Gallagher"
    = 0.852 due to 4-char prefix bonus), we require either:
    - Very high similarity (JW >= 0.93) for standalone matches, OR
    - Corroboration (same org or shared corporate email domain) for JW 0.85-0.93
    """
    uris = list(persons.keys())
    matches = []
    jw_threshold = config["fuzzy_jaro_winkler_threshold"]
    lev_max = config["fuzzy_levenshtein_max_distance"]
    base = config["fuzzy_base_confidence"]
    org_bonus = config["fuzzy_same_org_bonus"]
    domain_bonus = config["fuzzy_same_domain_bonus"]
    common_domains = config.get("common_email_domains", set())

    for i in range(len(uris)):
        a = persons[uris[i]]
        norm_a = _normalise_name(a.display_name)
        if not norm_a:
            continue
        for j in range(i + 1, len(uris)):
            b = persons[uris[j]]
            norm_b = _normalise_name(b.display_name)
            if not norm_b:
                continue

            # Skip if names are identical (handled by exact_name strategy)
            if norm_a == norm_b:
                continue

            jw_score = _jaro_winkler(norm_a, norm_b)
            lev_dist = _levenshtein(norm_a, norm_b)

            if jw_score < jw_threshold and lev_dist > lev_max:
                continue

            # Hard-conflict veto (spec §3b): different LinkedIn / phone /
            # corporate email = different people, never merge.
            if has_hard_conflict(a, b, config):
                continue

            confidence = base
            reasons = []

            same_org = (
                a.organization and b.organization
                and a.organization.lower() == b.organization.lower()
            )
            if same_org:
                confidence += org_bonus
                reasons.append(f"same org '{a.organization}'")

            shared_domains = a.email_domains & b.email_domains - common_domains
            has_corporate_domain = bool(shared_domains)
            if has_corporate_domain:
                confidence += domain_bonus
                reasons.append(f"shared email domain {next(iter(shared_domains))}")

            # Require corroboration for JW in the 0.85-0.93 "danger zone" where
            # shared first-name prefixes inflate scores artificially.
            if jw_score < 0.93 and not same_org and not has_corporate_domain:
                continue

            # Name + org auto-merge (Andy 2026-06-10): a strong name match
            # (jw >= name_org_auto_merge_jw_threshold, so NOT a first-name-prefix
            # collision) at the same organisation -- having already cleared the
            # hard-conflict veto above -- is a confident same-person merge. Lift
            # it over the auto-merge line so the user is never asked to confirm
            # the obvious. The jw gate deliberately leaves the 0.85-0.93 danger
            # zone (e.g. "David Freer" ~ "David Gallagher" at the same employer)
            # in review, where a shared first name could mask two real people.
            if same_org and jw_score >= config["name_org_auto_merge_jw_threshold"]:
                confidence = max(confidence, config["name_org_auto_merge_confidence"])
                reasons.append("name+org auto-merge")

            detail_parts = [
                f"Jaro-Winkler={jw_score:.3f}",
                f"Levenshtein={lev_dist}",
            ]
            if reasons:
                detail_parts.extend(reasons)

            matches.append(DuplicateMatch(
                uri_a=uris[i],
                name_a=a.display_name,
                uri_b=uris[j],
                name_b=b.display_name,
                confidence=confidence,
                strategy="fuzzy_name",
                details="; ".join(detail_parts),
            ))
    return matches


def detect_name_subset_matches(
    persons: Dict[str, PersonRecord], config: Dict[str, Any]
) -> List[DuplicateMatch]:
    """Strategy 5: Name subset match (confidence 0.5).

    "Simon" matches "Simon Burrows" if there's only one Simon.
    Ambiguous matches (multiple people sharing a first name) are skipped.
    """
    # Build index of first names to full-name URIs
    first_name_index: Dict[str, List[str]] = defaultdict(list)
    single_name_uris: Dict[str, str] = {}  # uri -> normalised single name

    for uri, p in persons.items():
        norm = _normalise_name(p.display_name)
        if not norm:
            continue
        parts = norm.split()
        if len(parts) == 1:
            single_name_uris[uri] = norm
        if parts:
            first_name_index[parts[0]].append(uri)

    matches = []
    for single_uri, single_name in single_name_uris.items():
        # Find all persons whose first name matches this single name
        candidates = [
            uri for uri in first_name_index.get(single_name, [])
            if uri != single_uri and len(_normalise_name(persons[uri].display_name).split()) > 1
        ]
        # Only match if unambiguous (exactly one full-name candidate)
        if len(candidates) == 1:
            full_uri = candidates[0]
            # Hard-conflict veto: a single name matching a full name with a
            # conflicting verified identifier is a different person.
            if has_hard_conflict(persons[single_uri], persons[full_uri], config):
                continue
            matches.append(DuplicateMatch(
                uri_a=single_uri,
                name_a=persons[single_uri].display_name,
                uri_b=full_uri,
                name_b=persons[full_uri].display_name,
                confidence=config["name_subset_confidence"],
                strategy="name_subset",
                details=f"Single name '{single_name}' uniquely matches full name",
            ))
    return matches


# ── Merge logic ──────────────────────────────────────────────────────────────

def _pair_key(a: str, b: str) -> Tuple[str, str]:
    return (min(a, b), max(a, b))


def pick_canonical(
    persons: Dict[str, PersonRecord], uri_a: str, uri_b: str
) -> Tuple[str, str]:
    """Pick which URI to keep (canonical) and which to discard.

    Prefer: more data (triple count), then more identifiers, then shorter slug.
    """
    a = persons[uri_a]
    b = persons[uri_b]

    a_ids = len(a.phones) + len(a.emails)
    b_ids = len(b.phones) + len(b.emails)

    # Compare by triple count first
    if a.triple_count != b.triple_count:
        if a.triple_count > b.triple_count:
            return uri_a, uri_b
        return uri_b, uri_a

    # Then by identifier count
    if a_ids != b_ids:
        if a_ids > b_ids:
            return uri_a, uri_b
        return uri_b, uri_a

    # Then by URI length (shorter = cleaner slug, no hash suffix)
    if len(uri_a) <= len(uri_b):
        return uri_a, uri_b
    return uri_b, uri_a


def consolidate_matches(
    all_matches: List[DuplicateMatch],
    config: Dict[str, Any],
) -> Tuple[List[DuplicateMatch], List[DuplicateMatch]]:
    """Consolidate matches: keep highest confidence per pair,
    split into auto-merge and needs-review."""
    best: Dict[Tuple[str, str], DuplicateMatch] = {}
    for m in all_matches:
        key = _pair_key(m.uri_a, m.uri_b)
        existing = best.get(key)
        if existing is None or m.confidence > existing.confidence:
            best[key] = m

    auto = []
    review = []
    threshold = config["auto_merge_threshold"]
    review_threshold = config["review_threshold"]

    for m in sorted(best.values(), key=lambda x: -x.confidence):
        # Never auto-merge on fuzzy name alone below 0.7
        if m.strategy == "fuzzy_name" and m.confidence < 0.7:
            if m.confidence >= review_threshold:
                review.append(m)
            continue

        if m.confidence >= threshold:
            auto.append(m)
        elif m.confidence >= review_threshold:
            review.append(m)

    return auto, review


# ── Pre-ingestion check ─────────────────────────────────────────────────────

def check_before_insert(
    oxigraph_url: str,
    display_name: str,
    email: Optional[str] = None,
    phone: Optional[str] = None,
    config: Optional[Dict[str, Any]] = None,
    default_country_code: int = 852,
) -> Optional[str]:
    """Check if a person already exists before creating a new node.

    Returns the existing canonical person URI if a match is found, or None
    if this is genuinely new. Intended to be called by the contact syncer
    before creating new person nodes.
    """
    cfg = {**DEFAULT_CONFIG, **(config or {})}
    client = httpx.Client(timeout=30.0)

    # Fetch all persons
    persons = _fetch_all_persons(oxigraph_url, client, cfg)

    # Check email match (strongest signal)
    if email:
        norm_email = normalise_email(email)
        for uri, p in persons.items():
            if norm_email in p.emails:
                return uri

    # Check phone match
    if phone:
        norm_phone = normalise_phone(phone, default_country_code)
        for uri, p in persons.items():
            if norm_phone in p.phones:
                return uri

    # Check exact name match
    norm_name = _normalise_name(display_name)
    exact_matches = [
        uri for uri, p in persons.items()
        if _normalise_name(p.display_name) == norm_name
    ]
    if len(exact_matches) == 1:
        return exact_matches[0]

    # Check fuzzy name match (conservative: Jaro-Winkler >= 0.93)
    for uri, p in persons.items():
        candidate_norm = _normalise_name(p.display_name)
        if not candidate_norm:
            continue
        jw = _jaro_winkler(norm_name, candidate_norm)
        if jw >= 0.93:
            return uri

    client.close()
    return None


# ── Oxigraph interaction ────────────────────────────────────────────────────

def _sparql_query(url: str, client: httpx.Client, sparql: str) -> List[Dict[str, str]]:
    resp = client.post(
        f"{url}/query",
        content=sparql,
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
    )
    resp.raise_for_status()
    data = resp.json()
    results = []
    for binding in data.get("results", {}).get("bindings", []):
        row = {var: info.get("value", "") for var, info in binding.items()}
        results.append(row)
    return results


def _sparql_update(url: str, client: httpx.Client, sparql: str) -> None:
    resp = client.post(
        f"{url}/update",
        content=sparql,
        headers={"Content-Type": "application/sparql-update"},
    )
    resp.raise_for_status()


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _fetch_all_persons(
    url: str, client: httpx.Client, config: Dict[str, Any]
) -> Dict[str, PersonRecord]:
    """Fetch all person nodes from Oxigraph with identifiers and triple counts."""
    # Get all persons with identifiers
    rows = _sparql_query(url, client, f"""
        PREFIX pwg: <{PWG}>
        SELECT ?person ?name ?org ?title ?givenName ?familyName ?idType ?idValue WHERE {{
            ?person a pwg:Person ;
                    pwg:displayName ?name .
            FILTER NOT EXISTS {{ ?person pwg:mergedInto ?merged }}
            OPTIONAL {{ ?person pwg:organization ?org }}
            OPTIONAL {{ ?person pwg:jobTitle ?title }}
            OPTIONAL {{ ?person pwg:givenName ?givenName }}
            OPTIONAL {{ ?person pwg:familyName ?familyName }}
            OPTIONAL {{
                ?person pwg:hasIdentifier ?id .
                ?id pwg:identifierType ?idType ;
                    pwg:identifierValue ?idValue .
            }}
        }}
    """)

    country_code = config.get("default_country_code", 852)
    persons: Dict[str, PersonRecord] = {}
    for row in rows:
        uri = row["person"]
        if uri not in persons:
            persons[uri] = PersonRecord(
                uri=uri,
                display_name=row.get("name", ""),
                given_name=row.get("givenName", ""),
                family_name=row.get("familyName", ""),
                organization=row.get("org", ""),
                job_title=row.get("title", ""),
            )
        p = persons[uri]
        id_type = row.get("idType", "")
        id_value = row.get("idValue", "")
        if id_type == "phone" and id_value:
            p.phones.add(normalise_phone(id_value, country_code))
        elif id_type == "email" and id_value:
            norm = normalise_email(id_value)
            p.emails.add(norm)
            domain = norm.split("@")[-1] if "@" in norm else ""
            if domain:
                p.email_domains.add(domain)
        elif id_type == "linkedin_url" and id_value:
            p.linkedin_urls.add(id_value)

    # Get triple counts for canonical selection
    count_rows = _sparql_query(url, client, f"""
        PREFIX pwg: <{PWG}>
        SELECT ?person (COUNT(*) as ?cnt) WHERE {{
            ?person a pwg:Person .
            {{ ?person ?p ?o }} UNION {{ ?s ?p2 ?person }}
        }}
        GROUP BY ?person
    """)
    for row in count_rows:
        uri = row["person"]
        if uri in persons:
            try:
                persons[uri].triple_count = int(row.get("cnt", "0"))
            except (ValueError, TypeError):
                pass

    return persons


def _backup_triples(
    url: str, client: httpx.Client, uris: List[str], output_path: str,
) -> None:
    """Dump all triples involving the given URIs to a TriG file for rollback."""
    lines = ["# Backup before identity resolution merge", ""]
    for uri in uris:
        rows = _sparql_query(url, client, f"""
            SELECT ?s ?p ?o WHERE {{
                {{ <{uri}> ?p ?o . BIND(<{uri}> AS ?s) }}
                UNION
                {{ ?s ?p <{uri}> . BIND(<{uri}> AS ?o) }}
            }}
        """)
        lines.append(f"# --- {uri} ---")
        for row in rows:
            lines.append(f"<{row['s']}> <{row['p']}> <{row['o']}> .")
        lines.append("")

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    logger.info("Backup written to %s", output_path)


def _merge_oxigraph(
    url: str, client: httpx.Client, keep_uri: str, discard_uri: str,
) -> None:
    """Merge discard_uri into keep_uri in Oxigraph."""
    now = datetime.now(timezone.utc).isoformat()

    # 1. Move identifiers
    _sparql_update(url, client,
        f"DELETE {{ <{discard_uri}> <{PWG}hasIdentifier> ?id }} "
        f"INSERT {{ <{keep_uri}> <{PWG}hasIdentifier> ?id }} "
        f"WHERE {{ <{discard_uri}> <{PWG}hasIdentifier> ?id }}"
    )

    # 2. Move facts
    _sparql_update(url, client,
        f"DELETE {{ ?fact <{PWG}aboutPerson> <{discard_uri}> }} "
        f"INSERT {{ ?fact <{PWG}aboutPerson> <{keep_uri}> }} "
        f"WHERE {{ ?fact <{PWG}aboutPerson> <{discard_uri}> }}"
    )

    # 3. Move meeting attendee links
    _sparql_update(url, client,
        f"DELETE {{ ?meeting <{PWG}meetingAttendee> <{discard_uri}> }} "
        f"INSERT {{ ?meeting <{PWG}meetingAttendee> <{keep_uri}> }} "
        f"WHERE {{ ?meeting <{PWG}meetingAttendee> <{discard_uri}> }}"
    )

    # 4. Move history entries
    _sparql_update(url, client,
        f"DELETE {{ ?entry <{PWG}aboutPerson> <{discard_uri}> }} "
        f"INSERT {{ ?entry <{PWG}aboutPerson> <{keep_uri}> }} "
        f"WHERE {{ ?entry a <{PWG}HistoryEntry> . "
        f"  ?entry <{PWG}aboutPerson> <{discard_uri}> }}"
    )

    # 5. Merge scalar properties — copy from discard where keep is missing
    scalar_props = [
        "displayName", "givenName", "familyName", "organization",
        "jobTitle", "relationship", "howWeMet", "notes", "birthday",
        "contactType", "lastContact",
    ]
    for prop in scalar_props:
        _sparql_update(url, client,
            f"INSERT {{ <{keep_uri}> <{PWG}{prop}> ?val }} "
            f"WHERE {{ "
            f"  <{discard_uri}> <{PWG}{prop}> ?val . "
            f"  FILTER NOT EXISTS {{ <{keep_uri}> <{PWG}{prop}> ?existing }} "
            f"}}"
        )

    # 6. Mark discard as merged
    _sparql_update(url, client,
        f"INSERT DATA {{ "
        f"  <{discard_uri}> <{PWG}mergedInto> <{keep_uri}> . "
        f'  <{discard_uri}> <{PWG}mergedAt> "{now}"^^<http://www.w3.org/2001/XMLSchema#dateTime> '
        f"}}"
    )

    # 7. Remove discard's type triple (no longer a live Person)
    _sparql_update(url, client,
        f"DELETE DATA {{ <{discard_uri}> a <{PWG}Person> }}"
    )

    logger.info("Oxigraph merge: %s → %s", discard_uri, keep_uri)


def _merge_qdrant(
    qdrant_url: str, collection: str, keep_uri: str, discard_uri: str,
) -> None:
    """Merge Qdrant points: update canonical payload, delete duplicate point."""
    try:
        from qdrant_client import QdrantClient
    except ImportError:
        logger.warning("qdrant-client not installed — skipping Qdrant merge")
        return

    client = QdrantClient(url=qdrant_url, timeout=30)
    keep_point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, keep_uri))
    discard_point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, discard_uri))

    try:
        keep_points = client.retrieve(
            collection_name=collection, ids=[keep_point_id], with_payload=True,
        )
        discard_points = client.retrieve(
            collection_name=collection, ids=[discard_point_id], with_payload=True,
        )
    except Exception as exc:
        logger.warning("Qdrant retrieve failed: %s", exc)
        return

    if not discard_points:
        logger.info("Qdrant: discard point %s not found, nothing to merge", discard_point_id)
        return

    discard_payload = discard_points[0].payload or {}

    if keep_points:
        keep_payload = keep_points[0].payload or {}
        # Merge list fields (union)
        for list_field in ("phones", "emails"):
            existing = set(keep_payload.get(list_field, []))
            incoming = set(discard_payload.get(list_field, []))
            merged = sorted(existing | incoming)
            if merged:
                keep_payload[list_field] = merged

        # Merge scalar fields (keep existing, fill gaps)
        for scalar_field in ("organization", "job_title", "given_name", "family_name",
                             "icloud_uid", "last_contact", "last_contact_ts"):
            if not keep_payload.get(scalar_field) and discard_payload.get(scalar_field):
                keep_payload[scalar_field] = discard_payload[scalar_field]

        keep_payload["updated_at"] = datetime.now(timezone.utc).isoformat()

        client.set_payload(
            collection_name=collection,
            payload=keep_payload,
            points=[keep_point_id],
        )

    # Delete the discard point
    client.delete(
        collection_name=collection,
        points_selector=[discard_point_id],
    )
    logger.info("Qdrant merge: %s → %s (deleted %s)", discard_point_id, keep_point_id, discard_point_id)


# ── Main orchestrator ────────────────────────────────────────────────────────

class BatchResolver:
    """Batch duplicate detection and merge for person nodes."""

    def __init__(
        self,
        oxigraph_url: str = "http://localhost:7878",
        qdrant_url: str = "http://localhost:6333",
        qdrant_collection: str = "people",
        config: Optional[Dict[str, Any]] = None,
    ):
        self.oxigraph_url = oxigraph_url.rstrip("/")
        self.qdrant_url = qdrant_url.rstrip("/")
        self.qdrant_collection = qdrant_collection
        self.config = {**DEFAULT_CONFIG, **(config or {})}
        self._client = httpx.Client(timeout=60.0)

    def detect(self) -> ResolverReport:
        """Run all detection strategies and return a report."""
        persons = _fetch_all_persons(self.oxigraph_url, self._client, self.config)
        logger.info("Loaded %d active person nodes from Oxigraph", len(persons))

        all_matches: List[DuplicateMatch] = []
        all_matches.extend(detect_exact_name_matches(persons, self.config))
        all_matches.extend(detect_email_matches(persons, self.config))
        all_matches.extend(detect_phone_matches(persons, self.config))
        all_matches.extend(detect_fuzzy_name_matches(persons, self.config))
        all_matches.extend(detect_name_subset_matches(persons, self.config))

        auto, review = consolidate_matches(all_matches, self.config)

        # BW-2 correction loop: honour operator merge/distinct decisions from
        # duplicates.yaml. distinct = permanent never-merge block; merge =
        # forced union. Shared contract with the CM044 review page.
        decisions = load_duplicate_decisions(self.config.get("corrections_dir", ""))
        if decisions["merge_groups"] or decisions["distinct_pairs"]:
            def _user_match(ua: str, na: str, ub: str, nb: str) -> DuplicateMatch:
                return DuplicateMatch(
                    uri_a=ua, name_a=na, uri_b=ub, name_b=nb,
                    confidence=1.0, strategy="user_decision",
                    details="Operator marked these as the same person",
                )
            auto, review = apply_user_decisions(
                auto, review, persons, decisions, match_factory=_user_match,
            )

        report = ResolverReport(total_persons=len(persons))

        # Build merge actions for auto-merge candidates
        seen_uris: Set[str] = set()
        for m in auto:
            # Skip if either URI is already involved in a merge this run
            if m.uri_a in seen_uris or m.uri_b in seen_uris:
                review.append(m)
                continue

            keep, discard = pick_canonical(persons, m.uri_a, m.uri_b)
            report.auto_merges.append(MergeAction(
                keep_uri=keep,
                keep_name=persons[keep].display_name,
                discard_uri=discard,
                discard_name=persons[discard].display_name,
                confidence=m.confidence,
                strategy=m.strategy,
                details=m.details,
            ))
            seen_uris.add(m.uri_a)
            seen_uris.add(m.uri_b)

        report.needs_review = review
        report.duplicate_groups = len(report.auto_merges) + len(review)

        return report

    def execute(self, report: ResolverReport, backup_dir: str = "./backups") -> None:
        """Execute all auto-merge actions in the report."""
        if not report.auto_merges:
            logger.info("Nothing to merge")
            return

        # Backup all affected URIs
        all_uris = []
        for action in report.auto_merges:
            all_uris.extend([action.keep_uri, action.discard_uri])

        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        backup_path = os.path.join(backup_dir, f"merge_backup_{timestamp}.trig")
        _backup_triples(self.oxigraph_url, self._client, all_uris, backup_path)

        for action in report.auto_merges:
            logger.info(
                "Merging: %s (%s) → %s (%s) [%s, conf=%.2f]",
                action.discard_name, action.discard_uri,
                action.keep_name, action.keep_uri,
                action.strategy, action.confidence,
            )
            _merge_oxigraph(
                self.oxigraph_url, self._client,
                action.keep_uri, action.discard_uri,
            )
            _merge_qdrant(
                self.qdrant_url, self.qdrant_collection,
                action.keep_uri, action.discard_uri,
            )
            action.executed = True

    def converge(
        self,
        max_rounds: int = 10,
        backup_dir: str = "./backups",
        dry_run: bool = False,
    ) -> List[ResolverReport]:
        """Whole-graph consolidation to a fixpoint.

        ``detect()`` is already a whole-graph pass, but it merges each URI at
        most once per run (the ``seen_uris`` guard in detect()), so a cluster
        of 3+ nodes for the same person only partially collapses in a single
        round -- the remainder spills to ``needs_review``. The under-merge seen
        on a one-shot install is that gap: cross-source twins that never shared
        an incremental batch are only reconciled by a whole-graph pass, and a
        single pass leaves transitive 3+ clusters half-merged.

        Running detect()->execute() repeatedly closes it: after each round the
        merged-away nodes drop out (``_merge_oxigraph`` writes ``mergedInto``
        and removes their Person type, so detect()'s filter skips them) and the
        surviving node inherits their identifiers (step 1 of the merge), so the
        next round picks up the transitive matches. The loop terminates when a
        round yields zero auto-merges -- the fixpoint.

        This is PURE ORCHESTRATION over the existing detect/execute. It adds NO
        new rule, threshold, or flag and changes no individual merge decision
        (the BW-2 hard-conflict veto and duplicates.yaml decisions still apply
        unchanged, every round). It only ensures the existing decisions are
        applied across the WHOLE graph after all sources have hydrated, instead
        of per-source / per-batch only.

        Returns the per-round reports (round 0 first). With ``dry_run`` it runs
        a single detect() and does not execute, so a caller can preview the
        first round's auto-merges without mutating the graph.
        """
        rounds: List[ResolverReport] = []
        if dry_run:
            rounds.append(self.detect())
            return rounds
        for i in range(max_rounds):
            report = self.detect()
            rounds.append(report)
            n = len(report.auto_merges)
            logger.info(
                "Converge round %d: %d auto-merge(s), %d need review (of %d persons)",
                i + 1, n, len(report.needs_review), report.total_persons,
            )
            if n == 0:
                break
            self.execute(report, backup_dir=backup_dir)
        else:
            logger.warning(
                "Converge hit max_rounds=%d without a fixpoint; remaining "
                "auto-merges left for the next run / review", max_rounds,
            )
        return rounds

    def close(self) -> None:
        self._client.close()


# ── Report formatting ────────────────────────────────────────────────────────

def format_report_yaml(report: ResolverReport) -> str:
    """Format the report as YAML-like text for human review."""
    lines = [
        "# Identity Resolver — Dry Run Report",
        f"# Generated: {datetime.now(timezone.utc).isoformat()}",
        "",
        f"total_persons: {report.total_persons}",
        f"duplicate_groups: {report.duplicate_groups}",
        f"auto_merge_count: {len(report.auto_merges)}",
        f"needs_review_count: {len(report.needs_review)}",
        "",
    ]

    if report.auto_merges:
        lines.append("auto_merges:")
        for i, action in enumerate(report.auto_merges, 1):
            lines.extend([
                f"  - index: {i}",
                f"    strategy: {action.strategy}",
                f"    confidence: {action.confidence:.2f}",
                f"    details: {action.details}",
                f"    keep:",
                f"      uri: {action.keep_uri}",
                f"      name: {action.keep_name!r}",
                f"    discard:",
                f"      uri: {action.discard_uri}",
                f"      name: {action.discard_name!r}",
                f"    executed: {action.executed}",
                "",
            ])

    if report.needs_review:
        lines.append("needs_review:")
        for i, m in enumerate(report.needs_review, 1):
            lines.extend([
                f"  - index: {i}",
                f"    strategy: {m.strategy}",
                f"    confidence: {m.confidence:.2f}",
                f"    details: {m.details}",
                f"    person_a:",
                f"      uri: {m.uri_a}",
                f"      name: {m.name_a!r}",
                f"    person_b:",
                f"      uri: {m.uri_b}",
                f"      name: {m.name_b!r}",
                "",
            ])

    return "\n".join(lines)


# ── CLI ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Batch identity resolver — detect and merge duplicate person nodes",
    )
    parser.add_argument(
        "--dry-run", action="store_true", default=True,
        help="Show what would be merged without executing (default)",
    )
    parser.add_argument(
        "--execute", action="store_true",
        help="Execute merges (overrides --dry-run)",
    )
    parser.add_argument(
        "--threshold", type=float, default=None,
        help="Auto-merge confidence threshold (default: 0.8)",
    )
    parser.add_argument(
        "--oxigraph-url", default=os.environ.get("OXIGRAPH_URL", "http://localhost:7878"),
        help="Oxigraph SPARQL endpoint URL",
    )
    parser.add_argument(
        "--qdrant-url", default=os.environ.get("QDRANT_URL", "http://localhost:6333"),
        help="Qdrant HTTP endpoint URL",
    )
    parser.add_argument(
        "--qdrant-collection", default=os.environ.get("QDRANT_COLLECTION", "people"),
        help="Qdrant collection name",
    )
    parser.add_argument(
        "--output", default="resolver_dry_run.yaml.preview",
        help="Output file for dry run report",
    )
    parser.add_argument(
        "--backup-dir", default="./backups",
        help="Directory for backup files before merge",
    )
    parser.add_argument(
        "--exclude", type=str, default="",
        help="Comma-separated list of 1-based indices to exclude from execution (e.g. '12,13,15')",
    )
    parser.add_argument(
        "--converge", action="store_true",
        help="Whole-graph consolidation: loop detect+merge to a fixpoint so "
             "transitive 3+ node clusters fully collapse (run once after all "
             "sources have hydrated). Requires --execute. Pure orchestration: "
             "changes no merge rule or threshold.",
    )
    parser.add_argument(
        "--max-rounds", type=int, default=10,
        help="Safety cap on --converge rounds (default 10)",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Enable verbose logging",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
    )

    config = dict(DEFAULT_CONFIG)
    if args.threshold is not None:
        config["auto_merge_threshold"] = args.threshold

    resolver = BatchResolver(
        oxigraph_url=args.oxigraph_url,
        qdrant_url=args.qdrant_url,
        qdrant_collection=args.qdrant_collection,
        config=config,
    )

    try:
        # Whole-graph convergence path: loop to a fixpoint, then report the
        # final round. Used by the post-hydrate install pass so transitive
        # clusters collapse fully rather than spilling to review.
        if args.converge and args.execute:
            rounds = resolver.converge(
                max_rounds=args.max_rounds, backup_dir=args.backup_dir,
            )
            total_merged = sum(len(r.auto_merges) for r in rounds)
            report = rounds[-1]
            print(f"\n{'=' * 70}")
            print("IDENTITY RESOLVER - WHOLE-GRAPH CONVERGENCE")
            print(f"{'=' * 70}")
            print(f"Rounds run:        {len(rounds)}")
            print(f"Total merged:      {total_merged}")
            print(f"Final persons:     {report.total_persons}")
            print(f"Remaining review:  {len(report.needs_review)}")
            yaml_report = format_report_yaml(report)
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(yaml_report)
            print(f"Report written to {args.output}")
            print(f"\n{'=' * 70}")
            return

        report = resolver.detect()

        print(f"\n{'=' * 70}")
        print("IDENTITY RESOLVER REPORT")
        print(f"{'=' * 70}")
        print(f"Total persons:     {report.total_persons}")
        print(f"Duplicate groups:  {report.duplicate_groups}")
        print(f"Auto-merge (≥{config['auto_merge_threshold']}):  {len(report.auto_merges)}")
        print(f"Needs review:      {len(report.needs_review)}")

        if report.auto_merges:
            print(f"\n{'─' * 70}")
            print("AUTO-MERGE CANDIDATES:")
            for i, action in enumerate(report.auto_merges[:20], 1):
                print(f"\n  {i}. [{action.strategy}] conf={action.confidence:.2f}")
                print(f"     KEEP:    {action.keep_name!r} ({action.keep_uri})")
                print(f"     DISCARD: {action.discard_name!r} ({action.discard_uri})")
                print(f"     Reason:  {action.details}")
            if len(report.auto_merges) > 20:
                print(f"\n  ... and {len(report.auto_merges) - 20} more")

        if report.needs_review:
            print(f"\n{'─' * 70}")
            print("NEEDS REVIEW:")
            for i, m in enumerate(report.needs_review[:10], 1):
                print(f"\n  {i}. [{m.strategy}] conf={m.confidence:.2f}")
                print(f"     A: {m.name_a!r} ({m.uri_a})")
                print(f"     B: {m.name_b!r} ({m.uri_b})")
                print(f"     Reason: {m.details}")
            if len(report.needs_review) > 10:
                print(f"\n  ... and {len(report.needs_review) - 10} more")

        print(f"\n{'=' * 70}")

        # Write YAML report
        yaml_report = format_report_yaml(report)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(yaml_report)
        print(f"Report written to {args.output}")

        if args.execute and not args.dry_run:
            # --execute explicitly set, --dry-run is just the default
            pass

        if args.execute:
            # Filter out excluded indices (1-based) before executing
            if args.exclude:
                exclude_set = {int(x.strip()) for x in args.exclude.split(",") if x.strip()}
                original_count = len(report.auto_merges)
                report.auto_merges = [
                    action for i, action in enumerate(report.auto_merges, 1)
                    if i not in exclude_set
                ]
                print(f"\nExcluded {original_count - len(report.auto_merges)} merges (indices: {sorted(exclude_set)})")
            print(f"\nExecuting {len(report.auto_merges)} merges...")
            resolver.execute(report, backup_dir=args.backup_dir)
            print("Done. Merges executed successfully.")
            # Rewrite report with executed status
            yaml_report = format_report_yaml(report)
            with open(args.output, "w", encoding="utf-8") as f:
                f.write(yaml_report)
        else:
            print("\nDry run — no changes made. Use --execute to apply merges.")

    finally:
        resolver.close()


if __name__ == "__main__":
    main()
