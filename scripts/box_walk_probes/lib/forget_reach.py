#!/usr/bin/env python3
"""forget_reach -- does forgetting a SYNTHETIC person reach every store? (134)

Three modes, one file, so the judge the live probe uses is the judge its
--self-test drives:

  plant     (box)    write a synthetic person + conversations into the stores
  read      (box)    read every store for the forgotten and control person
  forget    (box)    POST /api/v1/people/<slug>/forget on the box, print the reply
  assemble  (driver) join plant/pre/response/post into one facts document
  judge     (driver) grade a facts document -> ok / FAIL / CANNOT lines, rc 0/1/78
  --self-test          judge cases, one per store, plus clean and blind cases

Exit codes follow lib/probe.sh: 0 PASS, 1 FAIL, 78 CANNOT-RUN.

Every route, field and path below is cited to the PR it was read from. The
probe must not drift from them without re-reading the source:
  CM041 PR #288 (head b2fb543f2): assistant_api/ical-server.py
      route            :11591-11597  do_POST, POST /api/v1/people/{slug}/forget
      handler          :2978-3190    api_people_forget (response keys :3169-3180)
      guard / token    :10607-10627  _guard, service token -> 401 without it
      gist filter      assistant_api/forget_conversations.py gist_delete_filter
      queue marker     _RECOMPILE_QUEUE_DIR :1670 (OSTLER_QUEUE_DIR, ~/.ostler/queue)
      audit line       :2746-2748    "<iso>Z forget <slug>" in forget_audit.log
  CM044 PR #451 (head 3b5caae41): compiler/erasure.py, compile.py
      ledger env       compiler/config.py OSTLER_FORGET_LEDGER (~/.ostler/queue/forget_audit.log)
      rollback root    compiler/config.py:79 OSTLER_WIKI_ROLLBACK_ROOT (~/.ostler/wiki-rollback)
  CM048 (main): src/ingest.py:430-432 payload source/conversation_id;
      :473 point_type conversation_summary; :526 point_type fact (payload is **fact,
      so subject is the fact's subject, "other:<slug>" per ingest.py:1132)
  CM051 install.sh:22309 vault mount ${OSTLER_WIKI_DIR:-$HOME/Ostler/Wiki}
  CM051 install.sh:22368 conversations mount ${OSTLER_CONVERSATIONS_DIR:-$HOME/Ostler/Conversations}
"""
from __future__ import annotations

import base64
import datetime as _dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

RC_PASS = 0
RC_FAIL = 1
RC_CANNOT = 78

SCHEMA = "forget_reach/1"

# The response keys that exist only on a 134 build (CM041 PR #288
# api_people_forget, ical-server.py:3169-3180). A pre-134 build answers the
# same route without them, and that is CANNOT-RUN, not a pass.
CONV_KEYS_134 = ("wiki_recompile_kicked", "bundles_deleted", "bundles_redacted")

# Stores graded by the judge. Order is the order they are printed.
STORES = ("graph", "qdrant_facts", "qdrant_summaries", "bundles", "wiki", "anchors", "ledger")

FORGOTTEN_NAME = "Jane Patel"
FORGOTTEN_SLUG = "jane-patel"
CONTROL_NAME = "Tom Andersen"
CONTROL_SLUG = "tom-andersen"
PERSON_NS = "https://probe.example/forget-walk/person/"
PWG_NS = "https://schema.ostler.ai/ontology#"
COLLECTION = "conversations"

# ---------------------------------------------------------------------------
# JUDGE
# ---------------------------------------------------------------------------


class _Rows:
    def __init__(self):
        self.rows = []

    def ok(self, t):
        self.rows.append(("ok", t))

    def fail(self, t):
        self.rows.append(("FAIL", t))

    def cannot(self, t):
        self.rows.append(("CANNOT", t))

    def note(self, t):
        self.rows.append(("note", t))

    def counts(self):
        c = {"ok": 0, "FAIL": 0, "CANNOT": 0}
        for tag, _ in self.rows:
            if tag in c:
                c[tag] += 1
        return c


def _num(d, k):
    v = d.get(k, 0)
    return v if isinstance(v, (int, float)) else 0


def judge(facts):
    """facts -> (rc, rows). Pure: no I/O, so the self-test drives this exact code."""
    r = _Rows()
    if not isinstance(facts, dict) or facts.get("schema") != SCHEMA:
        r.cannot("facts document missing or not schema forget_reach/1; nothing measured")
        return RC_CANNOT, r.rows

    resp = facts.get("response")
    if not isinstance(resp, dict):
        r.cannot("forget route returned no JSON object; nothing after it was measured")
        return RC_CANNOT, r.rows
    missing = [k for k in CONV_KEYS_134 if k not in resp]
    if missing:
        r.cannot("forget conversation-store leg not in this build: response lacks %s (CM041 PR #288 not installed)" % ", ".join(missing))
        return RC_CANNOT, r.rows
    if resp.get("forgotten") is not True:
        r.fail("forget route did not forget the synthetic person (forgotten=%r, reason=%r); the lookup did not resolve slug %s" % (resp.get("forgotten"), resp.get("reason", ""), facts.get("forgotten", {}).get("slug", "?")))
    else:
        r.ok("forget route answered forgotten=true for the synthetic person (stores_purged=%s)" % ",".join(resp.get("stores_purged", [])))

    if resp.get("wiki_recompile_kicked") is True:
        r.ok("forget kicked the wiki recompile (wiki_recompile_kicked=true)")
    else:
        r.fail("forget did not kick the wiki recompile (wiki_recompile_kicked=%r); the erasure waits for the daily tick" % resp.get("wiki_recompile_kicked"))

    if resp.get("degraded"):
        r.note("response carries degraded=true: %s" % str(resp.get("reason", ""))[:200])

    pre = facts.get("precondition") or {}
    post = facts.get("stores") or {}

    # --- precondition: the probe is only blind if a precondition is unmet ---
    for store in STORES:
        p = pre.get(store) or {}
        if p.get("readable") is not True:
            r.cannot("precondition: store %s unreadable before forget (%s)" % (store, str(p.get("error", "no reason recorded"))[:160]))
    if not any(tag == "CANNOT" for tag, _ in r.rows):
        g = pre["graph"]
        q = pre["qdrant_facts"]
        w = pre["wiki"]
        b = pre["bundles"]
        if _num(g, "control_refs") <= 0:
            r.cannot("control person absent from the graph BEFORE forget; the probe is blind to over-erasure")
        if _num(g, "forgotten_refs") <= 0:
            r.cannot("forgotten person absent from the graph BEFORE forget; the seed did not land")
        if _num(q, "control") <= 0 or _num(q, "forgotten") <= 0:
            r.cannot("qdrant conversations facts not seeded before forget (forgotten=%s control=%s)" % (q.get("forgotten"), q.get("control")))
        if _num(w, "forgotten") <= 0:
            r.cannot("wiki did not render the forgotten person before forget; the wiki leg cannot be graded")
        if _num(w, "control") <= 0:
            r.cannot("wiki did not render the control person before forget; the wiki leg cannot be graded")
        if _num(b, "forgotten_hits") <= 0:
            r.cannot("source bundles did not contain the forgotten person before forget; nothing to erase")
        if b.get("control_one_to_one_present") is not True:
            r.cannot("control's 1:1 bundle absent before forget; the bundle positive control is missing")

    # --- ledger: the wiki can only erase what the ledger names ---
    L = post.get("ledger") or {}
    if L.get("readable") is not True:
        r.cannot("ledger unreadable after forget (%s)" % str(L.get("error", ""))[:160])
    elif L.get("forgotten_line") is True:
        r.ok("forget ledger names the forgotten slug (the wiki compile can read it)")
    else:
        r.fail("forget ledger has no line for the forgotten slug; the wiki compile will not erase it")

    # --- graph ---
    G = post.get("graph") or {}
    if G.get("readable") is not True:
        r.cannot("graph unreadable after forget (%s)" % str(G.get("error", ""))[:160])
    else:
        n = _num(G, "forgotten_refs")
        (r.fail if n else r.ok)("graph: %d triple(s) still reference the forgotten person URI (of %s checked)" % (n, "all graphs"))
        n = _num(G, "forgotten_literals")
        (r.fail if n else r.ok)("graph: %d literal(s) still contain the forgotten name" % n)
        if _num(G, "control_refs") <= 0:
            r.fail("graph: control person has 0 triples after forget (over-erasure)")
        else:
            r.ok("graph: control person keeps %d triple(s)" % _num(G, "control_refs"))

    # --- qdrant gists: facts ---
    Q = post.get("qdrant_facts") or {}
    if Q.get("readable") is not True:
        r.cannot("qdrant conversations facts unreadable after forget (%s)" % str(Q.get("error", ""))[:160])
    else:
        n = _num(Q, "forgotten")
        (r.fail if n else r.ok)("qdrant %s: %d fact point(s) with subject other:<forgotten> remain" % (COLLECTION, n))
        if _num(Q, "control") <= 0:
            r.fail("qdrant %s: control person's fact points are gone (over-erasure)" % COLLECTION)
        else:
            r.ok("qdrant %s: control keeps %d fact point(s)" % (COLLECTION, _num(Q, "control")))

    # --- qdrant gists: summaries ---
    S = post.get("qdrant_summaries") or {}
    if S.get("readable") is not True:
        r.cannot("qdrant conversations summaries unreadable after forget (%s)" % str(S.get("error", ""))[:160])
    else:
        n = _num(S, "forgotten")
        (r.fail if n else r.ok)("qdrant %s: %d conversation_summary point(s) of the forgotten person's conversations remain" % (COLLECTION, n))
        if _num(S, "control") <= 0:
            r.fail("qdrant %s: control person's own 1:1 summary point is gone (over-erasure)" % COLLECTION)
        else:
            r.ok("qdrant %s: control's 1:1 summary point survives" % COLLECTION)
        if _num(S, "shared_removed") > 0:
            r.note("qdrant %s: %d summary point(s) of the SHARED conversation removed with the forgotten person (gist_delete_filter deletes every summary of a conversation they were in)" % (COLLECTION, _num(S, "shared_removed")))

    # --- bundles on disk ---
    B = post.get("bundles") or {}
    if B.get("readable") is not True:
        r.cannot("conversation bundles unreadable after forget (%s)" % str(B.get("error", ""))[:160])
    else:
        n = _num(B, "one_to_one_remaining")
        (r.fail if n else r.ok)("bundles: %d 1:1 bundle(s) of the forgotten person remain (must be deleted)" % n)
        n = _num(B, "forgotten_hits")
        (r.fail if n else r.ok)("bundles: %d file(s) still name the forgotten person (multi-party must be redacted)" % n)
        if B.get("multi_folder_present") is not True:
            r.fail("bundles: the multi-party conversation folder is gone; it must be redacted and kept for the other participant")
        elif B.get("control_in_multi") is not True:
            r.fail("bundles: the redacted multi-party bundle no longer names the control person (other participant's content lost)")
        else:
            r.ok("bundles: multi-party bundle kept with the control participant's content")
        if B.get("control_one_to_one_present") is not True:
            r.fail("bundles: control's 1:1 bundle is gone (over-erasure)")
        else:
            r.ok("bundles: control's 1:1 bundle is intact")

    # --- wiki ---
    W = post.get("wiki") or {}
    if W.get("readable") is not True:
        r.cannot("wiki vault unreadable after forget (%s)" % str(W.get("error", ""))[:160])
    else:
        for key, label in (("person", "person page"), ("conversation", "conversation timeline page"), ("other", "other wiki page (AI chat or index)")):
            n = _num(W, key + "_hits")
            (r.fail if n else r.ok)("wiki: %d %s(s) still name the forgotten person" % (n, label))
        if _num(W, "control_hits") <= 0:
            r.fail("wiki: control person absent from the wiki after the recompile (over-erasure)")
        else:
            r.ok("wiki: control person still rendered (%d file(s))" % _num(W, "control_hits"))

    # --- rollback anchors ---
    A = post.get("anchors") or {}
    if A.get("readable") is not True:
        r.cannot("rollback anchors unreadable after forget (%s)" % str(A.get("error", ""))[:160])
    else:
        n = _num(A, "hits")
        (r.fail if n else r.ok)("rollback anchors: %d file(s) still name the forgotten person (a restore would bring them back)" % n)

    counts = r.counts()
    if counts["FAIL"]:
        return RC_FAIL, r.rows
    if counts["CANNOT"]:
        return RC_CANNOT, r.rows
    return RC_PASS, r.rows


def _render(rows):
    out = []
    for tag, text in rows:
        if tag == "note":
            out.append("  note %s" % text)
        else:
            out.append("  %s %s" % (tag, text))
    return "\n".join(out)


# ---------------------------------------------------------------------------
# SELF-TEST. Every case builds a facts document, judges it with judge() above,
# and must produce the rc and the store named in its expectation.
# ---------------------------------------------------------------------------


def clean_facts():
    return {
        "schema": SCHEMA,
        "forgotten": {"slug": FORGOTTEN_SLUG, "name": FORGOTTEN_NAME},
        "control": {"slug": CONTROL_SLUG, "name": CONTROL_NAME},
        "response": {
            "forgotten": True, "wiki_recompile_kicked": True,
            "stores_purged": ["oxigraph", "qdrant", "conversation_bundles", "conversation_gists"],
            "bundles_deleted": 1, "bundles_redacted": 1,
        },
        "precondition": {
            "graph": {"readable": True, "forgotten_refs": 5, "control_refs": 5},
            "qdrant_facts": {"readable": True, "forgotten": 2, "control": 2},
            "qdrant_summaries": {"readable": True, "forgotten": 2, "control": 1, "shared_removed": 0},
            "bundles": {"readable": True, "forgotten_hits": 4, "one_to_one_remaining": 1,
                        "multi_folder_present": True, "control_in_multi": True, "control_one_to_one_present": True},
            "wiki": {"readable": True, "person_hits": 1, "conversation_hits": 2, "other_hits": 1, "control_hits": 3,
                     "forgotten": 4, "control": 3},
            "anchors": {"readable": True, "hits": 1},
            "ledger": {"readable": True, "forgotten_line": False},
        },
        "stores": {
            "graph": {"readable": True, "forgotten_refs": 0, "forgotten_literals": 0, "control_refs": 5},
            "qdrant_facts": {"readable": True, "forgotten": 0, "control": 2},
            "qdrant_summaries": {"readable": True, "forgotten": 0, "control": 1, "shared_removed": 1},
            "bundles": {"readable": True, "one_to_one_remaining": 0, "forgotten_hits": 0,
                        "multi_folder_present": True, "control_in_multi": True, "control_one_to_one_present": True},
            "wiki": {"readable": True, "person_hits": 0, "conversation_hits": 0, "other_hits": 0, "control_hits": 3},
            "anchors": {"readable": True, "hits": 0},
            "ledger": {"readable": True, "forgotten_line": True},
        },
    }


def _case(name, mutate, want_rc, want_text=None):
    f = clean_facts()
    mutate(f)
    rc, rows = judge(f)
    text = _render(rows)
    ok = rc == want_rc and (want_text is None or want_text in text)
    return name, ok, rc, want_rc, text


def _store_residue_cases():
    cases = []
    cases.append(_case("residue graph refs", lambda f: f["stores"]["graph"].update(forgotten_refs=2), RC_FAIL, "graph: 2 triple"))
    cases.append(_case("residue graph literal", lambda f: f["stores"]["graph"].update(forgotten_literals=1), RC_FAIL, "graph: 1 literal"))
    cases.append(_case("residue qdrant facts", lambda f: f["stores"]["qdrant_facts"].update(forgotten=3), RC_FAIL, "fact point(s) with subject"))
    cases.append(_case("residue qdrant summaries", lambda f: f["stores"]["qdrant_summaries"].update(forgotten=1), RC_FAIL, "conversation_summary point(s)"))
    cases.append(_case("residue bundle 1:1 kept", lambda f: f["stores"]["bundles"].update(one_to_one_remaining=1), RC_FAIL, "1:1 bundle(s)"))
    cases.append(_case("residue bundle multi unredacted", lambda f: f["stores"]["bundles"].update(forgotten_hits=4), RC_FAIL, "file(s) still name"))
    cases.append(_case("residue wiki person page", lambda f: f["stores"]["wiki"].update(person_hits=1), RC_FAIL, "person page"))
    cases.append(_case("residue wiki timeline page", lambda f: f["stores"]["wiki"].update(conversation_hits=1), RC_FAIL, "conversation timeline page"))
    cases.append(_case("residue wiki other page (AI chat)", lambda f: f["stores"]["wiki"].update(other_hits=1), RC_FAIL, "other wiki page"))
    cases.append(_case("residue rollback anchor", lambda f: f["stores"]["anchors"].update(hits=1), RC_FAIL, "rollback anchors: 1 file"))
    cases.append(_case("residue ledger has no line", lambda f: f["stores"]["ledger"].update(forgotten_line=False), RC_FAIL, "forget ledger has no line"))
    return cases


def self_test_cases():
    cases = []
    cases.append(_case("all clean is PASS", lambda f: None, RC_PASS, "  ok forget ledger"))
    cases += _store_residue_cases()
    cases.append(_case("control person missing before forget is CANNOT (blind)",
                       lambda f: f["precondition"]["graph"].update(control_refs=0), RC_CANNOT, "control person absent from the graph BEFORE"))
    cases.append(_case("control person over-erased after forget is FAIL",
                       lambda f: f["stores"]["graph"].update(control_refs=0), RC_FAIL, "over-erasure"))
    cases.append(_case("unreadable graph is CANNOT, not PASS",
                       lambda f: f["stores"]["graph"].update(readable=False, error="HTTP 503"), RC_CANNOT, "graph unreadable"))
    cases.append(_case("unreadable qdrant facts is CANNOT",
                       lambda f: f["stores"]["qdrant_facts"].update(readable=False, error="curl rc=7"), RC_CANNOT, "qdrant conversations facts unreadable"))
    cases.append(_case("unreadable wiki precondition is CANNOT",
                       lambda f: f["precondition"]["wiki"].update(readable=False, error="no vault"), RC_CANNOT, "precondition: store wiki unreadable"))
    cases.append(_case("pre-134 build (no conversation-store keys) is CANNOT",
                       lambda f: f["response"].pop("bundles_deleted"), RC_CANNOT, "not in this build"))
    cases.append(_case("forget did not kick the recompile is FAIL",
                       lambda f: f["response"].update(wiki_recompile_kicked=False), RC_FAIL, "did not kick the wiki recompile"))
    cases.append(_case("control bundle gone is FAIL",
                       lambda f: f["stores"]["bundles"].update(control_one_to_one_present=False), RC_FAIL, "control's 1:1 bundle is gone"))
    cases.append(_case("multi-party bundle gone is FAIL (should be redacted, not deleted)",
                       lambda f: f["stores"]["bundles"].update(multi_folder_present=False), RC_FAIL, "multi-party conversation folder is gone"))
    cases.append(_case("forget did not resolve the person is FAIL",
                       lambda f: f["response"].update(forgotten=False, reason="no match"), RC_FAIL, "did not forget the synthetic person"))
    return cases


def self_test():
    cases = self_test_cases()
    bad = 0
    for name, ok, rc, want, text in cases:
        print("case %-62s rc=%d want=%d %s" % (name, rc, want, "ok" if ok else "MISMATCH"))
        if not ok:
            bad += 1
            print(text)
    print("self-test: %d case(s), %d mismatch(es)" % (len(cases), bad))
    return 0 if bad == 0 else 1


def bad_only(store):
    """A facts document whose ONLY residue is in one store. Used by the shell
    negative controls: each store must, on its own, turn the verdict FAIL."""
    f = clean_facts()
    mut = {
        "graph": lambda: f["stores"]["graph"].update(forgotten_refs=1),
        "qdrant_facts": lambda: f["stores"]["qdrant_facts"].update(forgotten=1),
        "qdrant_summaries": lambda: f["stores"]["qdrant_summaries"].update(forgotten=1),
        "bundles": lambda: f["stores"]["bundles"].update(forgotten_hits=1),
        "wiki": lambda: f["stores"]["wiki"].update(person_hits=1),
        "anchors": lambda: f["stores"]["anchors"].update(hits=1),
        "ledger": lambda: f["stores"]["ledger"].update(forgotten_line=False),
    }
    if store not in mut:
        raise SystemExit("unknown store %r" % store)
    mut[store]()
    return f


# ---------------------------------------------------------------------------
# BOX SIDE. Everything below runs ON the box (staged there by the probe).
# It reads secrets by PATH only and never prints a token or a key.
# ---------------------------------------------------------------------------

_NO_PROXY_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _http(method, url, body=None, headers=None, timeout=20):
    data = None
    h = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        h.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with _NO_PROXY_OPENER.open(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def _sparql(oxi, query):
    req = urllib.request.Request(oxi.rstrip("/") + "/query", data=query.encode(),
                                 headers={"Content-Type": "application/sparql-query",
                                          "Accept": "application/sparql-results+json"}, method="POST")
    with _NO_PROXY_OPENER.open(req, timeout=30) as r:
        doc = json.loads(r.read().decode("utf-8", "replace"))
    return doc["results"]["bindings"]


def _sparql_update(oxi, update):
    req = urllib.request.Request(oxi.rstrip("/") + "/update", data=update.encode(),
                                 headers={"Content-Type": "application/sparql-update"}, method="POST")
    with _NO_PROXY_OPENER.open(req, timeout=30) as r:
        return r.status


def _count_bindings(rows):
    if not rows:
        return 0
    return int(rows[0]["n"]["value"])


def _qdrant(qurl, conf, method, path, body=None):
    """Qdrant with the store credential read by curl -K from its PATH (never its value)."""
    cmd = ["curl", "-sS", "--noproxy", "*", "--max-time", "30", "-w", "\n%{http_code}",
           "-X", method, qurl.rstrip("/") + path]
    conf = os.path.expanduser(conf) if conf else conf
    if conf and os.path.isfile(conf):
        cmd += ["-K", conf]
    if body is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", "@-"]
    p = subprocess.run(cmd, input=(json.dumps(body).encode() if body is not None else None),
                       capture_output=True, timeout=60)
    if p.returncode != 0:
        raise RuntimeError("curl rc=%d" % p.returncode)
    raw = p.stdout.decode("utf-8", "replace")
    text, _, code = raw.rpartition("\n")
    if not code.strip().startswith("2"):
        raise RuntimeError("HTTP %s" % (code.strip() or "000"))
    return json.loads(text) if text.strip() else {}


def _qcount(qurl, conf, must):
    doc = _qdrant(qurl, conf, "POST", "/collections/%s/points/count" % COLLECTION,
                  {"filter": {"must": must}, "exact": True})
    return int(doc["result"]["count"])


def _fact_filter(subject):
    return [{"key": "source", "match": {"value": "human_conversation"}},
            {"key": "point_type", "match": {"value": "fact"}},
            {"key": "subject", "match": {"value": "other:" + subject}}]


def _summary_filter(conv_ids):
    return [{"key": "source", "match": {"value": "human_conversation"}},
            {"key": "point_type", "match": {"value": "conversation_summary"}},
            {"key": "conversation_id", "match": {"any": list(conv_ids)}}]


def _summary_for(conv_id):
    return [{"key": "source", "match": {"value": "human_conversation"}},
            {"key": "point_type", "match": {"value": "conversation_summary"}},
            {"key": "conversation_id", "match": {"value": conv_id}}]


def _sha(path):
    import hashlib
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]


def _frontmatter(text):
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end == -1:
        return {}
    out = {"participants": []}
    in_list = False
    for line in text[4:end].split("\n"):
        if line.startswith("participants:"):
            in_list = True
            continue
        if in_list:
            m = re.match(r'^\s*-\s*"?([^"\n]+?)"?\s*$', line)
            if m:
                out["participants"].append(m.group(1))
                continue
            if line and not line.startswith(" "):
                in_list = False
        m = re.match(r'^conversation_id:\s*"?([^"\n]+?)"?\s*$', line)
        if m:
            out["conversation_id"] = m.group(1)
    return out


def _read_bundles(root, spec):
    """Return the bundle-store block. Reads every file under root; counts only."""
    res = {"readable": True, "error": "", "one_to_one_remaining": 0, "forgotten_hits": 0,
           "multi_folder_present": False, "control_in_multi": False, "control_one_to_one_present": False,
           "folders_seen": 0}
    if not root.is_dir():
        res["readable"] = True
        res["error"] = "bundles root absent: %s" % root
        return res
    fslug, fname = spec["forgotten"]["slug"], spec["forgotten"]["name"].lower()
    cslug, cname = spec["control"]["slug"], spec["control"]["name"].lower()
    conv = spec["planted"]
    try:
        for summary in root.rglob("summary.md"):
            res["folders_seen"] += 1
            folder = summary.parent
            fm = _frontmatter(summary.read_text(encoding="utf-8", errors="replace"))
            parts = fm.get("participants", [])
            cid = fm.get("conversation_id", "")
            if cid == conv["one_to_one"] and f"other:{fslug}" in parts:
                res["one_to_one_remaining"] += 1
            if cid == conv["multi"]:
                res["multi_folder_present"] = True
                if f"other:{cslug}" in parts:
                    res["control_in_multi"] = True
            if cid == conv["control_one_to_one"]:
                res["control_one_to_one_present"] = True
        for f in root.rglob("*"):
            if not f.is_file():
                continue
            text = f.read_text(encoding="utf-8", errors="replace").lower()
            if fname in text or f"other:{fslug}" in text or f"{fslug}-" in f.parent.name.lower():
                res["forgotten_hits"] += 1
    except OSError as exc:
        res["readable"] = False
        res["error"] = "bundle read failed: %s" % type(exc).__name__
    return res


def _read_wiki(vault, spec):
    res = {"readable": True, "error": "", "person_hits": 0, "conversation_hits": 0, "other_hits": 0,
           "control_hits": 0, "forgotten": 0, "control": 0}
    if not vault.is_dir():
        res["readable"] = False
        res["error"] = "wiki vault absent: %s" % vault
        return res
    fname, fslug = spec["forgotten"]["name"].lower(), spec["forgotten"]["slug"]
    cname, cslug = spec["control"]["name"].lower(), spec["control"]["slug"]
    try:
        for f in vault.rglob("*.md"):
            text = f.read_text(encoding="utf-8", errors="replace").lower()
            rel = f.relative_to(vault).as_posix().lower()
            if fname in text or fslug in rel:
                res["forgotten"] += 1
                if rel.startswith("people/") or rel.split("/")[-1] == fslug + ".md":
                    res["person_hits"] += 1
                elif "timeline" in rel or "conversation" in rel:
                    res["conversation_hits"] += 1
                else:
                    res["other_hits"] += 1
            if cname in text or cslug in rel:
                res["control"] += 1
                res["control_hits"] += 1
    except OSError as exc:
        res["readable"] = False
        res["error"] = "wiki read failed: %s" % type(exc).__name__
    return res


def _read_anchors(root, spec):
    res = {"readable": True, "error": "", "hits": 0}
    if not root.is_dir():
        return res
    fname, fslug = spec["forgotten"]["name"].lower(), spec["forgotten"]["slug"]
    try:
        for f in root.rglob("*"):
            if f.is_file():
                t = f.read_text(encoding="utf-8", errors="replace").lower()
                if fname in t or fslug in f.as_posix().lower():
                    res["hits"] += 1
    except OSError as exc:
        res["readable"] = False
        res["error"] = "anchor read failed: %s" % type(exc).__name__
    return res


def _read_ledger(path, slug):
    res = {"readable": True, "error": "", "forgotten_line": False}
    if not path.exists():
        return res
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if re.search(r"\sforget " + re.escape(slug) + r"$", line.strip()):
                res["forgotten_line"] = True
    except OSError as exc:
        res["readable"] = False
        res["error"] = "ledger read failed: %s" % type(exc).__name__
    return res


def _home(p):
    return Path(os.path.expanduser(p))


def read_all(spec):
    """Read every store for both persons. Returns the 'stores' block."""
    oxi = spec["oxigraph"]
    qurl = spec["qdrant"]
    conf = spec["store_conf"]
    out = {}
    fu, cu = spec["forgotten"]["uri"], spec["control"]["uri"]
    fname, cname = spec["forgotten"]["name"].lower(), spec["control"]["name"].lower()
    # GRAPH
    g = {"readable": True, "error": ""}
    try:
        def cnt(uri):
            return _count_bindings(_sparql(oxi,
                "SELECT (COUNT(*) AS ?n) WHERE { { <%s> ?p ?o } UNION { ?s ?p <%s> } "
                "UNION { GRAPH ?g { <%s> ?p ?o } } UNION { GRAPH ?g { ?s ?p <%s> } } }" % (uri, uri, uri, uri)))
        def lit(name):
            return _count_bindings(_sparql(oxi,
                'SELECT (COUNT(*) AS ?n) WHERE { { ?s ?p ?o . FILTER(isLiteral(?o) && CONTAINS(LCASE(STR(?o)), "%s")) } '
                'UNION { GRAPH ?g { ?s ?p ?o . FILTER(isLiteral(?o) && CONTAINS(LCASE(STR(?o)), "%s")) } } }' % (name, name)))
        g["forgotten_refs"] = cnt(fu)
        g["control_refs"] = cnt(cu)
        g["forgotten_literals"] = lit(fname)
    except Exception as exc:  # noqa: BLE001 -- recorded as unreadable, never a pass
        g = {"readable": False, "error": "oxigraph: %s" % type(exc).__name__}
    out["graph"] = g
    # QDRANT facts + summaries
    qf = {"readable": True, "error": ""}
    qs = {"readable": True, "error": ""}
    try:
        qf["forgotten"] = _qcount(qurl, conf, _fact_filter(spec["forgotten"]["slug"]))
        qf["control"] = _qcount(qurl, conf, _fact_filter(spec["control"]["slug"]))
    except Exception as exc:  # noqa: BLE001
        qf = {"readable": False, "error": "qdrant facts: %s" % exc}
    try:
        qs["forgotten"] = _qcount(qurl, conf, _summary_filter([spec["planted"]["one_to_one"], spec["planted"]["multi"]]))
        qs["control"] = _qcount(qurl, conf, _summary_for(spec["planted"]["control_one_to_one"]))
        qs["shared_removed"] = _qcount(qurl, conf, _summary_for(spec["planted"]["multi"]))
    except Exception as exc:  # noqa: BLE001
        qs = {"readable": False, "error": "qdrant summaries: %s" % exc}
    out["qdrant_facts"] = qf
    out["qdrant_summaries"] = qs
    # BUNDLES, WIKI, ANCHORS, LEDGER
    bundles_root = _home(spec.get("bundles_root") or "~/Ostler/Conversations")
    vault = _home(spec.get("vault") or "~/Ostler/Wiki")
    anchors = _home(spec.get("anchors") or "~/.ostler/wiki-rollback")
    ledger = _home(spec.get("ledger") or "~/.ostler/queue/forget_audit.log")
    try:
        out["bundles"] = _read_bundles(bundles_root, spec)
    except Exception as exc:  # noqa: BLE001
        out["bundles"] = {"readable": False, "error": "bundles: %s" % type(exc).__name__}
    try:
        out["wiki"] = _read_wiki(vault, spec)
    except Exception as exc:  # noqa: BLE001
        out["wiki"] = {"readable": False, "error": "wiki: %s" % type(exc).__name__}
    try:
        out["anchors"] = _read_anchors(anchors, spec)
    except Exception as exc:  # noqa: BLE001
        out["anchors"] = {"readable": False, "error": "anchors: %s" % type(exc).__name__}
    out["ledger"] = _read_ledger(ledger, spec["forgotten"]["slug"])
    out["_paths"] = {"bundles_root": str(bundles_root), "vault": str(vault),
                     "anchors": str(anchors), "ledger": str(ledger)}
    return out


def plant(spec):
    """WRITE. Synthetic person in the graph, bundles on disk, facts+summaries in Qdrant.
    Refuses (returns ok=False with a reason) if the conversations collection is absent."""
    oxi, qurl, conf = spec["oxigraph"], spec["qdrant"], spec["store_conf"]
    try:
        coll = _qdrant(qurl, conf, "GET", "/collections/%s" % COLLECTION)
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "reason": "conversations collection unreadable: %s" % exc}
    vec = coll["result"]["config"]["params"]["vectors"]
    dim = vec["size"] if "size" in vec else next(iter(vec.values()))["size"]
    v = [1.0 / (dim ** 0.5)] * dim
    fslug, fname = spec["forgotten"]["slug"], spec["forgotten"]["name"]
    cslug, cname = spec["control"]["slug"], spec["control"]["name"]
    fu, cu = spec["forgotten"]["uri"], spec["control"]["uri"]
    stamp = spec["stamp"]
    date = spec["date"]
    ids = dict(spec["planted"])  # chosen by the driver, so read and judge know them
    # GRAPH (default graph: the one _forget_person_update and the SELECT both use)
    _sparql_update(oxi,
        "INSERT DATA { <%s> a <%sPerson> ; <%sdisplayName> \"%s\" . "
        "<%s> a <%sPerson> ; <%sdisplayName> \"%s\" . }" % (fu, PWG_NS, PWG_NS, fname, cu, PWG_NS, PWG_NS, cname))
    # BUNDLES
    root = _home(spec.get("bundles_root") or "~/Ostler/Conversations")
    def bundle(folder, cid, parts, body):
        d = root / date / folder
        d.mkdir(parents=True, exist_ok=True)
        fm = ["---", 'conversation_id: "%s"' % cid, "privacy_level: L2", "participants:"]
        fm += ['  - "%s"' % p for p in parts] + ["---", ""]
        head = "\n".join(fm) + "\n"
        (d / "summary.md").write_text(head + "# Summary\n\n%s\n" % body, encoding="utf-8")
        (d / "transcript.md").write_text(head + "**other:** %s\n" % body, encoding="utf-8")
        (d / "todos.md").write_text(head + "- Ask %s | owner: user\n" % body, encoding="utf-8")
    bundle("%s-%s" % (fslug, stamp[-8:]), ids["one_to_one"], ["user", "other:" + fslug],
           "%s wants Saturday" % fname)
    bundle("%s-%s-%s" % (fslug, cslug, stamp[-8:]), ids["multi"], ["user", "other:" + fslug, "other:" + cslug],
           "%s and %s planning. %s will bring the car" % (fname, cname, cname))
    bundle("%s-%s" % (cslug, stamp[-8:]), ids["control_one_to_one"], ["user", "other:" + cslug],
           "%s only" % cname)
    # QDRANT
    def pt(seed, conv, ptype, subject, text):
        payload = {"source": "human_conversation", "conversation_id": conv, "point_type": ptype,
                   "user_id": "walk-probe", "text": text}
        if subject:
            payload["subject"] = subject
        return {"id": str(uuid.uuid5(uuid.NAMESPACE_URL, seed)), "vector": v, "payload": payload}
    pts = [
        pt("f1" + stamp, ids["one_to_one"], "fact", "other:" + fslug, "synthetic fact about %s" % fname),
        pt("f2" + stamp, ids["multi"], "fact", "other:" + fslug, "synthetic fact about %s" % fname),
        pt("f3" + stamp, ids["multi"], "fact", "other:" + cslug, "synthetic fact about %s" % cname),
        pt("f4" + stamp, ids["control_one_to_one"], "fact", "other:" + cslug, "synthetic fact about %s" % cname),
        pt("s1" + stamp, ids["one_to_one"], "conversation_summary", None, "synthetic summary"),
        pt("s2" + stamp, ids["multi"], "conversation_summary", None, "synthetic shared summary"),
        pt("s3" + stamp, ids["control_one_to_one"], "conversation_summary", None, "synthetic control summary"),
    ]
    _qdrant(qurl, conf, "PUT", "/collections/%s/points?wait=true" % COLLECTION, {"points": pts})
    return {"ok": True, "reason": "", "ids": ids, "dim": dim, "points": len(pts)}


def forget(spec):
    """POST the route ON THE BOX. The service token is read from its path and never printed."""
    token_path = _home(spec.get("token_path") or "~/.ostler/secrets/service_token")
    try:
        token = token_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        return {"http": 0, "body": None, "error": "token unreadable: %s" % type(exc).__name__}
    url = spec["api_base"].rstrip("/") + "/api/v1/people/%s/forget" % spec["slug"]
    try:
        status, text = _http("POST", url, headers={"Authorization": "Bearer " + token}, body=None, timeout=120)
    except Exception as exc:  # noqa: BLE001
        return {"http": 0, "body": None, "error": "transport: %s" % type(exc).__name__}
    try:
        body = json.loads(text)
    except ValueError:
        body = None
    return {"http": status, "body": body, "error": "" if body is not None else "non-JSON reply"}


def _box_main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="forget_reach.py")
    ap.add_argument("mode", choices=["plant", "read", "forget"])
    ap.add_argument("--spec", required=True)
    a = ap.parse_args(argv)
    spec = json.loads(Path(a.spec).read_text(encoding="utf-8"))
    if a.mode == "plant":
        out = plant(spec)
    elif a.mode == "read":
        out = read_all(spec)
    else:
        out = forget(spec)
    print(json.dumps(out, sort_keys=True))
    return 0


# ---------------------------------------------------------------------------
# DRIVER SIDE
# ---------------------------------------------------------------------------


def _assemble(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="forget_reach.py assemble")
    ap.add_argument("--spec", required=True)
    ap.add_argument("--pre", required=True)
    ap.add_argument("--post", required=True)
    ap.add_argument("--forget", required=True)
    a = ap.parse_args(argv)
    spec = json.loads(Path(a.spec).read_text(encoding="utf-8"))
    pre = json.loads(Path(a.pre).read_text(encoding="utf-8"))
    post = json.loads(Path(a.post).read_text(encoding="utf-8"))
    fg = json.loads(Path(a.forget).read_text(encoding="utf-8"))
    facts = {
        "schema": SCHEMA,
        "forgotten": {"slug": spec["forgotten"]["slug"], "name": spec["forgotten"]["name"]},
        "control": {"slug": spec["control"]["slug"], "name": spec["control"]["name"]},
        "precondition": {k: v for k, v in pre.items() if not k.startswith("_")},
        "stores": {k: v for k, v in post.items() if not k.startswith("_")},
        "paths": post.get("_paths", {}),
        "http": fg.get("http"),
        "response": fg.get("body"),
    }
    print(json.dumps(facts, sort_keys=True))
    return 0


def _judge_cli(argv):
    if argv and argv[0] == "--bad-only":
        facts = bad_only(argv[1])
    else:
        facts = json.loads(Path(argv[0]).read_text(encoding="utf-8"))
    rc, rows = judge(facts)
    print(_render(rows))
    return rc


def main(argv):
    if not argv:
        print("usage: forget_reach.py {plant|read|forget --spec F | assemble ... | judge FILE | judge --bad-only STORE | --self-test}", file=sys.stderr)
        return 2
    if argv[0] == "--self-test":
        return self_test()
    if argv[0] in ("plant", "read", "forget"):
        return _box_main(argv)
    if argv[0] == "assemble":
        return _assemble(argv[1:])
    if argv[0] == "judge":
        return _judge_cli(argv[1:])
    print("unknown mode %r" % argv[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
