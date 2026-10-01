"""Vendored copy of the shared Ostler usage-journal writer contract.

Re-exports ``record_usage``, ``tokens_from_ollama`` and
``RollingUsageRecorder`` from :mod:`usage_journal`. See that module for
the full contract. This module's one caller (scout_newsletters.py) uses
plain per-call ``record_usage``, not the rollup: its measured volume
(opt-in, once per weekly digest compile) is far below the threshold that
justifies the rollup's calls-count tradeoff. ``RollingUsageRecorder`` is
carried here anyway so this vendored copy stays byte-identical to its
siblings elsewhere in the product (andygmassey/evernote-knowledge,
andygmassey/CM051-Home-Hub-Installer), keeping future divergence patches
small.
"""
from .usage_journal import RollingUsageRecorder, record_usage, tokens_from_ollama

__all__ = ["record_usage", "tokens_from_ollama", "RollingUsageRecorder"]
