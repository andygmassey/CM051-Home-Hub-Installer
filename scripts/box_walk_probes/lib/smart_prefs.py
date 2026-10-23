#!/usr/bin/env python3
"""Smart Preferences walk probes: the shared fixture, box readers and judges.

Five BLOCKING probes (OS003 docs/SMART_PREFERENCES_SPEC.md, "Done means PROVEN"):

  derived_preferences_runs         the cm019 venv imports yaml + the derive
                                   package, and a derive pass completed
  derived_preferences_breadth      the Hub route serves items from >= 6 broad
                                   categories on the seed fixture
  derived_preferences_dislike      an owner message stating a dislike yields a
                                   NEGATIVE item in the matching dimension
  derived_preferences_not_others   another person's stated like yields NO owner
                                   item (with a control: the owner's own like
                                   DOES derive, so an empty engine cannot pass)
  dislike_respected_in_brief       the brief built on the seed does not suggest
                                   the disliked thing (and does use preferences)

SYNTHETIC ONLY. Every name, domain and sentence below is invented. No real
person, address or message.

Modes (stdlib only, python 3.9+; box modes run on the box):
  seed            write the fixture (Qdrant points + CM048-shaped facts), read it
                  back, kick the derive agent, wait for a pass. Prints JSON.
  forget          remove the fixture and kick the agent so derived nodes go too.
  box-runs        facts for derived_preferences_runs        (JSON on stdout)
  box-served      facts for breadth / dislike / not_others  (JSON on stdout)
  box-brief       facts for dislike_respected_in_brief      (JSON on stdout)
  judge NAME FACTS.json   -> ok/FAIL/CANNOT lines; exit 0 / 1 / 78
  engine-check TREE       run a cm019 tree's REAL derive engine over the fixture
                  (needs rdflib + pyyaml) and judge what it would serve
  --self-test     every judge against a good fixture and one mutant per
                  assertion, including the uniform-zero control; exit 0 when
                  the judges behave, 1 when a mutant slipped through

Labels leave the box only if they are this file's own synthetic constants; a
real preference label, digest line or brief sentence never does. Counts and
yes/no answers only.
"""
import json
import os
import re
import subprocess
import sys
import time
import uuid

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78

TAG = "smartprefs-walk-fixture"
UUID_NS = uuid.UUID("5f0c2c1e-9a52-4a63-8d0e-5a7c0c1f0e18")
GRAPH = "urn:ostler-walk-fixture:smartprefs"
OWNER_NODE = "urn:ostler:user/WalkOwner"
OTHER_NODE = "urn:ostler:other/walk_alex"
AGENT_LABEL = "com.ostler.derive-preferences"
MIN_CATEGORIES = 6

# The statements. Vocabulary-known values on purpose (stated_vocab.yaml), so a
# box with no local model still derives them: the verdict must not depend on a
# model fallback. Each is said in three separate conversations because a single
# remark is deliberately too weak to clear the consume threshold.
DISLIKE = {"dimension": "food.ingredient", "label": "Coriander",
           "text": "WalkOwner really can't stand coriander."}
OWNER_LIKE = {"dimension": "food.cuisine", "label": "Sichuan",
              "text": "WalkOwner loves Sichuan food."}
OTHER_LIKE = {"dimension": "media.music.genre", "label": "Jazz",
              "text": "WalkOther loves jazz."}
CONVERSATIONS = 3

# Broad evidence, one row per category: (route category, qdrant category,
# payload locator, values). Four points per value clears every min_evidence
# floor in dimensions.yaml.
BROAD = [
    ("films", "movie", "title", ["WalkFilm One", "WalkFilm Two"]),
    ("books", "book", "title", ["WalkBook One", "WalkBook Two"]),
    ("interests", "interest", "title", ["WalkInterest One", "WalkInterest Two"]),
    ("tv", "tv_show", "subject", ["WalkSeries Alpha", "WalkSeries Beta"]),
    ("music", "music", "extra.artist", ["WalkArtist One", "WalkArtist Two"]),
    ("podcasts", "podcast", "extra.podcast_name", ["WalkPodcast One", "WalkPodcast Two"]),
    ("web", "bookmark", "extra.domain", ["walk-example-one.test", "walk-example-two.test"]),
    ("news", "bookmark", "extra.domain", ["bbc.com", "reuters.com"]),
    ("place", "place", "extra.city", ["Walkton", "Fixtureville"]),
    ("brands", "product", "extra.brand", ["WalkBrand Alpha", "WalkBrand Beta"]),
    ("food", "food", "extra.restaurant", ["WalkNoodle House", "WalkTrattoria"]),
    ("health", "fitness", "extra.activity", ["swimming", "cycling"]),
    ("work", "professional", "extra.skill_name", ["WalkSkill Alpha", "WalkSkill Beta"]),
]
# The BROAD tier is types of things (genres, topics), not single things, and
# those dimensions read an Oxigraph overlay tag joined to the point by id
# (enrichment/ontology#hasGenre / hasTopic), not a payload field. One tag per
# category, shared by both values, so each broad dimension has 8 pieces of
# evidence. Labels are synthetic or plain genre words; the music one is in the
# shipped music_style vocabulary.
ENRICH_NS = "https://schema.ostler.ai/enrichment/ontology#"
RDFS_LABEL = "http://www.w3.org/2000/01/rdf-schema#label"
TAG_NS = "urn:ostler-walk-fixture:smartprefs/tag/"
OVERLAY = {"movie": ("hasGenre", "science fiction"), "book": ("hasGenre", "history"),
           "interest": ("hasTopic", "photography"), "tv_show": ("hasGenre", "drama"),
           "music": ("hasGenre", "hip hop"), "podcast": ("hasTopic", "technology")}
EXPECTED_TAGS = len({l for _, l in OVERLAY.values()})
POINTS_PER_VALUE = 4
EXPECTED_POINTS = sum(len(v) for _, _, _, v in BROAD) * POINTS_PER_VALUE
EXPECTED_FACTS = 3 * CONVERSATIONS

_MEDIA = {"film": "films", "tv": "tv", "music": "music", "book": "books", "podcast": "podcasts"}
_HEAD = {"commerce": "brands", "interests": "interests", "web": "web", "news": "news",
         "food": "food", "place": "place", "health": "health", "work": "work", "finance": "finance"}


def category_of(item):
    """Broad category of a served item: its own field when it has one, else the
    dimension's prefix (the register in dimensions.yaml names category by
    dimension, and the route has not served the field so far)."""
    c = item.get("category")
    if isinstance(c, str) and c:
        return c
    parts = str(item.get("dimension", "")).split(".")
    if parts[0] == "media" and len(parts) > 1:
        return _MEDIA.get(parts[1], parts[1])
    return _HEAD.get(parts[0], parts[0])


# ---------------------------------------------------------------------------
# the fixture
# ---------------------------------------------------------------------------

def _get(d, path):
    for p in path.split("."):
        d = d.get(p) if isinstance(d, dict) else None
    return d


def _iso(days_ago=3):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - days_ago * 86400))


def qdrant_points(dim_vector):
    pts = []
    for cat, qcat, loc, values in BROAD:
        for v in values:
            for i in range(POINTS_PER_VALUE):
                key = "%s|%s|%d" % (cat, v, i)
                extra, subject = {}, "Walk fixture %s" % cat
                if loc == "subject":
                    subject = "%s - S01E0%d" % (v, i + 1)
                elif loc == "title":
                    subject = v
                else:
                    extra = {loc.split(".", 1)[1]: v}
                pts.append({
                    "id": str(uuid.uuid5(UUID_NS, key)),
                    "vector": dim_vector,
                    "payload": {
                        "category": qcat, "preference_id": "walk-" + key, "subject": subject,
                        "source": "walk_fixture_%s" % ("a" if i % 2 else "b"),
                        "strength": 0.7, "observed_at": _iso(3 + i), "extra": extra, "walk_fixture": TAG,
                    },
                })
    return pts


def overlay_triples():
    """Enrichment-overlay tags for the broad (genre / topic) dimensions, as
    N-Triples lines for the DEFAULT graph (the overlay reader's SPARQL is not
    graph-scoped), one tag node per label."""
    lines, seen = [], set()
    for p in qdrant_points([0.0]):
        spec = OVERLAY.get(p["payload"]["category"])
        if not spec:
            continue
        pred, label = spec
        node = TAG_NS + label.replace(" ", "-")
        lines.append("<urn:ostler:preference:%s> <%s%s> <%s> ." % (p["id"], ENRICH_NS, pred, node))
        lines.append("<urn:ostler:preference:%s> <%senrichmentConfidence> \"0.8\" ." % (p["id"], ENRICH_NS))
        if node not in seen:
            seen.add(node)
            lines.append("<%s> <%s> %s ." % (node, RDFS_LABEL, _lit(label)))
    return lines


def _lit(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fact_triples():
    """CM048-shaped urn:ostler:Fact triples (the shape the stated reader's SPARQL
    reads), as SPARQL/Turtle-compatible lines. Three conversations each."""
    lines, n = [], 0
    for stmt, about in ((DISLIKE, OWNER_NODE), (OWNER_LIKE, OWNER_NODE), (OTHER_LIKE, OTHER_NODE)):
        for c in range(CONVERSATIONS):
            n += 1
            f = "<urn:ostler-walk-fixture:smartprefs/fact%d>" % n
            lines.append(
                "%s a <urn:ostler:Fact> ; <urn:ostler:fromConversation> <urn:ostler-walk-fixture:smartprefs/conv%d> ;"
                " <urn:ostler:about> <%s> ; <urn:ostler:userId> \"WalkOwner\" ; <urn:ostler:type> \"preference\" ;"
                " <urn:ostler:domain> \"walk\" ; <urn:ostler:privacyLevel> \"L1\" ; <urn:ostler:signalStrength> \"strong\" ;"
                " <urn:ostler:provenanceHeader> \"[pwg:src=walk_fixture id=%d]\" ; <urn:ostler:text> %s ."
                % (f, n, about, n, _lit(stmt["text"])))
    return lines


# ---------------------------------------------------------------------------
# box plumbing
# ---------------------------------------------------------------------------
HOME = os.path.expanduser("~")
OSTLER = os.environ.get("OSTLER_DIR") or os.path.join(HOME, ".ostler")
SECRETS = os.environ.get("OSTLER_SECRETS_DIR", os.path.join(OSTLER, "secrets"))
HUB = os.environ.get("OSTLER_HUB_URL", "http://127.0.0.1:8090").rstrip("/")
QDRANT = os.environ.get("OSTLER_QDRANT_URL", "http://127.0.0.1:6333").rstrip("/")
OXI = os.environ.get("OSTLER_OXIGRAPH_URL", "http://127.0.0.1:7878").rstrip("/")
COLLECTION = os.environ.get("QDRANT_COLLECTION", "preferences")
CM019 = os.environ.get("OSTLER_CM019_DIR") or os.path.join(OSTLER, "services", "cm019")
STATUS = os.path.join(OSTLER, "state", "derived-preferences.json")
MARKER = os.path.join(OSTLER, "state", "smartprefs-walk-seed.json")
LOG = os.path.join(OSTLER, "logs", "derive-preferences.log")
PLIST = os.path.join(HOME, "Library", "LaunchAgents", AGENT_LABEL + ".plist")
LAUNCHCTL = os.environ.get("OSTLER_SMARTPREFS_LAUNCHCTL", "/bin/launchctl")


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _secret(name):
    return _read(os.path.join(SECRETS, name))


def _http(method, url, body=None, headers=None, timeout=30):
    """-> (status, parsed json or None, error). Never raises for an HTTP status."""
    import urllib.error
    import urllib.request
    data = body if body is None or isinstance(body, bytes) else json.dumps(body).encode()
    h = dict(headers or {})
    if data is not None and "Content-Type" not in h:
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as r:
            raw, code = r.read(), r.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    except Exception as e:  # transport: could not look
        return None, None, "%s: %s" % (type(e).__name__, e)
    try:
        return code, (json.loads(raw) if raw else None), ""
    except ValueError:
        return code, None, ""


def _qdrant(method, path, body=None):
    h = {}
    k = _secret("qdrant_api_key")
    if k:
        h["api-key"] = k
    return _http(method, QDRANT + path, body, h)


def _oxi_update(sparql):
    h = {"Content-Type": "application/sparql-update"}
    t = _secret("oxigraph_token")
    if t:
        h["Authorization"] = "Bearer " + t
    return _http("POST", OXI + "/update", sparql.encode(), h)


def _oxi_select(sparql):
    import urllib.parse
    h = {"Accept": "application/sparql-results+json"}
    t = _secret("oxigraph_token")
    if t:
        h["Authorization"] = "Bearer " + t
    return _http("GET", OXI + "/query?query=" + urllib.parse.quote(sparql), None, h)


def _status():
    try:
        return json.loads(_read(STATUS) or "null") or {}
    except ValueError:
        return {"outcome": "unreadable"}


def fixture_presence():
    """Read the fixture back out of both stores. -> dict of counts (None = could not look)."""
    out = {"points": None, "facts": None, "tags": None, "error": ""}
    code, body, err = _qdrant("POST", "/collections/%s/points/count" % COLLECTION,
                              {"exact": True, "filter": {"must": [{"key": "walk_fixture", "match": {"value": TAG}}]}})
    if code == 200 and isinstance(body, dict):
        out["points"] = int((body.get("result") or {}).get("count", 0))
    else:
        out["error"] += "qdrant count: status=%s %s; " % (code, err)
    code, body, err = _oxi_select(
        'SELECT (COUNT(DISTINCT ?f) AS ?n) WHERE { GRAPH <%s> { ?f a <urn:ostler:Fact> } }' % GRAPH)
    try:
        out["facts"] = int(body["results"]["bindings"][0]["n"]["value"])
    except Exception:
        out["error"] += "oxigraph count: status=%s %s; " % (code, err)
    code, body, err = _oxi_select(
        'SELECT (COUNT(DISTINCT ?t) AS ?n) WHERE { ?t <%s> ?l . FILTER(STRSTARTS(STR(?t), "%s")) }' % (RDFS_LABEL, TAG_NS))
    try:
        out["tags"] = int(body["results"]["bindings"][0]["n"]["value"])
    except Exception:
        out["error"] += "oxigraph tag count: status=%s %s; " % (code, err)
    return out


def _kick():
    uid = os.getuid()
    try:
        p = subprocess.run([LAUNCHCTL, "kickstart", "-k", "gui/%d/%s" % (uid, AGENT_LABEL)],
                           capture_output=True, text=True, timeout=30)
        return p.returncode, (p.stdout + p.stderr).strip()[-300:]
    except Exception as e:
        return 127, "%s: %s" % (type(e).__name__, e)


def _import_check(py, mod_expr):
    try:
        p = subprocess.run([py, "-c", mod_expr], cwd=CM019, capture_output=True, text=True, timeout=120)
        return {"rc": p.returncode, "err": (p.stderr.strip().splitlines() or [""])[-1][:200]}
    except Exception as e:
        return {"rc": 127, "err": "%s: %s" % (type(e).__name__, e)}


def _cm019_py():
    return os.path.join(CM019, ".venv", "bin", "python3")


def _derive_wait(prev, budget):
    deadline = time.time() + budget
    poll = float(os.environ.get("OSTLER_SMARTPREFS_POLL_S", "3"))
    while True:
        s = _status()
        if s.get("last_run_at") and s.get("last_run_at") != prev:
            return True, s
        if time.time() >= deadline:
            return False, s
        time.sleep(poll)


def seed_main():
    out = {"state": "failed", "why": "", "points_written": 0, "facts_written": 0}
    code, info, err = _qdrant("GET", "/collections/%s" % COLLECTION)
    if code != 200:
        out["why"] = "collection %s not readable: status=%s %s" % (COLLECTION, code, err)
        print(json.dumps(out)); return 0
    try:
        vecs = info["result"]["config"]["params"]["vectors"]
        size = vecs["size"] if "size" in vecs else next(iter(vecs.values()))["size"]
        name = None if "size" in vecs else next(iter(vecs))
    except Exception as e:
        out["why"] = "cannot read the vector size: %s" % type(e).__name__
        print(json.dumps(out)); return 0
    vec = [0.01] * int(size)
    pts = qdrant_points(vec)
    if name:
        for p in pts:
            p["vector"] = {name: p["vector"]}
    for i in range(0, len(pts), 50):
        code, _b, err = _qdrant("PUT", "/collections/%s/points?wait=true" % COLLECTION, {"points": pts[i:i + 50]})
        if code not in (200, 202):
            out["why"] = "qdrant upsert refused: status=%s %s" % (code, err)
            print(json.dumps(out)); return 0
        out["points_written"] += len(pts[i:i + 50])
    ins = "INSERT DATA { GRAPH <%s> {\n%s\n} }" % (GRAPH, "\n".join(fact_triples()))
    code, _b, err = _oxi_update(ins)
    if code not in (200, 204):
        out["why"] = "oxigraph insert refused: status=%s %s" % (code, err)
        print(json.dumps(out)); return 0
    out["facts_written"] = EXPECTED_FACTS
    code, _b, err = _oxi_update("INSERT DATA {\n%s\n}" % "\n".join(overlay_triples()))
    if code not in (200, 204):
        out["why"] = "oxigraph overlay insert refused: status=%s %s" % (code, err)
        print(json.dumps(out)); return 0
    out["presence"] = fixture_presence()
    prev = _status().get("last_run_at")
    rc, kout = _kick()
    out["kick"] = {"rc": rc, "out": kout}
    ran, st = (False, _status())
    if rc == 0:
        ran, st = _derive_wait(prev, float(os.environ.get("OSTLER_SMARTPREFS_DERIVE_BUDGET_S", "240")))
    out["derive"] = {"ran_after_seed": ran, "outcome": st.get("outcome"), "reason": (st.get("reason") or "")[:200]}
    out["state"] = "seeded"
    try:
        os.makedirs(os.path.dirname(MARKER), exist_ok=True)
        with open(MARKER, "w") as fh:
            json.dump({"seeded_at": _iso(0), "ran_after_seed": ran, "outcome": st.get("outcome"), "kick_rc": rc}, fh)
    except OSError as e:
        out["why"] = "marker not written: %s" % e
    print(json.dumps(out))
    return 0


def _forget_brief_job():
    """Delete the brief probe's cron job by id if one was recorded (a walk killed
    mid-wait leaves the marker). -> HTTP status, or None when nothing to delete."""
    try:
        job = json.loads(_read(BRIEFJOB) or "null")["job"]
    except (ValueError, KeyError, TypeError):
        return None
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import wow_moments as wm
    admin = wm._secret("zeroclaw_admin_token")
    code = _delete_brief_job(wm, job, {"Authorization": "Bearer " + admin} if admin else {})
    try:
        os.remove(BRIEFJOB)
    except OSError:
        pass
    return code


def forget_main():
    res = {}
    code, _b, err = _qdrant("POST", "/collections/%s/points/delete?wait=true" % COLLECTION,
                            {"filter": {"must": [{"key": "walk_fixture", "match": {"value": TAG}}]}})
    res["qdrant_delete"] = code
    code, _b, err = _oxi_update("DROP SILENT GRAPH <%s>" % GRAPH)
    res["oxigraph_drop"] = code
    res["overlay_delete"] = _oxi_update(
        'DELETE { ?s ?p ?o } WHERE { ?s ?p ?o . FILTER(STRSTARTS(STR(?o), "%s") || STRSTARTS(STR(?s), "%s") '
        '|| (STRSTARTS(STR(?s), "urn:ostler:preference:") && EXISTS { ?s <%shasGenre> ?x } ) ) }' % (TAG_NS, TAG_NS, ENRICH_NS))[0]
    res["brief_job_deleted"] = _forget_brief_job()
    try:
        os.remove(MARKER)
    except OSError:
        pass
    res["kick_rc"] = _kick()[0]
    res["presence_after"] = fixture_presence()
    print(json.dumps(res))
    return 0


# ---------------------------------------------------------------------------
# box readers
# ---------------------------------------------------------------------------

def _marker():
    try:
        return json.loads(_read(MARKER) or "null") or {}
    except ValueError:
        return {}


def _engine_state():
    py = _cm019_py()
    imp = ({"rc": 127, "err": "no interpreter at %s" % py} if not os.path.exists(py)
           else _import_check(py, "import yaml, services.enrich.src.derive"))
    return imp, os.path.isfile(PLIST)


def box_runs_main():
    py = _cm019_py()
    f = {"python": py, "python_exists": os.path.exists(py)}
    if f["python_exists"]:
        f["yaml"] = _import_check(py, "import yaml")
        f["derive"] = _import_check(py, "import services.enrich.src.derive")
        f["pyshacl"] = _import_check(py, "import pyshacl")
    else:
        none = {"rc": 127, "err": "no cm019 interpreter"}
        f["yaml"], f["derive"], f["pyshacl"] = none, none, none
    f["scheduled"] = os.path.isfile(PLIST)
    s = _status()
    f["status"] = {"present": bool(s), "outcome": s.get("outcome"), "last_run_at": s.get("last_run_at"),
                   "reason": (s.get("reason") or "")[:200], "graph_node_count": s.get("graph_node_count")}
    log = _read(LOG).splitlines()
    f["log"] = {"present": bool(log),
                "completed_ticks": sum(1 for l in log if "tick finished: written" in l),
                "failed_ticks": sum(1 for l in log if "tick finished: NOT written" in l)}
    print(json.dumps(f))
    return 0


def _route(tier=None):
    tok = _secret("service_token")
    q = "limit=200&min_confidence=0" + ("&tier=%s" % tier if tier else "")
    code, body, err = _http("GET", HUB + "/api/v1/preferences/derived?" + q, None,
                            {"Authorization": "Bearer " + tok} if tok else {})
    return code, body, err


def broad_categories(body, items):
    """Which categories are BROAD in what the route served for ?tier=broad.
    -> (sorted categories, mode). Modes, each labelled in the probe output:
      fallback  the route says tier_fallback (a graph written before tiers, so
                it served every tier): NOT broad, zero broad categories.
      item      items carry a tier field: count only tier == broad.
      served    the payload says tier == broad: the route filtered, count all.
      absent    no tier support in the payload (an older route): count every
                category with a positive item. A labelled fallback, not a pass."""
    b = body if isinstance(body, dict) else {}
    pos = [i for i in items if (i.get("strength") or 0) > 0]
    if b.get("tier_fallback"):
        return [], "fallback"
    if any("tier" in i for i in pos):
        return sorted({category_of(i) for i in pos if i.get("tier") == "broad"}), "item"
    if b.get("tier") == "broad":
        return sorted({category_of(i) for i in pos}), "served"
    return sorted({category_of(i) for i in pos}), "absent"


def box_served_main():
    imp, scheduled = _engine_state()
    m = _marker()
    f = {"fixture": fixture_presence(),
         "seed": {"marker": bool(m), "ran_after_seed": bool(m.get("ran_after_seed")), "outcome": m.get("outcome"),
                  "seed_state_env": os.environ.get("OSTLER_SMARTPREFS_SEED_STATE", "")},
         "engine_can_run": imp["rc"] == 0 and scheduled, "engine_why": "" if imp["rc"] == 0 and scheduled else
         ("not scheduled" if not scheduled else "import failed: %s" % imp["err"])}
    # TWO READS. Breadth is a statement about the BROAD tier, so it reads the
    # route's own broad tier (?tier=broad, CM041 #234). Everything else (the
    # stated dislike, the owner's like, another person's like) reads ?tier=all,
    # because a stated ingredient is legitimately not a broad item. A route that
    # predates tiers ignores the parameter, which the tier_mode below records.
    code, body, err = _route("all")
    bcode, bbody, berr = _route("broad")
    if code is None or bcode is None:
        f["route"] = {"status": None, "error": err or berr}
        print(json.dumps(f)); return 0
    items = body.get("items") if isinstance(body, dict) else None
    items = [i for i in (items if isinstance(items, list) else []) if isinstance(i, dict)]
    bitems = bbody.get("items") if isinstance(bbody, dict) else None
    bitems = [i for i in (bitems if isinstance(bitems, list) else []) if isinstance(i, dict) and (i.get("strength") or 0) > 0]
    cats = {}
    for i in items:
        if (i.get("strength") or 0) > 0:
            cats.setdefault(category_of(i), 0)
            cats[category_of(i)] += 1
    broad_cats, tier_mode = broad_categories(bbody, bitems)

    def find(stmt, other=False):
        hits = [i for i in items if str(i.get("label", "")).strip().lower() == stmt["label"].lower()]
        return {"count": len(hits), "dimension_match": any(i.get("dimension") == stmt["dimension"] for i in hits),
                "strengths": [round(float(i.get("strength") or 0), 3) for i in hits
                              if i.get("dimension") == stmt["dimension"]][:3]}
    f["route"] = {"status": code, "degraded": bool(body.get("degraded")) if isinstance(body, dict) else True,
                  "items": len(items), "categories": broad_cats, "categories_all": sorted(cats),
                  "tier_mode": tier_mode, "broad_status": bcode,
                  "dislike": find(DISLIKE), "owner_like": find(OWNER_LIKE), "other_like": find(OTHER_LIKE)}
    print(json.dumps(f))
    return 0


# ---------------------------------------------------------------------------
# the brief reader. A walk probe must NEVER send outward: the job is created
# with delivery mode none SET EXPLICITLY, read back, and deleted before it can
# fire if the gateway did not keep it. The job id is recorded so that forget()
# (normal path and abort trap) removes it even if this process was killed.
# ---------------------------------------------------------------------------
BRIEFJOB = os.path.join(OSTLER, "state", "smartprefs-brief-job.json")
BRIEF_LEAD_S = 150   # cron has minute granularity: the minute is truncated, so >= 90 s of margin


def _delivery_mode(job):
    d = (job or {}).get("delivery")
    if isinstance(d, dict):
        return d.get("mode")
    return d if isinstance(d, str) else None


def _delete_brief_job(wm, job, auth):
    return wm._http("DELETE", wm.GATEWAY + "/api/cron/%s" % job, headers=auth)[0]


def _read_job(wm, job, auth):
    code, body = wm._http("GET", wm.GATEWAY + "/api/cron/%s" % job, headers=auth)
    if code == 200 and isinstance(body, dict):
        return body.get("job") if isinstance(body.get("job"), dict) else body
    code, body = wm._http("GET", wm.GATEWAY + "/api/cron", headers=auth)
    rows = body if isinstance(body, list) else (body or {}).get("jobs") or []
    for r in rows:
        if isinstance(r, dict) and r.get("id") == job:
            return r
    return None


def box_brief_main():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import wow_moments as wm
    served = json.loads(_capture(box_served_main))
    f = {"served": served}
    prompt = wm._morning_prompt()
    if not prompt:
        f["cannot"] = "no morning-brief job in ~/.ostler/assistant-config/config.toml (no brief channel was set up)"
        print(json.dumps(f)); return 0
    admin = wm._secret("zeroclaw_admin_token")
    auth = {"Authorization": "Bearer " + admin} if admin else {}
    positives = []
    code, body, _e = _route("all")
    if code == 200 and isinstance(body, dict):
        positives = [str(i.get("label", "")).strip() for i in body.get("items") or []
                     if isinstance(i, dict) and (i.get("strength") or 0) > 0 and len(str(i.get("label", "")).strip()) >= 4]
    t = time.localtime(time.time() + BRIEF_LEAD_S)
    expr = "%d %d %d %d *" % (t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon)
    code, body = wm._http("POST", wm.GATEWAY + "/api/cron", body={
        "name": "smartprefs-brief-walk-probe", "schedule": expr, "job_type": "agent",
        "prompt": prompt, "session_target": "isolated", "delete_after_run": False,
        "delivery": {"mode": "none"}}, headers=auth)
    job = ((body or {}).get("job") or {}).get("id")
    if code != 200 or not job:
        f["cannot"] = "could not add the probe's copy of the morning brief job (HTTP %s)" % code
        print(json.dumps(f)); return 0
    try:
        os.makedirs(os.path.dirname(BRIEFJOB), exist_ok=True)
        with open(BRIEFJOB, "w") as fh:
            json.dump({"job": job}, fh)
    except OSError:
        pass
    # READ IT BACK before it can fire. "Undelivered" is a property of the stored
    # job, not of what we sent: a gateway that defaulted or ignored the field
    # would send this brief out on the owner's channel or by email.
    stored = _read_job(wm, job, auth)
    mode = _delivery_mode(stored)
    if mode != "none":
        gone = _delete_brief_job(wm, job, auth)
        try:
            os.remove(BRIEFJOB)
        except OSError:
            pass
        f["cannot"] = ("REFUSED: the gateway stored delivery mode %r (not 'none') for the probe's job; deleted it (HTTP %s) "
                       "before it could fire, so nothing was sent" % (mode, gone))
        print(json.dumps(f)); return 0
    try:
        text, deadline = None, time.time() + float(os.environ.get("OSTLER_SMARTPREFS_BRIEF_WAIT_S", "600"))
        while time.time() < deadline:
            time.sleep(float(os.environ.get("OSTLER_SMARTPREFS_BRIEF_POLL_S", "10")))
            code, runs = wm._http("GET", wm.GATEWAY + "/api/cron/%s/runs" % job, headers=auth)
            rows = runs if isinstance(runs, list) else (runs or {}).get("runs") or []
            if rows:
                text = rows[0].get("output") or ""
                f["run_status"] = rows[0].get("status")
                break
        if text is None:
            f["cannot"] = "the probe's morning brief did not run in time"
        else:
            f["answered"] = bool(text.strip())
            f["names_disliked"] = bool(names_any(text, [DISLIKE["label"], "cilantro"]))
            f["positives_graded"] = len(positives)
            f["positives_named"] = names_any(text, positives)
    finally:
        _delete_brief_job(wm, job, auth)
        try:
            os.remove(BRIEFJOB)
        except OSError:
            pass
    print(json.dumps(f))
    return 0


def _capture(fn):
    import io
    old, buf = sys.stdout, io.StringIO()
    sys.stdout = buf
    try:
        fn()
    finally:
        sys.stdout = old
    return buf.getvalue()


def names_any(text, labels):
    low = (text or "").lower()
    return sum(1 for l in labels if l and re.search(r"(?<!\w)" + re.escape(l.lower()) + r"(?!\w)", low))


# ---------------------------------------------------------------------------
# judges. Each returns [(assertion, state, detail)], state in ok|FAIL|CANNOT.
# ---------------------------------------------------------------------------

def _gate(f):
    """Shared preconditions for the four probes that read what derive produced.
    -> CANNOT/FAIL rows if the measurement cannot stand, else None."""
    fx, sd = f.get("fixture") or {}, f.get("seed") or {}
    if fx.get("points") is None or fx.get("facts") is None:
        return [("seed fixture is readable back from the stores", "CANNOT", fx.get("error") or "no reading")]
    if fx.get("tags") is None:
        return [("seed fixture is readable back from the stores", "CANNOT", fx.get("error") or "no tag reading")]
    if fx["points"] < EXPECTED_POINTS or fx["facts"] < EXPECTED_FACTS or fx["tags"] < EXPECTED_TAGS:
        return [("seed fixture is on the box", "CANNOT",
                 "points %s/%s, facts %s/%s, overlay tags %s/%s (seed state %r); the walk did not seed it, so nothing here was measured"
                 % (fx["points"], EXPECTED_POINTS, fx["facts"], EXPECTED_FACTS, fx["tags"], EXPECTED_TAGS, sd.get("seed_state_env")))]
    if not sd.get("ran_after_seed"):
        if not f.get("engine_can_run"):
            return [("a derive pass ran after the seed", "FAIL",
                     "the derive engine cannot run on this box (%s); see derived_preferences_runs" % f.get("engine_why"))]
        return [("a derive pass ran after the seed", "CANNOT",
                 "the engine can start but no pass finished after the kick (outcome %s); deferred or busy, not a verdict"
                 % sd.get("outcome"))]
    r = f.get("route") or {}
    if r.get("status") is None:
        return [("the Hub route answers", "CANNOT", "route unmeasured: %s" % r.get("error", "no reading"))]
    if r["status"] != 200:
        return [("the Hub route answers 200", "FAIL", "GET /api/v1/preferences/derived answered %s" % r["status"])]
    return None


def judge_runs(f):
    rows = []
    if not f.get("python_exists"):
        rows.append(("the cm019 venv interpreter exists", "FAIL", "no interpreter at %s" % f.get("python")))
    for key, name in (("yaml", "import yaml"), ("derive", "import services.enrich.src.derive"),
                      ("pyshacl", "import pyshacl")):
        r = f.get(key) or {}
        rows.append(("cm019 venv python: " + name, "ok" if r.get("rc") == 0 else "FAIL",
                     "" if r.get("rc") == 0 else "rc=%s %s" % (r.get("rc"), r.get("err"))))
    rows.append(("the derive LaunchAgent is scheduled", "ok" if f.get("scheduled") else "FAIL",
                 "" if f.get("scheduled") else "no com.ostler.derive-preferences plist"))
    s = f.get("status") or {}
    lg = f.get("log") or {}
    if not s.get("present"):
        why = "no state/derived-preferences.json: the tick has never recorded a pass"
        broken = any(r[1] == "FAIL" for r in rows)
        rows.append(("a derive pass completed", "FAIL" if broken else "CANNOT", why))
    elif s.get("outcome") in ("written", "empty"):
        rows.append(("a derive pass completed", "ok",
                     "outcome=%s last_run_at=%s graph_nodes=%s log_ticks_written=%s"
                     % (s["outcome"], s.get("last_run_at"), s.get("graph_node_count"), lg.get("completed_ticks"))))
    else:
        rows.append(("a derive pass completed", "FAIL",
                     "outcome=%s reason=%s failed_ticks_in_log=%s" % (s.get("outcome"), s.get("reason"), lg.get("failed_ticks"))))
    return rows


def judge_breadth(f):
    g = _gate(f)
    if g:
        return g
    r = f["route"]
    n = len(r.get("categories") or [])
    mode = r.get("tier_mode", "absent")
    note = {"served": " (tier: the route served tier=broad)",
            "item": " (tier: counted items with tier == broad)",
            "fallback": " (tier_fallback: the graph predates tiers and the route served every tier, which is NOT broad)",
            "absent": " (NO TIER in the payload, older route: fell back to counting every category with a positive item)"}.get(mode, "")
    if mode == "fallback":
        return [("route serves items from >= %d broad categories" % MIN_CATEGORIES, "FAIL",
                 "0 broad categories%s; the next derive run must write tiers" % note)]
    if r.get("degraded") or not r.get("items"):
        return [("route serves items from >= %d broad categories" % MIN_CATEGORIES, "FAIL",
                 "status=200 degraded=%s items=%s; nothing derived is served" % (r.get("degraded"), r.get("items")))]
    return [("route serves items from >= %d broad categories" % MIN_CATEGORIES,
             "ok" if n >= MIN_CATEGORIES else "FAIL",
             "%d categories %s from %d items%s" % (n, r.get("categories"), r.get("items"), note))]


def judge_dislike(f):
    g = _gate(f)
    if g:
        return g
    d = (f["route"].get("dislike") or {})
    name = "a stated dislike yields a negative item in %s" % DISLIKE["dimension"]
    if not d.get("dimension_match"):
        return [(name, "FAIL", "no %s item for the seeded dislike (route items=%s, label seen in any dimension: %s)"
                 % (DISLIKE["dimension"], f["route"].get("items"), d.get("count")))]
    neg = [s for s in d.get("strengths") or [] if s < 0]
    return [(name, "ok" if neg else "FAIL",
             "strengths=%s" % d.get("strengths"))]


def judge_not_others(f):
    g = _gate(f)
    if g:
        return g
    r = f["route"]
    ctl = r.get("owner_like") or {}
    pos = [s for s in ctl.get("strengths") or [] if s > 0]
    rows = [("control: the owner's own stated like DOES derive (a blind engine cannot pass)",
             "ok" if pos else "FAIL",
             "strengths=%s" % ctl.get("strengths") if pos else
             "the owner's own stated like produced no item, so stated preferences are not derived at all and "
             "'no item for another person' proves nothing")]
    if not pos:
        return rows
    o = r.get("other_like") or {}
    rows.append(("another person's stated like yields no owner item", "ok" if not o.get("count") else "FAIL",
                 "owner items for the other person's like: %s" % o.get("count", 0)))
    return rows


def judge_brief(f):
    s = f.get("served") or {}
    if f.get("cannot"):
        return [("the brief was built", "CANNOT", f["cannot"])]
    g = _gate(s)
    if g:
        return g
    d = (s["route"].get("dislike") or {})
    neg = [x for x in d.get("strengths") or [] if x < 0] if d.get("dimension_match") else []
    rows = [("precondition: the dislike is derived, so there is one to respect", "ok" if neg else "FAIL",
             "" if neg else "no negative item for the seeded dislike; a brief that omits it proves nothing")]
    if not f.get("answered"):
        return rows + [("the brief was written", "FAIL", "run status %s, empty output" % f.get("run_status"))]
    rows.append(("the brief does not suggest the disliked thing", "FAIL" if f.get("names_disliked") else "ok",
                 "names the disliked label: %s" % bool(f.get("names_disliked"))))
    graded = f.get("positives_graded") or 0
    named = f.get("positives_named") or 0
    rows.append(("the brief is weighted by preferences: it names a served liked item",
                 "ok" if named > 0 else "FAIL", "named %s of %s served liked labels" % (named, graded)))
    return rows


JUDGES = {
    "derived_preferences_runs": judge_runs,
    "derived_preferences_breadth": judge_breadth,
    "derived_preferences_dislike": judge_dislike,
    "derived_preferences_not_others": judge_not_others,
    "dislike_respected_in_brief": judge_brief,
}


def report(rows):
    for name, state, detail in rows:
        print("  %-6s %s%s" % (state, name, " (%s)" % detail if detail else ""))
    if any(s == "FAIL" for _, s, _ in rows):
        return EX_FAIL
    if any(s == "CANNOT" for _, s, _ in rows):
        return EX_CANNOT
    return EX_PASS


# ---------------------------------------------------------------------------
# the real engine over the fixture (driver side)
# ---------------------------------------------------------------------------

def engine_items(tree):
    """Run <tree>/services/enrich/src/derive over the fixture; -> served-shape items."""
    import datetime
    import rdflib
    sys.path.insert(0, os.path.join(tree, "services", "common"))
    sys.path.insert(0, os.path.join(tree, "services", "enrich", "src"))
    from derive.config import build_readers, load_dimensions
    from derive.engine import Aggregator, DerivationEngine
    pts = qdrant_points([0.0])
    ds = rdflib.Dataset()
    ds.graph(rdflib.URIRef(GRAPH)).parse(data="\n".join(fact_triples()), format="turtle")
    (getattr(ds, "default_graph", None) or ds.default_context).parse(data="\n".join(overlay_triples()), format="nt")

    class Gw:
        def scroll(self, categories, fields):
            return [{"id": p["id"], "payload": {k: v for k, v in p["payload"].items() if k in fields}}
                    for p in pts if p["payload"]["category"] in categories]

        def sparql(self, query):
            return [{str(k): {"value": str(v)} for k, v in r.asdict().items()} for r in ds.query(query)]
    now = datetime.datetime.now(datetime.timezone.utc)
    res = DerivationEngine(readers=build_readers(Gw()), aggregator=Aggregator(load_dimensions())).run_result("ostler", now=now)
    out = []
    for n in res.nodes:
        it = {"dimension": n.dimension, "label": n.subject, "strength": n.preference_strength, "confidence": n.confidence}
        t = getattr(n, "tier", None)
        if t:
            it["tier"] = t
        out.append(it)
    return out, res


def served_facts_from_items(items):
    """The facts box-served would produce for a route serving `items` on a box
    whose fixture is seeded and whose derive pass ran."""
    pos = [i for i in items if (i.get("strength") or 0) > 0]
    cats, tier_mode = broad_categories({}, pos)

    def find(stmt):
        hits = [i for i in items if str(i["label"]).strip().lower() == stmt["label"].lower()]
        return {"count": len(hits), "dimension_match": any(i["dimension"] == stmt["dimension"] for i in hits),
                "strengths": [round(float(i["strength"]), 3) for i in hits if i["dimension"] == stmt["dimension"]]}
    return {"fixture": {"points": EXPECTED_POINTS, "facts": EXPECTED_FACTS, "tags": EXPECTED_TAGS, "error": ""},
            "seed": {"marker": True, "ran_after_seed": True, "outcome": "written", "seed_state_env": "seeded"},
            "engine_can_run": True, "engine_why": "",
            "route": {"status": 200, "degraded": not items, "items": len(items), "categories": cats,
                      "categories_all": cats, "tier_mode": tier_mode,
                      "dislike": find(DISLIKE), "owner_like": find(OWNER_LIKE), "other_like": find(OTHER_LIKE)}}


def engine_check_main(tree):
    try:
        items, res = engine_items(tree)
    except ImportError as e:
        print("CANNOT-RUN: %s (pip install rdflib pyyaml)" % e)
        return EX_CANNOT
    f = served_facts_from_items(items)
    print("engine tree: %s" % tree)
    print("derived nodes: %d, readers total/failed: %s/%s" % (len(items), res.readers_total, len(res.failed_readers)))
    worst = EX_PASS
    for name in ("derived_preferences_breadth", "derived_preferences_dislike", "derived_preferences_not_others"):
        print(name)
        rc = report(JUDGES[name](f))
        worst = EX_FAIL if EX_FAIL in (worst, rc) else max(worst, rc)
    return worst


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------

def _good_served():
    cats = ["films", "tv", "music", "podcasts", "web", "news", "place", "brands", "food", "health", "work"]
    return {"fixture": {"points": EXPECTED_POINTS, "facts": EXPECTED_FACTS, "tags": EXPECTED_TAGS, "error": ""},
            "seed": {"marker": True, "ran_after_seed": True, "outcome": "written", "seed_state_env": "seeded"},
            "engine_can_run": True, "engine_why": "",
            "route": {"status": 200, "degraded": False, "items": 40, "categories": cats, "categories_all": cats,
                      "tier_mode": "served",
                      "dislike": {"count": 1, "dimension_match": True, "strengths": [-0.8]},
                      "owner_like": {"count": 1, "dimension_match": True, "strengths": [0.8]},
                      "other_like": {"count": 0, "dimension_match": False, "strengths": []}}}


def _good_runs():
    ok = {"rc": 0, "err": ""}
    return {"python": "/x/python3", "python_exists": True, "yaml": ok, "derive": ok, "pyshacl": ok, "scheduled": True,
            "status": {"present": True, "outcome": "written", "last_run_at": "2026-10-22T00:00:00Z",
                       "reason": "", "graph_node_count": 30},
            "log": {"present": True, "completed_ticks": 2, "failed_ticks": 0}}


def _good_brief():
    return {"served": _good_served(), "answered": True, "names_disliked": False,
            "positives_graded": 5, "positives_named": 2, "run_status": "ok"}


def _mut(base, fn):
    import copy
    d = copy.deepcopy(base)
    fn(d)
    return d


_CASES = [0]


def self_test():
    """Exit 0 when every judge behaves, 1 when a mutant slipped through."""
    bad = []

    def expect(label, judge, facts, want):
        rc = report_quiet(judge(facts))
        _CASES[0] += 1
        ok = rc == want
        print("  %s  %s -> rc %s (want %s)" % ("ok   " if ok else "BROKEN", label, rc, want))
        if not ok:
            bad.append(label)

    def served(**kw):
        return _mut(_good_served(), lambda d: d["route"].update(kw))
    G = _good_served()
    expect("breadth good", judge_breadth, G, EX_PASS)
    expect("breadth: films only (v1.0.116)", judge_breadth, served(categories=["films"], categories_all=["films"], items=5), EX_FAIL)
    expect("breadth: five categories", judge_breadth, served(categories=list("abcde")), EX_FAIL)
    expect("breadth: degraded empty route", judge_breadth, served(degraded=True, items=0, categories=[]), EX_FAIL)
    expect("breadth: tier served, only 2 broad categories", judge_breadth,
           served(tier_mode="served", categories=["films", "tv"]), EX_FAIL)
    expect("breadth: tier_fallback is NOT broad even with many categories", judge_breadth,
           served(tier_mode="fallback", categories=[]), EX_FAIL)
    expect("breadth: no tier in payload falls back to category count (labelled)", judge_breadth,
           served(tier_mode="absent"), EX_PASS)
    expect("breadth: overlay tags missing is CANNOT", judge_breadth,
           _mut(G, lambda d: d["fixture"].update(tags=0)), EX_CANNOT)
    expect("breadth: fixture missing is CANNOT, not FAIL", judge_breadth,
           _mut(G, lambda d: d["fixture"].update(points=0)), EX_CANNOT)
    expect("breadth: route unmeasured is CANNOT", judge_breadth,
           _mut(G, lambda d: d.update(route={"status": None, "error": "URLError"})), EX_CANNOT)
    expect("breadth: derive never ran, engine broken -> FAIL", judge_breadth,
           _mut(G, lambda d: (d["seed"].update(ran_after_seed=False), d.update(engine_can_run=False, engine_why="import failed"))), EX_FAIL)
    expect("breadth: derive never ran, engine fine -> CANNOT", judge_breadth,
           _mut(G, lambda d: d["seed"].update(ran_after_seed=False)), EX_CANNOT)
    expect("breadth: route 404 -> FAIL", judge_breadth, _mut(G, lambda d: d["route"].update(status=404)), EX_FAIL)

    expect("dislike good", judge_dislike, G, EX_PASS)
    expect("dislike: absent", judge_dislike, served(dislike={"count": 0, "dimension_match": False, "strengths": []}), EX_FAIL)
    expect("dislike: derived as a LIKE (polarity inverted)", judge_dislike,
           served(dislike={"count": 1, "dimension_match": True, "strengths": [0.8]}), EX_FAIL)
    expect("dislike: right label, wrong dimension", judge_dislike,
           served(dislike={"count": 1, "dimension_match": False, "strengths": []}), EX_FAIL)

    expect("not_others good", judge_not_others, G, EX_PASS)
    expect("not_others: other's like leaked to the owner", judge_not_others,
           served(other_like={"count": 1, "dimension_match": True, "strengths": [0.6]}), EX_FAIL)
    expect("not_others: UNIFORM ZERO (engine blind: control absent too)", judge_not_others,
           served(owner_like={"count": 0, "dimension_match": False, "strengths": []},
                  dislike={"count": 0, "dimension_match": False, "strengths": []}, items=0, degraded=True), EX_FAIL)

    B = _good_brief()
    expect("brief good", judge_brief, B, EX_PASS)
    expect("brief: names the disliked thing", judge_brief, _mut(B, lambda d: d.update(names_disliked=True)), EX_FAIL)
    expect("brief: no dislike derived (nothing to respect)", judge_brief,
           _mut(B, lambda d: d["served"]["route"].update(dislike={"count": 0, "dimension_match": False, "strengths": []})), EX_FAIL)
    expect("brief: empty output", judge_brief, _mut(B, lambda d: d.update(answered=False)), EX_FAIL)
    expect("brief: preferences not used (names no liked item)", judge_brief, _mut(B, lambda d: d.update(positives_named=0)), EX_FAIL)
    expect("brief: no brief channel is CANNOT", judge_brief, {"served": G, "cannot": "no morning-brief job"}, EX_CANNOT)

    R = _good_runs()
    expect("runs good", judge_runs, R, EX_PASS)
    expect("runs: pyyaml missing (the v1.0.116 box)", judge_runs, _mut(R, lambda d: d.update(yaml={"rc": 1, "err": "ModuleNotFoundError: yaml"})), EX_FAIL)
    expect("runs: derive tree missing", judge_runs, _mut(R, lambda d: d.update(derive={"rc": 1, "err": "No module named services.enrich.src.derive"})), EX_FAIL)
    expect("runs: not scheduled", judge_runs, _mut(R, lambda d: d.update(scheduled=False)), EX_FAIL)
    expect("runs: pass kept the previous graph", judge_runs, _mut(R, lambda d: d["status"].update(outcome="not_written", reason="a reader failed")), EX_FAIL)
    expect("runs: cannot_start", judge_runs, _mut(R, lambda d: d["status"].update(outcome="cannot_start")), EX_FAIL)
    expect("runs: scheduled, imports fine, never ran is CANNOT", judge_runs,
           _mut(R, lambda d: d["status"].update(present=False, outcome=None)), EX_CANNOT)
    expect("runs: never ran AND imports broken is FAIL", judge_runs,
           _mut(R, lambda d: (d["status"].update(present=False, outcome=None), d.update(yaml={"rc": 1, "err": "x"}))), EX_FAIL)
    expect("runs: no interpreter", judge_runs, _mut(R, lambda d: d.update(python_exists=False, yaml={"rc": 127, "err": "x"})), EX_FAIL)

    # the vocabulary this file's judges depend on must still map
    for want, got in (("films", category_of({"dimension": "media.film.genre"})),
                      ("food", category_of({"dimension": "food.ingredient"})),
                      ("brands", category_of({"dimension": "commerce.brand"})),
                      ("tv", category_of({"dimension": "media.tv.series", "category": "tv"}))):
        ok = want == got
        print("  %s  category_of -> %s (want %s)" % ("ok   " if ok else "BROKEN", got, want))
        if not ok:
            bad.append("category_of " + want)
    print("EXAMINED: %d judge cases" % _CASES[0])
    return 1 if bad else 0


def report_quiet(rows):
    if any(s == "FAIL" for _, s, _ in rows):
        return EX_FAIL
    if any(s == "CANNOT" for _, s, _ in rows):
        return EX_CANNOT
    return EX_PASS


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "--self-test":
        # exit 0 = judges behave. The wrapper probe inverts it into its own verdict.
        import io
        buf, old = io.StringIO(), sys.stdout
        sys.stdout = buf
        try:
            self_test()
        finally:
            sys.stdout = old
        out = buf.getvalue()
        sys.stdout.write(out)
        return 1 if "BROKEN" in out else 0
    if cmd == "seed":
        return seed_main()
    if cmd == "forget":
        return forget_main()
    if cmd == "box-runs":
        return box_runs_main()
    if cmd == "box-served":
        return box_served_main()
    if cmd == "box-brief":
        return box_brief_main()
    if cmd == "judge" and len(argv) >= 4 and argv[2] in JUDGES:
        try:
            facts = json.load(open(argv[3]))
        except (OSError, ValueError) as e:
            print("  CANNOT the box-side reader returned no readable facts: %s" % e)
            return EX_CANNOT
        return report(JUDGES[argv[2]](facts))
    if cmd == "engine-check" and len(argv) >= 3:
        return engine_check_main(argv[2])
    print("usage: smart_prefs.py seed|forget|box-runs|box-served|box-brief|judge NAME FACTS|engine-check TREE|--self-test")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
