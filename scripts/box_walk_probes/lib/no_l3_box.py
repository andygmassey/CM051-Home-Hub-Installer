#!/usr/bin/env python3
# lib/no_l3_box.py -- runs ON THE BOX (never on the walker's machine).
#
# Seeds a synthetic L3 conversation and an L2 twin through the SHIPPED writer
# (pwg-convo process, metadata.json privacy_level), waits for each step-09
# bundle, then calls the seven pwg_* tools' loopback endpoints and prints ONE
# JSON capture on stdout. Nothing secret is printed: the service token and the
# Qdrant key are read here and used in-process, never echoed.
#
# Routes (read, not assumed):
#   writer      vendor/cm048_pipeline/src/privacy.py:26-29 (explicit
#               metadata privacy_level wins); processor.py:240-258 (L3 skips the
#               gist sinks); ingest.py:861-872 (todo privacy from metadata).
#   tools       crates/zeroclaw-tools/src/pwg_*.rs (paths listed in TOOLS).
import base64, json, os, subprocess, sys, tempfile, time, urllib.parse, urllib.request, uuid

API = "http://127.0.0.1:8090"
OLLAMA = "http://127.0.0.1:11434"
QDRANT = "http://127.0.0.1:6333"
CLI = "/usr/local/bin/pwg-convo"
TOKEN_PATH = os.path.expanduser("~/.ostler/secrets/service_token")
STORE_CONF = os.path.expanduser("~/.ostler/secrets/store-curl.conf")
KNOWLEDGE_COLLECTION = "evernote_knowledge"   # pwg_knowledge_search.rs:35
EMBED_MODEL = "nomic-embed-text"              # pwg_knowledge_search.rs:32
SEED_BUDGET_S = 900


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


def main():
    owner = os.environ.get("OSTLER_NO_L3_OWNER_ID", "")
    if not owner:
        print(json.dumps({"error": "OSTLER_NO_L3_OWNER_ID is unset; teardown needs the box owner id"}))
        return 0
    token = _token()
    # Unique per run: a second run must not be fooled by the first run's rows.
    stamp = uuid.uuid4().hex[:12]
    m3, m2 = "ZEPHYR" + stamp, "QUARTZ" + stamp
    seeds = {
        "l3": _seed(f"ostler-walk-l3-{stamp}", m3, "L3"),
        "l2": _seed(f"ostler-walk-l2-{stamp}", m2, "L2"),
    }
    tools = _tools(m3, m2, token)
    teardown = {
        "l3": _teardown(f"ostler-walk-l3-{stamp}", owner),
        "l2": _teardown(f"ostler-walk-l2-{stamp}", owner),
    }
    # NOT YET: the L0 seed route and the timeline, brief (catchup) and reply-debt
    # captures are unverified (see the PR body). They are reported as not_yet, so
    # the judge returns CANNOT-RUN, never PASS, until each one is captured.
    paths = {name: {"status": "not_yet"} for name in ("timeline", "brief_catchup", "reply_debt")}
    print(json.dumps({"markers": {"l3": m3, "l2": m2, "l0": "ZETA" + stamp}, "seeds": seeds,
                      "tools": tools, "teardown": teardown, "paths": paths}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
