"""One-shot box runner for the preference-derivation engine ("What you like").

Upstream (personal-world-graph) ships the engine as a library with no box
entrypoint: ``DerivationEngine.run_result(user_id)`` is the whole API. Its own
CLI script is not vendored (its user-id default names the operator, and this
repository is public). This module is the CM051 entrypoint, run by the
``com.ostler.derive-preferences`` LaunchAgent from the installed tree:

    cd ~/.ostler/services/cm019
    .venv/bin/python -m services.enrich.src.derive_runner --user-id <slug>

What one run does:

1. Builds the engine from the vendored registry (readers.yaml, dimensions.yaml)
   against the box's own Oxigraph + Qdrant ``preferences`` collection.
2. Runs every reader. ANY reader failure means nothing is written: the prior
   derived graph stays exactly as it was. This is stricter than upstream's CLI,
   which writes a partial set when some readers fail and so silently drops the
   dimensions whose reader was down.
3. Otherwise hands the nodes to the upstream writer, which builds a temp graph,
   SHACL-validates it and swaps it in atomically, then mirrors to the separate
   ``derived_preferences`` Qdrant collection.
4. Counts ``pwg:DerivedPreference`` nodes actually present in the named graph
   afterwards. That count, not the presence of the graph, is the readiness
   signal: an empty run still leaves a present graph (the run marker).
5. Writes a counts-only status file for the Doctor. No preference value, title
   or label is ever written to it or to the log.

Local only. It reads and writes the box's own stores and calls nothing else.

Exit codes: 0 written (including a proven-empty run), 1 not written (reader
failure, SHACL failure, store unreachable), 2 could not start (engine missing
a dependency).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

_TREE_ROOT = Path(__file__).resolve().parents[3]
_COMMON = _TREE_ROOT / "services" / "common"

DERIVED_NODE_COUNT_QUERY = (
    "SELECT (COUNT(DISTINCT ?n) AS ?c) WHERE { GRAPH <%s> { "
    "?n a <https://schema.ostler.ai/ontology#DerivedPreference> } }"
)

STATUS_SCHEMA = 1


def _default_status_path() -> Path:
    root = Path(os.environ.get("OSTLER_DIR") or (Path.home() / ".ostler"))
    return root / "state" / "derived-preferences.json"


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_status(path: Path, status: dict) -> None:
    """Atomic write, so the Doctor never reads half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(status, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def _no_proxy_opener() -> None:
    """Local stores must never be reached through HTTP(S)_PROXY.

    Same defect personal-world-graph #409 fixed for the httpx clients: a
    customer with a system proxy would send loopback store traffic (and its
    store credential) to the proxy. The store-auth shim wraps
    ``urllib.request.urlopen`` and calls through to the opener installed here,
    so the credential is still attached.
    """
    urllib.request.install_opener(
        urllib.request.build_opener(urllib.request.ProxyHandler({}))
    )


def count_derived_nodes(store, graph_iri: str) -> int:
    rows = store._select(DERIVED_NODE_COUNT_QUERY % graph_iri)
    return int(rows[0]["c"]["value"]) if rows else 0


def run(
    user_id: str,
    gateway,
    store,
    validator,
    mirror,
    status_path: Path,
    now: datetime | None = None,
) -> int:
    """One derivation pass. Store-facing objects are injected so a test can
    drive the real engine and writer against an in-memory graph."""
    from derive.config import build_readers, load_dimensions
    from derive.engine import Aggregator, DerivationEngine
    from derive.model import DERIVED_GRAPH
    from derive.writer import DerivedGraphWriter

    status = {
        "schema": STATUS_SCHEMA,
        "last_run_at": _now_iso(),
        "derived_graph": DERIVED_GRAPH,
        "outcome": "failed",
        "readers_total": 0,
        "readers_failed": 0,
        "nodes_derived": 0,
        "graph_node_count": None,
        "derivation_version": None,
        "reason": "",
    }

    try:
        readers = build_readers(gateway)
        aggregator = Aggregator(load_dimensions())
        status["derivation_version"] = aggregator._version
        engine = DerivationEngine(readers=readers, aggregator=aggregator)
        result = engine.run_result(user_id, now=now)
    except Exception as exc:  # noqa: BLE001 - recorded, never silent
        status["reason"] = f"engine did not start: {type(exc).__name__}"
        _write_status(status_path, status)
        print(f"derive: {status['reason']}: {exc}", file=sys.stderr, flush=True)
        return 1

    status["readers_total"] = result.readers_total
    status["readers_failed"] = len(result.failed_readers)
    status["nodes_derived"] = len(result.nodes)
    print(
        f"derive: {result.readers_total} reader(s), "
        f"{len(result.failed_readers)} failed, {len(result.nodes)} node(s) derived",
        flush=True,
    )

    if result.failed_readers:
        # Reader names and exception types only. A reader's message can carry
        # a SPARQL fragment, never preference content, but the type is enough.
        for f in result.failed_readers:
            print(f"derive: reader FAILED: {f.split(':', 2)[0]}: {f.split(':', 2)[1].strip()}",
                  file=sys.stderr, flush=True)
        status["outcome"] = "not_written"
        status["reason"] = "a reader failed; the previous derived graph was kept"
        try:
            status["graph_node_count"] = count_derived_nodes(store, DERIVED_GRAPH)
        except Exception:  # noqa: BLE001 - the count is best-effort here
            status["graph_node_count"] = None
        _write_status(status_path, status)
        return 1

    writer = DerivedGraphWriter(store, validator, mirror=mirror)
    try:
        written = writer.write(
            result.nodes, proven_empty=result.proven_empty, user_id=user_id, now=now
        )
        status["graph_node_count"] = count_derived_nodes(store, DERIVED_GRAPH)
    except Exception as exc:  # noqa: BLE001 - recorded, never silent
        status["outcome"] = "not_written"
        status["reason"] = f"write refused or failed: {type(exc).__name__}"
        _write_status(status_path, status)
        print(f"derive: {status['reason']}", file=sys.stderr, flush=True)
        return 1

    if not written.literals_untouched:
        # The writer only ever touches its own named graph, so this means
        # something else wrote to the default graph during the run (ingest,
        # enrich). Not an error of ours, but worth a line.
        print("derive: default-graph triple count moved during the run "
              "(another writer was active)", flush=True)

    status["outcome"] = "written" if result.nodes else "empty"
    status["reason"] = ""
    _write_status(status_path, status)
    print(
        f"derive: wrote {written.node_count} node(s); "
        f"{status['graph_node_count']} pwg:DerivedPreference node(s) now in the graph",
        flush=True,
    )
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Derive preferences once (local only).")
    ap.add_argument("--user-id", default=os.environ.get("OSTLER_DERIVE_USER") or "ostler")
    ap.add_argument("--oxigraph-url", default=os.environ.get("OXIGRAPH_URL", "http://localhost:7878"))
    ap.add_argument("--qdrant-url", default=os.environ.get("QDRANT_URL", "http://localhost:6333"))
    ap.add_argument("--collection", default=os.environ.get("QDRANT_COLLECTION", "preferences"))
    ap.add_argument("--status-file", type=Path, default=_default_status_path())
    args = ap.parse_args(argv)

    sys.path.insert(0, str(_COMMON))
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    _no_proxy_opener()

    try:
        from derive.readers import HttpStoreGateway
        from derive.shacl import PyShaclValidator
        from derive.writer import HttpGraphStore, QdrantDerivedMirror
        import pyshacl  # noqa: F401 - fail here, not after the reads
    except Exception as exc:  # noqa: BLE001
        status = {
            "schema": STATUS_SCHEMA,
            "last_run_at": _now_iso(),
            "outcome": "cannot_start",
            "reason": f"missing dependency: {type(exc).__name__}: {exc}",
        }
        _write_status(args.status_file, status)
        print(f"derive: {status['reason']}", file=sys.stderr, flush=True)
        return 2

    return run(
        user_id=args.user_id,
        gateway=HttpStoreGateway(
            oxigraph_url=args.oxigraph_url,
            qdrant_url=args.qdrant_url,
            collection=args.collection,
        ),
        store=HttpGraphStore(oxigraph_url=args.oxigraph_url),
        validator=PyShaclValidator(),
        mirror=QdrantDerivedMirror(qdrant_url=args.qdrant_url),
        status_path=args.status_file,
    )


if __name__ == "__main__":
    raise SystemExit(main())
