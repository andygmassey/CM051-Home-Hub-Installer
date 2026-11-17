#!/usr/bin/env python3
# lib/no_l3_graph_seed.py -- runs ON THE BOX under the CM048 venv python
# (~/.ostler/services/cm048/.venv/bin/python3, cwd = the CM048 checkout), driven
# by lib/no_l3_box.py. Never run on the walker's machine.
#
# It builds the graph rows for the timeline and brief paths with CM048's OWN
# serialisers (src.ingest._conversation_to_triples, _fact_to_triples,
# _todo_to_triples, the same functions pwg-convo's step 09 calls) and POSTs them
# the way ingest._write_oxigraph does: Turtle to <oxigraph>/store?graph=
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
#
# stdout: one JSON object. Diagnostics go to stderr, which the caller keeps.
import json
import re
import sys

PWG_NS = "https://schema.ostler.ai/ontology#"


def build(payload):
    from src import ingest
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
    cleaned = []
    for b in blocks:
        cleaned.append("\n".join(l for l in b.split("\n") if not l.startswith("@prefix ")))
    ttl = ingest._turtle_prefixes() + "\n" + "\n\n".join(cleaned)
    subjects = sorted(set(re.findall(r"^<(urn:[^>\s]+)> a ", ttl, re.M)))
    return ingest, settings, ttl, subjects


def main():
    payload = json.loads(sys.argv[1])
    ingest, settings, ttl, subjects = build(payload)
    out = {"subjects": subjects, "bytes": len(ttl), "posted": False}
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
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
