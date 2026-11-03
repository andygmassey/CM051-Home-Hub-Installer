#!/usr/bin/env python3
"""Every vendored graph reader whose output can leave the box filters L3.

WHY. 2026-11-03 P0 audit (scratch/p1_scoped.evidence.txt): three readers
(brief._get_meeting_history, brief._get_last_conversation_id,
ical-server._query_operator_career_facts) read the graph WITHOUT the L3
filter that _get_person_facts has, and their output goes into the emailed
brief / the context digest. Nothing noticed, because nothing enumerated them.

HOW "REACHES OUTBOUND" IS DECIDED. It is an EXPLICIT REGISTRY, not inference
(a static call graph cannot see "this route is read by the digest"). Every
function that calls a graph reader (ical-server `_sparql_select`, brief
`_sparql_query`; `graph_scoped_select` is only reached through those two) must
be in exactly one of:
  OUTBOUND  output reaches the brief / digest / an email / a send. MUST carry
            an L3 filter (checked below). RED if it does not.
  ONBOX     does not. Needs a REASON. Not flagged when unfiltered.
  KNOWN_GAP outbound AND unfiltered today, recorded openly with the consumer.
            Passes, prints loudly, and goes RED the day it gains a filter
            (delete the row) so it cannot rot into a silent exemption.
A caller in NONE of the three is RED ("classify me"), so a new reader cannot be
written blind. A registry row naming a function that no longer exists is RED
(a rename would otherwise drop it from the scan).

WHAT "HAS AN L3 FILTER" MEANS. In the function's CODE (docstring excluded): a
call to pwg_privacy.is_l3 / filter_l3_facts / _effective_privacy_level, or a
string constant "L3" / a [Ll][0-2] clearance regex. A structural check, not a
proof of behaviour: behaviour is pinned by CM041's per-reader tests
(test_brief_outbound_l3.py, test_employer_outbound_l3.py).

CONSUMER EVIDENCE for the registry: context-refresh/bin/generate_pwg_context.py
reads /api/v1/{employer,timeline,coach/recent,preferences,commitments,memory};
meeting_syncer.brief is the emailed brief. oa-side consumers of the other
routes were NOT audited: those rows say so.

EXIT: 0 clean, 1 RED, 2 could not look (unparseable / missing file / zero
callers found: a zero denominator is CANNOT-RUN, never a pass).
"""
import ast
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

ICAL = "vendor/cm041/assistant_api/ical-server.py"
BRIEF = "vendor/cm041/meeting_syncer/brief.py"
READERS = {ICAL: {"_sparql_select", "graph_scoped_select"},
           BRIEF: {"_sparql_query", "graph_scoped_select"}}
# The helpers themselves (definitions / the scoper) are not callers.
HELPERS = {"_sparql_select", "_sparql_query", "_graph_scoped", "_sparql_select_unscoped"}
MIN_CALLERS = {ICAL: 25, BRIEF: 4}  # denominator control (33 and 5 on 2026-11-03)

FILTER_CALLS = {"is_l3", "filter_l3_facts", "_effective_privacy_level"}
CLEARANCE_RE = re.compile(r"\[Ll\]\[0-2\]")

_ID = "identity/plumbing: returns identifiers or counts, no fact or meeting content"
_HUB = ("Hub-only route; NOT read by context-refresh or meeting_syncer.brief "
        "(grep 2026-11-03). oa-side consumers NOT audited")

OUTBOUND = {
    (ICAL, "person_context"), (ICAL, "person_enrichment"), (ICAL, "person_timeline"),
    (ICAL, "commitments_list"),
    (ICAL, "_query_operator_career_facts"),
    (BRIEF, "_get_person_facts"), (BRIEF, "_get_meeting_history"),
    (BRIEF, "_get_last_conversation_id"), (BRIEF, "_get_outstanding_todos"),
}
KNOWN_GAP = {
    (ICAL, "_timeline_from_graph"):
        "feeds /api/v1/timeline, which context-refresh reads (generate_pwg_context.py:1081, "
        "7-day digest); pwg:Meeting rows carry no L3 filter. Needs an outbound flag on the "
        "route (the Hub Timeline is on-box) and the digest to pass it. NOT fixed in the "
        "fix122_l3out PR",
}
ONBOX = {
    (ICAL, "_load_people_list_self_uris"): _ID, (ICAL, "_load_carded_uris"): _ID,
    (ICAL, "_forget_graph_left"): _ID, (ICAL, "_identifiers_shared_with_other_than"): _ID,
    (ICAL, "_personal_identifiers_for"): _ID, (ICAL, "_suppression_reason"): _ID,
    (ICAL, "_suppressed_identity_index"): _ID, (ICAL, "_merge_aware_name_rows"): _ID,
    (ICAL, "_merged_cluster"): _ID, (ICAL, "_operator_email_domains"): _ID,
    (ICAL, "_hygiene_verdicts"): "hygiene overlay verdicts (fact ids), no content",
    (ICAL, "_assert_fact_person"): "write path (resolves the subject), not a read for output",
    (ICAL, "_memory_query_facts"):
        "the on-box Memory tab (/api/v1/memory) shows every level by design; the digest reads only a "
        "COUNT of corrected facts from it (generate_pwg_context.py:1706). Its response also carries "
        "current_employer and facts unfiltered: whether any non-Hub client (oa) reads it is NOT audited",
    (ICAL, "_wiki_triples_count"): "a count",
    (ICAL, "api_health_day"): "counts for the Hub health screen",
    (ICAL, "api_people_suppress_suggestions"): "Hub write action", (ICAL, "api_people_forget"): "Hub write action",
    (ICAL, "api_people_set_minor"): "Hub write action", (ICAL, "api_minors_suggestions"): "Hub suggestion list",
    (ICAL, "decisions_list"): _HUB, (ICAL, "topics_list"): _HUB, (ICAL, "topic_mentions"): _HUB,
    (ICAL, "people_list"): _HUB, (ICAL, "people_stale"): _HUB, (ICAL, "people_recent"): _HUB,
    (ICAL, "people_birthdays"): _HUB,
    (BRIEF, "_find_person_by_email"): "attendee identity lookup (person URI), no content",
}


def callers(root, rel):
    """-> {func: (has_filter, lineno)} for every function calling a reader."""
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), filename=rel)
    out = {}
    for fn in ast.walk(tree):
        if not isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)) or fn.name in HELPERS:
            continue
        calls = False
        filt = False
        body = list(fn.body)
        if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) \
                and isinstance(body[0].value.value, str):
            body = body[1:]  # docstring is prose, not a filter
        for stmt in body:
            for n in ast.walk(stmt):
                if isinstance(n, ast.Call):
                    nm = getattr(n.func, "id", None) or getattr(n.func, "attr", None)
                    if nm in READERS[rel]:
                        calls = True
                    if nm in FILTER_CALLS:
                        filt = True
                elif isinstance(n, ast.Constant) and isinstance(n.value, str):
                    if n.value == "L3" or CLEARANCE_RE.search(n.value):
                        filt = True
        if calls:
            out[fn.name] = (filt, fn.lineno)
    return out


def verdict(root, outbound=OUTBOUND, known_gap=KNOWN_GAP, onbox=ONBOX, quiet=False):
    say = (lambda *a: None) if quiet else print
    seen = {}
    try:
        for rel in READERS:
            seen[rel] = callers(root, rel)
    except (OSError, SyntaxError, UnicodeDecodeError) as e:
        say("CANNOT-RUN: %s: %r" % (rel, e))
        return 2
    for rel, found in seen.items():
        say("%s: %d reader caller(s)" % (rel, len(found)))
        if len(found) < MIN_CALLERS[rel]:
            say("CANNOT-RUN: %s has %d callers, expected >= %d (wrong tree or broken scan)"
                % (rel, len(found), MIN_CALLERS[rel]))
            return 2
    red = []
    classified = set(outbound) | set(known_gap) | set(onbox)
    for rel, found in seen.items():
        for name, (filt, line) in sorted(found.items(), key=lambda kv: kv[1][1]):
            key = (rel, name)
            if key not in classified:
                red.append("UNCLASSIFIED %s:%d %s calls a graph reader; add it to OUTBOUND, ONBOX or KNOWN_GAP" % (rel, line, name))
            elif key in outbound and not filt:
                red.append("UNFILTERED OUTBOUND %s:%d %s reaches the brief/digest/a send with no L3 filter" % (rel, line, name))
            elif key in known_gap and filt:
                red.append("STALE KNOWN_GAP %s:%d %s now filters L3; delete its KNOWN_GAP row" % (rel, line, name))
    for key in sorted(classified):
        if key[1] not in seen.get(key[0], {}):
            red.append("STALE REGISTRY %s::%s no longer calls a graph reader (renamed or removed?)" % key)
    for key in sorted(known_gap):
        say("  KNOWN GAP (outbound, unfiltered): %s::%s -- %s" % (key[0], key[1], known_gap[key]))
    for r in red:
        say("  RED  " + r)
    if red:
        return 1
    say("OK: %d outbound readers filter L3; %d known gap(s); %d on-box/plumbing callers classified"
        % (len(outbound), len(known_gap), len(onbox)))
    return 0


def self_test():
    tmp = tempfile.mkdtemp()
    try:
        shutil.copytree(os.path.join(ROOT, "vendor", "cm041"), os.path.join(tmp, "vendor", "cm041"),
                        ignore=shutil.ignore_patterns("__pycache__", "node_modules", "tests"))
        target = os.path.join(tmp, ICAL)
        orig = open(target, encoding="utf-8").read()
        plant_bad = "\n\ndef _planted(x):\n    return _sparql_select('SELECT ?s WHERE { ?s ?p ?o }')\n"
        plant_ok = ("\n\ndef _planted(x):\n    rows = _sparql_select('SELECT ?s WHERE { ?s ?p ?o }')\n"
                    "    return [r for r in rows if not pwg_privacy.is_l3(r)]\n")
        plant_doc = ("\n\ndef _planted(x):\n    \"\"\"filters L3, honest.\"\"\"\n"
                     "    return _sparql_select('SELECT ?s WHERE { ?s ?p ?o }')\n")
        key = (ICAL, "_planted")
        cases = [
            ("baseline tree", orig, {}, 0),
            ("unfiltered outbound caller", orig + plant_bad, {"outbound": OUTBOUND | {key}}, 1),
            ("same, docstring says L3 (prose is not a filter)", orig + plant_doc, {"outbound": OUTBOUND | {key}}, 1),
            ("filtered outbound caller", orig + plant_ok, {"outbound": OUTBOUND | {key}}, 0),
            ("unfiltered on-box-only caller", orig + plant_bad, {"onbox": {**ONBOX, key: "test"}}, 0),
            ("unclassified caller", orig + plant_bad, {}, 1),
            ("known gap that gained a filter", orig + plant_ok, {"known_gap": {**KNOWN_GAP, key: "t"}}, 1),
            ("a real outbound reader loses its filter",
             orig.replace("owner_level=r.get(\"ownerPriv\")", "owner_level=None").replace(
                 "pwg_privacy.is_l3({\"privacy_level\": r.get(\"fpriv\")}", "(lambda *a, **k: False)({\"privacy_level\": r.get(\"fpriv\")}"),
             {}, 1),
        ]
        ok = True
        for label, text, kw, want in cases:
            open(target, "w", encoding="utf-8").write(text)
            got = verdict(tmp, quiet=True, **kw)
            ok &= got == want
            print("  self-test %s: %s -> exit %d (want %d)" % ("PASS" if got == want else "FAIL", label, got, want))
        return 0 if ok else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    sys.exit(verdict(ROOT))
