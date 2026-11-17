"""CLI: python -m src.receipts --input <dir|file> --store receipts.jsonl --pwg-out email_receipts.jsonl"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .extractor import ReceiptExtractor, ReceiptStore
from .llm_fallback import OllamaLocal
from .sources import iter_path
from .to_pwg import export


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Extract receipts from local mail into PWG rows (offline).")
    ap.add_argument("--input", required=True, type=Path, help=".eml folder, .mbox, .emlx or Apple Mail store")
    ap.add_argument("--store", required=True, type=Path, help="receipt store (JSONL, idempotent per message-id)")
    ap.add_argument("--pwg-out", type=Path, help="write PWG-shaped rows here (rewritten each run)")
    ap.add_argument("--llm-model", help="optional local model name (loopback Ollama) for the generic fallback")
    ap.add_argument("--to-receipts-core", metavar="CORE_DIR",
                    help="after extraction, hand every receipt to the receipts core (PWG services/ingest) as Check rows")
    args = ap.parse_args(argv)

    llm = OllamaLocal(args.llm_model) if args.llm_model else None
    ex = ReceiptExtractor(ReceiptStore(args.store), llm=llm)
    for raw in iter_path(args.input):
        ex.process_bytes(raw)
    print(json.dumps(ex.stats, sort_keys=True))
    if args.to_receipts_core:
        from .core_handoff import handoff
        reply = handoff(ex.store.all(), args.to_receipts_core)
        print(json.dumps({"receipts_core": reply.get("state"), "results": len(reply.get("results", []))}))
    if args.pwg_out:
        rows = export(ex.store.all())
        args.pwg_out.parent.mkdir(parents=True, exist_ok=True)
        args.pwg_out.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows), encoding="utf-8")
        print(f"wrote {len(rows)} rows to {args.pwg_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
