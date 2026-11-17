#!/usr/bin/env python3
# lib/no_l3_graph_seed.py -- runs ON THE BOX under the CM048 venv python
# (~/.ostler/services/cm048/.venv/bin/python3, cwd = the CM048 checkout), driven
# by lib/no_l3_box.py. Never run on the walker's machine.
#
# It builds the graph rows for the timeline, brief, topic and decision paths with
# CM048's and CM041's OWN writers (src.ingest._conversation_to_triples,
# _fact_to_triples, _todo_to_triples, src.topic_writer.write_topics /
# build_topic_update, meeting_syncer decision_extractor.write_decision), and POSTs
# them the way ingest._write_oxigraph does: Turtle to <oxigraph>/store?graph=
# urn:ostler:user/<owner>, no proxy, store auth from the ostler_store_auth .pth
# shim that this venv carries.
#
# Why not `pwg-convo process`: the facts and todos it writes come out of an LLM,
# so a chosen level on a chosen fact cannot be pinned. These serialisers take the
# level as an argument, which is the property the probe needs.
#
# What is NOT a shipped writer, stated rather than hidden:
#   * the fixture Person node (a pwg:Person with a pwg:displayName): the real ones
#     come from the contact syncer;
#   * `<conv> urn:ostler:date "<iso>"`: READ by _person_timeline_body
#     (ical-server.py:7525) and by meeting_syncer/brief.py:364, and WRITTEN by
#     nothing in the shipped tree (git grep 'ostler:date' over vendor/ on
#     origin/main finds readers only; a live box holds 0 such triples). On a
#     shipped install the timeline's conversation arm therefore never has a date
#     and never yields an event. The triple is seeded here so the arm, as coded,
#     is exercised.
#   * THE L3 TOPIC ROW (kind "topic", level L3): topic_writer.write_topics refuses
#     every level but L0/L1/L2 (topic_writer.py:377-404, the L3 refusal), so the
#     shipped writer can never put an L3 topic in the graph. The L3 row is posted
#     from topic_writer.build_topic_update's OUTPUT, which is the shipped SPARQL
#     builder, bypassing only the refusal. The question this arm asks is whether the
#     READER withholds a row that exists, which is the defence-in-depth gap: the
#     reader (ical-server.py topics_list / topic_mentions) has no privacy predicate.
#     The L2 topic goes through write_topics unchanged.
#     ACCEPTED (Archie ruling, defence in depth): the L3 topic writer bypass is
#     accepted. The shipped topic_writer refuses L3, so the bypass is a test of the
#     READER alone, not a claim that the shipped system produces L3 topics.
#   * THE MEETING LEVEL NODE (`<urn:ostler:meeting/...> pwg:privacyLevel`): the
#     decision writer (decision_extractor.write_decision) takes NO privacy input, so
#     a decision carries no level of its own. The level a decision is judged by is
#     its source meeting's pwg:privacyLevel (the convention ical-server.py:6831 reads
#     for meetings). The meeting node is minimal and seeded here.
#
# stdout: one JSON object. Diagnostics go to stderr, which the caller keeps.
import importlib.util
import json
import os
import re
import sys
import uuid

PWG_NS = "https://schema.ostler.ai/ontology#"
HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DATE = "2026-11-10"
# Fixed createdAt for the decision rows: the planned SPARQL (for teardown) and the
# executed SPARQL must be the same text, and write_decision defaults to now().
NOW_ISO = "2026-11-16T23:55:00+00:00"


def _decision_extractor():
    # meeting_syncer/decision_extractor.py is staged next to this file by the box
    # runner (it needs only httpx and the standard library).
    spec = importlib.util.spec_from_file_location("decision_extractor",
                                                  os.path.join(HERE, "decision_extractor.py"))
    mod = importlib.util.module_from_spec(spec)
    # registered before exec: @dataclass looks the module up in sys.modules
    sys.modules["decision_extractor"] = mod
    spec.loader.exec_module(mod)
    return mod


def build(payload):
    from src import ingest, topic_writer
    from src.outstanding_todos import OutstandingTodo
    from src.settings import Settings

    settings = Settings(user_id=payload["owner"])
    # The store the seed writes to. It is set by NO_L3_SEED_OXIGRAPH_URL alone. Fail
    # closed: if OSTLER_OXIGRAPH_URL is ambient and the dedicated name is not set, main()
    # refuses (rc 5, before any write). Settings(user_id=...) built here does not read
    # OSTLER_OXIGRAPH_URL today (only load_settings does, at settings.py:235), but the
    # refusal does not depend on that: an ambient CM048 setting never picks the target.
    if os.environ.get("NO_L3_SEED_OXIGRAPH_URL"):
        settings.oxigraph_url = os.environ["NO_L3_SEED_OXIGRAPH_URL"]
    stamp = payload["stamp"]
    person_id = "other:walkfx-" + stamp
    person_uri = ingest._urn(person_id.replace(":", "/"))
    blocks = [
        ingest._turtle_prefixes(),
        f'{person_uri} a <{PWG_NS}Person> ;\n  <{PWG_NS}displayName> "{payload["person_name"]}" .',
    ]
    classification = type("C", (), {"setting": "work", "shape": "one-on-one", "stakes": "low"})()
    for c in payload["convs"]:
        cid, level, marker = c["id"], c["level"], c["marker"]
        blocks += ingest._conversation_to_triples(cid, classification, settings)
        conv_uri = ingest._urn("conversation/" + cid)
        blocks.append(f'{conv_uri} <urn:ostler:date> "{c["date"]}" .')
        fact = {"text": f"{marker} the quarry lease renewal was approved", "type": "fact",
                "domain": "general", "privacy_level": level, "subject": person_id,
                "signal_strength": "medium"}
        blocks += ingest._fact_to_triples(cid, fact, settings, {"channel": "spoken", "date": c["date"]})
        todo = OutstandingTodo(
            todo_id=ingest._deterministic_id(cid, "todo", marker),
            subject_person_ids=[person_id], owner="user", owner_display="You",
            action_text=f"{marker} send the signed quarry lease",
            deadline=None, priority=None, source_conversation_id=cid,
            source_conversation_date=c["date"], status="open",
            created_at="2026-11-16T09:00:00+00:00")
        blocks += ingest._todo_to_triples(cid, todo, settings, privacy_level=level)

    # --- topic and decision rows (one per level), each tied to its own conversation
    de = _decision_extractor()
    writes, slugs, extra_subjects = [], {}, []
    for lvl in ("L2", "L3"):
        marker = payload["topic_markers"][lvl]
        conv_id = "ostler-walk-" + payload["conv_markers"][lvl]
        name = "walk probe " + marker + " quarry"
        topics = [{"name": name, "points": ["the quarry lease", "renewal"]}]
        meta = {"channel": "spoken", "date": FIXTURE_DATE}
        slug = topic_writer.slugify_topic(name)
        slugs[lvl] = slug
        extra_subjects += [topic_writer.topic_uri(slug), topic_writer.mention_uri(conv_id, slug)]
        writes.append({"kind": "topic", "level": lvl, "conv": conv_id, "topics": topics, "meta": meta})

        mkr = payload["decision_markers"][lvl]
        meeting = f"urn:ostler:meeting/walkfx-{stamp}-{lvl.lower()}"
        blocks.append(f'<{meeting}> a <{PWG_NS}Meeting> ; <{PWG_NS}privacyLevel> "{lvl}" .')
        # ingest._urn() returns the angle-bracketed IRI; decision_extractor wraps its
        # about_persons in <...> itself, so pass the BARE IRI (else <<urn:...>>, a parse error).
        dec = de.ExtractedDecision(summary=f"{mkr} approve the quarry lease renewal",
                                   source_uri=meeting, date=FIXTURE_DATE + "T00:00:00Z",
                                   about_persons=[person_uri[1:-1]], status="active")
        extra_subjects += [dec.uri, meeting]
        writes.append({"kind": "decision", "level": lvl, "decision": dec})

    cleaned = []
    for b in blocks:
        cleaned.append("\n".join(l for l in b.split("\n") if not l.startswith("@prefix ")))
    ttl = ingest._turtle_prefixes() + "\n" + "\n\n".join(cleaned)
    subjects = sorted(set(re.findall(r"^<(urn:[^>\s]+)> a ", ttl, re.M)) | set(extra_subjects))
    return ingest, settings, ttl, subjects, writes, slugs


def _ttl_parts(ttl):
    """(PREFIX lines, body) of the seed's Turtle, as SPARQL."""
    prefixes, body = [], []
    for line in ttl.split("\n"):
        if line.startswith("@prefix "):
            prefixes.append("PREFIX " + line[len("@prefix "):].strip().rstrip(".").strip())
        elif line.strip():
            body.append(line)
    return prefixes, "\n".join(body)


def _insert_parts(sparql):
    """(PREFIX lines, INSERT DATA body) of a topic or decision UPDATE. The topic UPDATE's
    DELETE WHERE operations are dropped on purpose: they are replace-ops on rows the
    seed owns (see DELETE_WHERE_SCOPE), and the staging records only what is INSERTed."""
    i = sparql.index("INSERT DATA {")
    body = sparql[i + len("INSERT DATA {"):].rstrip()
    if not body.endswith("}"):
        raise ValueError("INSERT DATA block not closed")
    prefixes = [l for l in sparql[:i].split("\n") if l.startswith("PREFIX ")]
    return prefixes, body[:-1]


def stage_unit(update, count, target, unit_id, prefixes, body, exclude_existing=True):
    """Record the quads one write is about to add, minus those ALREADY in the target
    graph, so the teardown can never remove a row that was on the box before the seed.

    The quads are staged in a scratch graph by the store itself (no client-side Turtle
    parsing), the set difference is taken in SPARQL, and the result is frozen in a
    teardown graph until the teardown runs. target: a named graph IRI, or None for the
    default graph. Returns (teardown statements, quads the seed wrote, quads to delete).
    Mutant: exclude_existing=False removes pre-existing rows too."""
    stage = "urn:ostler:no-l3-seed/stage/%s" % unit_id
    frozen = "urn:ostler:no-l3-seed/teardown/%s" % unit_id
    pre = "\n".join(prefixes) + "\n"
    try:
        update(pre + "INSERT DATA { GRAPH <%s> {\n%s\n} }" % (stage, body))
        n_seed = count("SELECT (COUNT(*) AS ?n) WHERE { GRAPH <%s> { ?s ?p ?o } }" % stage)
        if not exclude_existing:
            keep = ""
        elif target is None:
            keep = "FILTER NOT EXISTS { ?s ?p ?o }"
        else:
            keep = "FILTER NOT EXISTS { GRAPH <%s> { ?s ?p ?o } }" % target
        update("INSERT { GRAPH <%s> { ?s ?p ?o } } WHERE { GRAPH <%s> { ?s ?p ?o } %s }"
               % (frozen, stage, keep))
        n_del = count("SELECT (COUNT(*) AS ?n) WHERE { GRAPH <%s> { ?s ?p ?o } }" % frozen)
    finally:
        update("DROP SILENT GRAPH <%s>" % stage)
    if target is None:
        remove = "DELETE { ?s ?p ?o } WHERE { GRAPH <%s> { ?s ?p ?o } }" % frozen
    else:
        remove = "DELETE { GRAPH <%s> { ?s ?p ?o } } WHERE { GRAPH <%s> { ?s ?p ?o } }" % (target, frozen)
    return [remove, "DROP SILENT GRAPH <%s>" % frozen], n_seed, n_del


def run_units(update, count, post_ttl, write_one, ttl, graph, writes, teardown, exclude_existing=True):
    """Stage every unit, then perform its write. Appends the teardown statements to
    `teardown` as it goes (the caller owns the list, so a failure keeps what was staged).
    Returns (quads excluded as pre-existing, quads the teardown will remove)."""
    excluded = to_delete = 0
    prefixes, body = _ttl_parts(ttl)
    stmts, n_seed, n_del = stage_unit(update, count, graph, uuid.uuid4().hex, prefixes, body,
                                      exclude_existing)
    teardown.extend(stmts)
    excluded += n_seed - n_del
    to_delete += n_del
    post_ttl()
    for idx, (label, sparql) in enumerate(writes):
        prefixes, body = _insert_parts(sparql)
        stmts, n_seed, n_del = stage_unit(update, count, None, uuid.uuid4().hex, prefixes, body,
                                          exclude_existing)
        teardown.extend(stmts)
        excluded += n_seed - n_del
        to_delete += n_del
        write_one(idx, label, sparql)
    return excluded, to_delete


DELETE_WHERE_SCOPE = (
    "topic UPDATE, per topic: DELETE WHERE { <topic_uri> rdfs:label ?l } and "
    "DELETE WHERE { <mention_uri> ?p ?o }. topic_uri = pwg:topic_<slug>, slug from the "
    "run-unique marker (ZEPHYRT<stamp> / QUARTZT<stamp>); mention_uri = "
    "topicmention_<uuid5(conversation_id, slug)>, conversation_id = ostler-walk-<marker>.")


def plan_writes(settings, writes):
    """The SPARQL each write executes, computed without I/O, aligned with `writes`. The
    probe posts through the shipped writers (write_topics for L2, write_decision for
    decisions); those build the SAME text from the same arguments (NOW_ISO fixed)."""
    from src import topic_writer
    de = _decision_extractor()
    plan = []
    for w in writes:
        if w["kind"] == "topic":
            sparql = topic_writer.build_topic_update(w["conv"], w["topics"], settings, metadata=w["meta"])
            plan.append(("topic_" + w["level"], sparql))
        else:
            plan.append(("decision_" + w["level"], de.build_decision_sparql(w["decision"], now_iso=NOW_ISO)))
    return plan


class SeedRejected(RuntimeError):
    """The store refused the Turtle itself (nothing of the seed landed)."""


def refusal_reason(environ):
    """Why the seed must not run, or None. Fail closed on an ambient store setting."""
    if environ.get("OSTLER_OXIGRAPH_URL") and not environ.get("NO_L3_SEED_OXIGRAPH_URL"):
        return ("OSTLER_OXIGRAPH_URL is set but NO_L3_SEED_OXIGRAPH_URL is not: refusing, so "
                "no ambient CM048 setting can choose the store the seed writes to")
    return None


def main():
    payload = json.loads(sys.argv[1])
    reason = refusal_reason(os.environ)
    if reason:
        print("refused: " + reason, file=sys.stderr)
        print(json.dumps({"refused": True, "rc": 5, "reason": reason, "posted": False,
                          "teardown_sparql": []}))
        return 5
    ingest, settings, ttl, subjects, writes, slugs = build(payload)
    graph = f"urn:ostler:user/{settings.user_id}"
    out = {"subjects": subjects, "bytes": len(ttl), "posted": False, "topic_slugs": slugs,
           "graph": graph, "rc": 0}
    teardown = []   # kept by reference: a failure below still prints what was staged
    rc = 0
    if payload.get("post"):
        import httpx
        from src import topic_writer
        de = _decision_extractor()
        client = httpx.Client(timeout=60.0, transport=httpx.HTTPTransport(proxy=None))
        url = settings.oxigraph_url

        def update(sparql):
            r = client.post(url + "/update", content=sparql.encode("utf-8"),
                            headers={"Content-Type": "application/sparql-update"})
            if r.status_code >= 400:
                raise RuntimeError("update HTTP %s" % r.status_code)

        def count(sparql):
            r = client.post(url + "/query", content=sparql.encode("utf-8"),
                            headers={"Content-Type": "application/sparql-query",
                                     "Accept": "application/sparql-results+json"})
            if r.status_code >= 400:
                raise RuntimeError("count HTTP %s" % r.status_code)
            return int(r.json()["results"]["bindings"][0]["n"]["value"])

        def post_ttl():
            r = client.post(url + "/store", content=ttl.encode(), params={"graph": graph},
                            headers={"Content-Type": "text/turtle"})
            if r.status_code >= 400:
                raise SeedRejected("oxigraph rejected the seed: HTTP %s %s"
                                   % (r.status_code, (r.text or "")[:300]))
            out["posted"] = True

        written = {}

        def write_one(idx, label, sparql):
            w = writes[idx]
            if w["kind"] == "topic" and w["level"] == "L2":
                n = topic_writer.write_topics(conversation_id=w["conv"], topics=w["topics"],
                                              settings=settings, privacy_level="L2", metadata=w["meta"])
                written["topic_L2"] = {"written": n, "writer": "topic_writer.write_topics"}
            elif w["kind"] == "topic":
                update(sparql)
                written["topic_L3"] = {"written": 1, "writer": "topic_writer.build_topic_update (refusal bypassed)"}
            else:
                de.write_decision(url, w["decision"], now_iso=NOW_ISO)
                written["decision_" + w["level"]] = {"written": 1, "writer": "decision_extractor.write_decision"}

        plan = plan_writes(settings, writes)
        try:
            excluded, to_delete = run_units(update, count, post_ttl, write_one, ttl, graph, plan,
                                            teardown, exclude_existing=True)
            out["writes"] = written
            out["excluded_quads"] = excluded
            out["to_delete_quads"] = to_delete
        except SeedRejected as exc:
            print(str(exc), file=sys.stderr)
            rc = 3
        except Exception as exc:  # noqa: BLE001 -- reported; the caller judges it
            print("seed write failed: %s: %s" % (type(exc).__name__, str(exc)[:300]), file=sys.stderr)
            rc = 4
    out["teardown_sparql"] = teardown
    out["rc"] = rc
    print(json.dumps(out))
    return rc


if __name__ == "__main__":
    sys.exit(main())
