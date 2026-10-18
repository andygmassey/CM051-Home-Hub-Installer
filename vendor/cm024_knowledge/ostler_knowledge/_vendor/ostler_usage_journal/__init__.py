"""Vendored copy of the shared Ostler usage-journal writer contract.

Used so this repo's Ollama-calling code (embedding, classification,
email summarization) reports measured token usage to the Hub's cost
panel, instead of silently dropping it.
"""
from .usage_journal import RollingUsageRecorder, record_usage, tokens_from_ollama

__all__ = ["record_usage", "tokens_from_ollama", "RollingUsageRecorder"]
