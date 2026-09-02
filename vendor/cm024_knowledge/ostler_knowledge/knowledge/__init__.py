"""
Email Knowledge Extraction Module.

Extracts knowledge from email correspondence for the Personal Knowledge Backend.

Components:
- ThreadAggregator: Groups emails into conversation threads
- EmailProcessor: Reads MBOX files and filters for correspondence
- EmailSummarizer: Uses LLM to extract knowledge from threads
"""

from .thread_aggregator import (
    EmailMessage,
    EmailThread,
    ThreadAggregator,
)

from .email_processor import (
    EmailProcessor,
    ProcessorStats,
    PERSONAL_DOMAINS,
    EXCLUDE_DOMAINS,
)

from .email_summarizer import (
    EmailSummarizer,
    ThreadKnowledge,
)

__all__ = [
    # Thread aggregation
    "EmailMessage",
    "EmailThread",
    "ThreadAggregator",
    # Email processing
    "EmailProcessor",
    "ProcessorStats",
    "PERSONAL_DOMAINS",
    "EXCLUDE_DOMAINS",
    # Knowledge extraction
    "EmailSummarizer",
    "ThreadKnowledge",
]
