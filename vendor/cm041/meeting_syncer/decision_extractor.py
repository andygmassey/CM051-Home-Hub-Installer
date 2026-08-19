"""Decision extractor -- promote decision-like facts into typed ``pwg:Decision`` nodes.

Why this exists
---------------
The People Graph already stores ``pwg:Meeting`` nodes carrying a
``pwg:meetingSummary`` literal and one ``pwg:meetingAttendee`` per
resolved participant (see ``meeting_syncer/syncer.py``). Decisions taken
in those meetings are buried inside the free-text summary -- the graph has
no first-class notion of "what did we decide". This module reads the
meeting summaries that already exist and promotes the decision-bearing
sentences into typed ``pwg:Decision`` nodes the assistant can recall when
the operator asks "what did we decide about X?".

Source assumption
-----------------
The ONLY source read here is the ``pwg:meetingSummary`` literal on existing
``pwg:Meeting`` nodes. No new ingestion is performed -- this is a pure
promotion pass over data the meeting syncer already wrote. If a richer
decision source lands later (e.g. a CM048 conversation "decisions" block),
add a second reader that yields the same ``ExtractedDecision`` shape and
feeds the same writer; the node shape and id rule below are the contract.

Node shape (namespace ``https://pwg.dev/ontology#`` -- the same NS as
``pwg:Meeting``/``pwg:Person`` so decisions are queryable alongside
meetings)::

    <pwg:decision_<id>> a pwg:Decision ;
        pwg:decisionId        "<id>" ;
        pwg:decisionSummary   "We will go with the Postgres backend" ;
        pwg:decisionDate      "2026-05-01"^^xsd:dateTime ;   # from the meeting
        pwg:decisionStatus    "active" ;                      # default; optional
        pwg:decisionSource    <pwg:meeting_<hash>> ;          # the source meeting
        pwg:decisionAbout     <pwg:person_<hash>> ;           # 0..n attendees
        pwg:createdAt         "<run-time>"^^xsd:dateTime .

Idempotency
-----------
``decisionId`` is a deterministic md5 over ``<source-meeting-uri>|<normalised
summary text>`` (first 12 hex chars), mirroring the ``_meeting_uri`` /
``contact_syncer`` stable-id pattern. The same decision re-extracted from the
same meeting on a later run produces the same URI, so the writer's
``INSERT DATA`` is a no-op on re-run (Oxigraph stores each triple once) -- no
duplicate nodes, no random uuid churn.
"""
from __future__ import annotations

import argparse
import hashlib
import logging
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, List, Optional

import httpx

logger = logging.getLogger(__name__)

PWG = "https://pwg.dev/ontology#"

# Cue phrases that mark a sentence as a decision. Lower-cased, word-boundary
# matched. Kept deliberately tight so the pass is high-precision (a wrong
# promotion is worse than a missed one -- the operator can always re-read the
# meeting summary). British English spellings included where relevant.
_DECISION_CUES = (
    "we decided",
    "we agreed",
    "we've decided",
    "we have decided",
    "it was decided",
    "it was agreed",
    "decision was",
    "the decision is",
    "decided to",
    "agreed to",
    "agreed that",
    "let's go with",
    "lets go with",
    "we will go with",
    "going with",
    "we'll go with",
    "we chose",
    "we settled on",
    "we're going to",
    "resolved to",
    "consensus was",
)

_DECISION_CUE_RE = re.compile(
    r"\b(" + "|".join(re.escape(c) for c in _DECISION_CUES) + r")\b",
    re.IGNORECASE,
)

# Split a summary into sentences on terminal punctuation or newlines/bullets.
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+|[\r\n]+|\s+[-*•]\s+")

# Bound a single decision summary so a runaway sentence cannot bloat a literal.
_MAX_SUMMARY_LEN = 400
_MIN_SUMMARY_LEN = 12


def _escape(value: str) -> str:
    """SPARQL/Turtle literal escape (matches meeting_syncer/syncer.py:_escape)."""
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "")
    )


def _normalise_for_id(text: str) -> str:
    """Lower-case, collapse whitespace -- stable across cosmetic re-renders."""
    return re.sub(r"\s+", " ", text.strip().lower())


def decision_id(source_uri: str, summary: str) -> str:
    """Deterministic 12-hex id from the source meeting + normalised summary.

    Mirrors ``_meeting_uri``'s ``md5(...)[:12]`` rule so the id is stable
    across runs (no random uuid). Two different decisions from the same
    meeting get different ids; the same decision re-run gets the same id.
    """
    key = "{}|{}".format(source_uri, _normalise_for_id(summary))
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:12]


def decision_uri(decision_id_value: str) -> str:
    return "{}decision_{}".format(PWG, decision_id_value)


@dataclass
class ExtractedDecision:
    """One decision pulled from a source. The writer's input contract."""

    summary: str
    source_uri: str
    date: Optional[str] = None
    about_persons: List[str] = field(default_factory=list)
    status: str = "active"

    @property
    def id(self) -> str:
        return decision_id(self.source_uri, self.summary)

    @property
    def uri(self) -> str:
        return decision_uri(self.id)


# ---------------------------------------------------------------------------
# Extraction (pure -- no I/O)
# ---------------------------------------------------------------------------

def extract_decisions_from_summary(
    summary: str,
    source_uri: str,
    *,
    date: Optional[str] = None,
    about_persons: Optional[List[str]] = None,
) -> List[ExtractedDecision]:
    """Pull decision-bearing sentences out of a single meeting summary.

    High-precision rule-based detector: a sentence is a decision iff it
    contains one of ``_DECISION_CUES``. De-duplicates by normalised text so a
    summary repeating the same decision twice yields one node.

    Empty / cue-free summaries return ``[]`` (the empty-source safe case).
    """
    if not summary or not summary.strip():
        return []

    about = list(about_persons or [])
    seen: set = set()
    out: List[ExtractedDecision] = []

    for raw in _SENTENCE_SPLIT_RE.split(summary):
        sentence = raw.strip().strip("-*• \t")
        if not sentence or not _DECISION_CUE_RE.search(sentence):
            continue
        if len(sentence) < _MIN_SUMMARY_LEN:
            continue
        if len(sentence) > _MAX_SUMMARY_LEN:
            sentence = sentence[:_MAX_SUMMARY_LEN].rstrip()
        key = _normalise_for_id(sentence)
        if key in seen:
            continue
        seen.add(key)
        out.append(
            ExtractedDecision(
                summary=sentence,
                source_uri=source_uri,
                date=date,
                about_persons=about,
            )
        )
    return out


# ---------------------------------------------------------------------------
# Oxigraph I/O (reuses the meeting_syncer transport shape)
# ---------------------------------------------------------------------------

def _sparql_query(oxigraph_url: str, sparql: str) -> dict:
    resp = httpx.post(
        oxigraph_url.rstrip("/") + "/query",
        content=sparql,
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
        timeout=30.0,
    )
    resp.raise_for_status()
    return resp.json()


def _sparql_update(oxigraph_url: str, sparql: str) -> None:
    resp = httpx.post(
        oxigraph_url.rstrip("/") + "/update",
        content=sparql,
        headers={"Content-Type": "application/sparql-update"},
        timeout=30.0,
    )
    resp.raise_for_status()


def read_meeting_summaries(oxigraph_url: str) -> List[Dict[str, object]]:
    """Read every ``pwg:Meeting`` carrying a non-empty summary, with its
    date and resolved attendees, ready for extraction.

    Returns a list of ``{"uri", "summary", "date", "attendees": [...]}`` .
    Attendees are grouped per meeting (one SELECT, GROUP_CONCAT).
    """
    sparql = """
PREFIX pwg: <{ns}>
SELECT ?m ?summary (SAMPLE(?date) AS ?mdate)
       (GROUP_CONCAT(DISTINCT ?att; SEPARATOR="|") AS ?attendees)
WHERE {{
  ?m a pwg:Meeting ;
     pwg:meetingSummary ?summary .
  OPTIONAL {{ ?m pwg:meetingDate ?date }}
  OPTIONAL {{ ?m pwg:meetingAttendee ?att }}
  FILTER (STR(?summary) != "")
}}
GROUP BY ?m ?summary
""".format(ns=PWG)
    data = _sparql_query(oxigraph_url, sparql)
    rows: List[Dict[str, object]] = []
    for b in data.get("results", {}).get("bindings", []):
        att_raw = b.get("attendees", {}).get("value", "")
        attendees = [a for a in att_raw.split("|") if a]
        rows.append(
            {
                "uri": b["m"]["value"],
                "summary": b.get("summary", {}).get("value", ""),
                "date": (b.get("mdate", {}) or {}).get("value"),
                "attendees": attendees,
            }
        )
    return rows


def build_decision_sparql(decision: ExtractedDecision, *, now_iso: Optional[str] = None) -> str:
    """Return the idempotent ``INSERT DATA`` for one decision node.

    Additive INSERT DATA: re-running with the same (deterministic) URI and
    triples is a no-op because Oxigraph stores each triple once.
    """
    if now_iso is None:
        now_iso = datetime.now(timezone.utc).isoformat()
    uri = decision.uri
    triples = [
        "<{}> a pwg:Decision".format(uri),
        '<{}> pwg:decisionId "{}"'.format(uri, decision.id),
        '<{}> pwg:decisionSummary "{}"'.format(uri, _escape(decision.summary)),
        "<{}> pwg:decisionSource <{}>".format(uri, decision.source_uri),
        '<{}> pwg:createdAt "{}"^^xsd:dateTime'.format(uri, now_iso),
    ]
    if decision.status:
        triples.append('<{}> pwg:decisionStatus "{}"'.format(uri, _escape(decision.status)))
    if decision.date:
        triples.append(
            '<{}> pwg:decisionDate "{}"^^xsd:dateTime'.format(uri, _escape(decision.date))
        )
    for person_uri in decision.about_persons:
        if person_uri:
            triples.append("<{}> pwg:decisionAbout <{}>".format(uri, person_uri))

    return (
        "PREFIX pwg: <{}>\n".format(PWG)
        + "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        + "INSERT DATA {\n  "
        + " .\n  ".join(triples)
        + " .\n}"
    )


def write_decision(
    oxigraph_url: str,
    decision: ExtractedDecision,
    *,
    dry_run: bool = False,
    now_iso: Optional[str] = None,
) -> str:
    """Create/update one ``pwg:Decision`` node. Returns the SPARQL used."""
    sparql = build_decision_sparql(decision, now_iso=now_iso)
    if not dry_run:
        _sparql_update(oxigraph_url, sparql)
    return sparql


# ---------------------------------------------------------------------------
# Promotion pass (the public entry point)
# ---------------------------------------------------------------------------

def promote_decisions(
    oxigraph_url: str,
    *,
    dry_run: bool = False,
    now_iso: Optional[str] = None,
) -> Dict[str, int]:
    """Read every meeting summary, extract decisions, write the nodes.

    Idempotent end-to-end: stable ids + additive INSERT DATA mean a second
    run over an unchanged graph writes the same triples and creates nothing
    new. Returns ``{"meetings", "decisions"}`` counts.
    """
    meetings = read_meeting_summaries(oxigraph_url)
    decisions_written = 0
    for row in meetings:
        decisions = extract_decisions_from_summary(
            str(row.get("summary", "")),
            str(row["uri"]),
            date=row.get("date"),  # type: ignore[arg-type]
            about_persons=list(row.get("attendees", [])),  # type: ignore[arg-type]
        )
        for decision in decisions:
            write_decision(oxigraph_url, decision, dry_run=dry_run, now_iso=now_iso)
            decisions_written += 1
    logger.info(
        "decision promotion: %d meeting(s) scanned, %d decision node(s) %s",
        len(meetings),
        decisions_written,
        "would be written (dry-run)" if dry_run else "written",
    )
    return {"meetings": len(meetings), "decisions": decisions_written}


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--oxigraph-url",
        default=os.environ.get("OXIGRAPH_URL", ""),
        help="Oxigraph base URL (default: $OXIGRAPH_URL).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Extract and log counts without writing any triples.",
    )
    args = parser.parse_args(argv)
    if not args.oxigraph_url:
        parser.error("--oxigraph-url (or $OXIGRAPH_URL) is required")
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    counts = promote_decisions(args.oxigraph_url, dry_run=args.dry_run)
    print(
        "Scanned {meetings} meeting(s); {decisions} decision node(s).".format(**counts)
    )
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
