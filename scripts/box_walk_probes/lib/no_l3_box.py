#!/usr/bin/env python3
# lib/no_l3_box.py -- runs ON THE BOX (never on the walker's machine).
#
# Seeds synthetic L2 (control), L0 and L3 items and reads the paths an outbound
# reply is built from. Nothing secret is printed: the service token and the store
# credential are read here and used in-process, never echoed. stderr is kept.
#
#   seven pwg_* tools   one L3 and one L2 conversation through the SHIPPED writer
#                       (pwg-convo process): privacy.py:26-29, processor.py:240-258,
#                       ingest.py:861-872.
#   timeline            fixture person + L2/L0/L3 facts and conversations built by
#                       CM048's own serialisers (lib/no_l3_graph_seed.py), read at
#                       GET /api/v1/person/<slug>/timeline (_person_timeline_body,
#                       ical-server.py:7453) AND by asking the assistant "what's been
#                       happening with <name> lately" over /ws/chat.
#   reply-debt          a schema-1 email snapshot (reply_debt_sources.read_snapshot,
#                       email_threads) with one L2, L0 and L3 thread, read at
#                       GET /api/v1/reply-debt. The directory is backed up first and
#                       restored byte for byte; the tree sha before and after is
#                       reported. The producer's own 15-minute tick is avoided by
#                       starting the window just after one.
#   brief               the smart_prefs.py:729-745 pattern: a copy of the morning-brief
#                       job with delivery mode none, refused unless the stored mode
#                       reads back as none, run once, deleted. The job's own delivery
#                       is never used. It reads the open owner todos seeded above and
#                       the reply-debt thread.
#
# Teardown (always, in finally): reply-debt dir restored; graph rows deleted BY
# SUBJECT and counted before and after, plus an independent "stamp anywhere" count
# and a live-rows positive control; the pwg-convo conversations forgotten with the
# harness's own statements and their processing/Conversations files removed by id.
# Append-only logs are not touched.
import base64, hashlib, json, os, re, shutil, subprocess, sys, tempfile, time, traceback
import urllib.parse, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

API = "http://127.0.0.1:8090"
OLLAMA = "http://127.0.0.1:11434"
QDRANT = "http://127.0.0.1:6333"
# The shipped CLI lives under the install's own bin directory (measured on the
# walk box 2026-11-16: /usr/local/bin/pwg-convo does not exist there). Prefer the
# install path, keep the old one as the fallback.
CLI = next((p for p in (os.path.expanduser("~/.ostler/bin/pwg-convo"), "/usr/local/bin/pwg-convo")
            if os.path.exists(p)), os.path.expanduser("~/.ostler/bin/pwg-convo"))
CM048_DIR = os.path.expanduser("~/.ostler/services/cm048")
VENV_PY = os.path.join(CM048_DIR, ".venv", "bin", "python3")
OXI = "http://127.0.0.1:7878"
PWG_NS = "https://schema.ostler.ai/ontology#"
RD_DIR = os.path.expanduser("~/.ostler/state/reply_debt")
GATEWAY = "http://127.0.0.1:8000"
FIXTURE_NAME = "John Doe"          # synthetic, reserved-style, not a real person
FIXTURE_SLUG = "john-doe"
FIXTURE_DATE = "2026-11-10"
TOKEN_PATH = os.path.expanduser("~/.ostler/secrets/service_token")
STORE_CONF = os.path.expanduser("~/.ostler/secrets/store-curl.conf")
KNOWLEDGE_COLLECTION = "evernote_knowledge"   # pwg_knowledge_search.rs:35
EMBED_MODEL = "nomic-embed-text"              # pwg_knowledge_search.rs:32
SEED_BUDGET_S = 900


# The brief path's derived route, the oa constant DERIVED_PATH (catchup.rs:60).
BRIEF_DERIVED_PATH = "/api/v1/preferences/derived?limit=8&min_confidence=0.4"
# The reply-debt snapshot field that carries the level: privacy_level
# (vendor/cm048_pipeline/src/reply_debt.py:146). Seed THAT field, not a guess.
REPLY_DEBT_LEVEL_FIELD = "privacy_level"


def _token():
    with open(TOKEN_PATH, encoding="utf-8") as fh:
        return fh.read().strip()


def _get(path, token):
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return {"status": r.status, "text": r.read(400000).decode("utf-8", "replace")}
    except Exception as exc:  # noqa: BLE001 -- the reason is data, reported as such
        return {"error": type(exc).__name__ + ": " + str(exc)[:200]}


def _transcript(marker, level):
    return (
        "---\n"
        f"title: Walk probe {marker}\n"
        f"call_id: {marker.lower()}\n"
        "timestamp: 2026-11-16T09:15:00Z\n"
        "duration_seconds: 90\n"
        "source: voice_note\n"
        f"privacy_level: {level}\n"
        "language: en-GB\n"
        "diarization_method: manual\n"
        "participants:\n  - speaker_label: USER\n    display_name: You\n"
        "---\n\n"
        f"**You** [00:04]: Decision: {marker} approve the quarry lease renewal.\n\n"
        f"**You** [00:31]: Topic: {marker} quarry negotiations.\n\n"
        f"**You** [01:12]: Commitment: I will send {marker} the signed quarry lease by Friday.\n\n"
        f"**You** [01:40]: Note: {marker} keep the pallet order on hold.\n"
    )


# The harness's own conversation-forget statements (lib/conversation_seed.sh
# forget step), run under /bin/sh, parametrised on the seeded id and the box's
# owner id. Prints before/after counts only; never the credential.
TEARDOWN_SH = r"""#!/bin/sh
ID="$1"; UID_="$2"
CONF="$HOME/.ostler/secrets/store-curl.conf"
[ -r "$CONF" ] || { echo "NO-CONF"; exit 4; }
K="-K $CONF"
CURL=/usr/bin/curl
Q=http://127.0.0.1:6333
OXI=http://127.0.0.1:7878/query
UPD="${OXI%/query}/update"
NS='https://schema.ostler.ai/ontology#'
G="urn:ostler:user/$UID_"
FILT='{"exact": true, "filter": {"must": [{"key": "conversation_id", "match": {"value": "'"$ID"'"}}]}}'
qcount() { $CURL -sS --noproxy '*' -m 20 $K -X POST -H 'Content-Type: application/json' --data "$FILT" "$Q/collections/conversations/points/count" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["count"])'; }
scount() { $CURL -sS --noproxy '*' -m 20 $K -H 'Content-Type: application/sparql-query' -H 'Accept: application/sparql-results+json' --data-binary "SELECT (COUNT(*) AS ?n) WHERE { { ?s ?p ?o } UNION { GRAPH ?g { ?s ?p ?o } } FILTER(CONTAINS(STR(?s), \"$ID\") || CONTAINS(STR(?o), \"$ID\")) }" "$OXI" | python3 -c 'import json,sys;print(json.load(sys.stdin)["results"]["bindings"][0]["n"]["value"])'; }
echo "BEFORE qdrant=$(qcount) graph=$(scount)"
$CURL -sS --noproxy '*' -m 30 $K -X POST -H 'Content-Type: application/json' --data '{"filter": {"must": [{"key": "conversation_id", "match": {"value": "'"$ID"'"}}]}}' "$Q/collections/conversations/points/delete?wait=true" >/dev/null 2>&1
u1="DELETE { ?t ?p ?o } WHERE { ?m <${NS}inConversation> <urn:ostler:conversation/$ID> ; <${NS}mentionsTopic> ?t . ?t ?p ?o . FILTER NOT EXISTS { ?m2 <${NS}mentionsTopic> ?t ; <${NS}inConversation> ?c2 . FILTER(?c2 != <urn:ostler:conversation/$ID>) } }"
u2="DELETE { ?m ?p ?o } WHERE { ?m <${NS}inConversation> <urn:ostler:conversation/$ID> ; ?p ?o }"
u3="DELETE { GRAPH <$G> { <urn:ostler:conversation/$ID> ?p ?o } } WHERE { GRAPH <$G> { <urn:ostler:conversation/$ID> ?p ?o } }"
u4="DELETE { GRAPH <$G> { ?s ?p2 ?o2 } } WHERE { GRAPH <$G> { ?s ?p <urn:ostler:conversation/$ID> ; ?p2 ?o2 } }"
for u in "$u1" "$u2" "$u3" "$u4"; do $CURL -sS --noproxy '*' -m 30 $K -H 'Content-Type: application/sparql-update' --data-binary "$u" "$UPD" -o /dev/null; done
echo "AFTER qdrant=$(qcount) graph=$(scount)"
"""


def _teardown(cid, owner):
    """Forget one seeded conversation. Returns the before/after counts parsed
    from the script's own output, so the judge can check the positive control
    (before > 0) and the residue (after == 0)."""
    import re
    path = os.path.join(tempfile.mkdtemp(prefix="no-l3-teardown-"), "teardown.sh")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(TEARDOWN_SH)
    try:
        out = subprocess.run(["/bin/sh", path, cid, owner], capture_output=True,
                             text=True, timeout=300).stdout
    finally:
        subprocess.run(["rm", "-rf", os.path.dirname(path)])
    b = re.search(r"BEFORE qdrant=(\d+) graph=(\d+)", out)
    a = re.search(r"AFTER qdrant=(\d+) graph=(\d+)", out)
    if not (b and a):
        return {"id": cid, "parsed": False, "raw": out[-200:]}
    return {"id": cid, "parsed": True,
            "before_qdrant": int(b.group(1)), "before_graph": int(b.group(2)),
            "after_qdrant": int(a.group(1)), "after_graph": int(a.group(2))}


def _seed(cid, marker, level):
    meta = {
        "conversation_id": cid, "date": "2026-11-16", "channel": "spoken",
        "source": "voice_note", "source_session_id": cid, "capture_source": "cm042_mac",
        "privacy_level": level, "title": "Walk probe " + marker,
        "participants": [{"id": "user", "display": "You", "role": "user"}],
    }
    d = tempfile.mkdtemp(prefix="no-l3-probe-")
    try:
        t_path, m_path = os.path.join(d, "transcript.md"), os.path.join(d, "metadata.json")
        with open(t_path, "w", encoding="utf-8") as fh:
            fh.write(_transcript(marker, level))
        with open(m_path, "w", encoding="utf-8") as fh:
            json.dump(meta, fh)
        try:
            rc = subprocess.run([CLI, "process", t_path, m_path], capture_output=True,
                                timeout=SEED_BUDGET_S).returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
    finally:
        subprocess.run(["rm", "-rf", d])
    bundle = os.path.expanduser(f"~/.ostler/processing/{cid}/09_bundle.json")
    return {"id": cid, "cli_rc": rc, "bundle": "present" if os.path.exists(bundle) else "absent"}


def _embed(prompt):
    body = json.dumps({"model": EMBED_MODEL, "prompt": prompt}).encode()
    req = urllib.request.Request(OLLAMA + "/api/embeddings", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["embedding"]


def _qdrant_search(vector):
    # Same body the oa tool sends (pwg_knowledge_search.rs, the fail-closed filter).
    body = json.dumps({
        "vector": vector, "limit": 10,
        "filter": {"must": [{"key": "privacy_level", "match": {"any": ["L1", "L2"]}}]},
        "with_payload": {"include": ["title", "content", "text", "notebook", "notebook_name",
                                     "tags", "source", "privacy_level"]},
    })
    url = f"{QDRANT}/collections/{KNOWLEDGE_COLLECTION}/points/search"
    out = subprocess.run(["curl", "-s", "--noproxy", "*", "-K", STORE_CONF, "-X", "POST",
                          url, "-H", "Content-Type: application/json", "-d", body],
                         capture_output=True, text=True, timeout=60)
    return {"status": 200 if out.returncode == 0 else out.returncode, "text": out.stdout}


def _tools(m3, m2, token):
    q = lambda m: urllib.parse.quote(m)  # noqa: E731
    got = {
        "pwg_decisions": _get(f"/api/v1/decisions?q={q(m3)}", token),
        "pwg_decisions_l2": _get(f"/api/v1/decisions?q={q(m2)}", token),
        "pwg_topics": _get(f"/api/v1/topics?q={q(m3)}", token),
        "pwg_topics_l2": _get(f"/api/v1/topics?q={q(m2)}", token),
        "pwg_commitments": _get("/api/v1/commitments?owner=user&status=open&limit=200", token),
        "pwg_preferences": _get("/api/v1/preferences?limit=1000", token),
        "pwg_overview": _get("/api/v1/hydration/status", token),
        "pwg_derived_preferences": _get("/api/v1/preferences/derived", token),
    }
    for label, marker in (("pwg_knowledge_search", m3), ("pwg_knowledge_search_l2", m2)):
        try:
            got[label] = _qdrant_search(_embed(marker))
        except Exception as exc:  # noqa: BLE001
            got[label] = {"error": type(exc).__name__ + ": " + str(exc)[:200]}
    return got




# ---------------------------------------------------------------------------
# The three L0/L3 paths: timeline, reply-debt, brief (catch-up).
# Every function below keeps stderr (the caller prints it) and returns data.
# ---------------------------------------------------------------------------

LOG = []


def _note(msg):
    LOG.append(msg)
    print("[no_l3] " + msg, file=sys.stderr, flush=True)


def _sparql(kind, text):
    """-> (http_code, body). kind is 'query' or 'update'. Auth is the box's own
    curl config; the credential is never printed."""
    ctype = "application/sparql-query" if kind == "query" else "application/sparql-update"
    out = subprocess.run(
        ["curl", "-sS", "--noproxy", "*", "-m", "90", "-K", STORE_CONF, "-o", "-", "-w", "\n%{http_code}",
         "-H", "Content-Type: " + ctype, "-H", "Accept: application/sparql-results+json",
         "--data-binary", text, OXI + "/" + kind], capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError("curl rc=%s: %s" % (out.returncode, out.stderr.strip()[:200]))
    body, _, code = out.stdout.rpartition("\n")
    return int(code or 0), body


def _count(where):
    """COUNT(*) over a graph pattern, in the default graph and every named graph."""
    code, body = _sparql("query",
        "SELECT (COUNT(*) AS ?n) WHERE { { GRAPH ?g { %s } } UNION { %s } }" % (where, where))
    if code != 200:
        raise RuntimeError("count query HTTP %s: %s" % (code, body[:200]))
    return int(json.loads(body)["results"]["bindings"][0]["n"]["value"])


def _count_subjects(subjects):
    vals = " ".join("<%s>" % s for s in subjects)
    return _count("VALUES ?s { %s } ?s ?p ?o" % vals)


def _count_stamp(stamp):
    """Independent surface: any triple whose subject or object mentions the stamp."""
    return _count('?s ?p ?o FILTER(CONTAINS(STR(?s), "%s") || CONTAINS(STR(?o), "%s"))' % (stamp, stamp))


def _count_total():
    return _count("?s ?p ?o")


def _delete_subjects(subjects):
    vals = " ".join("<%s>" % s for s in subjects)
    for upd in (
        "DELETE { GRAPH ?g { ?s ?p ?o } } WHERE { GRAPH ?g { VALUES ?s { %s } ?s ?p ?o } }" % vals,
        "DELETE { ?s ?p ?o } WHERE { VALUES ?s { %s } ?s ?p ?o }" % vals,
    ):
        code, body = _sparql("update", upd)
        if code not in (200, 204):
            raise RuntimeError("delete HTTP %s: %s" % (code, body[:200]))


def _tree_sha(directory):
    """sha256 over sorted 'f <rel> <sha256>' / 'd <rel>' lines. Mode and mtime are
    not in it; the restore copies them anyway (shutil.copy2)."""
    lines = []
    for root, dirs, files in os.walk(directory):
        for d in dirs:
            lines.append("d " + os.path.relpath(os.path.join(root, d), directory))
        for f in files:
            full = os.path.join(root, f)
            with open(full, "rb") as fh:
                lines.append("f %s %s" % (os.path.relpath(full, directory), hashlib.sha256(fh.read()).hexdigest()))
    return hashlib.sha256("\n".join(sorted(lines)).encode()).hexdigest()


def _file_sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def classify_path(text, l2_marker, error=None):
    """The per-path gate. A path is `captured` only when it was read AND its
    L2 control surfaced in it. Anything else is not a capture, so the judge says
    CANNOT-RUN, never PASS. Pure, so the self-test can drive it."""
    if error or text is None:
        return {"status": "not_captured", "error": str(error or "no capture"), "control": False}
    if not text.strip():
        return {"status": "empty", "text": "", "control": False}
    if l2_marker not in text:
        return {"status": "control_silent", "text": text, "control": False}
    return {"status": "captured", "text": text, "control": True}


def with_l3_control(cls, l3_count):
    """L3 POSITIVE CONTROL. `l3_count` is how many rows/files carrying the L3 token
    were counted in the store after seeding and before any capture. Zero means the
    L3 seed is not there, so "no L3 token in the output" would only mean "nothing
    to withhold": the path is not captured, never a pass. Pure, self-tested."""
    cls = dict(cls)
    cls["l3_seed_count"] = l3_count
    if not l3_count:
        cls["status"] = "l3_seed_absent"
        cls["control"] = False
    return cls


# --- timeline ---------------------------------------------------------------

def _seed_graph(owner, stamp, markers, subjects_out):
    payload = {"owner": owner, "stamp": stamp, "person_name": FIXTURE_NAME, "post": True,
               "convs": [{"id": "ostler-walk-" + markers[lvl], "level": lvl, "marker": markers[lvl],
                          "date": FIXTURE_DATE} for lvl in ("L2", "L0", "L3")]}
    p = subprocess.run([VENV_PY, os.path.join(HERE, "no_l3_graph_seed.py"), json.dumps(payload)],
                       cwd=CM048_DIR, capture_output=True, text=True, timeout=180)
    if p.stderr.strip():
        _note("graph seed stderr: " + p.stderr.strip()[:400])
    if p.returncode != 0:
        raise RuntimeError("graph seed rc=%s" % p.returncode)
    out = json.loads(p.stdout)
    subjects_out.extend(out["subjects"])
    return out


TIMELINE_PROMPT = "show me my recent conversations with %s" % FIXTURE_NAME


def _capture_timeline(token, markers):
    """TWO arms, judged separately by no_l3_probe.py (api_arm, outbound_arm):
    (a) the owner-local GET /api/v1/person/<slug>/timeline body, kept whole as
        api_text so the judge can read each event's privacy_level;
    (b) the channel reply through oa, kept as reply_text. The prompt names the
        fixture person and asks for their RECENT CONVERSATIONS so the timeline tool
        is actually reached; the L2 control marker must arrive in the reply, which
        the judge checks (absent -> CANNOT-RUN)."""
    api = _get("/api/v1/person/%s/timeline" % FIXTURE_SLUG, token)
    api_text = api.get("text") if api.get("status") == 200 else None
    import assistant_chat as ac
    reply = ac.ws_chat(TIMELINE_PROMPT)
    reply_text = (reply.get("text") or "").strip()
    out = {"api_text": api_text, "reply_text": reply_text, "prompt": TIMELINE_PROMPT,
           "reply_chars": len(reply_text), "reply_l2_control": markers["L2"] in reply_text,
           "api_l2_control": bool(api_text and markers["L2"] in api_text),
           "text": (api_text or "") + "\n--- channel reply ---\n" + reply_text}
    _note("timeline: api %s, reply %d chars, L2 control in reply: %s" % (
        "ok" if api_text is not None else (api.get("error") or "status=%s" % api.get("status")),
        len(reply_text), out["reply_l2_control"]))
    if api_text is None:
        out.update(status="not_captured", error=api.get("error") or "api status=%s" % api.get("status"), control=False)
    elif reply.get("error") and not reply_text:
        out.update(status="not_captured", error="channel reply: %s" % reply["error"], control=False)
    else:
        out.update(status="captured", control=out["api_l2_control"] and out["reply_l2_control"])
    return out


# --- reply-debt -------------------------------------------------------------

EMAIL_SNAPSHOT = os.path.join(RD_DIR, "email_threads.json")
TICK_S = 900          # the email-bundle LaunchAgent's StartInterval


def _email_snapshot(markers, stamp):
    """A schema-1 snapshot in the shape CM048 reply_debt_sources.read_snapshot /
    email_threads read. One thread per level, carrying that level's marker in the
    last message. L3 is included on purpose: the detector must drop it."""
    from datetime import datetime, timedelta, timezone
    now = datetime.now(timezone.utc)
    ts = (now - timedelta(days=3)).isoformat()
    threads = []
    for lvl in ("L2", "L0", "L3"):
        threads.append({
            "thread_id": "walkfx-%s-%s" % (stamp, lvl.lower()), "privacy_level": lvl,
            "last": {"timestamp": ts, "from_address": "sender-%s.%s@example.com" % (lvl.lower(), stamp),
                     "to": ["owner.walkfx@example.com"], "is_from_me": False,
                     "text": "%s can you send me the signed quarry lease by Friday?" % markers[lvl]}})
    return {"schema": 1, "status": "ok", "generated_at": now.isoformat(),
            "producer": "no_l3_in_tool_results walk probe (synthetic)",
            "owner_addresses": ["owner.walkfx@example.com"], "threads": threads}


def _wait_for_tick_window(need_s):
    """The email-bundle tick rewrites email_threads.json every TICK_S and would
    overwrite the seed. Start the seeded window just after a tick so it cannot
    land inside it. The phase comes from the file's mtime (written by a tick)."""
    m = os.stat(EMAIL_SNAPSHOT).st_mtime
    now = time.time()
    nxt = m + TICK_S * (int((now - m) // TICK_S) + 1)
    remain = nxt - now
    _note("email tick phase: next write expected in %.0fs, window needs %ss" % (remain, need_s))
    if remain < need_s:
        time.sleep(remain + 25)


def _api_reply_debt(token):
    r = _get("/api/v1/reply-debt?limit=50&lookback_days=30&include_group=0", token)
    return r


# --- brief (catch-up) -------------------------------------------------------

def _brief_via_copy(markers):
    """Smart-prefs pattern (smart_prefs.py:729-745): a COPY of the morning-brief
    job with delivery mode none, read back and refused unless the stored mode is
    'none', run once, its output captured, the copy deleted."""
    import wow_moments as wm
    import smart_prefs as sp
    out = {"job": None, "deleted": None}
    admin = wm._secret("zeroclaw_admin_token")
    auth = {"Authorization": "Bearer " + admin} if admin else {}
    prompt = wm._morning_prompt()
    if not prompt:
        # The job can live in the gateway's runtime store rather than config.toml
        # (measured on the walk box: config.toml has none, GET /api/cron lists it).
        _c, listing = wm._http("GET", wm.GATEWAY + "/api/cron", headers=auth)
        rows = listing if isinstance(listing, list) else (listing or {}).get("jobs") or []
        prompt = next((r.get("prompt") for r in rows if isinstance(r, dict) and r.get("id") == "morning-brief"), None)
    if not prompt:
        return None, "no morning-brief job in config.toml or in GET /api/cron", out
    t = time.localtime(time.time() + sp.BRIEF_LEAD_S)
    expr = "%d %d %d %d *" % (t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon)
    name = "no-l3-walk-probe-brief-" + uuid.uuid4().hex[:8]
    code, body = wm._http("POST", wm.GATEWAY + "/api/cron", body={
        "name": name, "schedule": expr, "job_type": "agent", "prompt": prompt,
        "session_target": "isolated", "delete_after_run": False,
        "delivery": {"mode": "none"}}, headers=auth)
    job = ((body or {}).get("job") or {}).get("id")
    if code != 200 or not job:
        return None, "could not add the probe's copy of the morning brief job (HTTP %s)" % code, out
    out["job"] = job
    try:
        stored = sp._read_job(wm, job, auth)
        mode = sp._delivery_mode(stored)
        if mode != "none":
            return None, ("REFUSED: the gateway stored delivery mode %r (not 'none') for the probe's job; "
                          "deleting it before it can fire" % (mode,)), out
        deadline = time.time() + float(os.environ.get("OSTLER_NO_L3_BRIEF_WAIT_S", "480"))
        while time.time() < deadline:
            time.sleep(10)
            code, runs = wm._http("GET", wm.GATEWAY + "/api/cron/%s/runs" % job, headers=auth)
            rows = runs if isinstance(runs, list) else (runs or {}).get("runs") or []
            if rows:
                return (rows[0].get("output") or ""), None, out
        return None, "the probe's morning brief did not run in time", out
    finally:
        out["deleted"] = sp._delete_brief_job(wm, job, auth)
        code, listing = wm._http("GET", wm.GATEWAY + "/api/cron", headers=auth)
        rows = listing if isinstance(listing, list) else (listing or {}).get("jobs") or []
        out["still_listed"] = sum(1 for r in rows if isinstance(r, dict) and r.get("id") == job)


# --- teardown ---------------------------------------------------------------

def _cleanup_files(cid, stamp):
    """Files the shipped writer leaves for a conversation id, removed by id and
    counted before and after. Logs are append-only and are not touched."""
    roots = [os.path.expanduser("~/.ostler/processing"),
             os.path.expanduser("~/Documents/Ostler/Conversations")]
    found = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirs, files in os.walk(root):
            for n in dirs + files:
                if cid in n or stamp in n:
                    found.append(os.path.join(dirpath, n))
    return found


def _remove_files(paths):
    for p in sorted(set(paths), key=len):
        if os.path.isdir(p):
            shutil.rmtree(p, ignore_errors=True)
        elif os.path.exists(p):
            os.remove(p)


def _restore_reply_debt(backup, seeded_sha, before_tree):
    """Put the directory back byte for byte. If the producer rewrote the file in
    the meantime (its sha is neither mine nor the backup's), the newer producer
    output is NOT overwritten with a stale copy, and that is reported."""
    res = {"before_tree": before_tree}
    cur = _file_sha(EMAIL_SNAPSHOT) if os.path.exists(EMAIL_SNAPSHOT) else None
    res["producer_overwrote"] = bool(cur and cur != seeded_sha and cur != _file_sha(os.path.join(backup, "email_threads.json")))
    if not res["producer_overwrote"]:
        shutil.copy2(os.path.join(backup, "email_threads.json"), EMAIL_SNAPSHOT)
    res["after_tree"] = _tree_sha(RD_DIR)
    res["restored"] = res["after_tree"] == before_tree
    return res


def self_test():
    """Offline checks of the pure pieces, run on the walker's machine. Each path
    gets the three outcomes that matter: missing -> not captured, control silent
    -> not captured, control present -> captured. Exit 0 only if all hold."""
    bad = []

    def want(label, got, expect):
        if got != expect:
            bad.append("%s: wanted %r, got %r" % (label, expect, got))

    for path in ("timeline", "reply_debt", "brief_catchup"):
        want(path + " missing capture", classify_path(None, "QUARTZ1", "http 500")["status"], "not_captured")
        want(path + " empty capture", classify_path("  ", "QUARTZ1")["status"], "empty")
        want(path + " L2 control silent", classify_path('{"debts": []}', "QUARTZ1")["status"], "control_silent")
        want(path + " L2 control present", classify_path('{"snippet": "QUARTZ1 hi"}', "QUARTZ1")["status"], "captured")
    for path in ("timeline", "reply_debt", "brief_catchup"):
        ok = classify_path("QUARTZ1 hi", "QUARTZ1")
        want(path + " L3 seed absent -> not captured", with_l3_control(ok, 0)["status"], "l3_seed_absent")
        want(path + " L3 seed counted -> stays captured", with_l3_control(ok, 3)["status"], "captured")
    # a leak is not this function's business: an L0 token with a live control is still `captured`
    want("leak keeps the capture", classify_path("QUARTZ1 and ZETA1", "QUARTZ1")["status"], "captured")
    # the reply-debt snapshot has the shape CM048 reads, one thread per level, marker in the text
    snap = _email_snapshot({"L2": "QUARTZ1", "L0": "ZETA1", "L3": "ZEPHYR1"}, "abc123")
    want("snapshot schema", (snap["schema"], snap["status"]), (1, "ok"))
    want("snapshot levels", sorted(t["privacy_level"] for t in snap["threads"]), ["L0", "L2", "L3"])
    want("snapshot markers", sorted(t["last"]["text"].split()[0] for t in snap["threads"]), ["QUARTZ1", "ZEPHYR1", "ZETA1"])
    want("snapshot addresses are reserved", all(t["last"]["from_address"].endswith("@example.com") for t in snap["threads"]), True)
    # the tree sha moves when a byte moves (the control for the restore check) and not otherwise
    d = tempfile.mkdtemp(prefix="no-l3-selftest-")
    try:
        with open(os.path.join(d, "a.json"), "w") as fh:
            fh.write("one")
        a1, a2 = _tree_sha(d), _tree_sha(d)
        with open(os.path.join(d, "a.json"), "w") as fh:
            fh.write("two")
        a3 = _tree_sha(d)
        want("tree sha is stable", a1, a2)
        want("tree sha sees a changed byte", a1 != a3, True)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    for b in bad:
        print("SELF-TEST CASE WRONG: " + b, file=sys.stderr)
    return 0 if not bad else 1


def main():
    owner = os.environ.get("OSTLER_NO_L3_OWNER_ID", "")
    if not owner:
        print(json.dumps({"error": "OSTLER_NO_L3_OWNER_ID is unset; teardown needs the box owner id"}))
        return 0
    token = _token()
    # Unique per run: a second run must not be fooled by the first run's rows.
    stamp = uuid.uuid4().hex[:12]
    markers = {"L3": "ZEPHYR" + stamp, "L2": "QUARTZ" + stamp, "L0": "ZETA" + stamp}
    m3, m2, m0 = markers["L3"], markers["L2"], markers["L0"]
    cap = {"markers": {"l3": m3, "l2": m2, "l0": m0}, "seeds": {}, "tools": {}, "teardown": {},
           "paths": {}, "fixture": {"stamp": stamp}, "log": LOG}
    subjects, legacy_ids = [], {"l3": f"ostler-walk-l3-{stamp}", "l2": f"ostler-walk-l2-{stamp}"}
    backup_dir = tempfile.mkdtemp(prefix="no-l3-rd-")
    rd = {"seeded": False}
    try:
        # --- preflight: refuse rather than write into an unmeasured box --------
        pre_name = _count('?s <%sdisplayName> "%s"' % (PWG_NS, FIXTURE_NAME))
        if pre_name != 0:
            raise RuntimeError("fixture name already present %d times; refusing to seed" % pre_name)
        cap["fixture"]["total_before"] = _count_total()
        cap["fixture"]["stamp_before"] = _count_stamp(stamp)
        cap["fixture"]["free_gb_before"] = round(shutil.disk_usage("/").free / 1e9, 1)

        # --- timeline + brief graph rows (CM048's own serialisers) ------------
        _seed_graph(owner, stamp, markers, subjects)
        cap["fixture"]["subjects"] = len(subjects)
        cap["fixture"]["triples_before_delete"] = _count_subjects(subjects)
        _note("graph seeded: %d subjects, %d triples" % (len(subjects), cap["fixture"]["triples_before_delete"]))
        # --- the existing seven-tool seed (shipped pwg-convo writer) -----------
        cap["seeds"] = {"l3": _seed(legacy_ids["l3"], m3, "L3"), "l2": _seed(legacy_ids["l2"], m2, "L2")}
        # --- L3 POSITIVE CONTROL, after seeding and BEFORE any capture ----------
        ctl = {
            "timeline": _count('?s <urn:ostler:text> ?o FILTER(CONTAINS(STR(?o), "%s"))' % m3),
            "brief_todo": _count('?s <urn:ostler:todoText> ?o FILTER(CONTAINS(STR(?o), "%s"))' % m3),
            "pwg_convo_bundle": 1 if cap["seeds"]["l3"].get("bundle") == "present" else 0,
        }
        cap["fixture"]["l3_seed_counts"] = ctl
        _note("L3 seed counts before any capture: " + json.dumps(ctl))
        tl = _capture_timeline(token, markers)
        cap["paths"]["timeline"] = with_l3_control(tl, ctl["timeline"])
        cap["tools"] = _tools(m3, m2, token)

        # --- reply-debt + brief, inside one tick-free window --------------------
        _wait_for_tick_window(700)
        # sha'd snapshot IMMEDIATELY before seeding (the producer is not stopped)
        rd["before_tree"] = _tree_sha(RD_DIR)
        shutil.copytree(RD_DIR, os.path.join(backup_dir, "bak"), copy_function=shutil.copy2)
        rd["backup"] = os.path.join(backup_dir, "bak")
        cap["fixture"]["reply_debt_tree_before"] = rd["before_tree"]
        _note("reply_debt tree sha before seeding: " + rd["before_tree"])
        seeded = _email_snapshot(markers, stamp)
        body = json.dumps(seeded, indent=1).encode()
        with open(EMAIL_SNAPSHOT, "wb") as fh:
            fh.write(body)
        os.chmod(EMAIL_SNAPSHOT, 0o600)
        rd["seeded"], rd["seeded_sha"] = True, hashlib.sha256(body).hexdigest()
        with open(EMAIL_SNAPSHOT, encoding="utf-8") as fh:
            ctl["reply_debt"] = fh.read().count(m3)
        _note("L3 seed count reply_debt (marker in the snapshot just written): %d" % ctl["reply_debt"])
        api = _api_reply_debt(token)
        rd_text = api.get("text") if api.get("status") == 200 else None
        cap["paths"]["reply_debt"] = with_l3_control(classify_path(
            rd_text, m2, None if rd_text is not None else (api.get("error") or "status=%s" % api.get("status"))),
            ctl["reply_debt"])
        text, why, cron = _brief_via_copy(markers)
        cap["fixture"]["brief_copy"] = cron
        intact = os.path.exists(EMAIL_SNAPSHOT) and _file_sha(EMAIL_SNAPSHOT) == rd["seeded_sha"]
        cap["paths"]["brief_catchup"] = with_l3_control(classify_path(text, m2, why), ctl["brief_todo"])
        cap["paths"]["brief_catchup"]["snapshot_intact_after_brief"] = intact
    except Exception as exc:  # noqa: BLE001 -- the judge turns "error" into CANNOT-RUN
        _note("run failed: " + traceback.format_exc()[-600:])
        cap["error"] = "box run failed: %s: %s" % (type(exc).__name__, str(exc)[:200])
    finally:
        cap["teardown"] = _teardown_all(cap, owner, stamp, legacy_ids, subjects, rd, backup_dir)
        # judge-shaped legacy teardown keys (l3 / l2) are inside cap["teardown"]
    cap["teardown"]["reply_debt"] = cap["fixture"].get("reply_debt")
    print(json.dumps(cap))
    return 0


def _teardown_all(cap, owner, stamp, legacy_ids, subjects, rd, backup_dir):
    td = {}
    fx = cap["fixture"]
    # 1. reply-debt directory, first: the shortest window on the box
    try:
        if rd.get("seeded") or os.path.exists(os.path.join(backup_dir, "bak")):
            fx["reply_debt"] = _restore_reply_debt(rd["backup"], rd.get("seeded_sha", ""), rd["before_tree"]) \
                if rd.get("backup") else {"restored": False, "why": "no backup taken"}
            _note("reply_debt restore: " + json.dumps(fx["reply_debt"]))
    except Exception as exc:  # noqa: BLE001
        fx["reply_debt"] = {"restored": False, "why": "%s: %s" % (type(exc).__name__, str(exc)[:150])}
        _note("reply_debt restore FAILED: " + fx["reply_debt"]["why"])
    finally:
        shutil.rmtree(backup_dir, ignore_errors=True)
    # 2. graph fixture rows, by subject, measured before and after
    try:
        if subjects:
            fx["graph_before"] = _count_subjects(subjects)
            _delete_subjects(subjects)
            fx["graph_after"] = _count_subjects(subjects)
    except Exception as exc:  # noqa: BLE001
        fx["graph_error"] = "%s: %s" % (type(exc).__name__, str(exc)[:150])
        _note("graph teardown FAILED: " + fx["graph_error"])
    # 3. the legacy pwg-convo conversations (store rows) and their files
    for key, cid in legacy_ids.items():
        try:
            files = _cleanup_files(cid, stamp)
            t = _teardown(cid, owner)
            _remove_files(files)
            t["files_before"], t["files_after"] = len(files), len(_cleanup_files(cid, stamp))
            if t.get("parsed") and t["files_after"] != 0:
                t = {"id": cid, "parsed": False, "raw": "file residue: %d" % t["files_after"]}
            td[key] = t
        except Exception as exc:  # noqa: BLE001
            td[key] = {"id": cid, "parsed": False, "raw": "%s: %s" % (type(exc).__name__, str(exc)[:150])}
    fx["free_gb_after"] = round(shutil.disk_usage("/").free / 1e9, 1)
    # 4. LAST: the independent "stamp anywhere" count, after every writer's rows are
    # gone (the pwg-convo rows carry the stamp too; measured 2026-11-16 before this
    # move: 20 stamp rows were still there at the old position).
    try:
        fx["stamp_after"] = _count_stamp(stamp)
        fx["total_after"] = _count_total()
        # positive control for the stamp query: the same shape of query on text that
        # IS live must be non-zero, or "0 after" proves nothing.
        fx["control_known_live"] = _count('?s ?p ?o FILTER(CONTAINS(STR(?o), "https://schema.ostler.ai/ontology#"))')
    except Exception as exc:  # noqa: BLE001
        fx["graph_error"] = "%s: %s" % (type(exc).__name__, str(exc)[:150])
    return td


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    sys.exit(main())
