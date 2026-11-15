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
import base64, json, os, subprocess, sys, tempfile, time, urllib.parse, urllib.request

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
    token = _token()
    stamp = str(os.getpid())
    m3, m2 = "ZEPHYR" + stamp, "QUARTZ" + stamp
    seeds = {
        "l3": _seed(f"ostler-walk-l3-{stamp}", m3, "L3"),
        "l2": _seed(f"ostler-walk-l2-{stamp}", m2, "L2"),
    }
    tools = _tools(m3, m2, token)
    print(json.dumps({"markers": {"l3": m3, "l2": m2}, "seeds": seeds, "tools": tools}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
