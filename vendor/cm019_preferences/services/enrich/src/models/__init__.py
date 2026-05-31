"""Data models for enrichment service."""

from .enrichment import (
    # Enums
    EnrichmentSource,
    MatchType,
    # Result types
    ConfidenceBreakdown,
    EnrichmentResult,
    TopicResult,
    GenreResult,
    EntityResult,
    # Metadata types
    BookMetadata,
    MovieMetadata,
    WatchProvider,
    SimilarTitle,
    MusicMetadata,
)

__all__ = [
    # Enums
    "EnrichmentSource",
    "MatchType",
    # Result types
    "ConfidenceBreakdown",
    "EnrichmentResult",
    "TopicResult",
    "GenreResult",
    "EntityResult",
    # Metadata types
    "BookMetadata",
    "MovieMetadata",
    "WatchProvider",
    "SimilarTitle",
    "MusicMetadata",
]
