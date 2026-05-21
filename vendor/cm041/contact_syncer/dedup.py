"""Duplicate detection report generator for People Graph person nodes."""
from __future__ import annotations

import sys
import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

import httpx

# Add parent directory to sys.path so identity_resolver is importable
_PARENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PARENT_DIR not in sys.path:
    sys.path.insert(0, _PARENT_DIR)

from identity_resolver.normalise import _jaro_winkler  # type: ignore[import-untyped]


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class DedupMatch:
    """A pair of person nodes that may be duplicates."""

    person_a_uri: str
    person_a_name: str
    person_b_uri: str
    person_b_name: str
    reason: str


@dataclass
class DedupReport:
    """Results of a dedup detection pass."""

    definite: List[DedupMatch] = field(default_factory=list)
    probable: List[DedupMatch] = field(default_factory=list)

    @property
    def definite_count(self) -> int:
        return len(self.definite)

    @property
    def probable_count(self) -> int:
        return len(self.probable)


# ---------------------------------------------------------------------------
# Detector
# ---------------------------------------------------------------------------

class DedupDetector:
    """Detect duplicate person nodes in Oxigraph."""

    def __init__(self, oxigraph_url: str) -> None:
        self.oxigraph_url = oxigraph_url.rstrip("/")

    # -- helpers --------------------------------------------------------------

    def _sparql_query(self, query: str) -> List[Dict[str, str]]:
        """Execute a SPARQL SELECT and return list of binding dicts."""
        resp = httpx.post(
            f"{self.oxigraph_url}/query",
            content=query,
            headers={
                "Content-Type": "application/sparql-query",
                "Accept": "application/sparql-results+json",
            },
            timeout=60.0,
        )
        resp.raise_for_status()
        data = resp.json()
        results: List[Dict[str, str]] = []
        for binding in data.get("results", {}).get("bindings", []):
            row: Dict[str, str] = {}
            for var, info in binding.items():
                row[var] = info.get("value", "")
            results.append(row)
        return results

    def _get_all_persons(self) -> List[Dict[str, str]]:
        """Fetch all person nodes with their identifiers."""
        query = """
        PREFIX pwg: <https://pwg.dev/ontology#>
        SELECT ?person ?name ?org ?idType ?idValue WHERE {
            ?person a pwg:Person ;
                    pwg:displayName ?name .
            OPTIONAL { ?person pwg:organization ?org }
            OPTIONAL {
                ?person pwg:hasIdentifier ?id .
                ?id pwg:identifierType ?idType ;
                    pwg:identifierValue ?idValue .
            }
        }
        """
        return self._sparql_query(query)

    # -- public API -----------------------------------------------------------

    def detect(self) -> DedupReport:
        """Query all person nodes and run pairwise duplicate detection."""
        rows = self._get_all_persons()

        # Build per-person structures
        # person_uri -> { name, org, phones: set, emails: set, email_domains: set }
        persons: Dict[str, Dict] = {}
        for row in rows:
            uri = row["person"]
            if uri not in persons:
                persons[uri] = {
                    "name": row.get("name", ""),
                    "org": row.get("org", ""),
                    "phones": set(),
                    "emails": set(),
                    "email_domains": set(),
                }
            id_type = row.get("idType", "")
            id_value = row.get("idValue", "")
            if id_type == "phone" and id_value:
                persons[uri]["phones"].add(id_value)
            elif id_type == "email" and id_value:
                persons[uri]["emails"].add(id_value.lower())
                domain = id_value.lower().split("@")[-1] if "@" in id_value else ""
                if domain:
                    persons[uri]["email_domains"].add(domain)

        # Build reverse indexes for fast lookup
        phone_index: Dict[str, List[str]] = {}  # phone -> [person_uris]
        email_index: Dict[str, List[str]] = {}  # email -> [person_uris]
        for uri, info in persons.items():
            for phone in info["phones"]:
                phone_index.setdefault(phone, []).append(uri)
            for email in info["emails"]:
                email_index.setdefault(email, []).append(uri)

        report = DedupReport()
        seen_pairs: set = set()

        def _pair_key(a: str, b: str) -> Tuple[str, str]:
            return (min(a, b), max(a, b))

        # --- Definite duplicates: shared phone ---
        for phone, uris in phone_index.items():
            if len(uris) < 2:
                continue
            for i in range(len(uris)):
                for j in range(i + 1, len(uris)):
                    pk = _pair_key(uris[i], uris[j])
                    if pk not in seen_pairs:
                        seen_pairs.add(pk)
                        report.definite.append(
                            DedupMatch(
                                person_a_uri=uris[i],
                                person_a_name=persons[uris[i]]["name"],
                                person_b_uri=uris[j],
                                person_b_name=persons[uris[j]]["name"],
                                reason=f"shared phone {phone}",
                            )
                        )

        # --- Definite duplicates: shared email ---
        for email, uris in email_index.items():
            if len(uris) < 2:
                continue
            for i in range(len(uris)):
                for j in range(i + 1, len(uris)):
                    pk = _pair_key(uris[i], uris[j])
                    if pk not in seen_pairs:
                        seen_pairs.add(pk)
                        report.definite.append(
                            DedupMatch(
                                person_a_uri=uris[i],
                                person_a_name=persons[uris[i]]["name"],
                                person_b_uri=uris[j],
                                person_b_name=persons[uris[j]]["name"],
                                reason=f"shared email {email}",
                            )
                        )

        # --- Probable duplicates: fuzzy name + same org or shared email domain ---
        uri_list = list(persons.keys())
        for i in range(len(uri_list)):
            for j in range(i + 1, len(uri_list)):
                pk = _pair_key(uri_list[i], uri_list[j])
                if pk in seen_pairs:
                    continue
                a = persons[uri_list[i]]
                b = persons[uri_list[j]]
                name_a = a["name"]
                name_b = b["name"]
                if not name_a or not name_b:
                    continue
                similarity = _jaro_winkler(name_a.lower(), name_b.lower())
                if similarity <= 0.85:
                    continue

                # Same org?
                if a["org"] and b["org"] and a["org"].lower() == b["org"].lower():
                    seen_pairs.add(pk)
                    report.probable.append(
                        DedupMatch(
                            person_a_uri=uri_list[i],
                            person_a_name=name_a,
                            person_b_uri=uri_list[j],
                            person_b_name=name_b,
                            reason=f"fuzzy name ({similarity:.2f}) + same org '{a['org']}'",
                        )
                    )
                    continue

                # Shared email domain?
                shared_domains = a["email_domains"] & b["email_domains"]
                if shared_domains:
                    seen_pairs.add(pk)
                    report.probable.append(
                        DedupMatch(
                            person_a_uri=uri_list[i],
                            person_a_name=name_a,
                            person_b_uri=uri_list[j],
                            person_b_name=name_b,
                            reason=f"fuzzy name ({similarity:.2f}) + shared email domain {shared_domains.pop()}",
                        )
                    )

        return report


def print_report(report: DedupReport) -> None:
    """Print a formatted dedup report to stdout."""
    print("=" * 70)
    print("DUPLICATE DETECTION REPORT")
    print("=" * 70)

    if report.definite:
        print(f"\nDEFINITE DUPLICATES ({report.definite_count}):")
        print("-" * 50)
        for m in report.definite:
            print(f'  "{m.person_a_name}" ({m.person_a_uri})')
            print(f'    <-> "{m.person_b_name}" ({m.person_b_uri})')
            print(f"    Reason: {m.reason}")
            print()
    else:
        print("\nNo definite duplicates found.")

    if report.probable:
        print(f"\nPROBABLE DUPLICATES ({report.probable_count}):")
        print("-" * 50)
        for m in report.probable:
            print(f'  "{m.person_a_name}" ({m.person_a_uri})')
            print(f'    <-> "{m.person_b_name}" ({m.person_b_uri})')
            print(f"    Reason: {m.reason}")
            print()
    else:
        print("\nNo probable duplicates found.")

    print("-" * 70)
    print(
        f"Summary: {report.definite_count} definite, "
        f"{report.probable_count} probable duplicates."
    )
    print("=" * 70)
