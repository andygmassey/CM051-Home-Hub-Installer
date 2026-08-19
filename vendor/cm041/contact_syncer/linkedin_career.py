"""LinkedIn Career Data Importer — reads Positions.csv,
Endorsement_Received_Info.csv, and Recommendations_Received.csv from a
LinkedIn GDPR export and writes career facts + relationship signals into
the PWG knowledge graph (Oxigraph).

For Positions.csv:
  - Each position becomes a PersonFact about the user (Andy).
  - "[user] was [title] at [company] from [date] to [date]"

For Endorsement_Received_Info.csv:
  - Each endorser is resolved against the people graph.
  - Matched: endorsement stored as a relationship signal.
  - New: person node created, then endorsement signal stored.

For Recommendations_Received.csv:
  - Recommender resolved against people graph.
  - Recommendation text stored as a PersonFact linked to the recommender.

Usage:
    python -m contact_syncer.linkedin_career \
        --dir /path/to/linkedin/export/ \
        [--dry-run] [--limit N] [--verbose]

Idempotent: uses deterministic URIs derived from content hashes.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx

# Add parent directory so identity_resolver is importable
_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from contact_syncer import config
from contact_syncer import privacy_model as _pm
from identity_resolver.models import PersonIdentity
from identity_resolver.resolver import IdentityResolver

try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import PointStruct

    HAS_QDRANT = True
except ImportError:
    HAS_QDRANT = False


# ── Oxigraph helpers ────────────────────────────────────────────────


def _sparql_update(oxigraph_url: str, sparql: str) -> None:
    """Execute a SPARQL UPDATE against Oxigraph."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=30.0, transport=transport) as client:
        resp = client.post(
            f"{oxigraph_url}/update",
            content=sparql,
            headers={"Content-Type": "application/sparql-update"},
        )
        resp.raise_for_status()


def _escape(s: str) -> str:
    """Escape a string for SPARQL literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _deterministic_id(seed: str) -> str:
    """Generate a short deterministic ID from a seed string."""
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:12]


# ── Embedding (reused from linkedin_connections) ────────────────────


def embed_text(
    ollama_url: str, text: str, model: str = "nomic-embed-text"
) -> List[float]:
    """Get embedding vector from Ollama."""
    transport = httpx.HTTPTransport(proxy=None)
    with httpx.Client(timeout=60.0, transport=transport) as client:
        resp = client.post(
            f"{ollama_url}/api/embed",
            json={"model": model, "input": text},
        )
        resp.raise_for_status()
        data = resp.json()
    embs = data.get("embeddings") or [data.get("embedding")]
    return embs[0]


# ── CSV parsing ──────────────────────────────────────────────────────


def parse_positions_csv(csv_path: str) -> List[Dict[str, str]]:
    """Parse LinkedIn Positions.csv.

    Columns: Company Name, Title, Description, Location, Started On, Finished On
    """
    rows = []
    with open(csv_path, "r", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            # Skip completely empty rows
            if not row.get("Company Name") and not row.get("Title"):
                continue
            rows.append(row)
    return rows


def parse_endorsements_csv(csv_path: str) -> List[Dict[str, str]]:
    """Parse LinkedIn Endorsement_Received_Info.csv.

    Columns: Endorsement Date, Skill Name, Endorser First Name,
             Endorser Last Name, Endorser Public Url, Endorsement Status
    """
    rows = []
    with open(csv_path, "r", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            if not row.get("Endorser First Name") and not row.get("Endorser Last Name"):
                continue
            rows.append(row)
    return rows


def parse_recommendations_csv(csv_path: str) -> List[Dict[str, str]]:
    """Parse LinkedIn Recommendations_Received.csv.

    Columns: First Name, Last Name, Company, Job Title, Text,
             Creation Date, Status
    """
    rows = []
    with open(csv_path, "r", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            if not row.get("First Name") and not row.get("Last Name"):
                continue
            rows.append(row)
    return rows


# ── Positions → Oxigraph (user career facts) ────────────────────────


def _format_date(raw: str) -> str:
    """Convert LinkedIn date like 'Jan 2023' to '2023-01'."""
    if not raw or not raw.strip():
        return ""
    raw = raw.strip()
    try:
        dt = datetime.strptime(raw, "%b %Y")
        return dt.strftime("%Y-%m")
    except ValueError:
        return raw


def import_positions(
    csv_path: str,
    *,
    dry_run: bool = False,
    limit: Optional[int] = None,
    verbose: bool = False,
    user_name: str = "The user",
) -> Dict[str, int]:
    """Import Positions.csv as career facts about the user."""
    rows = parse_positions_csv(csv_path)
    if limit:
        rows = rows[:limit]

    counts = {"total": len(rows), "written": 0, "skipped": 0, "errors": 0}
    user_uri = f"https://pwg.dev/ontology#user_{config.USER_ID}"
    now = datetime.now(timezone.utc).isoformat()

    print(f"Importing {len(rows)} positions...")

    for i, row in enumerate(rows, 1):
        company = (row.get("Company Name") or "").strip()
        title = (row.get("Title") or "").strip()
        description = (row.get("Description") or "").strip()
        location = (row.get("Location") or "").strip()
        started = _format_date(row.get("Started On") or "")
        finished = _format_date(row.get("Finished On") or "")

        if not company and not title:
            counts["skipped"] += 1
            continue

        # Build human-readable fact
        date_range = ""
        if started and finished:
            date_range = f" from {started} to {finished}"
        elif started:
            date_range = f" from {started} to present"

        fact_text = f"{user_name} was {title} at {company}{date_range}"
        if location:
            fact_text += f" ({location})"

        if verbose:
            print(f"  [{i}/{len(rows)}] {fact_text}")

        if dry_run:
            counts["written"] += 1
            continue

        try:
            # Deterministic fact URI based on company + title + start date
            fact_id = _deterministic_id(f"position:{company}:{title}:{started}")
            fact_uri = f"https://pwg.dev/ontology#fact_{fact_id}"

            triples = [
                f"<{fact_uri}> a pwg:PersonFact",
                f'<{fact_uri}> pwg:factType "career_position"',
                f'<{fact_uri}> pwg:factText "{_escape(fact_text)}"',
                f"<{fact_uri}> pwg:aboutPerson <{user_uri}>",
                f'<{fact_uri}> pwg:createdAt "{now}"^^xsd:dateTime',
                f'<{fact_uri}> pwg:source "linkedin_positions"',
                f'<{fact_uri}> pwg:privacyLevel '
                f'"{_pm.level_for(rdf_type="PersonFact", source="linkedin_positions")}"',
            ]
            if company:
                triples.append(f'<{fact_uri}> pwg:organization "{_escape(company)}"')
            if title:
                triples.append(f'<{fact_uri}> pwg:jobTitle "{_escape(title)}"')
            if started:
                triples.append(f'<{fact_uri}> pwg:startDate "{started}"')
            if finished:
                triples.append(f'<{fact_uri}> pwg:endDate "{finished}"')
            if location:
                triples.append(f'<{fact_uri}> pwg:location "{_escape(location)}"')
            if description:
                triples.append(
                    f'<{fact_uri}> pwg:description "{_escape(description)}"'
                )

            sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
            )
            _sparql_update(config.OXIGRAPH_URL, sparql)
            counts["written"] += 1

        except Exception as e:
            if verbose:
                print(f"    ERROR: {e}")
            counts["errors"] += 1

    print(
        f"  Positions: {counts['written']} written, "
        f"{counts['skipped']} skipped, {counts['errors']} errors "
        f"(of {counts['total']} total)"
    )
    return counts


# ── Endorsements → Oxigraph (relationship signals) ──────────────────


def _create_person_from_endorser(
    oxigraph_url: str,
    person_uri: str,
    person_id: str,
    display_name: str,
    given_name: str,
    family_name: str,
    linkedin_url: str,
    user_id: str,
) -> None:
    """Create a minimal Person node from an endorser."""
    now = datetime.now(timezone.utc).isoformat()

    triples = [
        f"<{person_uri}> a pwg:Person",
        f'<{person_uri}> pwg:displayName "{_escape(display_name)}"',
        f'<{person_uri}> pwg:contactType "person"',
        f'<{person_uri}> pwg:privacyLevel "{config.DEFAULT_PRIVACY_LEVEL}"',
        f'<{person_uri}> pwg:createdAt "{now}"^^xsd:dateTime',
    ]
    if given_name:
        triples.append(f'<{person_uri}> pwg:givenName "{_escape(given_name)}"')
    if family_name:
        triples.append(f'<{person_uri}> pwg:familyName "{_escape(family_name)}"')
    if user_id:
        triples.append(
            f"<{person_uri}> pwg:belongsToUser <https://pwg.dev/ontology#user_{user_id}>"
        )

    # LinkedIn URL identifier
    if linkedin_url:
        id_uri = f"https://pwg.dev/ontology#id_{person_id}_linkedin"
        triples.append(f"<{person_uri}> pwg:hasIdentifier <{id_uri}>")
        triples.append(f"<{id_uri}> a pwg:PersonIdentifier")
        triples.append(f'<{id_uri}> pwg:identifierType "linkedin_url"')
        triples.append(f'<{id_uri}> pwg:identifierValue "{_escape(linkedin_url)}"')

    sparql = (
        "PREFIX pwg: <https://pwg.dev/ontology#>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
    )
    _sparql_update(oxigraph_url, sparql)


def import_endorsements(
    csv_path: str,
    *,
    dry_run: bool = False,
    limit: Optional[int] = None,
    verbose: bool = False,
) -> Dict[str, int]:
    """Import Endorsement_Received_Info.csv as relationship signals."""
    rows = parse_endorsements_csv(csv_path)
    if limit:
        rows = rows[:limit]

    resolver = IdentityResolver(
        oxigraph_url=config.OXIGRAPH_URL,
        default_country_code=config.DEFAULT_COUNTRY_CODE,
    )

    counts = {
        "total": len(rows),
        "matched": 0,
        "created": 0,
        "skipped": 0,
        "errors": 0,
        "endorsements_written": 0,
    }
    user_uri = f"https://pwg.dev/ontology#user_{config.USER_ID}"
    now = datetime.now(timezone.utc).isoformat()

    # De-duplicate: group endorsements by person to avoid resolving the
    # same endorser multiple times.
    endorser_groups: Dict[str, List[Dict[str, str]]] = {}
    for row in rows:
        first = (row.get("Endorser First Name") or "").strip()
        last = (row.get("Endorser Last Name") or "").strip()
        key = f"{first}|{last}"
        endorser_groups.setdefault(key, []).append(row)

    print(
        f"Importing {len(rows)} endorsements from "
        f"{len(endorser_groups)} unique endorsers..."
    )

    for group_idx, (key, group_rows) in enumerate(endorser_groups.items(), 1):
        first, last = key.split("|", 1)
        display_name = f"{first} {last}".strip()
        if not display_name:
            counts["skipped"] += len(group_rows)
            continue

        # Use first row for LinkedIn URL
        linkedin_url = (group_rows[0].get("Endorser Public Url") or "").strip()
        if linkedin_url and not linkedin_url.startswith("http"):
            linkedin_url = f"https://{linkedin_url}"

        if verbose:
            skills = [r.get("Skill Name", "") for r in group_rows]
            print(
                f"  [{group_idx}/{len(endorser_groups)}] {display_name} "
                f"({len(group_rows)} skills: {', '.join(skills[:3])}{'...' if len(skills) > 3 else ''})"
            )

        try:
            identity = PersonIdentity(
                display_name=display_name,
                given_name=first or None,
                family_name=last or None,
                linkedin_url=linkedin_url or None,
            )

            match = resolver.resolve(identity, use_fuzzy=True)

            if match and match.person_uri and match.match_type != "new":
                person_uri = match.person_uri
                person_id = (
                    person_uri.split("person_")[-1]
                    if "person_" in person_uri
                    else _deterministic_id(f"endorser:{display_name}")
                )
                if verbose:
                    print(
                        f"    MATCH ({match.match_type}, {match.confidence:.2f})"
                    )
                counts["matched"] += 1
            else:
                # New person — create node
                person_id = _deterministic_id(
                    f"endorser:{linkedin_url or display_name}"
                )
                person_uri = f"https://pwg.dev/ontology#person_{person_id}"

                if verbose:
                    print(f"    NEW → {person_uri}")

                if not dry_run:
                    _create_person_from_endorser(
                        config.OXIGRAPH_URL,
                        person_uri,
                        person_id,
                        display_name,
                        first,
                        last,
                        linkedin_url,
                        config.USER_ID,
                    )
                counts["created"] += 1

            # Write each endorsement as a relationship signal
            for row in group_rows:
                skill = (row.get("Skill Name") or "").strip()
                date_str = (row.get("Endorsement Date") or "").strip()
                status = (row.get("Endorsement Status") or "").strip()

                if not skill:
                    counts["skipped"] += 1
                    continue

                endorsement_id = _deterministic_id(
                    f"endorsement:{display_name}:{skill}"
                )
                endorsement_uri = (
                    f"https://pwg.dev/ontology#endorsement_{endorsement_id}"
                )

                if dry_run:
                    counts["endorsements_written"] += 1
                    continue

                triples = [
                    f"<{endorsement_uri}> a pwg:RelationshipSignal",
                    f'<{endorsement_uri}> pwg:signalType "linkedin_endorsement"',
                    f'<{endorsement_uri}> pwg:privacyLevel '
                    f'"{_pm.level_for(rdf_type="RelationshipSignal", source="linkedin_endorsement")}"',
                    f'<{endorsement_uri}> pwg:skillName "{_escape(skill)}"',
                    f"<{endorsement_uri}> pwg:fromPerson <{person_uri}>",
                    f"<{endorsement_uri}> pwg:aboutPerson <{user_uri}>",
                    f'<{endorsement_uri}> pwg:source "linkedin_endorsements"',
                    f'<{endorsement_uri}> pwg:createdAt "{now}"^^xsd:dateTime',
                ]
                if date_str:
                    triples.append(
                        f'<{endorsement_uri}> pwg:signalDate "{_escape(date_str)}"'
                    )
                if status:
                    triples.append(
                        f'<{endorsement_uri}> pwg:status "{_escape(status)}"'
                    )

                sparql = (
                    "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                    "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                    "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
                )
                _sparql_update(config.OXIGRAPH_URL, sparql)
                counts["endorsements_written"] += 1

        except Exception as e:
            if verbose:
                print(f"    ERROR: {e}")
            counts["errors"] += 1

    print(
        f"  Endorsements: {counts['matched']} matched, "
        f"{counts['created']} created, {counts['endorsements_written']} signals written, "
        f"{counts['skipped']} skipped, {counts['errors']} errors "
        f"(of {counts['total']} total)"
    )
    return counts


# ── Recommendations → Oxigraph (PersonFacts) ────────────────────────


def import_recommendations(
    csv_path: str,
    *,
    dry_run: bool = False,
    limit: Optional[int] = None,
    verbose: bool = False,
) -> Dict[str, int]:
    """Import Recommendations_Received.csv as PersonFacts."""
    rows = parse_recommendations_csv(csv_path)
    if limit:
        rows = rows[:limit]

    resolver = IdentityResolver(
        oxigraph_url=config.OXIGRAPH_URL,
        default_country_code=config.DEFAULT_COUNTRY_CODE,
    )

    counts = {
        "total": len(rows),
        "matched": 0,
        "created": 0,
        "skipped": 0,
        "errors": 0,
        "recommendations_written": 0,
    }
    user_uri = f"https://pwg.dev/ontology#user_{config.USER_ID}"
    now = datetime.now(timezone.utc).isoformat()

    print(f"Importing {len(rows)} recommendations...")

    for i, row in enumerate(rows, 1):
        first = (row.get("First Name") or "").strip()
        last = (row.get("Last Name") or "").strip()
        display_name = f"{first} {last}".strip()
        company = (row.get("Company") or "").strip()
        job_title = (row.get("Job Title") or "").strip()
        text = (row.get("Text") or "").strip()
        creation_date = (row.get("Creation Date") or "").strip()
        status = (row.get("Status") or "").strip()

        if not display_name:
            counts["skipped"] += 1
            continue

        if not text:
            counts["skipped"] += 1
            if verbose:
                print(f"  [{i}/{len(rows)}] {display_name} — no text, skipping")
            continue

        if verbose:
            preview = text[:80] + "..." if len(text) > 80 else text
            print(f"  [{i}/{len(rows)}] {display_name} ({company}): {preview}")

        try:
            identity = PersonIdentity(
                display_name=display_name,
                given_name=first or None,
                family_name=last or None,
                organization=company or None,
            )

            match = resolver.resolve(identity, use_fuzzy=True)

            if match and match.person_uri and match.match_type != "new":
                person_uri = match.person_uri
                if verbose:
                    print(
                        f"    MATCH ({match.match_type}, {match.confidence:.2f})"
                    )
                counts["matched"] += 1
            else:
                # New person — create minimal node
                person_id = _deterministic_id(
                    f"recommender:{display_name}:{company}"
                )
                person_uri = f"https://pwg.dev/ontology#person_{person_id}"

                if verbose:
                    print(f"    NEW → {person_uri}")

                if not dry_run:
                    _create_person_from_endorser(
                        config.OXIGRAPH_URL,
                        person_uri,
                        person_id,
                        display_name,
                        first,
                        last,
                        "",  # no LinkedIn URL in recommendations CSV
                        config.USER_ID,
                    )
                    # Also write org + title if available
                    if company or job_title:
                        extra_triples = []
                        if company:
                            extra_triples.append(
                                f'<{person_uri}> pwg:organization "{_escape(company)}"'
                            )
                        if job_title:
                            extra_triples.append(
                                f'<{person_uri}> pwg:jobTitle "{_escape(job_title)}"'
                            )
                        sparql = (
                            "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                            "INSERT DATA {\n  "
                            + " .\n  ".join(extra_triples)
                            + " .\n}"
                        )
                        _sparql_update(config.OXIGRAPH_URL, sparql)
                counts["created"] += 1

            # Write the recommendation as a PersonFact
            rec_id = _deterministic_id(f"recommendation:{display_name}:{text[:50]}")
            rec_uri = f"https://pwg.dev/ontology#fact_{rec_id}"

            if dry_run:
                counts["recommendations_written"] += 1
                continue

            triples = [
                f"<{rec_uri}> a pwg:PersonFact",
                f'<{rec_uri}> pwg:factType "linkedin_recommendation"',
                f'<{rec_uri}> pwg:privacyLevel '
                f'"{_pm.level_for(rdf_type="PersonFact", source="linkedin_recommendation")}"',
                f'<{rec_uri}> pwg:factText "{_escape(text)}"',
                f"<{rec_uri}> pwg:aboutPerson <{user_uri}>",
                f"<{rec_uri}> pwg:fromPerson <{person_uri}>",
                f'<{rec_uri}> pwg:source "linkedin_recommendations"',
                f'<{rec_uri}> pwg:createdAt "{now}"^^xsd:dateTime',
            ]
            if creation_date:
                triples.append(
                    f'<{rec_uri}> pwg:signalDate "{_escape(creation_date)}"'
                )

            sparql = (
                "PREFIX pwg: <https://pwg.dev/ontology#>\n"
                "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
                "INSERT DATA {\n  " + " .\n  ".join(triples) + " .\n}"
            )
            _sparql_update(config.OXIGRAPH_URL, sparql)
            counts["recommendations_written"] += 1

        except Exception as e:
            if verbose:
                print(f"    ERROR: {e}")
            counts["errors"] += 1

    print(
        f"  Recommendations: {counts['matched']} matched, "
        f"{counts['created']} created, "
        f"{counts['recommendations_written']} written, "
        f"{counts['skipped']} skipped, {counts['errors']} errors "
        f"(of {counts['total']} total)"
    )
    return counts


# ── Main orchestrator ────────────────────────────────────────────────


def import_career_data(
    export_dir: str,
    *,
    dry_run: bool = False,
    limit: Optional[int] = None,
    verbose: bool = False,
    user_name: str = "The user",
) -> Dict[str, Dict[str, int]]:
    """Import all career-related LinkedIn data from an export directory.

    Looks for: Positions.csv, Endorsement_Received_Info.csv,
    Recommendations_Received.csv
    """
    results = {}
    export_path = Path(export_dir)

    # Positions
    positions_csv = export_path / "Positions.csv"
    if positions_csv.is_file():
        results["positions"] = import_positions(
            str(positions_csv), dry_run=dry_run, limit=limit, verbose=verbose,
            user_name=user_name,
        )
    else:
        print(f"Positions.csv not found in {export_dir}, skipping.")

    # Endorsements
    endorsements_csv = export_path / "Endorsement_Received_Info.csv"
    if endorsements_csv.is_file():
        results["endorsements"] = import_endorsements(
            str(endorsements_csv), dry_run=dry_run, limit=limit, verbose=verbose
        )
    else:
        print(f"Endorsement_Received_Info.csv not found in {export_dir}, skipping.")

    # Recommendations
    recommendations_csv = export_path / "Recommendations_Received.csv"
    if recommendations_csv.is_file():
        results["recommendations"] = import_recommendations(
            str(recommendations_csv), dry_run=dry_run, limit=limit, verbose=verbose
        )
    else:
        print(f"Recommendations_Received.csv not found in {export_dir}, skipping.")

    # Summary
    print("\n=== Summary ===")
    for section, counts in results.items():
        print(f"  {section}: {counts}")

    return results


# ── CLI ──────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Import LinkedIn career data (positions, endorsements, "
        "recommendations) into PWG knowledge graph"
    )
    parser.add_argument(
        "--dir",
        type=str,
        required=True,
        help="Path to LinkedIn GDPR export directory",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse and resolve but don't write to Oxigraph",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Process only first N rows per file",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Print each item"
    )
    parser.add_argument(
        "--user-name", type=str, default="The user",
        help="Your name (used in career fact text)"
    )
    args = parser.parse_args()

    if not os.path.isdir(args.dir):
        print(f"Directory not found: {args.dir}", file=sys.stderr)
        return 1

    # Validate config
    if not config.OXIGRAPH_URL:
        print(
            "OXIGRAPH_URL not configured. Set in .env or environment.",
            file=sys.stderr,
        )
        return 1

    results = import_career_data(
        args.dir, dry_run=args.dry_run, limit=args.limit, verbose=args.verbose,
        user_name=args.user_name,
    )

    total_errors = sum(c.get("errors", 0) for c in results.values())
    return 0 if total_errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
