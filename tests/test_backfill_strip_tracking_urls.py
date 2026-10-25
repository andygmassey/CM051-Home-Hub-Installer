"""Backfill of already-stored tracking URLs: dry-run writes nothing, --apply
re-keys / dedupes / rewrites, a second --apply is a no-op. Fake loopback
Qdrant; synthetic URLs. The script is never pointed at a real box here."""
from __future__ import annotations

import importlib.util
import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("bf", REPO / "scripts" / "backfill_strip_tracking_urls.py")
bf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bf)

TS = "2026-10-01T10:00:00+00:00"
TRACKED = "https://www.example.com/a?utm_source=x&id=1"
CLEAN = "https://www.example.com/a?id=1"
KEEP = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
ONLY = "https://www.example.org/b?fbclid=Z"   # clean twin absent
ONLY_CLEAN = "https://www.example.org/b"


def vid(url, src="safari_history"):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"browsing|{src}|{url}|{TS}"))


class Fake:
    def __init__(self):
        self.cols = {"safari_history": {}, "preferences": {}}
        self.writes = 0
        o = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def _send(self, obj):
                raw = json.dumps(obj).encode()
                self.send_response(200); self.send_header("Content-Length", str(len(raw)))
                self.end_headers(); self.wfile.write(raw)
            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                b = json.loads(self.rfile.read(n) or b"{}")
                parts = self.path.split("?")[0].strip("/").split("/")
                col = o.cols[parts[1]]
                if parts[-1] == "scroll":
                    return self._send({"result": {"points": [dict(id=i, payload=p["payload"]) for i, p in col.items()], "next_page_offset": None}})
                if parts[-1] == "delete":
                    o.writes += 1
                    for i in b["points"]: col.pop(i, None)
                    return self._send({"result": {}})
                if parts[-1] == "payload":
                    o.writes += 1
                    for i in b["points"]: col[i]["payload"].update(b["payload"])
                    return self._send({"result": {}})
                if parts[-1] == "points":
                    return self._send({"result": [dict(id=i, payload=col[i]["payload"], vector=col[i]["vector"]) for i in b["ids"] if i in col]})
                self._send({})
            def do_PUT(self):
                n = int(self.headers.get("Content-Length") or 0)
                b = json.loads(self.rfile.read(n))
                col = o.cols[self.path.split("?")[0].strip("/").split("/")[1]]
                o.writes += 1
                for p in b["points"]: col[p["id"]] = dict(payload=p["payload"], vector=p["vector"])
                self._send({"result": {}})
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_port}"

    def add(self, col, url, src="safari_history", pid=None):
        self.cols[col][pid or vid(url, src)] = dict(
            vector=[0.1, 0.2], payload=dict(url=url, timestamp=TS, source=src))


def test_backfill(monkeypatch, tmp_path):
    f = Fake()
    monkeypatch.setattr(bf, "QDRANT", f.url)
    f.add("safari_history", TRACKED)
    f.add("safari_history", CLEAN)                 # twin already exists -> dedupe
    f.add("safari_history", ONLY)                  # no twin -> re-key
    f.add("safari_history", KEEP)                  # control: untouched
    f.add("safari_history", "https://www.example.net/c?gclid=1", pid="custom-id-1")  # in place
    f.add("preferences", "https://www.example.com/bm?utm_medium=e", src="safari_bookmarks",
          pid=str(uuid.uuid5(uuid.NAMESPACE_URL, "bookmark|https://www.example.com/bm?utm_medium=e")))
    f.add("preferences", "https://x.example.com/?utm_a=1", src="other_source")  # not ours
    (tmp_path / "safari_history.json").write_text(json.dumps([{"url": TRACKED}, {"url": KEEP}]))

    dry = bf.backfill_collection("safari_history", False)
    assert f.writes == 0, "dry run wrote"
    assert dry["to_change"] == 3 and dry["rekeyed"] == 1 and dry["deduped"] == 1 and dry["in_place"] == 1

    got = bf.backfill_collection("safari_history", True)
    assert got["to_change"] == 3 and got["errors"] == 0
    urls = sorted(p["payload"]["url"] for p in f.cols["safari_history"].values())
    assert urls == sorted([CLEAN, ONLY_CLEAN, KEEP, "https://www.example.net/c"]), urls
    assert vid(ONLY_CLEAN) in f.cols["safari_history"] and vid(ONLY) not in f.cols["safari_history"]
    assert f.cols["safari_history"][vid(ONLY_CLEAN)]["vector"] == [0.1, 0.2]

    bm = bf.backfill_collection("preferences", True, bookmark=True)
    assert bm["to_change"] == 1
    assert any(p["payload"]["url"] == "https://x.example.com/?utm_a=1" for p in f.cols["preferences"].values())

    again = bf.backfill_collection("safari_history", True)
    assert again["to_change"] == 0 and again["scanned"] == 4   # idempotent

    j_dry = bf.backfill_json(tmp_path, False)
    assert j_dry["safari_history.json"] == 1 and "utm_" in (tmp_path / "safari_history.json").read_text()
    bf.backfill_json(tmp_path, True)
    assert bf.backfill_json(tmp_path, True)["safari_history.json"] == 0
    assert json.loads((tmp_path / "safari_history.json").read_text()) == [{"url": CLEAN}, {"url": KEEP}]
