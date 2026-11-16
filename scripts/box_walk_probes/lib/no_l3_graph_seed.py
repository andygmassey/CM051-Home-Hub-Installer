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

PWG_NS = "https://schema.ostler.ai/ontology#"
HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_DATE = "2026-11-10"


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
        dec = de.ExtractedDecision(summary=f"{mkr} approve the quarry lease renewal",
                                   source_uri=meeting, date=FIXTURE_DATE,
                                   about_persons=[person_uri], status="active")
        extra_subjects += [dec.uri, meeting]
        writes.append({"kind": "decision", "level": lvl, "decision": dec})

    cleaned = []
    for b in blocks:
        cleaned.append("\n".join(l for l in b.split("\n") if not l.startswith("@prefix ")))
    ttl = ingest._turtle_prefixes() + "\n" + "\n\n".join(cleaned)
    subjects = sorted(set(re.findall(r"^<(urn:[^>\s]+)> a ", ttl, re.M)) | set(extra_subjects))
    return ingest, settings, ttl, subjects, writes, slugs


def _post_writes(settings, writes):
    """Post the topic and decision rows. L2 topics go through the SHIPPED
    write_topics (its own gate and POST). The L3 topic is posted from the shipped
    builder's output, bypassing only write_topics' L3 refusal (see the header)."""
    import httpx
    from src import topic_writer
    de = _decision_extractor()
    out = {}
    for w in writes:
        if w["kind"] == "topic" and w["level"] == "L2":
            n = topic_writer.write_topics(conversation_id=w["conv"], topics=w["topics"],
                                          settings=settings, privacy_level="L2", metadata=w["meta"])
            out["topic_L2"] = {"written": n, "writer": "topic_writer.write_topics"}
        elif w["kind"] == "topic":
            sparql = topic_writer.build_topic_update(w["conv"], w["topics"], settings, metadata=w["meta"])
            with httpx.Client(timeout=60.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
                r = hc.post(f"{settings.oxigraph_url}/update", content=sparql.encode("utf-8"),
                            headers={"Content-Type": "application/sparql-update"})
            if r.status_code >= 400:
                raise RuntimeError("L3 topic update rejected: HTTP %s" % r.status_code)
            out["topic_L3"] = {"written": 1, "writer": "topic_writer.build_topic_update (refusal bypassed)"}
        else:
            de.write_decision(settings.oxigraph_url, w["decision"])
            out["decision_" + w["level"]] = {"written": 1, "writer": "decision_extractor.write_decision"}
    return out


def main():
    payload = json.loads(sys.argv[1])
    ingest, settings, ttl, subjects, writes, slugs = build(payload)
    out = {"subjects": subjects, "bytes": len(ttl), "posted": False, "topic_slugs": slugs}
    if payload.get("post"):
        import httpx
        graph = f"urn:ostler:user/{settings.user_id}"
        with httpx.Client(timeout=60.0, transport=httpx.HTTPTransport(proxy=None)) as hc:
            resp = hc.post(f"{settings.oxigraph_url}/store", content=ttl.encode(),
                           headers={"Content-Type": "text/turtle"}, params={"graph": graph})
            if resp.status_code >= 400:
                print("oxigraph rejected the seed: HTTP %s %s" % (resp.status_code, (resp.text or "")[:300]),
                      file=sys.stderr)
                return 3
        out["posted"] = True
        out["graph"] = graph
        try:
            out["writes"] = _post_writes(settings, writes)
        except Exception as exc:  # noqa: BLE001 -- reported; the caller judges it
            print("topic/decision write failed: %s: %s" % (type(exc).__name__, str(exc)[:300]), file=sys.stderr)
            return 4
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
