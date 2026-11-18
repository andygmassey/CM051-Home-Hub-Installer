#!/usr/bin/env python3
# lib/no_l3_reader_offline.py -- the per-kind arms of probes/no_l3_in_tool_results.sh,
# driven OFFLINE against a vendored CM041 tree. No box, no network, no live store.
#
#   python3 no_l3_reader_offline.py <tree>   <tree> = a directory that contains
#       vendor/cm041 (the repo root of a checkout, or a git-archive extract of one).
#   exit 0   every kind arm GREEN  (its L3 row withheld, its L2 control served)
#   exit 1   at least one kind arm RED (an L3 row reached the reader's output)
#   exit 78  CANNOT: the reader could not be driven, or a control did not surface
#
# What it runs: the four readers, UNMODIFIED, from <tree>/vendor/cm041/assistant_api/
# ical-server.py (topics_list, topic_mentions, decisions_list, api_preferences). The
# only substitutions are the three things the box provides and this machine does not:
#   * _sparql_select is answered by rdflib evaluating the reader's OWN SPARQL over an
#     in-memory graph holding the fixture rows below (the rows follow the shape the
#     readers document and the shipped writers produce);
#   * _decision_facts_from_conversations (the Qdrant `conversations` store) returns no
#     rows: that path is NOT exercised here (only the Oxigraph decision store is);
#   * the ostler_security import is stubbed, because ical-server refuses to import
#     without it and the stub is never asked to open a database.
# The L3 topic row is written by a path the shipped topic_writer REFUSES (it refuses
# every level but L0/L1/L2). Accepted as defence in depth (Archie ruling): the reader
# must withhold an L3 row whatever writes it.
# It proves the reader's predicate, not the store: a FAIL here is a reader defect
# (the reader serves an L3 row it was given); a GREEN here says nothing about rows the
# fixture does not contain.
import importlib.util
import json
import os
import sys
import tempfile
import types

M = {  # synthetic, service-sender-safe markers; never a real name
    "l3_topic": "ZEPHYRT-OFFLINE", "l2_topic": "QUARTZT-OFFLINE",
    "l3_decision": "ZEPHYRD-OFFLINE", "l2_decision": "QUARTZD-OFFLINE",
    "l3_pref": "ZEPHYRP-OFFLINE", "l2_pref": "QUARTZP-OFFLINE",
}
PWG = "https://schema.ostler.ai/ontology#"
PREFIXES = (f"@prefix pwg: <{PWG}> .\n"
            "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n"
            "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n")


def _lvl(tag):
    return "L3" if tag == "l3" else "L2"


def fixture_turtle():
    """One topic, one mention, one decision and one meeting per level. The level of a
    topic is its conversation's pwg:privacyLevel; the level of a decision is its
    source meeting's (the convention the box seed uses, see no_l3_graph_seed.py)."""
    out = [PREFIXES]
    for tag in ("l3", "l2"):
        lvl = _lvl(tag)
        slug = "walk-probe-" + M[tag + "_topic"].lower() + "-quarry"
        topic = f"<urn:offline:topic/{tag}>"
        conv = f"<urn:offline:conv/{tag}>"
        out.append(f'{topic} a pwg:ConversationTopic ; pwg:topicSlug "{slug}" ; '
                   f'rdfs:label "walk probe {M[tag + "_topic"]} quarry" .')
        out.append(f'<urn:offline:mention/{tag}> a pwg:TopicMention ; pwg:mentionsTopic {topic} ; '
                   f'pwg:inConversation {conv} ; pwg:topicWeight "2"^^xsd:integer ; '
                   f'pwg:validFrom "2026-11-10" .')
        out.append(f'{conv} pwg:privacyLevel "{lvl}" .')
        meet = f"<urn:offline:meeting/{tag}>"
        out.append(f'{meet} a pwg:Meeting ; pwg:privacyLevel "{lvl}" .')
        out.append(f'<urn:offline:decision/{tag}> a pwg:Decision ; '
                   f'pwg:decisionSummary "{M[tag + "_decision"]} approve the quarry lease renewal" ; '
                   f'pwg:decisionDate "2026-11-10"^^xsd:dateTime ; pwg:decisionSource {meet} .')
    return "\n".join(out)


def _stub_security():
    for name in ("ostler_security", "ostler_security.database", "ostler_security.posture",
                 "ostler_security.db_key"):
        if name not in sys.modules:
            sys.modules[name] = types.ModuleType(name)
    sys.modules["ostler_security.database"].get_db_connection = lambda *a, **k: None
    sys.modules["ostler_security.posture"].record_posture = lambda *a, **k: None
    # ical-server reads .key and .source off the result; an empty key is never used
    # here (the stubbed database connector is not called).
    sys.modules["ostler_security.db_key"].resolve_db_key = lambda *a, **k: types.SimpleNamespace(
        key=None, source="offline-stub", reason="offline-stub", detail="")


def load_reader(tree):
    api = os.path.join(tree, "vendor", "cm041", "assistant_api")
    if not os.path.isfile(os.path.join(api, "ical-server.py")):
        raise FileNotFoundError("no ical-server.py under " + api)
    sys.path.insert(0, api)
    _stub_security()
    spec = importlib.util.spec_from_file_location("ical_server_offline", os.path.join(api, "ical-server.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wire(mod, graph, profile_path):
    """Answer the reader's SPARQL from the rdflib graph; point it at the fixture
    profile. Nothing else in the reader is replaced."""
    def _select(sparql):
        rows = []
        for b in graph.query(sparql):
            rows.append({str(k): str(v) for k, v in b.asdict().items() if v is not None})
        return rows
    mod._sparql_select = _select
    mod._decision_facts_from_conversations = lambda about=None, query=None: ([], None)
    mod.INTEREST_PROFILE_PATH = profile_path


def profile_fixture():
    recs = []
    for tag, lvl in (("l3", "L3"), ("l2", "L2")):
        recs.append({"id": "offline-" + tag, "subject": "Walk probe " + M[tag + "_pref"] + " trail",
                     "domain": "walkprobe", "polarity": "like", "score": 0.9, "confidence": 0.9,
                     "privacy": lvl, "sources": ["walk-probe"], "evidence": [], "flags": []})
    return {"schema_version": "0.1", "interests": recs}


def arms(mod, graph, profile_path):
    """-> list of (arm, verdict, why). Verdict PASS / FAIL / CANNOT, the judge's words."""
    wire(mod, graph, profile_path)
    slug3 = "walk-probe-" + M["l3_topic"].lower() + "-quarry"
    slug2 = "walk-probe-" + M["l2_topic"].lower() + "-quarry"
    reads = {
        "topic": (lambda: mod.topics_list(query=M["l3_topic"]), lambda: mod.topics_list(query=M["l2_topic"]),
                  "l3_topic", "l2_topic"),
        "topic_mentions": (lambda: mod.topic_mentions(slug3), lambda: mod.topic_mentions(slug2),
                           "l3_topic", "l2_topic"),
        "decision": (lambda: mod.decisions_list(query=M["l3_decision"]),
                     lambda: mod.decisions_list(query=M["l2_decision"]), "l3_decision", "l2_decision"),
        "preference": (lambda: mod.api_preferences(), lambda: mod.api_preferences(), "l3_pref", "l2_pref"),
    }
    out = []
    for name, (r3, r2, k3, k2) in reads.items():
        res3, res2 = r3(), r2()
        body3 = json.dumps(res3[0] if isinstance(res3, tuple) else res3)
        body2 = json.dumps(res2[0] if isinstance(res2, tuple) else res2)
        control_ok = M[k2] in body2
        if not control_ok:
            out.append((name, "CANNOT", f"L2 control {k2} not served; the L3 result cannot be judged"))
            continue
        if M[k3] in body3:
            out.append((name, "FAIL", f"the reader served the L3 row {k3}: the L3 marker is in its output"))
        else:
            out.append((name, "PASS", f"the L3 row {k3} is withheld; the L2 control {k2} is served"))
    return out


def main(argv):
    if len(argv) != 2:
        print("usage: no_l3_reader_offline.py <tree containing vendor/cm041>", file=sys.stderr)
        return 78
    try:
        import rdflib
    except ImportError as exc:
        print(f"CANNOT rdflib is not installed ({exc}); the readers cannot be evaluated offline")
        return 78
    try:
        mod = load_reader(argv[1])
    except Exception as exc:  # noqa: BLE001 -- the reason is the output
        print(f"CANNOT the reader could not be imported from {argv[1]}: {type(exc).__name__}: {str(exc)[:300]}")
        return 78
    g = rdflib.Graph()
    g.parse(data=fixture_turtle(), format="turtle")
    prof = os.path.join(tempfile.mkdtemp(prefix="no-l3-offline-"), "interest_profile.json")
    with open(prof, "w", encoding="utf-8") as fh:
        json.dump(profile_fixture(), fh)
    results = arms(mod, g, prof)
    tag = {"PASS": "ok", "FAIL": "FAIL", "CANNOT": "CANNOT"}
    for name, verdict, why in results:
        print(f"  {tag[verdict]} path {name} {why}")
    verdicts = {v for _, v, _ in results}
    print(f"denominator: {len(results)} kind arms, {len(g)} fixture triples, tree={argv[1]}")
    if "FAIL" in verdicts:
        return 1
    if verdicts == {"PASS"}:
        return 0
    return 78


if __name__ == "__main__":
    sys.exit(main(sys.argv))
