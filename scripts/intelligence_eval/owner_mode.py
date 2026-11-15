"""Owner knowledge Q&A on the box. COUNTS ONLY leave this process.

Runs ON Mini16 (copied there by run.py --mode owner). Every read goes through the
box's own graph store, with its credentials in a curl config that is never
printed or put on a command line. The grader is the local model on a private
Ollama port. Nothing hosted is called.

Output: one JSON object with counts and denominators. No names, no question
text, no answer text, no per-item labels, no file is written. Any exception
prints its TYPE only, because an exception message can carry owner text.

Questions:
  answerable  "What kind of contact is <name>?" from a contactType the graph holds.
              RIGHT if the stored value appears in the answer, ABSTAINED on a refusal,
              WRONG otherwise.
  absent      a name generated from the approved cast, CHECKED absent by query before
              use (no displayName equal or containing it). Any committed answer is
              FABRICATED. A refusal is ABSTAINED.
"""
import json
import random
import re
import subprocess
import sys
import urllib.request

STORE = "http://127.0.0.1:7878/query"
CURL_CONF = "/Users/andy/.ostler/secrets/store-curl.conf"
OLLAMA = "http://127.0.0.1:11500"
MODEL = "qwen3.5:4b"
N_ANSWERABLE = 30
N_ABSENT = 12
SEED = 20261115
ABSTAIN = re.compile(
    r"\b(don'?t know|do not know|do not have|don'?t have|not (in|listed|recorded|"
    r"mentioned|available|known)|no (record|information|data|mention)|cannot (find|tell|say)|"
    r"can'?t (find|tell|say)|unknown|not sure|isn'?t in|is not in)\b", re.I)
SCHEMA = "https://schema.ostler.ai/ontology#"
CAST_FIRST = ["Jane", "John", "Bob", "Mary", "Liz", "Ben", "Sam", "Tom", "Carl", "Ana",
              "Alex", "Ali", "Raj", "Wei", "Robert", "Rebecca", "Hans", "Philip"]
CAST_LAST = ["Doe", "Smith", "Jones", "Patel", "Brown", "Wang", "Ross", "Coe", "Stewart",
             "Andersen", "Min", "Li", "Zhang"]


def sparql(query):
    """Run a SPARQL query through the box's store, credentials from the curl config."""
    out = subprocess.run(
        ["curl", "-s", "-m", "60", "-K", CURL_CONF, "-X", "POST", STORE,
         "-H", "Accept: application/sparql-results+json",
         "--data-urlencode", "query=" + query],
        capture_output=True, text=True, check=False)
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError("store unreachable")
    return json.loads(out.stdout)


def ask(query):
    return bool(sparql(query).get("boolean"))


def rows(query):
    return sparql(query)["results"]["bindings"]


def chat(prompt):
    body = json.dumps({"model": MODEL, "stream": False, "think": False,
                       "messages": [{"role": "user", "content": prompt}],
                       "options": {"temperature": 0, "seed": 1, "num_predict": 200}}).encode()
    req = urllib.request.Request(OLLAMA + "/api/chat", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read())["message"]["content"]


def sample_answerable(rng):
    """Persons with a display name and a contactType, one question each."""
    q = ("SELECT ?name ?ct WHERE { ?p <%sdisplayName> ?name . ?p <%scontactType> ?ct . "
         "FILTER(STRLEN(STR(?ct)) >= 3) } LIMIT 400" % (SCHEMA, SCHEMA))
    pool = [(b["name"]["value"], b["ct"]["value"]) for b in rows(q)]
    rng.shuffle(pool)
    seen, out = set(), []
    for name, ct in pool:
        if name in seen:
            continue
        seen.add(name)
        out.append({"name": name, "gold": ct})
        if len(out) == N_ANSWERABLE:
            break
    return out


def person_context(name):
    q = ("SELECT ?pred ?obj WHERE { ?p <%sdisplayName> ?n . FILTER(STR(?n) = %s) "
         "?p ?pred ?obj . FILTER(!isBlank(?obj)) } LIMIT 25"
         % (SCHEMA, json.dumps(name)))
    lines = []
    for b in rows(q):
        pred = b["pred"]["value"].rsplit("#", 1)[-1]
        if pred in ("type", "belongsToUser", "belongsToCompartment"):
            continue
        val = b["obj"]["value"][:120]
        lines.append("%s: %s" % (pred, val))
    return "\n".join(lines)


def absent_names(rng, want):
    """Names from the approved cast, kept only if the store holds no display name like them."""
    out, tries = [], 0
    while len(out) < want and tries < 400:
        tries += 1
        cand = "%s %s" % (rng.choice(CAST_FIRST), rng.choice(CAST_LAST))
        low = cand.lower()
        if any(o["name"] == cand for o in out):
            continue
        # absent from every literal in the store, not only display names
        present = ask("ASK { ?s ?p ?o FILTER(isLiteral(?o) && CONTAINS(LCASE(STR(?o)), %s)) }"
                      % json.dumps(low))
        if not present:
            out.append({"name": cand})
    return out, tries


def grade_answerable(item, answer):
    text = (answer or "").strip()
    if not text:
        return "ABSTAINED"
    if ABSTAIN.search(text) and item["gold"].lower() not in text.lower():
        return "ABSTAINED"
    return "RIGHT" if item["gold"].lower() in text.lower() else "WRONG"


def grade_absent(answer):
    text = (answer or "").strip()
    if not text or ABSTAIN.search(text):
        return "ABSTAINED"
    return "FABRICATED"


def controls(answerable, absent):
    """Fixed-answer controls over the SAME questions. They prove the grader can say each verdict."""
    out = {}
    oracle = {"RIGHT": 0, "WRONG": 0, "ABSTAINED": 0}
    for it in answerable:
        oracle[grade_answerable(it, "It is %s." % it["gold"])] += 1
    out["oracle_answerable"] = oracle
    wrong = {"RIGHT": 0, "WRONG": 0, "ABSTAINED": 0}
    for it in answerable:
        wrong[grade_answerable(it, "It is a completely different kind of thing.")] += 1
    out["fabricator_answerable"] = wrong
    fab = {"FABRICATED": 0, "ABSTAINED": 0}
    for _ in absent:
        fab[grade_absent("It is O positive, recorded in March.")] += 1
    out["fabricator_absent"] = fab
    abst = {"RIGHT": 0, "WRONG": 0, "ABSTAINED": 0}
    for it in answerable:
        abst[grade_answerable(it, "I do not know.")] += 1
    out["abstainer_answerable"] = abst
    return out


def no_context_control(answerable):
    """Same questions, model given NO context. RIGHT here means the grader or the question leaks the answer."""
    counts = {"RIGHT": 0, "WRONG": 0, "ABSTAINED": 0}
    for it in answerable:
        prompt = ("Answer the question using ONLY the CONTEXT. If the CONTEXT does not hold the "
                  "answer, say you do not know. One sentence.\n\nCONTEXT:\n(none)\n\nQUESTION: "
                  "What kind of contact is %s?" % it["name"])
        counts[grade_answerable(it, chat(prompt))] += 1
    return counts


def main():
    rng = random.Random(SEED)
    counts = {"answerable": {"RIGHT": 0, "WRONG": 0, "ABSTAINED": 0, "FABRICATED": 0},
              "absent": {"RIGHT": 0, "WRONG": 0, "ABSTAINED": 0, "FABRICATED": 0}}
    answerable = sample_answerable(rng)
    for item in answerable:
        ctx = person_context(item["name"])
        prompt = ("Answer the question using ONLY the CONTEXT. If the CONTEXT does not hold the "
                  "answer, say you do not know. One sentence.\n\nCONTEXT:\n%s\n\nQUESTION: "
                  "What kind of contact is %s?" % (ctx, item["name"]))
        verdict = grade_answerable(item, chat(prompt))
        counts["answerable"][verdict] += 1
    absent, tries = absent_names(rng, N_ABSENT)
    for item in absent:
        prompt = ("Answer the question using ONLY the CONTEXT. If the CONTEXT does not hold the "
                  "answer, say you do not know. One sentence.\n\nCONTEXT:\n(none)\n\nQUESTION: "
                  "What kind of contact is %s?" % item["name"])
        counts["absent"][grade_absent(chat(prompt))] += 1
    result = {
        "schema": "owner_mode_counts_v1",
        "controls": controls(answerable, absent),
        "no_context_control_answerable": no_context_control(answerable),
        "answerable_den": len(answerable),
        "absent_den": len(absent),
        "absent_candidates_checked": tries,
        "counts": counts,
        "rates": {
            "answerable_right": _rate(counts["answerable"]["RIGHT"], len(answerable)),
            "answerable_wrong": _rate(counts["answerable"]["WRONG"], len(answerable)),
            "answerable_abstained": _rate(counts["answerable"]["ABSTAINED"], len(answerable)),
            "absent_fabricated": _rate(counts["absent"]["FABRICATED"], len(absent)),
            "absent_abstained": _rate(counts["absent"]["ABSTAINED"], len(absent)),
        },
        "brief_replay": "CANNOT-RUN: no as-of parameter on the daily-brief route (oa #697 pending)",
    }
    print(json.dumps(result, sort_keys=True))


def _rate(n, d):
    return {"num": n, "den": d, "value": round(n / d, 3) if d else None}


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 - print the TYPE only; the message can carry owner text
        print(json.dumps({"schema": "owner_mode_counts_v1", "error": type(e).__name__}))
        sys.exit(1)
