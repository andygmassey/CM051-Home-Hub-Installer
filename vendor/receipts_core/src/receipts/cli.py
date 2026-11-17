"""CLI entry: `python -m receipts.cli <op>` with a JSON object on stdin.

Exit 0 when the op ran (its state is in the body). Exit 2 means CANNOT-RUN, with
{"state":"cannot_run","reason":...}. Refuses everything unless OSTLER_RECEIPTS=1.
Roots: OSTLER_RECEIPTS_HOME (store), OSTLER_RECEIPTS_FILES (default ~/Ostler/Receipts),
OSTLER_RECEIPTS_INBOX (default <files>/Inbox).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, Dict

from .model import SCHEMA
from .store import files_root
from .ops import OPS, _state


def _cannot(reason: str) -> int:
    print(json.dumps({"schema": SCHEMA, "state": "cannot_run", "reason": reason}))
    return 2


def _upload_args(req: Dict[str, Any]):
    """Validate an upload body. Returns (path, source, text, error_state_or_None)."""
    inbox = Path(os.environ.get("OSTLER_RECEIPTS_INBOX") or (files_root() / "Inbox")).resolve()
    raw = req.get("path") or ""
    path = Path(raw).resolve() if raw else None
    if not raw or path is None or inbox not in path.parents or not path.is_file():
        return None, None, None, _state("invalid", reason="path must be a staged file inside the Inbox")
    source = req.get("source")
    if source not in ("photo", "share"):
        return None, None, None, _state("invalid", reason="source must be photo or share")
    text = req.get("ocr_text") or ""
    if not text.strip():
        return None, None, None, _state("cannot_run", reason="no ocr_text; the device must send text (VisionKit or PDF text)")
    return path, source, text, None


def ingest_file_begin(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    """Step 1 of the upload (contract v0.3). Writes a `processing` placeholder so the receipt id exists
    before the lens runs. The gateway answers 202 with this id and then runs `ingest.file`."""
    from .pipeline import placeholder
    path, source, text, err = _upload_args(req)
    if err:
        return err
    res = placeholder(store, path=path, source=source, text=text, files_root=files_root())
    if res.get("outcome") == "known":
        return _state("ok", outcome="known", receipt_id=res.get("receipt_id"), status=None, reasons=[])
    return _state("ok", outcome="processing", receipt_id=res["receipt_id"], status="processing", reasons=[])


def _lens_or_none():
    """The same Ollama config the Inbox run uses (RECEIPTS_LENS_URL / RECEIPTS_LENS_MODEL)."""
    from .lens import OllamaLens
    try:
        return OllamaLens(seed=1)
    except ValueError:
        return None


def ingest_file(store: Store, req: Dict[str, Any]) -> Dict[str, Any]:
    """Step 2 of the upload (contract v0.3). Runs the lens, then files or sends to Check. Body:
    {path, ocr_text, source}. Returns receipt id and state. A crash is recorded on the receipt as
    check with cannot_run, so `processing` never sticks."""
    from .pipeline import ingest
    path, source, text, err = _upload_args(req)
    if err:
        return err
    try:
        res = ingest(store, source=source, text=text, files_root=files_root(), source_path=path,
                     lens=_lens_or_none())
    except Exception as e:  # never leave a receipt in processing
        res = {"outcome": "stored", "receipt_id": placeholder_id(path), "status": "check",
               "reasons": [f"cannot_run:{type(e).__name__}"]}
        _mark_failed(store, res["receipt_id"], res["reasons"])
    return _state("ok" if res["outcome"] in ("stored", "duplicate", "known") else res["outcome"],
                  outcome=res["outcome"], receipt_id=res.get("receipt_id"), status=res.get("status"),
                  reasons=res.get("reasons", []))


def placeholder_id(path) -> str:
    import hashlib
    from .store import new_id
    return new_id("rcpt_", hashlib.sha256(Path(path).read_bytes()).hexdigest())


def _mark_failed(store: Store, rid: str, reasons) -> None:
    rec = store.get_receipt(rid)
    if rec and rec.get("status") == "processing":
        rec.update(status="check", reasons=list(reasons))
        store.put_receipt(rec)


def run(op: str, req: Dict[str, Any]) -> Dict[str, Any]:
    from .store import Store
    if op == "ingest.inbox":
        from .inbox import scan_inbox
        from .lens import OllamaLens
        store = Store()
        inbox = Path(os.environ.get("OSTLER_RECEIPTS_INBOX") or (files_root() / "Inbox"))
        res = scan_inbox(store, inbox, files_root(), lens=OllamaLens(seed=int(req.get("seed", 1))))
        return {"schema": SCHEMA, "state": "ok", "results": res}
    if op == "ingest.file":
        return ingest_file(Store(), req)
    if op == "ingest.file.begin":
        return ingest_file_begin(Store(), req)
    if op == "ingest.email":
        from .pipeline import ingest
        store = Store()
        out = []
        for row in req.get("rows", []):
            # message_id is in the text so two receipts with the same supplier, date and total are not one (sha dedupe).
            text = "\n".join(str(x) for x in [row.get("merchant"), row.get("occurred_at"),
                                              f"TOTAL {row.get('currency') or ''} {row.get('total')}",
                                              f"Message-Id {row.get('message_id')}" if row.get("message_id") else None] if x)
            prefilled = {"date": (row.get("occurred_at") or "")[:10] or None, "supplier": row.get("merchant"),
                         "amount_gross": row.get("total"), "currency": row.get("currency"),
                         "tax_amount": None, "book": row.get("book")}
            out.append(ingest(store, source="email", text=text, files_root=files_root(), data=None,
                              prefilled=prefilled, sender=row.get("sender")))
        return {"schema": SCHEMA, "state": "ok", "results": out}
    if op not in OPS:
        return _state("invalid", reason=f"unknown op {op}")
    return OPS[op](Store(), req)


def main(argv: Any = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        return _cannot("no op given")
    if os.environ.get("OSTLER_RECEIPTS") != "1":
        print(json.dumps({"schema": SCHEMA, "state": "closed"}))
        return 0
    raw = sys.stdin.read().strip() or "{}"
    try:
        req = json.loads(raw)
    except ValueError:
        print(json.dumps(_state("invalid", reason="stdin is not JSON")))
        return 0
    try:
        body = run(argv[0], req)
    except OSError as e:
        return _cannot(type(e).__name__)
    print(json.dumps(body, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
