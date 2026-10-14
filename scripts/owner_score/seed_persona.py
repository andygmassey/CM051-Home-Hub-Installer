#!/usr/bin/env python3
"""Seed the SYNTHETIC persona (persona.json) into a box's graph and conversation
store, under a namespace that can be purged exactly.  Runs ON THE BOX.

    seed_persona.py seed  [--user-id U] [--store URL] [--conversations-root DIR]
    seed_persona.py count [same]
    seed_persona.py purge [same]

WHY. Until now the persona reached the assistant only through CONTEXT.md, so
the 80 questions never exercised pwg_people / pwg_knowledge_search. This puts
the same facts where those tools look, so a run measures retrieval as well as
reading. The score is split in two (SCORE-CONTEXT-ONLY, SCORE-NEEDS-RETRIEVAL)
so a gain from seeding is never mistaken for a product gain.

THE NAMESPACE (the thing that makes purge exact)
  graph:  every subject this tool writes has an IRI starting
          https://schema.ostler.ai/ontology#ownerscoreseed_
          People and facts keep the shapes the product writes: a pwg:Person in
          the default graph (the shape POST /api/v1/memory/assert mints), and
          each fact as a urn:ostler:Fact in the owner's named graph
          urn:ostler:user/<USER_ID> (the shape CM048 writes and the readers
          scope to; the --union-default-graph invariant means a graph IRI of
          our own would be invisible to them, which is why the prefix is on
          the IRI and not on the graph).
  files:  conversations land at <root>/<date>/<slug>-<sha1(id)[:8]>/ with
          conversation_id "ownerscoreseed-conv-NN" and owner_score_seed: true
          in the frontmatter; a manifest lists exactly the folders made.
purge deletes subjects with that prefix (default graph and every named graph)
and the marked folders, and nothing else. count prints the numbers that prove
it: before seed, after seed, after purge, with the rest of the store unchanged.

SAFETY. It refuses (exit 10) unless the box is declared synthetic: the
workspace CONTEXT.md carries the persona marker (context_swap.sh only puts it
there on a box it has proven synthetic) or ~/.ostler/state/synthetic-box
exists. purge never needs that: removing our own namespace is always allowed.
Exit: 0 ok, 1 counts did not match, 10 refused, 78 cannot run (no token / no
user id / store unreachable; never reported as a clean zero). Stdlib only.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
NS = "https://schema.ostler.ai/ontology#"
PREFIX = NS + "ownerscoreseed_"
MARKER = "Synthetic owner: Jane Smith"
BATCH = "owner-score-seed"
XSD_DT = "http://www.w3.org/2001/XMLSchema#dateTime"
EX_OK, EX_COUNT, EX_REFUSED, EX_CANNOT = 0, 1, 10, 78

DOMAIN = {"Work": "work", "Family": "family", "Tastes": "preferences", "Routines": "routines",
          "People": "relationship", "Upcoming events": "events", "Open todos": "todos",
          "Recent conversations": "conversation"}

MONTHS = {m: i for i, m in enumerate(
    ["january", "february", "march", "april", "may", "june", "july", "august",
     "september", "october", "november", "december"], 1)}
WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


class Cannot(Exception):
    pass


# ------------------------------------------------------------------ helpers --
def esc(s):
    """Escape for a double-quoted SPARQL literal; control characters are refused."""
    if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", s):
        raise ValueError("control character in a seeded string")
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def slugify(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def person_iri(name):
    return PREFIX + "person_" + slugify(name)


def load_persona(path=None):
    return json.load(open(path or os.path.join(HERE, "persona.json"), encoding="utf-8"))


def named_people(lines):
    """Full names found in the People section: a line opening with two capitalised
    words, or '... doctor First Last'. Pure; the persona is synthetic."""
    names = []
    for ln in lines:
        m = re.match(r"([A-Z][a-z]+ [A-Z][a-z]+)\b", ln) or re.search(r"doctor ([A-Z][a-z]+ [A-Z][a-z]+)", ln)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return names


def people_for_line(line, names):
    """Which named people a People line is about: full names in it, else a unique first name."""
    hit = [n for n in names if n in line]
    if hit:
        return hit
    return [n for n in names if len([x for x in names if x.split()[0] == n.split()[0]]) == 1
            and re.search(r"\b%s\b" % n.split()[0], line)]


def conversation_date(line, as_of):
    """The day a 'Recent conversations' line happened, from its own words and the
    persona's as_of date. Explicit 'D Month' wins; then yesterday; then a weekday
    name in its first words (the latest such day before as_of); 'last week' is
    as_of minus 7 days. A date later in the sentence ('booked for 20 October')
    is what the conversation was ABOUT, not when it happened, and is ignored."""
    d0 = date.fromisoformat(as_of)
    m = re.match(r"(?:On )?(?:[A-Z][a-z]+day )?(\d{1,2}) (%s)\b" % "|".join(m.capitalize() for m in MONTHS), line)
    if not m:   # "On Tuesday 6 October ..." / "On Sunday 4 October ..."
        m = re.match(r"On [A-Z][a-z]+day (\d{1,2}) (%s)\b" % "|".join(m.capitalize() for m in MONTHS), line)
    if m:
        return date(d0.year, MONTHS[m.group(2).lower()], int(m.group(1)))
    low = line.lower()
    if "yesterday" in low[:80]:
        return d0 - timedelta(days=1)
    for i, wd in enumerate(WEEKDAYS):
        if re.search(r"\b%s\b" % wd, low[:30]):
            back = (d0.weekday() - i) % 7 or 7
            return d0 - timedelta(days=back)
    if "last week" in low:
        return d0 - timedelta(days=7)
    return d0


def build_plan(persona, user_id):
    """-> dict with the SPARQL INSERT, the expected seeded triple count, and the
    conversation folders to write. Pure: no I/O."""
    owner = persona["owner"]
    sections = persona["sections"]
    names = named_people(sections.get("People", []))
    people = [owner] + names
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    default_triples, named_triples = [], []
    for n in people:
        default_triples.append('<%s> a <%sPerson> ; <%sdisplayName> "%s" ; <%ssource> "%s" ; <%screatedAt> "%s" .'
                               % (person_iri(n), NS, NS, esc(n), NS, BATCH, NS, now))
    n_fact = 0
    facts = []   # (text, domain, [about names])

    def fact(text, domain, about):
        facts.append((text, domain, about))

    for title, lines in sections.items():
        dom = DOMAIN.get(title, "personal")
        for ln in lines:
            about = [owner]
            if title == "People":
                about += people_for_line(ln, names)
            fact(ln, dom, about)
    for text, dom, about in facts:
        for who in about:
            n_fact += 1
            iri = PREFIX + "fact_%03d" % n_fact
            named_triples.append(
                '<%s> a <urn:ostler:Fact> ; <urn:ostler:text> "%s" ; <urn:ostler:about> <%s> ; '
                '<urn:ostler:userId> "%s" ; <urn:ostler:domain> "%s" ; <urn:ostler:type> "%s" ; '
                '<urn:ostler:privacyLevel> "L1" ; <urn:ostler:seedBatch> "%s" ; '
                '<urn:ostler:observedAt> "%s"^^<%s> .'
                % (iri, esc(text), person_iri(who), esc(user_id), dom, dom, BATCH,
                   persona["as_of"] + "T09:00:00Z", XSD_DT))
    # triples = one per predicate-object pair
    expected = sum(t.count(" ; ") + 1 for t in default_triples + named_triples)
    update = ("INSERT DATA {\n%s\n GRAPH <urn:ostler:user/%s> {\n%s\n }\n}"
              % ("\n".join(default_triples), esc(user_id), "\n".join(named_triples)))
    convs = []
    for i, ln in enumerate(sections.get("Recent conversations", []), 1):
        cid = "ownerscoreseed-conv-%02d" % i
        day = conversation_date(ln, persona["as_of"])
        folder = os.path.join(day.isoformat(), "%s-%s" % (slugify(ln)[:40].rstrip("-"),
                                                          hashlib.sha1(cid.encode()).hexdigest()[:8]))
        convs.append({"id": cid, "date": day.isoformat(), "folder": folder, "text": ln, "owner": owner})
    return {"update": update, "expected_triples": expected, "conversations": convs, "n_people": len(people),
            "n_facts": n_fact}


def purge_update():
    flt = 'FILTER(STRSTARTS(STR(?s), "%s"))' % PREFIX
    return ("DELETE { ?s ?p ?o } WHERE { ?s ?p ?o %s } ;\n"
            "DELETE { GRAPH ?g { ?s ?p ?o } } WHERE { GRAPH ?g { ?s ?p ?o %s } }" % (flt, flt))


def count_queries():
    f = 'STRSTARTS(STR(?s), "%s")' % PREFIX
    return {
        "seeded_default": "SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o FILTER(%s) }" % f,
        "seeded_named": "SELECT (COUNT(*) AS ?n) WHERE { GRAPH ?g { ?s ?p ?o FILTER(%s) } }" % f,
        "stray_refs": 'SELECT (COUNT(*) AS ?n) WHERE { { ?s ?p ?o FILTER(isIRI(?o) && STRSTARTS(STR(?o), "%s") && !%s) } '
                      'UNION { GRAPH ?g { ?s ?p ?o FILTER(isIRI(?o) && STRSTARTS(STR(?o), "%s") && !%s) } } }' % (PREFIX, f, PREFIX, f),
        "store_total": "SELECT (COUNT(*) AS ?n) WHERE { { ?s ?p ?o } UNION { GRAPH ?g { ?s ?p ?o } } }",
    }


# ------------------------------------------------------------------- store --
class Store:
    def __init__(self, base, token):
        self.base = base.rstrip("/")
        self.token = token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _call(self, path, data, ctype, accept=None):
        h = {"Content-Type": ctype}
        if accept:
            h["Accept"] = accept
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(self.base + path, data=data.encode("utf-8"), headers=h, method="POST")
        try:
            return self.opener.open(req, timeout=60).read()
        except urllib.error.HTTPError as e:
            raise Cannot("the store answered HTTP %s on %s%s" % (
                e.code, path, " (the token, not the graph)" if e.code in (401, 403) else ""))
        except (urllib.error.URLError, OSError) as e:
            raise Cannot("the store at %s is unreachable (%s)" % (self.base, getattr(e, "reason", e)))

    def update(self, sparql):
        self._call("/update", sparql, "application/sparql-update")

    def count(self, sparql):
        raw = self._call("/query", sparql, "application/sparql-query", "application/sparql-results+json")
        try:
            return int(json.loads(raw)["results"]["bindings"][0]["n"]["value"])
        except (ValueError, KeyError, IndexError):
            raise Cannot("the store's count answer was not understood: %r" % raw[:120])

    def counts(self):
        return {k: self.count(q) for k, q in count_queries().items()}


# ------------------------------------------------------------ conversations --
def manifest_path(root):
    return os.path.join(root, ".owner-score-seed-manifest.json")


def write_conversations(root, convs):
    created_dirs, folders = [], []
    for c in convs:
        day_dir = os.path.join(root, c["date"])
        if not os.path.isdir(day_dir):
            created_dirs.append(c["date"])
        d = os.path.join(root, c["folder"])
        os.makedirs(d, exist_ok=True)
        fm = ("---\nconversation_id: %s\nowner_score_seed: true\nstarted_at: %sT09:00:00Z\nprivacy_level: L1\n"
              "participants: [%s]\nsource: synthetic persona (owner-score)\n---\n" % (c["id"], c["date"], c["owner"]))
        open(os.path.join(d, "summary.md"), "w", encoding="utf-8").write(fm + "\n# Summary\n\n" + c["text"] + "\n")
        open(os.path.join(d, "transcript.md"), "w", encoding="utf-8").write(
            fm + "\n# Transcript\n\nSeeded synthetic note, no recording: " + c["text"] + "\n")
        open(os.path.join(d, "todos.md"), "w", encoding="utf-8").write(fm + "\n# Todos\n\nNone.\n")
        folders.append(c["folder"])
    json.dump({"folders": folders, "created_dirs": sorted(set(created_dirs))},
              open(manifest_path(root), "w"), indent=1)
    return len(folders)


def _is_ours(folder):
    p = os.path.join(folder, "summary.md")
    try:
        head = open(p, encoding="utf-8").read(600)
    except OSError:
        return False
    return "owner_score_seed: true" in head and "conversation_id: ownerscoreseed-conv-" in head


def conversation_folders(root):
    """Folders carrying our marker: the manifest's plus any found by scanning."""
    found = set()
    try:
        for f in json.load(open(manifest_path(root)))["folders"]:
            if _is_ours(os.path.join(root, f)):
                found.add(f)
    except (OSError, ValueError, KeyError):
        pass
    if os.path.isdir(root):
        for day in sorted(os.listdir(root)):
            dd = os.path.join(root, day)
            if os.path.isdir(dd):
                for sub in sorted(os.listdir(dd)):
                    if _is_ours(os.path.join(dd, sub)):
                        found.add(os.path.join(day, sub))
    return sorted(found)


def purge_conversations(root):
    n = 0
    for f in conversation_folders(root):
        shutil.rmtree(os.path.join(root, f))
        n += 1
    try:
        created = json.load(open(manifest_path(root)))["created_dirs"]
    except (OSError, ValueError, KeyError):
        created = []
    for day in created:   # only date folders WE created, and only when now empty
        dd = os.path.join(root, day)
        if os.path.isdir(dd) and not os.listdir(dd):
            os.rmdir(dd)
    if os.path.exists(manifest_path(root)):
        os.remove(manifest_path(root))
    return n


# ------------------------------------------------------------------- main --
def resolve_token(a):
    tok = (os.environ.get("OXIGRAPH_TOKEN") or "").strip()
    if tok:
        return tok
    try:
        return open(os.path.expanduser(a.token_path)).read().strip()
    except OSError:
        return ""


def resolve_user_id(a):
    if a.user_id:
        return a.user_id.strip().lower()
    for p in ("~/.ostler/config/.env", "~/.ostler/.env"):
        try:
            for line in open(os.path.expanduser(p)):
                if line.strip().startswith("USER_ID="):
                    return line.split("=", 1)[1].strip().strip("\"'").lower()
        except OSError:
            pass
    return ""


def is_synthetic_box(a):
    state = os.environ.get("OSTLER_STATE_DIR") or os.path.expanduser("~/.ostler/state")
    if os.path.exists(os.path.join(state, "synthetic-box")):
        return True
    ws = a.workspace or os.environ.get("OSTLER_WORKSPACE_DIR") or os.path.expanduser("~/.ostler/assistant-config/workspace")
    try:
        return MARKER in open(os.path.join(ws, "CONTEXT.md"), encoding="utf-8").read()
    except OSError:
        return False


def line(**kw):
    return " ".join("%s=%s" % (k, v) for k, v in kw.items())


def main(argv=None):
    ap = argparse.ArgumentParser(prog="seed_persona")
    ap.add_argument("cmd", choices=("seed", "count", "purge"))
    ap.add_argument("--store", default=os.environ.get("OSTLER_OXIGRAPH_BASE", "http://127.0.0.1:7878"))
    ap.add_argument("--token-path", default="~/.ostler/secrets/oxigraph_token")
    ap.add_argument("--user-id")
    ap.add_argument("--conversations-root", default=os.environ.get("OSTLER_CONVERSATIONS_ROOT",
                                                                    "~/Documents/Ostler/Conversations"))
    ap.add_argument("--workspace")
    ap.add_argument("--persona")
    a = ap.parse_args(argv)
    root = os.path.expanduser(a.conversations_root)
    try:
        store = Store(a.store, resolve_token(a))
        if a.cmd == "seed":
            if not is_synthetic_box(a):
                print("REFUSED: this box is not declared synthetic (no persona CONTEXT.md, no ~/.ostler/state/synthetic-box). "
                      "Nothing was written.")
                return EX_REFUSED
            uid = resolve_user_id(a)
            if not uid:
                print("CANNOT-RUN: no USER_ID (~/.ostler/config/.env or --user-id), so the owner's graph is unknown")
                return EX_CANNOT
            plan = build_plan(load_persona(a.persona), uid)
            before = store.counts()
            if before["seeded_default"] or before["seeded_named"]:
                print("REFUSED: a previous seed is still in the store (%s). Run purge first." % line(**before))
                return EX_REFUSED
            print("COUNT before-seed " + line(**before))
            store.update(plan["update"])
            n_conv = write_conversations(root, plan["conversations"])
            after = store.counts()
            print("COUNT after-seed " + line(**after, conversation_folders=len(conversation_folders(root))))
            got = after["seeded_default"] + after["seeded_named"]
            ok = (got == plan["expected_triples"] and after["store_total"] - before["store_total"] == got
                  and n_conv == len(plan["conversations"]))
            print("SEEDED triples=%d expected=%d people=%d facts=%d conversations=%d %s"
                  % (got, plan["expected_triples"], plan["n_people"], plan["n_facts"], n_conv, "OK" if ok else "MISMATCH"))
            return EX_OK if ok else EX_COUNT
        if a.cmd == "count":
            print("COUNT now " + line(**store.counts(), conversation_folders=len(conversation_folders(root))))
            return EX_OK
        before = store.counts()
        nf = len(conversation_folders(root))
        print("COUNT before-purge " + line(**before, conversation_folders=nf))
        store.update(purge_update())
        purge_conversations(root)
        after = store.counts()
        left = len(conversation_folders(root))
        print("COUNT after-purge " + line(**after, conversation_folders=left))
        removed = before["seeded_default"] + before["seeded_named"]
        ok = (after["seeded_default"] == 0 and after["seeded_named"] == 0 and left == 0
              and before["store_total"] - after["store_total"] == removed)
        print("PURGED triples=%d conversations=%d rest_of_store_unchanged=%s %s"
              % (removed, nf, "yes" if before["store_total"] - removed == after["store_total"] else "NO",
                 "OK" if ok else "MISMATCH"))
        if after["stray_refs"]:
            print("NOTE   %d triples outside the namespace point at seeded IRIs; they were not seeded, so they were left" % after["stray_refs"])
        return EX_OK if ok else EX_COUNT
    except Cannot as e:
        print("CANNOT-RUN: %s" % e)
        return EX_CANNOT


if __name__ == "__main__":
    sys.exit(main())
