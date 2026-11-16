"""Drop-folder run: ~/Ostler/Receipts/Inbox/ (PDF, TXT, JPG, PNG, HEIC).

Same shape as scripts/money_local.sh (PR #401): an on-demand run of the producer,
not a new daemon. Idempotent: a file whose bytes are already in the store is
skipped (outcome "known"). Originals are read, never moved or deleted.

Text: PDF text layer via statements.importers.extract_pdf_text; TXT read directly.
Images need OCR. The Mac has no OCR engine in this repo yet, so images return
outcome cannot_run with reason ocr_unavailable unless an `ocr` callable is passed.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional

from .lens import OllamaLens
from .pipeline import ingest
from .store import Store

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic"}
TEXT_EXT = {".pdf", ".txt"}
OcrFn = Callable[[Path], Optional[str]]


def _text_of(path: Path, ocr: Optional[OcrFn]) -> Optional[str]:
    ext = path.suffix.lower()
    if ext == ".txt":
        return path.read_text(errors="replace")
    if ext == ".pdf":
        from statements.importers import extract_pdf_text   # #401 reader, text layer only
        return extract_pdf_text(path)
    if ext in IMAGE_EXT and ocr is not None:
        return ocr(path)
    return None


def scan_inbox(store: Store, inbox: Path, files_root: Path, *, lens: Optional[OllamaLens] = None,
               statements: Iterable[Any] = (), ocr: Optional[OcrFn] = None) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    if not inbox.is_dir():
        return [{"outcome": "cannot_run", "reasons": ["inbox_missing"], "path": str(inbox)}]
    for path in sorted(p for p in inbox.iterdir() if p.is_file() and not p.name.startswith(".")):
        ext = path.suffix.lower()
        if ext not in TEXT_EXT | IMAGE_EXT:
            results.append({"outcome": "skipped", "reasons": ["unsupported_type"], "name": path.name})
            continue
        try:
            text = _text_of(path, ocr)
        except Exception as e:  # a bad file is a row in the result, never a crash
            results.append({"outcome": "cannot_run", "reasons": [f"read_failed:{type(e).__name__}"], "name": path.name})
            continue
        if text is None:
            results.append({"outcome": "cannot_run", "reasons": ["ocr_unavailable"], "name": path.name})
            continue
        if not text.strip():
            results.append({"outcome": "cannot_run", "reasons": ["no_text_layer"], "name": path.name})
            continue
        res = ingest(store, source="folder", text=text, files_root=files_root, source_path=path,
                     lens=lens, statements=statements)
        res["name"] = path.name
        results.append(res)
    return results
