#!/usr/bin/env python3
"""data_conservation: per-row salted-hash evidence, written ON THE BOX.

Instrumentation only. collect() still returns the same facts (counts). It also
writes data_conservation_rows_*.json into the probe evidence dir (0600): a
per-run salt, per source the stored row ids and content keys as salted
sha256, per people store (Qdrant vs Oxigraph) the distinct and duplicate counts,
and the set differences between the two stores. The IN side per row is
NOT INSTRUMENTED (importers write counts only), and the file says so.

No plaintext from the fixture may reach the file, and the driver output gets
counts only. Runs collect() end to end with the stores faked.
"""
import glob
import importlib.util
import json
import os
import stat
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "data_conservation", os.path.join(ROOT, "scripts", "box_walk_probes", "lib", "data_conservation.py"))
dc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dc)

# Synthetic fixture. Every token below must be absent from the evidence file.
FIXTURE_TOKENS = ("Alex Doe", "Ben Doe", "Tom Smith", "alex doe", "ben doe", "tom smith",
                  "fixture-point", "example.org", "fixture jazz set")

QDRANT = {
    "people": [
        ("fixture-point-001", {"source": "contacts", "display_name": "Alex Doe", "contact_type": "person", "privacy_level": "L1"}),
        ("fixture-point-002", {"source": "contacts", "display_name": "Ben Doe", "contact_type": "person", "privacy_level": "L1"}),
        ("fixture-point-003", {"source": "contacts", "display_name": "Ben Doe", "contact_type": "person", "privacy_level": "L1"}),
    ],
    "preferences": [
        ("fixture-point-101", {"source": "whatsapp", "category": "music", "subject": "fixture jazz set", "preference_type": "like", "privacy_level": "L1"}),
    ],
}
# Graph persons: subject IRI and display name. Ben appears once here, Tom only
# here (the graph-only difference), Alex in both.
GRAPH_PERSONS = [
    ("https://example.org/person/g-1", "Alex Doe"),
    ("https://example.org/person/g-2", "Ben Doe"),
    ("https://example.org/person/g-3", "Tom Smith"),
]


def fake_http(url, body=None, headers=None, form=None, timeout=60):
    if "/points/scroll" in url:
        coll = url.split("/collections/")[1].split("/")[0]
        pts = [{"id": pid, "payload": pl} for pid, pl in QDRANT.get(coll, [])]
        return 200, {"result": {"points": pts, "next_page_offset": None}}
    if "/collections/" in url:
        coll = url.split("/collections/")[1]
        return 200, {"result": {"points_count": len(QDRANT.get(coll, []))}}
    return 0, None


def fake_sparql(q, hdr):
    if "displayName" in q and "Person" in q:
        return [{"p": {"value": s}, "d": {"value": n}} for s, n in GRAPH_PERSONS]
    return []


def _set_env_and_patch(evidence_dir, tmp):
    os.environ["OSTLER_WALK_EVIDENCE_DIR"] = evidence_dir
    dc.HOME = tmp
    dc.LOG_DIR = os.path.join(tmp, "logs")
    dc.WIKI_DIR = os.path.join(tmp, "wiki")
    dc.STORE_CONF = os.path.join(tmp, "no-store-curl.conf")
    dc._http = fake_http
    dc._sparql = fake_sparql


def main():
    fails = []

    def check(label, ok):
        print("  %s  %s" % ("ok   " if ok else "FAIL ", label))
        if not ok:
            fails.append(label)

    tmp = tempfile.mkdtemp(prefix="dc-row-ev-")
    ev_dir = os.path.join(tmp, "evidence")
    _set_env_and_patch(ev_dir, tmp)
    blob = dc.collect()
    facts, meta = blob["facts"], blob["meta"]

    rows_meta = meta.get("row_evidence") or {}
    check("collect() records where the row evidence went (no error)",
          bool(rows_meta.get("path")) and not rows_meta.get("error"))
    files = sorted(glob.glob(os.path.join(ev_dir, "data_conservation_rows_*.json")))
    check("the row evidence file is written into the evidence dir", len(files) == 1)
    check("the facts are still counts only (no row keys leak into the verdict input)",
          not any("row" in k for k in facts))
    if files:
        raw = open(files[0], "rb").read()
        ev = json.loads(raw.decode("utf-8"))
        leaked = [t for t in FIXTURE_TOKENS if t.encode("utf-8") in raw]
        check("evidence file holds no plaintext fixture token (%s)" % (leaked or "none present"), not leaked)
        check("evidence file carries a per-run salt", isinstance(ev.get("salt"), str) and len(ev["salt"]) >= 16)
        mode = stat.S_IMODE(os.stat(files[0]).st_mode)
        check("evidence file is owner-only (0600), got %s" % oct(mode), mode == 0o600)
        sources = ev.get("sources") or {}
        contacts = sources.get("contacts") or {}
        check("contacts: the in-set per row is NOT INSTRUMENTED, said in the file",
              "NOT INSTRUMENTED" in json.dumps(contacts.get("in", "")))
        qids = (contacts.get("stored") or {}).get("qdrant_ids") or []
        check("contacts: three stored Qdrant rows, each id a 64-hex salted hash",
              len(qids) == 3 and all(len(x) == 64 for x in qids))
        check("contacts: the stored rows are keyed under their source, not the collection",
              (contacts.get("by_collection") or {}).get("people") == 3)
        people = ev.get("people") or {}
        per = people.get("per_store") or {}
        check("people: Qdrant has two distinct names over three rows (one duplicate)",
              per.get("qdrant", {}).get("rows") == 3 and per.get("qdrant", {}).get("distinct") == 2
              and per.get("qdrant", {}).get("duplicate_rows") == 1)
        check("people: graph has three distinct names over three rows",
              per.get("graph", {}).get("rows") == 3 and per.get("graph", {}).get("distinct") == 3)
        diff = people.get("diff") or {}
        check("people: the graph holds one name Qdrant lacks (positive control, hash listed)",
              diff.get("graph_not_qdrant", {}).get("count") == 1
              and len(diff.get("graph_not_qdrant", {}).get("hashes") or []) == 1)
        check("people: Qdrant holds no name the graph lacks",
              diff.get("qdrant_not_graph", {}).get("count") == 0)
        whatsapp = sources.get("whatsapp") or {}
        check("whatsapp: per-row stored id recorded under its source",
              len((whatsapp.get("stored") or {}).get("qdrant_ids") or []) == 1)
        check("the in-set is never guessed: meta says the in side is unread",
              rows_meta.get("unreadable") == [] and rows_meta.get("stored_rows") == 4)

    # Outage is not a verdict: an evidence dir that is a FILE must not raise.
    bad = os.path.join(tmp, "not-a-dir")
    open(bad, "w").close()
    _set_env_and_patch(bad, tmp)
    blob2 = dc.collect()
    check("an unwritable evidence dir records an error and still returns the facts",
          bool((blob2["meta"].get("row_evidence") or {}).get("error")) and bool(blob2["facts"]))

    print("every check held" if not fails else "FAILED: %d" % len(fails))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
