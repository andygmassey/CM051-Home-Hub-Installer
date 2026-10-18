"""Vendored copy of HR015 ``ostler_fda.usage_journal``.

Re-exported so call sites import a stable name rather than reaching through
the module path, which lets the vendored layout change without touching
producers.

``RollingUsageRecorder`` lives in a separate sibling file, ``rolling.py``,
not in ``usage_journal.py``: that file carries a "DO NOT EDIT" banner and
stays byte-identical to its canonical HR015 source.
"""
from .usage_journal import (  # noqa: F401
    PURPOSES,
    record_usage,
    resolve_journal_path,
    tokens_from_ollama,
)
from .rolling import RollingUsageRecorder  # noqa: F401

__all__ = [
    "PURPOSES",
    "record_usage",
    "resolve_journal_path",
    "tokens_from_ollama",
    "RollingUsageRecorder",
]
