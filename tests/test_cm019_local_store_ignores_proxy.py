#!/usr/bin/env python3
"""The vendored CM019 enricher reaches the LOCAL stores even with a proxy set.

httpx honours HTTP_PROXY/HTTPS_PROXY by default. With a proxy configured and
no matching NO_PROXY, every enricher request to the local Qdrant and Oxigraph
went to the proxy: measured on a dev Mac (proxy 127.0.0.1:8118),
_store_enrichment returned False until the proxy env was cleared, so the
enrichment it had just fetched was lost. Upstream: personal-world-graph #409.

  arm 1  a real loopback server stands in for the stores and a DEAD proxy (a
         closed port) is in the environment. _store_enrichment,
         _check_already_enriched, _query_qdrant_preferences and
         TopicHierarchyService._execute_query must each reach the server.
  arm 2  CONTROL: a client that honours the env fails against that proxy, so
         arm 1 measures the setting and not a proxy that happens to forward.
  arm 3  every httpx.AsyncClient(...) in the vendored enricher.py,
         hierarchy.py and cli.py passes trust_env=False (AST), so a new call
         site cannot quietly opt back in.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import ast
import asyncio
import json
import os
import socket
import sys
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parent.parent
ENRICH = REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
SRC = ENRICH / "src"
MODULES = ("enricher.py", "hierarchy.py", "cli.py")

for m in MODULES:
    if not (SRC / m).is_file():
        print(f"CANNOT RUN: missing {SRC / m}", file=sys.stderr)
        sys.exit(2)
try:
    import httpx
except ImportError as exc:
    print(f"CANNOT RUN: {exc}", file=sys.stderr)
    sys.exit(2)

# Dead proxy BEFORE anything builds a client.
_s = socket.socket()
_s.bind(("127.0.0.1", 0))
DEAD = f"http://127.0.0.1:{_s.getsockname()[1]}"
_s.close()
for var in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
    os.environ[var] = DEAD
for var in ("NO_PROXY", "no_proxy"):
    os.environ.pop(var, None)

sys.path.insert(0, str(ENRICH))
try:
    from src.config import settings
    from src.enricher import EnrichmentService
    from src.hierarchy import TopicHierarchyService
    from src.models.enrichment import EnrichmentResult, EnrichmentSource
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT RUN: vendored enricher does not import: {exc!r}", file=sys.stderr)
    sys.exit(2)

REPLY = json.dumps({
    "boolean": False,
    "head": {"vars": []},
    "results": {"bindings": []},
    "result": {"points": [], "next_page_offset": None},
}).encode()
HITS = []


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):  # noqa: N802
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        HITS.append(self.path)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(REPLY)


def main() -> int:
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
    port = httpd.server_address[1]
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    settings.oxigraph_host = settings.qdrant_host = "127.0.0.1"
    settings.oxigraph_port = settings.qdrant_port = port
    fails = []

    def arm(name, coro, want):
        HITS.clear()
        try:
            asyncio.run(coro)
        except Exception as exc:  # noqa: BLE001
            fails.append(f"{name}: raised {exc!r}")
            return
        if not want(list(HITS)):
            fails.append(f"{name}: local store hits {HITS!r}")

    result = EnrichmentResult(
        preference_id="00000000-0000-4000-8000-0000000000aa",
        original_subject="Synthetic Title",
        source=EnrichmentSource.TMDB,
        enriched_at=datetime(2026, 1, 2, 3, 4, 5),
        matched_title="Synthetic Title",
    )
    arm("_store_enrichment",
        EnrichmentService._store_enrichment(SimpleNamespace(_enriched_ids=set()), result),
        lambda h: h == ["/update"])
    arm("_check_already_enriched",
        EnrichmentService._check_already_enriched(SimpleNamespace(_enriched_ids=set()), "p1"),
        lambda h: h == ["/query"])
    arm("_query_qdrant_preferences",
        EnrichmentService._query_qdrant_preferences(SimpleNamespace(), limit=1),
        lambda h: len(h) == 1 and h[0].startswith("/collections/"))
    svc = TopicHierarchyService.__new__(TopicHierarchyService)
    svc._oxigraph_url = f"http://127.0.0.1:{port}"
    arm("TopicHierarchyService._execute_query", svc._execute_query("ASK {}"),
        lambda h: h == ["/query"])
    n_arm1 = 4

    # arm 2: control
    HITS.clear()

    async def honours_env():
        async with httpx.AsyncClient(timeout=5.0) as c:
            await c.post(f"http://127.0.0.1:{port}/query", content="ASK {}")

    try:
        asyncio.run(honours_env())
        fails.append("control: an env-honouring client reached the store; the dead proxy is not dead")
    except httpx.HTTPError:
        if HITS:
            fails.append(f"control: store was hit {HITS!r}")

    # arm 3: static
    n_calls = 0
    for m in MODULES:
        tree = ast.parse((SRC / m).read_text(encoding="utf-8"))
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
                 and isinstance(n.func, ast.Attribute) and n.func.attr == "AsyncClient"]
        if not calls:
            fails.append(f"{m}: no AsyncClient calls found (predicate broken?)")
        n_calls += len(calls)
        for n in calls:
            if not any(k.arg == "trust_env" and isinstance(k.value, ast.Constant)
                       and k.value.value is False for k in n.keywords):
                fails.append(f"{m}:{n.lineno}: AsyncClient without trust_env=False")
    httpd.shutdown()

    if fails:
        for f in fails:
            print(f"FAIL: {f}")
        return 1
    print(f"PASS: {n_arm1} of {n_arm1} local-store calls reached the store through a dead proxy; "
          f"control failed as it must; {n_calls} of {n_calls} AsyncClient calls set trust_env=False")
    return 0


if __name__ == "__main__":
    sys.exit(main())
