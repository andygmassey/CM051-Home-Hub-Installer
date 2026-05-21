"""KnowledgeSourceAdapter package + registry.

Adapters wrap a knowledge source (Evernote, Obsidian, Notion, ...) and
produce a normalised ParsedNote stream consumed by the downstream
chunker / embedder / markdown_writer / qdrant_store. See base.py for the
Protocol contract.

Usage:
    from src.ingestion.adapters import ADAPTERS, KnowledgeSourceAdapter
    adapter_cls = ADAPTERS["evernote"]
    adapter = adapter_cls()
    for raw in adapter.discover(path):
        note = adapter.parse(raw)
        if note is None:
            continue
        ...  # downstream pipeline

Register new adapters by adding ``"<name>": <Cls>`` to ``ADAPTERS``.
"""
from .base import KnowledgeSourceAdapter, ParsedNote, RawNote
from .evernote import EvernoteAdapter

ADAPTERS: dict[str, type[KnowledgeSourceAdapter]] = {
    "evernote": EvernoteAdapter,
}

__all__ = [
    "ADAPTERS",
    "EvernoteAdapter",
    "KnowledgeSourceAdapter",
    "ParsedNote",
    "RawNote",
]
