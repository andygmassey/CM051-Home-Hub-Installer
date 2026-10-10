"""Synthetic SCALE fixture for the box walk (v1.0.107 cut #16 console walk).

WHY. Andy's #16 console walk failed because ostler-qdrant (Qdrant v1.12.1,
compose with no ulimits, so nofile=1024) ran out of file descriptors: 751
RocksDB .sst files were open (reminders_knowledge 394, apple_notes 276) after
the hydrate's many small upserts. Places then wrote 0 of 979 and printed
status=ok. The synthetic walk could not see it: its seed is a handful of rows.

WHAT DRIVES THE SST COUNT (measured on the pinned digest, 2 CPUs as the
installer's `colima start --cpu 2`, see scripts/qdrant_fd_scale_proof.sh):
the CM024 `embed` step upserts ONE point per call, paced by the Ollama embed
between calls. Each Qdrant flush cycle (every few seconds) writes new L0 SST
files for every segment that took a write, and on this image they are not
compacted away while the writes continue. So the SST count grows with the
WALL TIME of paced writes, not with the number of points: 1,500 points in
5 s left 12 SSTs, while 3,000 points paced 50 ms apart left 221 more. Open
fds track SSTs (about 95 + SSTs). Crossing 1,024 fds takes roughly 930 s of
paced writes across the knowledge collections.

So the volume below is sized in CHUNKS x per-chunk embed time. The defaults
(9,000 one-chunk reminders, 6,000 three-chunk notes: about 27,000 chunks) give
about 18 minutes of paced writes at 40 ms a chunk. The box's real embed time
is NOT INSTRUMENTED from this repo; scale with --reminders/--notes, and the
probe qdrant_has_fd_headroom_and_writes_land reads the result either way.

PEOPLE. 4,200+ unique synthetic people across the three export shapes the
importers read, overlapping on purpose so dedupe has work: LinkedIn
Connections.csv (notes header, then First Name,...), Facebook your_friends.json
({"friends_v2": [...]}) and an Apple Contacts vCard 3.0 file.

SYNTHETIC ONLY. Names are the approved cast tokens with a middle initial,
emails are @example.com, phone numbers are the Ofcom drama range (07700 900xxx),
organisations are cast organisations. Deterministic for a given --seed: the
same seed writes byte-identical files (sha256 in manifest.json).

USAGE
  generate  --out DIR [--seed 108] [--people 4200] [--reminders 9000] [--notes 6000]
  replay    --fixture DIR [--knowledge-bin PATH] [--qdrant URL] [--ollama URL]
            Runs the INSTALLED hydrate path (ostler-knowledge convert + embed,
            the exact flags install.sh uses) over the fixture's reminders and
            notes, into reminders_knowledge and apple_notes_knowledge, logging
            to ~/.ostler/diagnostics/<UTC stamp>-scale-fixture/hydrate-*.log
            so the probe reads the step's own counts.
"""
import argparse
import csv
import hashlib
import io
import json
import os
import random
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

# Approved synthetic cast (.pii-name-registry.tsv), lower case on purpose.
_FIRST = ("jane john alex alexander alexandra mary raj liz elizabeth sam samuel jonathan ana ben "
          "carl tom thomas hans alison allison ali catherine katherine kathryn kathleen geoffrey "
          "jeffrey stephen steven philip phillip lawrence laurence nathaniel nathan charles rebecca "
          "margaret bob robert").split()
_LAST = "doe smith jones ross coe patel brown andersen stewart".split()
_ORGS = ("acme corp", "globex corp", "initech corp", "riverside town")
_TOPICS = ("budget review", "venue shortlist", "quarterly plan", "garden project", "school run",
           "boiler service", "book club", "travel booking", "insurance renewal", "dentist visit")
_WORDS = ("the plan needs another pass before we share it with the group and agree the next "
          "steps for the spring with everyone who said they could help on the day").split()
BASE = datetime(2030, 1, 1, 9, 0, 0, tzinfo=timezone.utc)

# F12: a neighbour's note, written into the OWNER's named graph but ABOUT the
# neighbour. MUST equal lib/owner_digest.py NEIGHBOUR_NOTE (pinned by
# tests/test_scale_gate_probes.sh). owner_digest_knows_the_owner FAILS if it is
# ever presented as the owner's.
NEIGHBOUR_NOTE = "Philip Coe is based in Initech Town"
NEIGHBOUR_URI = "https://schema.ostler.ai/ontology#person_walkfixture_neighbour"
NEIGHBOUR_FACT = "urn:ostler:fact/walkfixture-neighbour-location"


def _cap(w):
    return w[:1].upper() + w[1:]


def people(rnd, n):
    """n unique synthetic people: first, middle initial, last."""
    seen, out = set(), []
    while len(out) < n:
        f, m, l = rnd.choice(_FIRST), chr(65 + rnd.randrange(26)), rnd.choice(_LAST)
        key = (f, m, l)
        if key in seen:
            continue
        seen.add(key)
        i = len(out)
        out.append({
            "first": _cap(f), "middle": m, "last": _cap(l),
            "email": "%s.%s.%s.%d@example.com" % (f, m.lower(), l, i),
            # Ofcom drama range: 07700 900000-900999. Only the first 1,000 get one.
            "phone": ("+44 7700 900%03d" % i) if i < 1000 else "",
            "org": " ".join(_cap(w) for w in rnd.choice(_ORGS).split()),
            "title": rnd.choice(("Engineer", "Designer", "Manager", "Teacher", "Consultant")),
        })
    return out


def _linkedin_csv(rows):
    buf = io.StringIO()
    buf.write("Notes:\n\"When exporting your connection data, you may notice that some of the email "
              "addresses are missing.\"\n\n")
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["First Name", "Last Name", "URL", "Email Address", "Company", "Position", "Connected On"])
    for i, p in enumerate(rows):
        w.writerow([p["first"], p["last"], "https://www.linkedin.example/in/fixture-%d" % i,
                    p["email"] if i % 3 else "", p["org"], p["title"],
                    (BASE - timedelta(days=i % 2000)).strftime("%d %b %Y")])
    return buf.getvalue()


def _facebook_json(rows):
    return json.dumps({"friends_v2": [
        {"name": "%s %s" % (p["first"], p["last"]), "timestamp": int((BASE - timedelta(days=i)).timestamp())}
        for i, p in enumerate(rows)]}, indent=2)


def _vcards(rows):
    out = []
    for p in rows:
        out += ["BEGIN:VCARD", "VERSION:3.0",
                "N:%s;%s;%s.;;" % (p["last"], p["first"], p["middle"]),
                "FN:%s %s. %s" % (p["first"], p["middle"], p["last"]),
                "ORG:%s" % p["org"], "TITLE:%s" % p["title"],
                "EMAIL;TYPE=INTERNET:%s" % p["email"]]
        if p["phone"]:
            out.append("TEL;TYPE=CELL:%s" % p["phone"])
        out.append("END:VCARD")
    return "\r\n".join(out) + "\r\n"


def _reminders(rnd, ppl, n):
    out = []
    for i in range(n):
        p = ppl[i % len(ppl)]
        due = BASE + timedelta(days=rnd.randrange(-200, 200), hours=rnd.randrange(24))
        done = rnd.random() < 0.3
        out.append({
            "title": "Call %s about the %s (%d)" % (p["first"], rnd.choice(_TOPICS), i),
            "is_completed": done,
            "due_date": due.isoformat(),
            "completion_date": (due + timedelta(hours=2)).isoformat() if done else None,
            "creation_date": (due - timedelta(days=7)).isoformat(),
            "priority": rnd.choice((0, 1, 5, 9)),
            "notes": "Synthetic reminder %d for the walk scale fixture." % i,
            "list_name": rnd.choice(("Home", "Work", "Family")),
            "is_flagged": rnd.random() < 0.1,
        })
    return out


def _note_body(rnd, i):
    # About 6,000 characters in paragraphs: three chunks at the chunker's
    # 512-token (~2,000 character) limit.
    paras = []
    for j in range(12):
        n = 70 + rnd.randrange(20)
        paras.append(" ".join(rnd.choice(_WORDS) for _ in range(n)).capitalize() + ".")
    return ("Synthetic note %d.\n\n" % i) + "\n\n".join(paras)


def _notes(rnd, n):
    out = []
    for i in range(n):
        body = _note_body(rnd, i)
        made = BASE - timedelta(days=rnd.randrange(1, 900))
        out.append({
            "evernote_guid": "fixture-note-%06d" % i,
            "title": "Notes on the %s %d" % (rnd.choice(_TOPICS), i),
            "content": body,
            "notebook": rnd.choice(("Notes", "Home", "Work")),
            "created": made.isoformat(),
            "updated": (made + timedelta(days=1)).isoformat(),
            "tags": [],
            "source": "apple_notes",
            "compartment_level": 1,
            "is_pinned": False,
            "is_locked": False,
            "word_count": len(body.split()),
        })
    return out


def generate(out_dir, seed=108, n_people=4200, n_reminders=9000, n_notes=6000):
    rnd = random.Random(seed)
    ppl = people(rnd, n_people)
    # Three export shapes, overlapping so dedupe has work:
    # contacts 0..2399, linkedin 1800..3799, facebook 3200..end (+ 0..399).
    contacts = ppl[:2400]
    linkedin = ppl[1800:3800]
    facebook = ppl[3200:] + ppl[:400]
    files = {
        "contacts/contacts.vcf": _vcards(contacts),
        "linkedin/Connections.csv": _linkedin_csv(linkedin),
        "facebook/your_friends.json": _facebook_json(facebook),
        "fda/reminders.json": json.dumps(_reminders(rnd, ppl, n_reminders), indent=2),
        "fda/apple_notes.json": json.dumps(_notes(rnd, n_notes), indent=2),
    }
    manifest = {"seed": seed, "people_unique": len(ppl), "contacts": len(contacts),
                "linkedin": len(linkedin), "facebook": len(facebook),
                "reminders": n_reminders, "notes": n_notes,
                "chunks_estimate": n_reminders + 3 * n_notes, "files": {}}
    for rel, text in files.items():
        path = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = text.encode("utf-8")
        with open(path, "wb") as fh:
            fh.write(data)
        manifest["files"][rel] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    with open(os.path.join(out_dir, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
    return manifest


def replay(fixture, knowledge_bin, qdrant, ollama, home):
    """The installed hydrate path, as install.sh runs it (convert, then embed)."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    diag = os.path.join(home, ".ostler", "diagnostics", stamp + "-scale-fixture")
    os.makedirs(diag, exist_ok=True)
    os.chmod(diag, 0o700)
    env = dict(os.environ, OSTLER_QDRANT_URL=qdrant, OSTLER_OLLAMA_URL=ollama)
    results = {}
    for source, collection, log in (("reminders", "reminders_knowledge", "hydrate-reminders.log"),
                                    ("apple_notes", "apple_notes_knowledge", "hydrate-apple-notes.log")):
        src = os.path.join(fixture, "fda", source + ".json")
        staging = os.path.join(diag, "staging-" + source)
        db = os.path.join(diag, "knowledge-metadata-%s.db" % source)
        t0 = time.time()
        with open(os.path.join(diag, log), "ab") as fh:
            rc = subprocess.call([knowledge_bin, "convert", "--source", source, src, "--output", staging],
                                 env=env, stdout=fh, stderr=subprocess.STDOUT)
            if rc == 0:
                rc = subprocess.call([knowledge_bin, "embed", staging, "--collection", collection,
                                      "--embedding-model", os.environ.get("OSTLER_KNOWLEDGE_EMBED_MODEL", "nomic-embed-text"),
                                      "--max-compartment-level", "2", "--db-path", db],
                                     env=env, stdout=fh, stderr=subprocess.STDOUT)
        results[source] = {"rc": rc, "secs": round(time.time() - t0, 1), "log": os.path.join(diag, log)}
    with open(os.path.join(diag, "scale-fixture.json"), "w") as fh:
        json.dump(results, fh, indent=2)
    return diag, results


def _owner_user_id(home):
    for path in (os.path.join(home, ".ostler", "config", ".env"), os.path.join(home, ".ostler", ".env")):
        try:
            for line in open(path):
                if line.strip().startswith("USER_ID="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'").lower()
        except OSError:
            pass
    return ""


def neighbour_update(uid, now):
    """The SPARQL UPDATE that seeds the neighbour note (idempotent)."""
    return ("DELETE WHERE { GRAPH ?g { <%s> ?p ?o } } ;\n"
           "INSERT DATA {\n <%s> a <https://schema.ostler.ai/ontology#Person> ;"
           " <https://schema.ostler.ai/ontology#displayName> \"Philip Coe\" .\n"
           " GRAPH <urn:ostler:user/%s> {\n  <%s> a <urn:ostler:Fact> ; <urn:ostler:text> \"%s\" ;"
           " <urn:ostler:about> <%s> ; <urn:ostler:userId> \"%s\" ; <urn:ostler:type> \"location\" ;"
           " <urn:ostler:domain> \"personal\" ; <urn:ostler:privacyLevel> \"L1\" ;"
           " <urn:ostler:observedAt> \"%s\"^^<http://www.w3.org/2001/XMLSchema#dateTime> .\n }\n}"
           % (NEIGHBOUR_FACT, NEIGHBOUR_URI, uid, NEIGHBOUR_FACT, NEIGHBOUR_NOTE, NEIGHBOUR_URI, uid, now))


def seed_neighbour(home, store="http://127.0.0.1:7878", wait_s=600):
    """Write the neighbour's note into the owner's named graph (the way CM048
    writes a Fact, urn:ostler:about = the NEIGHBOUR), refresh the digest, and
    wait for CONTEXT.md to be rewritten. -> state word."""
    import urllib.request
    uid = _owner_user_id(home)
    if not uid:
        return "failed-no-user-id"
    tok = os.environ.get("OXIGRAPH_TOKEN") or ""
    if not tok:
        try:
            tok = open(os.path.join(home, ".ostler", "secrets", "oxigraph_token")).read().strip()
        except OSError:
            tok = ""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    upd = neighbour_update(uid, now)
    headers = {"Content-Type": "application/sparql-update"}
    if tok:
        headers["Authorization"] = "Bearer " + tok
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        opener.open(urllib.request.Request(store + "/update", data=upd.encode(), headers=headers, method="POST"), timeout=30).read()
    except Exception as e:
        return "failed-write-%s" % type(e).__name__
    ctx = os.path.join(home, ".ostler", "assistant-config", "workspace", "CONTEXT.md")
    before = os.path.getmtime(ctx) if os.path.exists(ctx) else 0
    subprocess.call(["launchctl", "kickstart", "-k", "gui/%d/com.creativemachines.ostler.context-refresh" % os.getuid()],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + wait_s
    while time.time() < deadline:
        if os.path.exists(ctx) and os.path.getmtime(ctx) > before:
            return "seeded"
        time.sleep(5)
    return "failed-digest-not-rewritten"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--out", required=True)
    g.add_argument("--seed", type=int, default=108)
    g.add_argument("--people", type=int, default=4200)
    g.add_argument("--reminders", type=int, default=9000)
    g.add_argument("--notes", type=int, default=6000)
    r = sub.add_parser("replay")
    r.add_argument("--fixture", required=True)
    r.add_argument("--knowledge-bin", default=os.environ.get("OSTLER_KNOWLEDGE_BIN", "/usr/local/bin/ostler-knowledge"))
    r.add_argument("--qdrant", default=os.environ.get("QDRANT_URL", "http://localhost:6333"))
    r.add_argument("--ollama", default=os.environ.get("EMBED_OLLAMA_URL", "http://localhost:11434"))
    r.add_argument("--home", default=os.path.expanduser("~"))
    nbp = sub.add_parser("seed-neighbour")
    nbp.add_argument("--home", default=os.path.expanduser("~"))
    a = ap.parse_args(argv)
    if a.cmd == "seed-neighbour":
        state = seed_neighbour(a.home)
        print(state)
        return 0 if state == "seeded" else 1
    if a.cmd == "generate":
        if a.people < 4000:
            ap.error("--people must be at least 4000 (the scale this fixture exists for)")
        print(json.dumps(generate(a.out, a.seed, a.people, a.reminders, a.notes), indent=2, sort_keys=True))
        return 0
    diag, res = replay(a.fixture, a.knowledge_bin, a.qdrant, a.ollama, a.home)
    print(json.dumps({"diagnostics": diag, "steps": res}, indent=2))
    return 0 if all(v["rc"] == 0 for v in res.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
