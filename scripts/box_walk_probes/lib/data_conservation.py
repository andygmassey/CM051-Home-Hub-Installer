#!/usr/bin/env python3
"""scripts/box_walk_probes/lib/data_conservation.py

DATA CONSERVATION: for every source and every category, count items IN (what
the importer saw), STORED (what the stores hold) and SHOWN (what a customer
can find in the wiki), and turn any UNEXPLAINED loss into a red result.

WHY. A sweep on 2026-10-15 found about eleven places where data was silently
dropped: 68,314 of 70,667 music preferences missing from the wiki because
"apple" was absent from an allow-list; calendars of type "other" falling to the
most-private level; social rows from four parsers filtered out; unmatched import
files skipped uncounted. Sweeps find INSTANCES. Every one of those was invisible
for the same reason: nothing compared a count at one stage with the count at the
next. This does, per (source, category), on every walk.

THREE SUBCOMMANDS
  collect      Runs ON THE BOX, read-only, stdlib only (python 3.9 safe).
               Prints one JSON object {"facts": {key: int}, "meta": {...}}.
               Facts are flat "dotted.key=value" counters, e.g.
                 log.imessage.messages            IN (install.log summary)
                 q.preferences.source=spotify|category=music        STORED
                 w.shown.preferences.source=spotify|category=music  SHOWN
  adjudicate   Pure. expected.json + facts.json -> table + verdicts. Exit 1 on
               any LOST, 78 if an instrument could not read, else 0.
  selftest     Mutation tests. A deleted store and an allow-list-shaped wiki
               filter MUST come out LOST, and the unmutated control MUST NOT.

VERDICTS (worst wins per row)
  LOST          fewer items at a stage than expected, or than the stage before
                minus the exclusions expected.json DECLARES. Unexplained. FAIL.
  NOT-MEASURED  the instrument could not read (store unreachable, log absent).
                Not a pass and not a fail. Overall CANNOT-RUN.
  EXPLAINED     a gap exists and equals the declared exclusions, reason named.
  CONSERVED     every stage matches.
  (SURPLUS is a note, never a verdict: more stored than expected is duplicates
   or an unmodelled writer, and is printed, not failed.)

READ-ONLY. GET, Qdrant scroll/count, SPARQL SELECT. It never creates a payload
index (facet needs one; scroll+tally does not), never writes, never prints the
store credential.

CONTROL FOR A ZERO. A fact of 0 is only believed if the same collection answered
a total in the same run. A fact that is ABSENT (collection 404, log unreadable)
is NOT-MEASURED, never 0: "could not look" and "found nothing" print differently.

British English, no em dashes.
"""

import json
import os
import re
import sys

PY2_GUARD = sys.version_info[0] >= 3

STAGES = ("in", "stored", "graph", "shown")
# KNOWN-GAP is a declared, expected-red row (never silently green, never fails the walk).
RANK = {"CONSERVED": 0, "EXPLAINED": 1, "KNOWN-GAP": 2, "NOT-MEASURED": 3, "LOST": 4, "INFLATED": 4}
FAILING = ("LOST", "INFLATED")


# ===========================================================================
# ADJUDICATION (pure)
# ===========================================================================

def _excl_count(e, facts):
    """An exclusion carries a literal count, or a `fact` the collector measured
    (e.g. the number of rows CM044 noise_reason() denied). A fact that is absent
    returns None: an exclusion that could not be measured explains nothing."""
    if "fact" in e:
        return _fact(facts, e["fact"])
    return int(e.get("count", 0))


def _excl_total(row, stage, facts):
    t = 0
    for e in row.get("exclusions", []):
        if e.get("stage") == stage:
            c = _excl_count(e, facts)
            t += c or 0
    return t


def _excl_reasons(row, stage, facts):
    out = []
    for e in row.get("exclusions", []):
        if e.get("stage") == stage:
            c = _excl_count(e, facts)
            if c:
                out.append("%s x%d" % (e.get("reason", "unstated"), c))
    return out


def _name(key):
    if isinstance(key, dict):
        return key["key"]
    return key


def _fact(facts, key):
    """Return int, or None when the fact is ABSENT (could not look)."""
    if key is None:
        return None
    if isinstance(key, dict):
        # {"key": K, "zero_if": C}: K absent means 0 ONLY IF control C was read in
        # the same run (a collection that answered, a graph that returned rows).
        v = facts.get(key["key"])
        if v is not None:
            return int(v)
        return 0 if facts.get(key["zero_if"]) is not None else None
    if isinstance(key, list):
        vals = [_fact(facts, k) for k in key]
        if any(v is None for v in vals):
            return None
        return sum(vals)
    v = facts.get(key)
    if v is None:
        return None
    return int(v)


def adjudicate_row(row, facts):
    """One row -> dict(verdict, stage values, expected, why, notes).

    Per stage, against (1) the GOLDEN number when the row has one and (2) the
    CHAIN: the previous stage less declared exclusions. Fewer than allowed is
    LOST; MORE than allowed at stored/graph/shown is INFLATED (duplicates: the
    mirror of LOST, equally a FAIL)."""
    fk = row.get("facts", {})
    exp = row.get("expected", {})
    chain_on = row.get("chain", True)
    m = {s: _fact(facts, fk.get(s)) for s in STAGES}
    verdict = "CONSERVED"
    why, notes = [], []

    unread = False                     # any stage or exclusion fact that could not be read

    def bump(v, text=None):
        nonlocal verdict, unread
        if v == "NOT-MEASURED":
            unread = True
        if RANK[v] > RANK[verdict]:
            verdict = v
        if text:
            why.append(text)

    prev_stage, prev_val = None, None
    for s in STAGES:
        if s not in fk:
            continue
        mv = m[s]
        if mv is None:
            bump("NOT-MEASURED", "%s: fact %s unreadable" % (s, _name(fk.get(s))))
            continue
        e = exp.get(s)
        declared = _excl_total(row, s, facts)
        unmeasured_excl = [x for x in row.get("exclusions", [])
                           if x.get("stage") == s and "fact" in x and _fact(facts, x["fact"]) is None]
        if unmeasured_excl:
            bump("NOT-MEASURED", "%s: exclusion fact %s unreadable" % (s, _name(unmeasured_excl[0]["fact"])))
            if s != "graph":
                prev_stage, prev_val = s, mv
            continue                   # cannot adjudicate a gap whose explanation is unreadable
        if e is not None:
            if mv < int(e):
                bump("LOST", "%s: %d of %d expected (lost %d)" % (s, mv, int(e), int(e) - mv))
            elif mv > int(e):
                if s == "in" or row.get("allow_surplus"):
                    notes.append("%s surplus +%d" % (s, mv - int(e)))
                else:
                    extra = ""
                    d = _fact(facts, fk.get("graph_distinct")) if s == "graph" else None
                    if d is not None and d <= int(e):
                        extra = " (%d distinct: nodes are mirrored)" % d
                    bump("INFLATED", "%s: %d held vs %d expected (+%d)%s" % (s, mv, int(e), mv - int(e), extra))
        if chain_on and prev_val is not None:
            floor = prev_val - declared
            if e is None and mv < floor:
                bump("LOST", "%s: %d from %d at %s, %d declared excluded (lost %d unexplained)"
                     % (s, mv, prev_val, prev_stage, declared, floor - mv))
            elif e is None and s != "in" and mv > prev_val:
                bump("INFLATED", "%s: %d exceeds %d at %s (+%d)" % (s, mv, prev_val, prev_stage, mv - prev_val))
            elif mv < prev_val and declared > 0 and (e is None or mv >= int(e)):
                bump("EXPLAINED", "%s: -%d %s" % (s, prev_val - mv, "; ".join(_excl_reasons(row, s, facts))))
        if s == "graph" and chain_on and m["stored"] is not None and e is None:
            if mv < m["stored"]:
                bump("LOST", "graph: %d vs %d in the vector store (lost %d)" % (mv, m["stored"], m["stored"] - mv))
            elif mv > m["stored"]:
                d = _fact(facts, fk.get("graph_distinct"))
                extra = " (%d distinct: nodes are mirrored)" % d if d is not None and d <= m["stored"] else ""
                bump("INFLATED", "graph: %d nodes vs %d stored (+%d)%s" % (mv, m["stored"], mv - m["stored"], extra))
        if s != "graph":              # graph is a parallel store, not a link in the chain
            prev_stage, prev_val = s, mv
    gap = row.get("known_gap")
    if gap:
        # A known gap applies ONLY to a row that WAS fully measured and failed.
        # NOT-MEASURED must never become KNOWN-GAP (which exits 0): an unread
        # row says nothing about the gap, and a failing row with an unread
        # stage is not a measured match either.
        if verdict in FAILING and not unread:
            why.insert(0, "KNOWN GAP (declared): %s" % gap)
            verdict = "KNOWN-GAP"
        elif unread:
            notes.append("known_gap declared but the row was not fully measured; it stays %s: %s" % (verdict, gap))
        else:
            notes.append("known_gap is now CLOSED, delete the flag: %s" % gap)
    return {"id": row["id"], "source": row.get("source", ""), "category": row.get("category", ""),
            "unit": row.get("unit", "items"), "in": m["in"], "stored": m["stored"], "graph": m["graph"],
            "shown": m["shown"], "expected": exp, "verdict": verdict,
            "why": "; ".join(why), "notes": "; ".join(notes)}


PREF_PAIR = re.compile(r"^q\.preferences\.(source=.+\|category=.+)$")


def expand_templates(expected, facts):
    """A row {"template": "preferences_pairs"} becomes one row per
    (source, category) the store ACTUALLY holds, so a category nobody wrote into
    expected.json is still checked stored -> graph -> shown. A new writer's
    category cannot hide by being new."""
    out = []
    for r in expected.get("rows", []):
        if r.get("template") != "preferences_pairs":
            out.append(r)
            continue
        for k in sorted(facts):
            m = PREF_PAIR.match(k)
            if not m:
                continue
            g = m.group(1)
            a_, b_ = g.split("|", 1)
            src, cat = a_.split("=", 1)[1], b_.split("=", 1)[1]
            out.append({
                "id": "preferences/%s/%s" % (src, cat), "source": src, "category": cat, "unit": "preferences",
                "facts": {"stored": k,
                          "graph": {"key": "x.pref.raw." + g, "zero_if": "x.pref.raw.total"},
                          "graph_distinct": {"key": "x.pref.distinct." + g, "zero_if": "x.pref.raw.total"},
                          "shown": {"key": "w.shown.preferences." + g, "zero_if": "w.corpus_chars"}},
                "exclusions": [{"stage": "shown", "fact": {"key": "w.denied.preferences." + g, "zero_if": "w.denied.preferences.total"},
                                "reason": "CM044 preference_filter.noise_reason() denied it"}]})
    return out


def adjudicate(expected, facts, probe_ok=None):
    """expected: parsed expected.json. facts: flat dict. -> (rows, counts)."""
    rows = [adjudicate_row(r, facts) for r in expand_templates(expected, facts)]
    counts = dict((k, 0) for k in RANK)
    for r in rows:
        counts[r["verdict"]] += 1
    return rows, counts


def overall(rows, counts):
    """-> (word, exit_code). 0 PASS, 1 FAIL, 78 CANNOT-RUN."""
    if not rows:
        return "CANNOT-RUN", 78           # a zero denominator is not a pass
    # An all-zero box proves nothing was loaded, not that nothing was lost:
    # every measured IN count 0, or every measured STORED count 0, is CANNOT-RUN.
    for stage in ("in", "stored"):
        vals = [r[stage] for r in rows if r.get(stage) is not None]
        if vals and not any(vals):
            return "CANNOT-RUN", 78
    if counts["LOST"] or counts["INFLATED"]:
        return "FAIL", 1
    if counts["NOT-MEASURED"]:
        return "CANNOT-RUN", 78
    return "PASS", 0


def _cell(v):
    return "-" if v is None else str(v)


def render_md(rows, counts, word):
    out = ["| source | category | IN | STORED | GRAPH | SHOWN | verdict | why |",
           "|---|---|---:|---:|---:|---:|---|---|"]
    for r in sorted(rows, key=lambda x: (-RANK[x["verdict"]], x["source"], x["category"])):
        why = r["why"] or r["notes"]
        out.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["source"], r["category"], _cell(r["in"]), _cell(r["stored"]), _cell(r["graph"]), _cell(r["shown"]),
            r["verdict"], why.replace("|", "/")))
    out.append("")
    out.append("ROWS %d: CONSERVED %d, EXPLAINED %d, KNOWN-GAP %d, NOT-MEASURED %d, INFLATED %d, LOST %d  => %s" % (
        len(rows), counts["CONSERVED"], counts["EXPLAINED"], counts["KNOWN-GAP"], counts["NOT-MEASURED"],
        counts["INFLATED"], counts["LOST"], word))
    return "\n".join(out)


# ===========================================================================
# SHOWN: is a stored item findable in the rendered wiki?  (independent of any
# allow-list: the wiki is read as TEXT, the way a customer reads it)
# ===========================================================================

def _norm(s):
    return re.sub(r"\s+", " ", re.sub(r"[^\w]+", " ", (s or "").lower())).strip()


def load_wiki_corpus(wiki_dir):
    """Concatenate every .md under wiki_dir (skipping dot dirs) into one
    normalised string. Returns (corpus, n_files)."""
    parts, n = [], 0
    for root, dirs, files in os.walk(wiki_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".") and not d.startswith("_")]
        for f in files:
            if f.endswith(".md") and not f.startswith("."):
                try:
                    with open(os.path.join(root, f), "r", encoding="utf-8", errors="replace") as fh:
                        parts.append(_norm(fh.read()))
                    n += 1
                except OSError:
                    pass
    return " \n ".join(parts), n


def is_shown(text, corpus):
    t = _norm(text)
    return bool(t) and (" " + t + " ") in (" " + corpus + " ")


# ===========================================================================
# COLLECT (on the box)
# ===========================================================================

QDRANT = os.environ.get("OSTLER_QDRANT_URL", "http://127.0.0.1:6333")
OXIGRAPH = os.environ.get("OSTLER_OXIGRAPH_URL", "http://127.0.0.1:7878/query")
HOME = os.path.expanduser("~")
STORE_CONF = os.environ.get("OSTLER_PROBE_STORE_CURL_CONF", os.path.join(HOME, ".ostler/secrets/store-curl.conf"))
WIKI_DIR = os.environ.get("OSTLER_WIKI_DIR", os.path.join(HOME, "Documents/Ostler/Wiki"))
LOG_DIR = os.environ.get("OSTLER_LOG_DIR", os.path.join(HOME, ".ostler/logs"))

# collection -> (payload keys to tally one by one, [(keyA, keyB) pairs], display key candidates)
# Pairs are the (source, category) grain the allow-list bugs live at.
COLLECTION_SPEC = {
    "preferences":           (["source", "category", "preference_type", "privacy_level"], [("source", "category")], ["subject"]),
    "people":                (["source", "contact_type", "privacy_level"], [], ["display_name"]),
    "conversations":         (["source", "channel", "kind", "privacy_level"], [("source", "channel")], ["title", "summary"]),
    "safari_history":        (["source", "privacy_level", "domain"], [], ["title", "domain"]),
    "apple_notes_knowledge": (["source", "kind", "privacy_level"], [], ["title"]),
    "reminders_knowledge":   (["source", "list", "privacy_level"], [], ["title"]),
    "evernote_knowledge":    (["source", "privacy_level"], [], ["title"]),
}
SHOWN_SAMPLE_CAP = 3000   # per (collection, group); beyond this we sample every k-th


def _headers():
    hdr = {}
    try:
        with open(STORE_CONF, "r") as fh:
            for line in fh:
                m = re.match(r'\s*header\s*=\s*"?([^:"]+):\s*([^"\n]+)"?', line)
                if m:
                    hdr[m.group(1).strip()] = m.group(2).strip()
    except OSError:
        pass
    return hdr


def _http(url, body=None, headers=None, form=None, timeout=60):
    import urllib.request
    import urllib.error
    import urllib.parse
    h = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["content-type"] = "application/json"
    elif form is not None:
        data = urllib.parse.urlencode(form).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode() or "null")
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None


def _scroll(coll, keys, hdr):
    """Yield payload dicts (only `keys`) for every point. Read-only."""
    offset = None
    while True:
        body = {"limit": 1000, "with_payload": {"include": keys}, "with_vector": False}
        if offset is not None:
            body["offset"] = offset
        code, js = _http("%s/collections/%s/points/scroll" % (QDRANT, coll), body=body, headers=hdr)
        if code != 200 or not js:
            yield None
            return
        res = js.get("result", {})
        for p in res.get("points", []):
            yield p.get("payload", {}) or {}
        offset = res.get("next_page_offset")
        if offset is None:
            return


def load_noise_reason(meta):
    """CM044's own deny decision (preference_filter.noise_reason), loaded from the
    install so the probe EXPLAINS a denial with the wiki's own rule rather than a
    copy of it. Absent on builds before it landed: then denials are NOT-MEASURED,
    never assumed zero."""
    import importlib.util
    cands = [os.environ.get("OSTLER_PREFERENCE_FILTER", "")]
    for base in (os.path.join(HOME, ".ostler/services/cm059-editor/compiler"),
                 os.path.join(HOME, ".ostler/services/cm044/compiler")):
        cands.append(os.path.join(base, "preference_filter.py"))
    for path in cands:
        if path and os.path.isfile(path):
            try:
                spec = importlib.util.spec_from_file_location("dc_preference_filter", path)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                fn = getattr(mod, "noise_reason", None)
                if fn:
                    meta["noise_reason"] = path
                    return fn
            except Exception as exc:
                meta["noise_reason_error"] = "%s: %s" % (path, type(exc).__name__)
    meta.setdefault("noise_reason", "absent")
    return None


def _slug(text):
    return re.sub(r"[^a-z0-9]+", "_", (text or "").lower()).strip("_")[:48]


def collect_qdrant(facts, meta, hdr, corpus):
    noise = load_noise_reason(meta)
    for coll, (keys, pairs, disp) in COLLECTION_SPEC.items():
        code, js = _http("%s/collections/%s" % (QDRANT, coll), headers=hdr)
        if code == 404:
            meta.setdefault("absent_collections", []).append(coll)
            facts["q.%s.total" % coll] = 0           # a 404 is ABSENT = empty, the control is below
            continue
        if code != 200 or not js:
            meta.setdefault("unreadable_collections", []).append("%s:HTTP_%s" % (coll, code))
            continue
        total = js["result"]["points_count"]
        facts["q.%s.total" % coll] = int(total)
        meta.setdefault("answered_collections", []).append(coll)
        want = None if (coll == "preferences" and noise) else list(keys) + list(disp)
        tallies, shown, seen_n, ok = {}, {}, 0, True
        groups = {}
        for pl in _scroll(coll, want, hdr):
            if pl is None:
                ok = False
                break
            seen_n += 1
            denied = None
            if coll == "preferences" and noise:
                try:
                    denied = noise(pl)
                except Exception:
                    denied = "noise_reason raised"
            gkeys = []
            for k in keys:
                v = pl.get(k)
                if v is not None and not isinstance(v, (dict, list)):
                    gkeys.append("%s=%s" % (k, v))
            for a, b in pairs:
                if pl.get(a) is not None and pl.get(b) is not None:
                    gkeys.append("%s=%s|%s=%s" % (a, pl[a], b, pl[b]))
            text = ""
            for d in disp:
                if pl.get(d):
                    text = str(pl[d])
                    break
            for g in gkeys:
                tallies[g] = tallies.get(g, 0) + 1
                if denied:
                    dk = "denied|" + g
                    tallies[dk] = tallies.get(dk, 0) + 1
                    rk = "denied_reason=%s|%s" % (_slug(denied), g)
                    tallies[rk] = tallies.get(rk, 0) + 1
                else:
                    groups.setdefault(g, []).append(text)
        if ok and coll == "preferences" and noise:
            facts["w.denied.preferences.total"] = sum(
                n for g, n in tallies.items() if g.startswith("denied|") and g.count("=") == 1 and g.startswith("denied|source="))
        if not ok:
            meta.setdefault("unreadable_collections", []).append("%s:scroll" % coll)
            for g in list(tallies):
                pass
            continue
        if seen_n != total:
            meta.setdefault("scroll_mismatch", []).append("%s scrolled %d of %d" % (coll, seen_n, total))
        for g, n in tallies.items():
            if g.startswith("denied|"):
                facts["w.denied.%s.%s" % (coll, g[len("denied|"):])] = n
            elif g.startswith("denied_reason="):
                facts["w.denied_reason.%s.%s" % (coll, g[len("denied_reason="):])] = n
            else:
                facts["q.%s.%s" % (coll, g)] = n
        # SHOWN: how many of the stored items' display text appear in the wiki.
        if corpus is not None:
            for g, texts in groups.items():
                n = len(texts)
                if n <= SHOWN_SAMPLE_CAP:
                    sample, scale = texts, 1.0
                else:
                    step = n // SHOWN_SAMPLE_CAP + 1
                    sample, scale = texts[::step], float(n) / len(texts[::step])
                hit = sum(1 for t in sample if is_shown(t, corpus))
                facts["w.shown.%s.%s" % (coll, g)] = int(round(hit * scale))
                if scale != 1.0:
                    meta.setdefault("shown_sampled", []).append("%s.%s x%.1f" % (coll, g, scale))


def _sparql(q, hdr):
    code, js = _http(OXIGRAPH, form={"query": q}, headers=dict(hdr, Accept="application/sparql-results+json"))
    if code != 200 or not js:
        return None
    return js["results"]["bindings"]


def collect_oxigraph(facts, meta, hdr):
    rows = _sparql("SELECT ?t (COUNT(*) AS ?n) WHERE { ?s a ?t } GROUP BY ?t", hdr)
    if rows is None:
        meta["oxigraph"] = "unreadable"
        return
    for r in rows:
        local = r["t"]["value"].rsplit("#", 1)[-1].rsplit("/", 1)[-1]
        facts["x.class.%s" % local] = int(r["n"]["value"])
    # PREFERENCES, raw vs distinct. Every like/dislike is held twice (pwg:pref_<id>
    # from the CM019 writer and urn:ostler:preference:<sha256> from the CM059
    # projection), so raw is what a tile that counts nodes reads and distinct is
    # what the customer actually has. Both are facts; the row decides.
    P = "https://schema.ostler.ai/ontology#"
    pr = _sparql("SELECT ?src ?cat (COUNT(?s) AS ?raw) (COUNT(DISTINCT CONCAT(STR(?subj), '|', STR(?t))) AS ?dist) WHERE { "
                 "?s a ?t . ?s <%ssubject> ?subj . OPTIONAL { ?s <%sdataSource> ?src } OPTIONAL { ?s <%scategory> ?cat } "
                 "FILTER(?t IN (<%sLikePreference>, <%sDislikePreference>, <%sNeutralPreference>)) } GROUP BY ?src ?cat" % (P, P, P, P, P, P), hdr)
    if pr is not None:
        rt = dt = 0
        for r in pr:
            src = r.get("src", {}).get("value", "")
            cat = r.get("cat", {}).get("value", "")
            raw, dist = int(r["raw"]["value"]), int(r["dist"]["value"])
            facts["x.pref.raw.source=%s|category=%s" % (src, cat)] = raw
            facts["x.pref.distinct.source=%s|category=%s" % (src, cat)] = dist
            rt += raw
            dt += dist
        facts["x.pref.raw.total"] = rt
        facts["x.pref.distinct.total"] = dt
    # Calendar facts on the ICS path: per calendarType, how many events exist and
    # how many are VISIBLE (privacy below L3, which the wiki and assistant withhold).
    cf = _sparql("SELECT ?ct ?pl (COUNT(?f) AS ?n) WHERE { ?f <%scalendarType> ?ct . OPTIONAL { ?f <%sprivacyLevel> ?pl } } GROUP BY ?ct ?pl" % (P, P), hdr)
    if cf is not None:
        facts["x.calfact.total"] = sum(int(r["n"]["value"]) for r in cf)
        for r in cf:
            ct = r["ct"]["value"]
            pl = r.get("pl", {}).get("value", "none")
            n = int(r["n"]["value"])
            facts["x.calfact.type=%s|privacy=%s" % (ct, pl)] = n
            k = "x.calfact.type=%s|total" % ct
            facts[k] = facts.get(k, 0) + n
            if pl != "L3":
                k = "x.calfact.type=%s|visible" % ct
                facts[k] = facts.get(k, 0) + n
    mp = _sparql("SELECT ?pl (COUNT(DISTINCT ?m) AS ?n) WHERE { ?m a <%sMeeting> . OPTIONAL { ?m <%sprivacyLevel> ?pl } } GROUP BY ?pl" % (P, P), hdr)
    if mp is not None:
        for r in mp:
            facts["x.meeting.privacy=%s" % r.get("pl", {}).get("value", "none")] = int(r["n"]["value"])
    mt = _sparql("SELECT (COUNT(DISTINCT ?m) AS ?n) WHERE { ?m a <%sMeeting> }" % P, hdr)
    if mt:
        facts["x.meetings"] = int(mt[0]["n"]["value"])
    tri = _sparql("SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }", hdr)
    if tri:
        facts["x.triples"] = int(tri[0]["n"]["value"])


# --- IN: importer self-reports -------------------------------------------------
# (fact name, log file, regex with ONE integer group per fact via named groups)
LOG_PATTERNS = [
    ("install.log", r"\[ok\] iMessage: (?P<log__imessage_conversations>\d+) conversations, (?P<log__imessage_messages>\d+) messages, (?P<log__imessage_contacts>\d+) contacts"),
    ("install.log", r"\[ok\] WhatsApp: t1_dm=(?P<log__whatsapp_t1_dm>\d+), t2_intimate=(?P<log__whatsapp_t2_intimate>\d+), t2_active=(?P<log__whatsapp_t2_active>\d+), t3_skipped=(?P<log__whatsapp_t3_skipped>\d+), people_added=(?P<log__whatsapp_people_added>\d+)"),
    ("install.log", r"\[ok\] Apple Music: (?P<log__apple_music_tracks>\d+) tracks, (?P<log__apple_music_artists>\d+) artists, (?P<log__apple_music_playlists>\d+) playlists"),
    ("install.log", r"\[ok\] Safari: (?P<log__safari_visits>\d+) visits across (?P<log__safari_domains>\d+) domains"),
    ("install.log", r"\[ok\] Calendar: (?P<log__calendar_events>\d+) events, (?P<log__calendar_meeting_contacts>\d+) meeting contacts"),
    ("install.log", r"\[ok\] Reminders: (?P<log__reminders_total>\d+) total \((?P<log__reminders_pending>\d+) pending, (?P<log__reminders_completed>\d+) completed\)"),
    ("install.log", r"\[ok\] Apple Mail: (?P<log__mail_messages>\d+) messages, (?P<log__mail_unread>\d+) unread"),
    ("install.log", r"\[ok\] Apple Notes: (?P<log__notes_notes>\d+) notes \((?P<log__notes_words>\d+) words\)"),
    ("install.log", r"Fetched (?P<log__contacts_vcards>\d+) vCards"),
    ("email-ingest.log", r"Emitted (?P<log__mbox_emitted>\d+) messages?"),
]


def collect_logs(facts, meta):
    seen = {}
    for fname, pat in LOG_PATTERNS:
        path = os.path.join(LOG_DIR, fname)
        if path not in seen:
            try:
                with open(path, "r", errors="replace") as fh:
                    seen[path] = fh.read()
            except OSError:
                seen[path] = None
                meta.setdefault("unreadable_logs", []).append(fname)
        text = seen[path]
        if text is None:
            continue
        last = None
        for m in re.finditer(pat, text):
            last = m          # the LAST line is the current state of the install
        if last:
            for k, v in last.groupdict().items():
                facts[k.replace("__", ".")] = int(v)


INGEST_RE = re.compile(r"Aggregated ingestion complete: (\d+) preferences, (\d+) filtered, (\d+) source-capped, (\d+) date-excluded")
CREATED_RE = re.compile(r"Preferences created:\s*([\d,]+)")


def collect_ingest_logs(facts, meta):
    """IN for the GDPR/preference importers: the pipeline's own tally. seen =
    created + filtered + capped + date-excluded is every preference the PARSERS
    emitted, before any drop; a file with no parser never reaches it."""
    found = None
    try:
        names = sorted(os.listdir(LOG_DIR))
    except OSError:
        meta["ingest_logs"] = "unreadable"
        return
    for n in names:
        if not (n.endswith(".log") or n.endswith(".err")):
            continue
        try:
            with open(os.path.join(LOG_DIR, n), "r", errors="replace") as fh:
                for m in INGEST_RE.finditer(fh.read()):
                    found = tuple(int(x) for x in m.groups())
        except OSError:
            continue
    if found:
        facts["log.ingest.created"], facts["log.ingest.filtered"], facts["log.ingest.capped"], facts["log.ingest.date_excluded"] = found
        facts["log.ingest.seen"] = sum(found)


def collect_wiki(facts, meta):
    stats = os.path.join(WIKI_DIR, "stats.md")
    try:
        with open(stats, "r", encoding="utf-8", errors="replace") as fh:
            txt = fh.read()
    except OSError:
        meta["wiki_stats"] = "unreadable"
        return
    for m in re.finditer(r'class="pw-stat-n">([\d,]+)<div class="pw-stat-l">([^<\n]+)', txt):
        label = re.sub(r"[^a-z0-9]+", "_", m.group(2).strip().lower()).strip("_")
        facts["w.stat.%s" % label] = int(m.group(1).replace(",", ""))


def collect_state(facts, meta):
    """IN from the importers' own state files: hydrate markers and the FDA
    extraction summary. item_count counts what the hydrate step reports."""
    hd = os.path.join(HOME, ".ostler/state/hydrate")
    if os.path.isdir(hd):
        for f in sorted(os.listdir(hd)):
            if f.endswith(".done"):
                try:
                    with open(os.path.join(hd, f)) as fh:
                        kv = dict(l.strip().split("=", 1) for l in fh if "=" in l)
                except OSError:
                    continue
                src = f[:-5]
                if kv.get("item_count", "").isdigit():
                    facts["hyd.%s.item_count" % src] = int(kv["item_count"])
                facts["hyd.%s.status_ok" % src] = 1 if kv.get("status") == "ok" else 0
    es = os.path.join(HOME, ".ostler/imports/fda/extraction_summary.json")
    try:
        with open(es) as fh:
            summ = json.load(fh)
        for k, v in (summ.get("sources") or {}).items():
            facts["fda.%s.ok" % k] = 1 if (v or {}).get("status") == "ok" else 0
    except (OSError, ValueError):
        meta["extraction_summary"] = "unreadable"
    # Bundle directories: one dir per conversation / capture.
    conv = os.path.join(HOME, "Documents/Ostler/Conversations")
    if os.path.isdir(conv):
        n = 0
        for day in os.listdir(conv):
            dp = os.path.join(conv, day)
            if os.path.isdir(dp):
                n += sum(1 for x in os.listdir(dp) if os.path.isdir(os.path.join(dp, x)))
        facts["d.conversations.bundles"] = n
    for sub in ("People", "Places", "Meetings", "Browsing", "Music", "Social", "Conversations", "Knowledge"):
        dp = os.path.join(WIKI_DIR, sub)
        if os.path.isdir(dp):
            facts["w.pages.%s" % sub] = sum(1 for x in os.listdir(dp) if x.endswith(".md") and x != "index.md")


def collect_doctor(facts, meta, hdr):
    """SHOWN at the Doctor: GET /api/v1/sources (item_count, last_run_count)."""
    code, js = _http("http://127.0.0.1:8089/api/v1/sources", headers=hdr, timeout=15)
    if code != 200 or not js:
        meta["doctor_sources"] = "HTTP_%s" % code
        return
    for r in js.get("sources", []):
        k = r.get("source")
        if k is None:
            continue
        for f in ("item_count", "last_run_count"):
            if isinstance(r.get(f), int):
                facts["doctor.%s.%s" % (k, f)] = r[f]


def collect():
    facts, meta = {}, {}
    hdr = _headers()
    meta["credential_headers"] = len(hdr)
    corpus, nfiles = None, 0
    if os.path.isdir(WIKI_DIR):
        corpus, nfiles = load_wiki_corpus(WIKI_DIR)
    meta["wiki_md_files"] = nfiles
    meta["wiki_corpus_chars"] = len(corpus) if corpus is not None else None
    if corpus:
        facts["w.corpus_chars"] = len(corpus)       # the control: the wiki WAS read
    collect_logs(facts, meta)
    collect_qdrant(facts, meta, hdr, corpus)
    collect_oxigraph(facts, meta, hdr)
    collect_wiki(facts, meta)
    collect_state(facts, meta)
    collect_ingest_logs(facts, meta)
    collect_doctor(facts, meta, hdr)
    return {"facts": facts, "meta": meta}


# ===========================================================================
# SELF-TEST: the probe must be able to go RED
# ===========================================================================

def _mini_expected():
    return {"rows": [
        {"id": "spotify/music", "source": "spotify", "category": "music", "unit": "prefs",
         "expected": {"in": 100, "stored": 100, "shown": 100},
         "facts": {"in": "log.spotify", "stored": "q.p.s", "shown": "w.shown.p.s"}},
        {"id": "apple/music", "source": "apple", "category": "music", "unit": "prefs",
         "expected": {"in": 70, "stored": 70, "shown": 70},
         "facts": {"in": "log.apple", "stored": "q.p.a", "shown": "w.shown.p.a"}},
        {"id": "cal/other", "source": "calendar", "category": "other", "unit": "events",
         "expected": {"in": 12, "stored": 12, "shown": 10},
         "exclusions": [{"stage": "shown", "count": 2, "reason": "set-aside calendar"}],
         "facts": {"in": "log.cal", "stored": "q.c", "shown": "w.shown.c"}},
        {"id": "chain/only", "source": "mail", "category": "inbox", "unit": "messages",
         "exclusions": [{"stage": "stored", "count": 3, "reason": "duplicate Message-ID"}],
         "facts": {"in": "log.m", "stored": "q.m", "shown": "w.shown.m"}},
    ]}


def _mini_facts():
    return {"log.spotify": 100, "q.p.s": 100, "w.shown.p.s": 100,
            "log.apple": 70, "q.p.a": 70, "w.shown.p.a": 70,
            "log.cal": 12, "q.c": 12, "w.shown.c": 10,
            "log.m": 50, "q.m": 47, "w.shown.m": 47}


def selftest():
    fails = []
    exp = _mini_expected()

    def run(facts):
        rows, counts = adjudicate(exp, facts)
        return rows, counts, overall(rows, counts)

    # 0. CONTROL: the unmutated set must not be LOST (else every mutation below proves nothing).
    rows, counts, (word, code) = run(_mini_facts())
    if counts["LOST"] != 0 or code != 0:
        fails.append("control (unmutated) was not clean: %s %s" % (counts, word))
    if counts["EXPLAINED"] != 2:
        fails.append("control should have 2 EXPLAINED rows, got %d" % counts["EXPLAINED"])

    # 1. MUTATION: delete stored items (the apple rows) -> LOST.
    f = _mini_facts()
    f["q.p.a"] = 0
    f["w.shown.p.a"] = 0
    rows, counts, (word, code) = run(f)
    if not (counts["LOST"] >= 1 and code == 1):
        fails.append("deleted stored items did NOT produce LOST (%s)" % counts)

    # 2. MUTATION: an unexplained shown drop (68,314 of 70,667 shape) -> LOST.
    f = _mini_facts()
    f["w.shown.p.a"] = 2
    rows, counts, (word, code) = run(f)
    lost = [r["id"] for r in rows if r["verdict"] == "LOST"]
    if lost != ["apple/music"] or code != 1:
        fails.append("unexplained shown drop not isolated to apple/music: %s" % lost)

    # 3. MUTATION: a drop LARGER than the declared exclusion is still LOST.
    f = _mini_facts()
    f["q.m"] = 40          # 50 in, 3 declared, 7 more gone
    rows, counts, (word, code) = run(f)
    if "chain/only" not in [r["id"] for r in rows if r["verdict"] == "LOST"]:
        fails.append("over-declared exclusion hid a loss")

    # 4. An unreadable instrument is NOT a pass and NOT a fail.
    f = _mini_facts()
    del f["q.p.s"]
    rows, counts, (word, code) = run(f)
    if not (counts["NOT-MEASURED"] == 1 and counts["LOST"] == 0 and code == 78):
        fails.append("absent fact must be NOT-MEASURED/CANNOT-RUN, got %s %s" % (counts, word))

    # 5. A zero denominator is CANNOT-RUN, never PASS.
    if overall([], {"CONSERVED": 0, "EXPLAINED": 0, "NOT-MEASURED": 0, "LOST": 0})[1] != 78:
        fails.append("empty row set did not CANNOT-RUN")

    # 6. REAL wiki reader against an allow-list-shaped filter. Build a tiny vault
    #    from items; the MUTATED copy renders through an allow-list that lacks
    #    "apple" (the 2026-10-15 shape) and the REAL is_shown must see the loss.
    import tempfile
    items = [("spotify", "track-1"), ("spotify", "track-2"), ("apple", "track-3"),
             ("apple", "track-4"), ("apple", "track-5")]

    def vault(allow):
        d = tempfile.mkdtemp(prefix="dcv_")
        with open(os.path.join(d, "Music.md"), "w") as fh:
            for src, t in items:
                if src in allow:
                    fh.write("- %s\n" % t)
        return d

    def shown_by_source(allow):
        corpus, _ = load_wiki_corpus(vault(allow))
        out = {}
        for src, t in items:
            out[src] = out.get(src, 0) + (1 if is_shown(t, corpus) else 0)
        return out

    good = shown_by_source({"spotify", "apple"})
    bad = shown_by_source({"spotify"})                 # "apple" removed from the allow-list copy
    exp2 = {"rows": [{"id": "apple/music", "source": "apple", "category": "music",
                      "expected": {"stored": 3, "shown": 3},
                      "facts": {"stored": "q", "shown": "s"}}]}
    r_good, c_good = adjudicate(exp2, {"q": 3, "s": good["apple"]})
    r_bad, c_bad = adjudicate(exp2, {"q": 3, "s": bad["apple"]})
    if c_good["LOST"] != 0:
        fails.append("wiki control (apple allowed) reported LOST")
    if c_bad["LOST"] != 1:
        fails.append("wiki mutation (apple removed from allow-list copy) did NOT produce LOST")

    # 7. INFLATED: the Oxigraph mirror (every like held twice) must FAIL, and the
    #    DISTINCT count must not hide it.
    exp3 = {"rows": [{"id": "p/likes", "source": "spotify", "category": "music",
                      "expected": {"in": 10, "stored": 10, "graph": 10},
                      "facts": {"in": "i", "stored": "q", "graph": "g", "graph_distinct": "gd"}}]}
    r3, c3 = adjudicate(exp3, {"i": 10, "q": 10, "g": 20, "gd": 10})
    if c3["INFLATED"] != 1 or overall(r3, c3)[1] != 1 or "mirrored" not in r3[0]["why"]:
        fails.append("mirrored graph nodes (20 raw, 10 distinct) did not produce INFLATED: %s" % r3[0])
    r3, c3 = adjudicate(exp3, {"i": 10, "q": 10, "g": 10, "gd": 10})
    if c3["INFLATED"] or c3["LOST"]:
        fails.append("INFLATED control (graph == stored) was not clean")

    # 8. Fact-driven exclusion (CM044 noise_reason denials): explained when the
    #    denied count is measured and exact; LOST when the shortfall is larger;
    #    NOT-MEASURED when the denial count could not be read.
    exp4 = {"rows": [{"id": "p/x", "source": "s", "category": "c",
                      "exclusions": [{"stage": "shown", "fact": "den", "reason": "noise_reason: error page"}],
                      "facts": {"stored": "q", "shown": "w"}}]}
    r4, c4 = adjudicate(exp4, {"q": 10, "w": 7, "den": 3})
    if c4["EXPLAINED"] != 1:
        fails.append("denied rows (3) were not EXPLAINED: %s" % c4)
    r4, c4 = adjudicate(exp4, {"q": 10, "w": 5, "den": 3})
    if c4["LOST"] != 1:
        fails.append("2 rows beyond the denied 3 were not LOST: %s" % c4)
    r4, c4 = adjudicate(exp4, {"q": 10, "w": 7})
    if c4["NOT-MEASURED"] != 1:
        fails.append("unmeasured denial count was not NOT-MEASURED: %s" % c4)

    # 9. KNOWN-GAP stays visible and non-failing while red, and says so when closed.
    exp5 = {"rows": [{"id": "places/areas", "source": "places", "category": "area",
                      "known_gap": "headline reads 'areas', no writer produces it",
                      "expected": {"stored": 4, "shown": 4}, "facts": {"stored": "q", "shown": "w"}}]}
    r5, c5 = adjudicate(exp5, {"q": 4, "w": 0})
    if c5["KNOWN-GAP"] != 1 or overall(r5, c5)[1] != 0:
        fails.append("known gap did not read KNOWN-GAP / exit 0: %s" % c5)
    r5, c5 = adjudicate(exp5, {"q": 4, "w": 4})
    if "CLOSED" not in r5[0]["notes"]:
        fails.append("a closed known gap did not say so")

    # 10. TEMPLATE: a (source, category) nobody listed is still checked.
    tf = {"q.preferences.source=apple|category=music": 100, "x.pref.raw.total": 100,
          "x.pref.raw.source=apple|category=music": 100, "x.pref.distinct.source=apple|category=music": 100,
          "w.shown.preferences.source=apple|category=music": 2, "w.denied.preferences.total": 0,
          "q.preferences.source=spotify|category=music": 5, "x.pref.raw.source=spotify|category=music": 10,
          "x.pref.distinct.source=spotify|category=music": 5, "w.shown.preferences.source=spotify|category=music": 5}
    rt, ct = adjudicate({"rows": [{"template": "preferences_pairs"}]}, tf)
    byid = dict((r["id"], r["verdict"]) for r in rt)
    if byid.get("preferences/apple/music") != "LOST":
        fails.append("template: apple/music 2 of 100 shown not LOST: %s" % byid)
    if byid.get("preferences/spotify/music") != "INFLATED":
        fails.append("template: spotify/music mirrored graph not INFLATED: %s" % byid)
    tf2 = dict(tf)
    tf2["w.shown.preferences.source=apple|category=music"] = 100
    tf2["x.pref.raw.source=spotify|category=music"] = 5
    rt, ct = adjudicate({"rows": [{"template": "preferences_pairs"}]}, tf2)
    if ct["LOST"] or ct["INFLATED"]:
        fails.append("template control (healthy) not clean: %s" % ct)

    # 11. A known gap may never swallow an UNREAD row: NOT-MEASURED is not PASS
    #     and not KNOWN-GAP. Only a row that WAS measured and failed is a gap.
    exp6 = {"rows": [{"id": "places/areas", "source": "places", "category": "area",
                      "known_gap": "headline reads 'areas', no writer produces it",
                      "expected": {"stored": 4, "shown": 4}, "facts": {"stored": "q", "shown": "w"}}]}
    r6, c6 = adjudicate(exp6, {"q": 4})            # shown unreadable
    if c6["NOT-MEASURED"] != 1 or c6["KNOWN-GAP"] != 0 or overall(r6, c6)[1] != 78:
        fails.append("known gap swallowed an unread row (want NOT-MEASURED / 78): %s" % c6)
    exp7 = {"rows": [{"id": "places/areas", "source": "places", "category": "area",
                      "known_gap": "headline reads 'areas', no writer produces it",
                      "expected": {"in": 4, "stored": 4}, "facts": {"in": "i", "stored": "q", "shown": "w"}}]}
    r7, c7 = adjudicate(exp7, {"i": 4, "q": 0})    # stored LOST, shown unreadable
    if c7["KNOWN-GAP"] != 0 or overall(r7, c7)[1] == 0:
        fails.append("known gap hid a row with an unread stage: %s" % c7)

    # 12. An all-zero box is CANNOT-RUN, never PASS (nothing was loaded, so
    #     nothing was conserved). Control: the same rows with data PASS.
    exp8 = {"rows": [{"id": "a/x", "source": "a", "category": "x", "expected": {"in": 0, "stored": 0, "shown": 0},
                      "facts": {"in": "i", "stored": "q", "shown": "w"}}]}
    r8, c8 = adjudicate(exp8, {"i": 0, "q": 0, "w": 0})
    if overall(r8, c8)[1] != 78:
        fails.append("all-zero box did not CANNOT-RUN: %s" % (overall(r8, c8),))
    exp9 = {"rows": [{"id": "a/x", "source": "a", "category": "x", "expected": {"in": 3, "stored": 3, "shown": 3},
                      "facts": {"in": "i", "stored": "q", "shown": "w"}},
                     {"id": "b/y", "source": "b", "category": "y", "expected": {"in": 0, "stored": 0, "shown": 0},
                      "facts": {"in": "i2", "stored": "q2", "shown": "w2"}}]}
    r9, c9 = adjudicate(exp9, {"i": 3, "q": 3, "w": 3, "i2": 0, "q2": 0, "w2": 0})
    if overall(r9, c9)[1] != 0:
        fails.append("control: a box with data and one genuinely empty row did not PASS: %s" % (overall(r9, c9),))
    r10, c10 = adjudicate(exp9, {"i": 3, "q": 0, "w": 0, "i2": 0, "q2": 0, "w2": 0})
    if overall(r10, c10)[1] != 78:
        fails.append("every STORED count 0 while IN is not did not CANNOT-RUN: %s" % (overall(r10, c10),))
    exp11 = {"rows": [{"id": "a/x", "source": "a", "category": "x", "expected": {"in": 0, "stored": 0},
                       "facts": {"in": "i", "stored": "q"}}]}
    r11, c11 = adjudicate(exp11, {"i": 0, "q": 0})
    if overall(r11, c11)[1] != 78:
        fails.append("all IN zero (and stored zero) did not CANNOT-RUN")

    for f_ in fails:
        print("SELFTEST FAIL: " + f_)
    if not fails:
        print("SELFTEST OK: control clean; 4 mutations LOST; mirrored nodes INFLATED; denial counts EXPLAIN exactly; known gap visible; absent fact NOT-MEASURED; empty set CANNOT-RUN; "
              "real wiki reader saw the allow-list drop (apple %d -> %d)" % (good["apple"], bad["apple"]))
    return 0 if not fails else 1


# ===========================================================================
# CLI
# ===========================================================================

def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "collect":
        json.dump(collect(), sys.stdout, sort_keys=True)
        print()
        return 0
    if cmd == "selftest":
        return selftest()
    if cmd == "adjudicate":
        import argparse
        ap = argparse.ArgumentParser()
        ap.add_argument("--expected", required=True)
        ap.add_argument("--facts", required=True)
        ap.add_argument("--out")
        ap.add_argument("--profile", default="chain")
        a = ap.parse_args(argv[2:])
        with open(a.expected) as fh:
            exp = json.load(fh)
        if "profiles" in exp:
            if a.profile not in exp["profiles"]:
                print("unknown profile %s (have: %s)" % (a.profile, ", ".join(sorted(exp["profiles"]))))
                return 78
            exp = exp["profiles"][a.profile]
        with open(a.facts) as fh:
            blob = json.load(fh)
        facts = blob.get("facts", blob)
        rows, counts = adjudicate(exp, facts)
        word, code = overall(rows, counts)
        table = render_md(rows, counts, word)
        print(table)
        if a.out:
            with open(a.out, "w") as fh:
                fh.write(table + "\n")
        return code
    print("unknown subcommand %s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
