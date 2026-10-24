#!/usr/bin/env python3
"""A derive reader's scroll carries the privacy level, so privacy_gate refuses L3 as L3.

Why: the vendored derive readers scroll Qdrant with `with_payload: SCROLL_FIELDS`.
Before this change SCROLL_FIELDS carried no level field, so a point scrolled by a
reader reached src/privacy_gate.py with no level at all and was refused as
"level_unknown". That fails closed, but it is the wrong reason, and an L2 point
was refused too: an online lookup driven from the derive scroll could never
tell private from publishable. Upstream personal-world-graph main carries
"privacy_level", "compartment_level" and "user_id" in SCROLL_FIELDS; the
vendored copy now does too.

Real components: the vendored HttpStoreGateway (real HTTP), a real
QdrantFieldReader built by build_readers() from the shipped readers.yaml, and
the vendored privacy_gate. Only Qdrant is faked, and the fake does what Qdrant
does with a `with_payload` list: it returns ONLY the listed payload keys.

  arm 1  the reader's scroll asked Qdrant for privacy_level, compartment_level, user_id
  arm 2  an L3 point (string level) scrolled by the reader: refused as level_L3
  arm 3  an L3 point (legacy compartment 3 only): refused as level_legacy_3
  arm 4  CONTROL: an L2 point scrolled by the reader: allowed (None)

Mutation: drop the three fields from SCROLL_FIELDS and arms 1 to 4 go red
(every point comes back level_unknown). Synthetic data only.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENRICH = REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
SRC = ENRICH / "src"
COMMON = REPO / "vendor" / "cm019_preferences" / "services" / "common"

for p in (SRC / "derive" / "readers.py", SRC / "derive" / "readers.yaml", SRC / "privacy_gate.py"):
    if not p.is_file():
        print(f"CANNOT-RUN: {p.relative_to(REPO)} is missing")
        sys.exit(2)
try:
    import yaml  # noqa: F401
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install pyyaml")
    sys.exit(2)

# A local HTTP proxy would answer for the fake Qdrant (503 "Forwarding failure");
# loopback must go direct.
for _k in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
    os.environ.pop(_k, None)
os.environ["no_proxy"] = os.environ["NO_PROXY"] = "127.0.0.1,localhost"

sys.path.insert(0, str(COMMON))
sys.path.insert(0, str(SRC))

from derive.config import build_readers  # noqa: E402
from derive.readers import HttpStoreGateway, QdrantFieldReader  # noqa: E402
import privacy_gate  # noqa: E402

PASS = FAIL = 0


def check(cond: bool, msg: str) -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS {msg}")
    else:
        FAIL += 1
        print(f"  FAIL {msg}")


# Full stored payloads. The fake returns only what the scroll asks for.
def stored_points(category: str) -> list:
    base = {"category": category, "source": "synthetic", "strength": 0.8,
            "observed_at": "2026-09-01T00:00:00Z", "extra": {}, "user_id": "owner"}
    return [
        {"id": 1, "payload": dict(base, preference_id="p-l3", subject="Synthetic Private Item",
                                  privacy_level="L3")},
        {"id": 2, "payload": dict(base, preference_id="p-legacy3", subject="Synthetic Legacy Item",
                                  compartment_level=3)},
        {"id": 3, "payload": dict(base, preference_id="p-l2", subject="Synthetic Public Item",
                                  privacy_level="L2")},
    ]


ASKED: list = []
POINTS: list = []


class FakeQdrant(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        want = body.get("with_payload")
        ASKED.append(want)
        pts = []
        for p in POINTS:
            if isinstance(want, list):
                pl = {k: v for k, v in p["payload"].items() if k in want}
            elif want is True:
                pl = dict(p["payload"])
            else:
                pl = {}
            pts.append({"id": p["id"], "payload": pl})
        out = json.dumps({"result": {"points": pts, "next_page_offset": None}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


def main() -> int:
    srv = HTTPServer(("127.0.0.1", 0), FakeQdrant)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        gw = HttpStoreGateway(qdrant_url="http://127.0.0.1:%d" % srv.server_address[1],
                              oxigraph_url="http://127.0.0.1:9")
        reader = next((r for r in build_readers(gw) if isinstance(r, QdrantFieldReader)), None)
        if reader is None:
            print("CANNOT-RUN: readers.yaml builds no qdrant_field reader")
            return 2
        cat = (reader.select_categories or [reader.category])[0]
        POINTS[:] = stored_points(cat)
        try:
            list(reader.read("owner"))
        except OSError as exc:
            print("CANNOT-RUN: the reader could not scroll the fake Qdrant: %s" % exc)
            return 2
        if not ASKED:
            print("CANNOT-RUN: the reader never scrolled Qdrant")
            return 2
        scrolled = gw.scroll(reader.select_categories, [])  # the memoised scroll the reader made
        by_id = {p["id"]: p["payload"] for p in scrolled}

        asked = ASKED[0] if isinstance(ASKED[0], list) else []
        check(all(k in asked for k in ("privacy_level", "compartment_level", "user_id")),
              "the reader's scroll asks for privacy_level, compartment_level and user_id (asked %s)" % sorted(asked))
        r1 = privacy_gate.outbound_refusal(by_id.get(1, {}))
        check(r1 == "level_L3", "L3 point scrolled by %s is refused as level_L3 (got %r)" % (reader.dimension, r1))
        r2 = privacy_gate.outbound_refusal(by_id.get(2, {}))
        check(r2 == "level_legacy_3", "legacy compartment 3 point is refused as level_legacy_3 (got %r)" % r2)
        r3 = privacy_gate.outbound_refusal(by_id.get(3, {}))
        check(r3 is None, "CONTROL: L2 point scrolled by the reader is allowed (got %r)" % r3)
    finally:
        srv.shutdown()
    print(f"{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
