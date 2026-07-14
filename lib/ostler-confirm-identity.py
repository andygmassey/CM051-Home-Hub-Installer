#!/usr/bin/env python3
"""End-of-install identity confirmation helper (propose-and-confirm).

Backs the identity half of the end-of-installation confirmation step. It
implements the LOCKED design in CM061
``design/EMPLOYER_IDENTITY_MERGE_PLAN.md``:

  * COLLAPSE the operator's own fragmented self-nodes into one profile, and
  * SPLIT OUT a namesake (a *different* real person who shares the operator's
    name) so it is never auto-merged into them.

Both are PROPOSED here and only ENACTED after the operator confirms. Nothing in
this module mutates the graph. A confirmed decision is written to the ONE file
the CM041 resolver already consumes:

    ~/.ostler/corrections/duplicates.yaml

in the exact schema ``identity_resolver/decisions.py`` reads:

    decisions:
      - merge:    [<selfA>, <selfB>]   # confirmed: these are ALL the operator
      - distinct: [<self>, <namesake>] # confirmed: never merge these two

``merge`` is the COLLAPSE hand-off; ``distinct`` is the SPLIT hand-off (a
permanent never-merge veto -- the non-destructive primitive the design's
"never auto-merge" rule wants). The resolver applies them on its next sweep
(install-time dedupe catch-up + daily recompile). This module never deletes a
node.

Honest boundaries (see EMPLOYER_IDENTITY_MERGE_PLAN.md §7):
  * The graph-side enactment of a confirmed ``merge`` is CM041's existing
    ``merge_persons`` (tombstone via ``pwg:mergedInto`` + a ``.trig`` backup),
    NOT the clean reversible overlay (``sameAs``/``differentFrom`` + undo
    record) the design envisions -- that overlay is design-only today.
  * ``distinct`` (the namesake veto) is fully non-destructive and reversible
    (drop the line).

Modes (driven from install.sh):

  --propose --oxigraph-url URL --user-id ID   [ | --from-json FIXTURE ]
      Query the graph for the operator's own node + name-matched candidate
      nodes + their distinguishing signals, score them (design §2), and emit
      one TAB-separated proposal per line:

          COLLAPSE <TAB> <sid,sid,...> <TAB> <human evidence>
          NAMESAKE <TAB> <self_sid,namesake_sid> <TAB> <human evidence>

      Conservative: a proposal is only emitted on a corroborating HARD id
      (shared email-domain / LinkedIn / org for COLLAPSE; a name match plus a
      diverging hard id with none shared for NAMESAKE). Name-only never
      proposes. On any error / empty graph it emits nothing (fail-safe:
      the step then does nothing and leaves the graph untouched).

  --record --corrections-dir DIR [--merge sid,sid,...]... [--distinct sid,sid]...
      Append the operator-confirmed decisions to duplicates.yaml idempotently.

Uses only stdlib (urllib/json/argparse) + PyYAML (present in the import-pipeline
venv, which is also the resolver's venv). Pure logic is factored out for tests.

All example names/ids are synthetic. No real personal data. See
PRODUCTISATION_CHECKLIST.md Rule 0.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from itertools import combinations
from typing import Any, Dict, List, Optional, Set, Tuple

PWG_NS = "https://pwg.dev/ontology#"


# ── short-id (byte-identical to identity_resolver.decisions.short_id) ────────
def short_id(uri: str) -> str:
    if "person_" in uri:
        return uri.split("person_")[-1]
    if "business_" in uri:
        return uri.split("business_")[-1]
    return uri.rsplit("/", 1)[-1]


def owner_uri(user_id: str) -> str:
    return f"{PWG_NS}user_{user_id}"


# ── name matching ────────────────────────────────────────────────────────────
def _name_tokens(name: str) -> Set[str]:
    return {t for t in (name or "").lower().replace(",", " ").split() if len(t) > 1}


def names_match(a: str, b: str) -> bool:
    """A candidate is a name-match to the operator when the display names are
    equal, or one is a subset of the other on word tokens (handles "Jane Doe"
    vs "Jane A Doe"). Name match is a *candidate generator*, never a decision
    (design §2)."""
    na, nb = (a or "").strip().lower(), (b or "").strip().lower()
    if not na or not nb:
        return False
    if na == nb:
        return True
    ta, tb = _name_tokens(a), _name_tokens(b)
    if len(ta) >= 2 and len(tb) >= 2 and (ta <= tb or tb <= ta):
        return True
    return False


def _domain(email: str) -> str:
    return email.split("@", 1)[1].lower().strip() if "@" in email else ""


# ── candidate model ──────────────────────────────────────────────────────────
def _blank_candidate(uri: str, name: str) -> Dict[str, Any]:
    return {
        "uri": uri,
        "sid": short_id(uri),
        "name": name,
        "email_domains": set(),
        "linkedin": set(),
        "orgs": set(),
        "is_owner": False,
    }


def build_candidates(rows: List[Dict[str, str]], owner_uri_str: str) -> Dict[str, Dict[str, Any]]:
    """Fold SPARQL result rows (person/name/org/idType/idValue) into per-node
    signal bags."""
    by_uri: Dict[str, Dict[str, Any]] = {}
    for row in rows:
        uri = (row.get("person") or "").strip()
        if not uri:
            continue
        c = by_uri.get(uri)
        if c is None:
            c = _blank_candidate(uri, (row.get("name") or "").strip())
            c["is_owner"] = uri == owner_uri_str or str(row.get("isOwner", "")).lower() == "true"
            by_uri[uri] = c
        if not c["name"] and row.get("name"):
            c["name"] = row["name"].strip()
        org = (row.get("org") or "").strip()
        if org:
            c["orgs"].add(org.lower())
        idtype = (row.get("idType") or "").strip().lower()
        idval = (row.get("idValue") or "").strip()
        if not idval:
            continue
        if idtype == "email" or "@" in idval:
            dom = _domain(idval)
            if dom:
                c["email_domains"].add(dom)
        if idtype in ("linkedin_url", "linkedin") or "linkedin.com" in idval.lower():
            c["linkedin"].add(idval.lower().rstrip("/"))
    return by_uri


# ── scoring (pure, design §2) ────────────────────────────────────────────────
def _shared_hard_evidence(owner: Dict[str, Any], cand: Dict[str, Any]) -> List[str]:
    ev: List[str] = []
    shared_dom = owner["email_domains"] & cand["email_domains"]
    if shared_dom:
        ev.append("shares your email domain " + ", ".join(sorted(shared_dom)))
    shared_li = owner["linkedin"] & cand["linkedin"]
    if shared_li:
        ev.append("same LinkedIn profile")
    shared_org = owner["orgs"] & cand["orgs"]
    if shared_org:
        ev.append("overlapping employer")
    return ev


def _diverging_hard_evidence(owner: Dict[str, Any], cand: Dict[str, Any]) -> List[str]:
    ev: List[str] = []
    # Two live, DIFFERENT LinkedIn URLs => two people (design: decisive).
    if owner["linkedin"] and cand["linkedin"] and not (owner["linkedin"] & cand["linkedin"]):
        ev.append("a different LinkedIn profile")
    # Disjoint email domains (each has ids, none shared).
    if owner["email_domains"] and cand["email_domains"] and not (
        owner["email_domains"] & cand["email_domains"]
    ):
        ev.append("only a different email domain")
    # Disjoint employer history.
    if owner["orgs"] and cand["orgs"] and not (owner["orgs"] & cand["orgs"]):
        ev.append("a different employer with no overlap to yours")
    return ev


def score_candidates(
    owner: Dict[str, Any], candidates: List[Dict[str, Any]]
) -> Dict[str, List[Dict[str, Any]]]:
    """Classify name-matched candidates into COLLAPSE (self-fragments) and
    NAMESAKE (split) buckets. Anything ambiguous is left out (fail-safe = do
    nothing)."""
    collapse: List[Dict[str, Any]] = []
    namesakes: List[Dict[str, Any]] = []
    for cand in candidates:
        if cand["uri"] == owner["uri"]:
            continue
        if not names_match(owner["name"], cand["name"]):
            continue
        shared = _shared_hard_evidence(owner, cand)
        diverging = _diverging_hard_evidence(owner, cand)
        if shared:
            # A corroborating hard id ties it to the operator -> self-fragment.
            collapse.append({**cand, "evidence": shared})
        elif diverging:
            # Name matches but a hard id diverges and none is shared -> a
            # different real person wrongly in the operator's name-space.
            namesakes.append({**cand, "evidence": diverging})
        # else: name-only match, no hard id either way -> propose nothing.
    return {"collapse": collapse, "namesakes": namesakes}


# ── graph fetch (best-effort) ────────────────────────────────────────────────
_PERSONS_SPARQL = """
PREFIX pwg: <https://pwg.dev/ontology#>
SELECT ?person ?name ?org ?idType ?idValue ?isOwner WHERE {
    ?person a pwg:Person ;
            pwg:displayName ?name .
    OPTIONAL { ?person pwg:isOwner ?isOwner }
    OPTIONAL { ?person pwg:organization ?org }
    OPTIONAL {
        ?person pwg:hasIdentifier ?id .
        ?id pwg:identifierType ?idType ;
            pwg:identifierValue ?idValue .
    }
    FILTER NOT EXISTS { ?person pwg:mergedInto ?merged }
}
"""


def fetch_rows(oxigraph_url: str) -> List[Dict[str, str]]:
    req = urllib.request.Request(
        oxigraph_url.rstrip("/") + "/query",
        data=_PERSONS_SPARQL.encode("utf-8"),
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 (localhost)
        data = json.loads(resp.read().decode("utf-8"))
    rows: List[Dict[str, str]] = []
    for b in data.get("results", {}).get("bindings", []):
        rows.append({k: v.get("value", "") for k, v in b.items()})
    return rows


def _serialise_evidence(ev: List[str]) -> str:
    return "; ".join(ev)


def _cmd_propose(args: argparse.Namespace) -> int:
    ouri = owner_uri(args.user_id) if args.user_id else ""
    try:
        if args.from_json:
            with open(args.from_json, "r", encoding="utf-8") as f:
                fixture = json.load(f)
            rows = fixture.get("rows", fixture) if isinstance(fixture, dict) else fixture
        else:
            rows = fetch_rows(args.oxigraph_url)
    except Exception:  # noqa: BLE001 - fail-safe: propose nothing
        return 0

    by_uri = build_candidates(rows, ouri)
    owner = by_uri.get(ouri)
    if owner is None:
        # Owner node not found by URI: fall back to the node flagged isOwner.
        for c in by_uri.values():
            if c["is_owner"]:
                owner = c
                ouri = c["uri"]
                break
    if owner is None or not owner["name"]:
        return 0

    scored = score_candidates(owner, list(by_uri.values()))

    owner_sid = short_id(ouri)
    # COLLAPSE: merge the operator's own name-matched FRAGMENTS together.
    #
    # SAFETY: we deliberately do NOT include the owner ``user_<id>`` node in the
    # merge group. CM041's ``pick_canonical`` (batch_resolver.py) chooses the
    # keeper by triple-count, not by ``isOwner`` -- so a freshly-minted owner
    # node (few triples) folded in against a data-rich imported fragment would
    # be the one TOMBSTONED, breaking every ``pwg:belongsToUser`` / ``isOwner``
    # reference. Merging fragments with each other only can never tombstone the
    # operator's canonical node. Requires >=2 fragments to form a group.
    #
    # Fully folding the collapsed fragment INTO the ``user_<id>`` owner node is
    # a scoped CM041 follow-up: teach ``pick_canonical`` (+ the forced-merge
    # path) to always keep an ``isOwner`` node. Until then this is the safe
    # subset, and the read-path fix (fix/employer-current-recency) keeps the
    # operator's own card correct regardless.
    frag_sids = [c["sid"] for c in scored["collapse"]]
    if len(frag_sids) >= 2:
        ev = "; ".join(
            f"{c['name']}: {_serialise_evidence(c['evidence'])}" for c in scored["collapse"]
        )
        sys.stdout.write("COLLAPSE\t" + ",".join(frag_sids) + "\t" + ev + "\n")
    # NAMESAKE: one distinct pair (owner, namesake) each.
    for ns in scored["namesakes"]:
        sys.stdout.write(
            "NAMESAKE\t"
            + f"{owner_sid},{ns['sid']}"
            + "\t"
            + f"{ns['name']}: {_serialise_evidence(ns['evidence'])}"
            + "\n"
        )
    return 0


# ── duplicates.yaml write (mirrors vendor/doctor/agent/duplicate_decision) ───
# short-ids here can carry the owner node's ``#`` (e.g. ``ontology#user_5``),
# so the accepted set is wider than the doctor writer's hex-only set -- but
# still rejects whitespace and shell/YAML metacharacters.
_ID_OK = re.compile(r"^[A-Za-z0-9_#.:/-]{1,128}$")


def _same_set(a: Any, b: Any) -> bool:
    return isinstance(a, list) and isinstance(b, list) and set(a) == set(b)


def write_decisions(
    path: str,
    merges: List[List[str]],
    distinct_pairs: List[List[str]],
) -> Dict[str, Any]:
    """Append merge groups + distinct pairs to duplicates.yaml, idempotently.

    Schema is exactly what identity_resolver.decisions.load_duplicate_decisions
    reads: a top-level ``decisions:`` list of single-key ``{merge: [...]}`` /
    ``{distinct: [a, b]}`` maps."""
    import os

    import yaml

    entries: List[Dict[str, List[str]]] = []
    for grp in merges:
        ids = [x for x in grp if x]
        if len(set(ids)) >= 2:
            entries.append({"merge": list(dict.fromkeys(ids))})
    for pair in distinct_pairs:
        ids = [x for x in pair if x]
        for a, b in combinations(dict.fromkeys(ids), 2):
            entries.append({"distinct": [a, b]})

    data: Dict[str, Any] = {"decisions": []}
    if os.path.exists(path):
        try:
            loaded = yaml.safe_load(open(path, "r", encoding="utf-8").read()) or {}
            if isinstance(loaded, dict) and isinstance(loaded.get("decisions"), list):
                data = loaded
        except yaml.YAMLError:
            pass  # malformed existing file -> start clean rather than crash install
    existing = data["decisions"]

    added: List[Dict[str, List[str]]] = []
    for entry in entries:
        (key, value), = entry.items()
        if any(isinstance(e, dict) and key in e and _same_set(e.get(key), value) for e in existing):
            continue
        existing.append(entry)
        added.append(entry)

    if added:
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
    return {"status": "recorded", "added": added, "path": path}


def _parse_id_list(raw: str) -> List[str]:
    out: List[str] = []
    for part in (raw or "").split(","):
        part = part.strip()
        if part and _ID_OK.match(part):
            out.append(part)
    return out


def _cmd_record(args: argparse.Namespace) -> int:
    import os

    corrections_dir = os.path.expanduser(args.corrections_dir)
    path = os.path.join(corrections_dir, "duplicates.yaml")
    merges = [_parse_id_list(m) for m in (args.merge or [])]
    distincts = [_parse_id_list(d) for d in (args.distinct or [])]
    result = write_decisions(path, merges, distincts)
    sys.stdout.write(json.dumps(result) + "\n")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description="Identity confirmation helper")
    sub = p.add_subparsers(dest="mode", required=True)

    pr = sub.add_parser("propose")
    pr.add_argument("--oxigraph-url", default="http://localhost:7878")
    pr.add_argument("--user-id", default="")
    pr.add_argument("--from-json", default="")
    pr.set_defaults(func=_cmd_propose)

    rc = sub.add_parser("record")
    rc.add_argument("--corrections-dir", default="~/.ostler/corrections")
    rc.add_argument("--merge", action="append", default=[])
    rc.add_argument("--distinct", action="append", default=[])
    rc.set_defaults(func=_cmd_record)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
