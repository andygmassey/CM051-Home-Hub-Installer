"""
Importance Scorer - Calculate importance scores for notes to boost RAG retrieval.

Factors contributing to importance:
- Quality tags (good, very good, starred, favorite)
- Source URL domain credibility
- Content substance (word count)
- Recency (recently updated notes)

Usage:
    scorer = ImportanceScorer()
    score = scorer.score(note)
"""

import logging
import re
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Set
from urllib.parse import urlparse

from .enex_parser import ParsedNote

logger = logging.getLogger(__name__)


@dataclass
class ImportanceResult:
    """Result of importance scoring."""

    score: float  # 0.0 - 1.0
    factors: Dict[str, float]  # Breakdown of score components
    reason: str  # Human-readable explanation


# Quality signal tags - indicates user manually marked as valuable
# Case-insensitive matching
QUALITY_TAGS: Dict[str, float] = {
    # Explicit quality ratings
    "very good": 0.35,
    "verygood": 0.35,
    "excellent": 0.40,
    "good": 0.20,
    "great": 0.25,

    # Favorite/star indicators
    "starred": 0.30,
    "favorite": 0.30,
    "favourite": 0.30,
    "★": 0.30,
    "⭐": 0.30,
    "_starred": 0.30,
    "_favorite": 0.30,
    "_important": 0.25,

    # Reference/keeper tags
    "keeper": 0.25,
    "reference": 0.15,
    "important": 0.20,
    "useful": 0.15,
    "save": 0.10,
    "bookmark": 0.10,

    # Learning/research value
    "learning": 0.10,
    "research": 0.10,
    "howto": 0.10,
    "how-to": 0.10,
    "tutorial": 0.10,
}

# Negative quality signals - content likely less useful for recall
NEGATIVE_TAGS: Dict[str, float] = {
    "archive": -0.10,
    "old": -0.10,
    "outdated": -0.15,
    "deprecated": -0.15,
    "temp": -0.10,
    "temporary": -0.10,
    "draft": -0.05,
    "todo": -0.05,  # May be incomplete
    "to-read": -0.05,  # May not have been read yet
}

# Trusted domains for web clips (source credibility)
TRUSTED_DOMAINS: Dict[str, float] = {
    # Encyclopedias & reference
    "wikipedia.org": 0.10,
    "britannica.com": 0.10,

    # Academic & research
    "arxiv.org": 0.15,
    "scholar.google.com": 0.12,
    "nature.com": 0.12,
    "sciencedirect.com": 0.10,
    "pubmed.ncbi.nlm.nih.gov": 0.12,
    "acm.org": 0.10,
    "ieee.org": 0.10,

    # Developer resources
    "github.com": 0.08,
    "stackoverflow.com": 0.08,
    "developer.mozilla.org": 0.10,
    "docs.python.org": 0.10,
    "docs.microsoft.com": 0.08,
    "developer.apple.com": 0.08,

    # Quality journalism/analysis
    "nytimes.com": 0.05,
    "theguardian.com": 0.05,
    "bbc.com": 0.05,
    "economist.com": 0.08,
    "hbr.org": 0.08,

    # Books & long-form
    "goodreads.com": 0.05,
    "amazon.com": 0.02,  # May be product pages
}

# Low-value domains (content often ephemeral or low quality)
LOW_VALUE_DOMAINS: Set[str] = {
    "twitter.com",
    "x.com",
    "facebook.com",
    "instagram.com",
    "tiktok.com",
    "reddit.com",  # Quality varies widely
    "buzzfeed.com",
}


class ImportanceScorer:
    """
    Calculate importance scores for notes.

    Importance affects RAG retrieval ranking - higher importance notes
    should be boosted in search results.
    """

    def __init__(
        self,
        quality_tags: Optional[Dict[str, float]] = None,
        trusted_domains: Optional[Dict[str, float]] = None,
        recency_years: int = 2,
        min_word_count: int = 100,
        max_word_count: int = 2000,
    ):
        """
        Initialize the importance scorer.

        Args:
            quality_tags: Override quality tag weights
            trusted_domains: Override trusted domain weights
            recency_years: Notes updated within this many years get recency boost
            min_word_count: Minimum words for substance score
            max_word_count: Words for maximum substance score
        """
        self.quality_tags = quality_tags or QUALITY_TAGS
        self.negative_tags = NEGATIVE_TAGS
        self.trusted_domains = trusted_domains or TRUSTED_DOMAINS
        self.recency_years = recency_years
        self.min_word_count = min_word_count
        self.max_word_count = max_word_count

        self._stats = {
            'scored': 0,
            'quality_tag_matches': 0,
            'domain_matches': 0,
            'recency_boosts': 0,
        }

    def score(self, note: ParsedNote) -> ImportanceResult:
        """
        Calculate importance score for a note.

        Args:
            note: ParsedNote to score

        Returns:
            ImportanceResult with score, factors, and reason
        """
        self._stats['scored'] += 1
        factors = {}
        reasons = []

        # Factor 1: Quality tags
        tag_score = self._score_tags(note.tags)
        if tag_score != 0:
            factors['quality_tags'] = tag_score
            if tag_score > 0:
                self._stats['quality_tag_matches'] += 1
                reasons.append(f"quality tags (+{tag_score:.2f})")
            else:
                reasons.append(f"negative tags ({tag_score:.2f})")

        # Factor 2: Source URL credibility
        if note.source_url:
            url_score = self._score_url(note.source_url)
            if url_score != 0:
                factors['source_url'] = url_score
                self._stats['domain_matches'] += 1
                reasons.append(f"trusted source (+{url_score:.2f})")

        # Factor 3: Content substance (word count)
        substance_score = self._score_substance(note.word_count)
        if substance_score > 0:
            factors['substance'] = substance_score
            reasons.append(f"substantive content (+{substance_score:.2f})")

        # Factor 4: Recency
        recency_score = self._score_recency(note.updated or note.created)
        if recency_score > 0:
            factors['recency'] = recency_score
            self._stats['recency_boosts'] += 1
            reasons.append(f"recent (+{recency_score:.2f})")

        # Calculate total score (clamped to 0.0 - 1.0)
        total_score = sum(factors.values())
        total_score = max(0.0, min(1.0, total_score))

        reason = ", ".join(reasons) if reasons else "no special indicators"

        return ImportanceResult(
            score=total_score,
            factors=factors,
            reason=reason,
        )

    def _score_tags(self, tags: List[str]) -> float:
        """Score based on quality/negative tags."""
        if not tags:
            return 0.0

        total = 0.0
        for tag in tags:
            tag_lower = tag.lower().strip()

            # Check quality tags
            if tag_lower in self.quality_tags:
                total += self.quality_tags[tag_lower]

            # Check negative tags
            if tag_lower in self.negative_tags:
                total += self.negative_tags[tag_lower]

        return total

    def _score_url(self, url: str) -> float:
        """Score based on source URL domain."""
        if not url:
            return 0.0

        try:
            parsed = urlparse(url)
            domain = parsed.netloc.lower()

            # Remove www. prefix
            if domain.startswith("www."):
                domain = domain[4:]

            # Check trusted domains (exact or suffix match)
            for trusted, score in self.trusted_domains.items():
                if domain == trusted or domain.endswith("." + trusted):
                    return score

            # Check low-value domains (slight penalty)
            for low_value in LOW_VALUE_DOMAINS:
                if domain == low_value or domain.endswith("." + low_value):
                    return -0.05

        except Exception:
            pass

        return 0.0

    def _score_substance(self, word_count: int) -> float:
        """
        Score based on content length.

        Very short notes may lack context.
        Very long notes may have more substance.
        """
        if word_count < self.min_word_count:
            return 0.0

        # Linear scale from min to max
        ratio = min(1.0, (word_count - self.min_word_count) /
                    (self.max_word_count - self.min_word_count))

        # Max substance boost is 0.10
        return ratio * 0.10

    def _score_recency(self, timestamp: Optional[datetime]) -> float:
        """
        Score based on how recently the note was updated.

        Recently updated notes may be more relevant.
        """
        if not timestamp:
            return 0.0

        now = datetime.now()
        cutoff = now - timedelta(days=self.recency_years * 365)

        if timestamp > cutoff:
            # Linear decay from now to cutoff
            days_old = (now - timestamp).days
            max_days = self.recency_years * 365
            freshness = 1.0 - (days_old / max_days)

            # Max recency boost is 0.10
            return freshness * 0.10

        return 0.0

    def score_batch(self, notes: List[ParsedNote]) -> List[ImportanceResult]:
        """Score multiple notes."""
        return [self.score(note) for note in notes]

    @property
    def stats(self) -> dict:
        """Get scoring statistics."""
        return self._stats.copy()

    def reset_stats(self):
        """Reset statistics."""
        self._stats = {
            'scored': 0,
            'quality_tag_matches': 0,
            'domain_matches': 0,
            'recency_boosts': 0,
        }


def score_note(note: ParsedNote) -> float:
    """
    Convenience function to score a single note.

    Args:
        note: ParsedNote to score

    Returns:
        Importance score (0.0 - 1.0)
    """
    scorer = ImportanceScorer()
    result = scorer.score(note)
    return result.score


def get_quality_tags() -> Dict[str, float]:
    """Get the quality tag weights for reference."""
    return QUALITY_TAGS.copy()


if __name__ == "__main__":
    # Test the scorer
    import sys
    from .enex_parser import sample_notes

    if len(sys.argv) < 2:
        print("Usage: python -m src.ingestion.importance_scorer <file.enex>")
        sys.exit(1)

    file_path = sys.argv[1]

    logging.basicConfig(level=logging.INFO)

    print(f"Scoring notes from: {file_path}")
    print()

    notes = sample_notes(file_path, 10)
    scorer = ImportanceScorer()

    for note in notes:
        result = scorer.score(note)
        print(f"Title: {note.title[:60]}...")
        print(f"  Tags: {note.tags}")
        print(f"  URL: {note.source_url}")
        print(f"  Words: {note.word_count}")
        print(f"  Score: {result.score:.2f}")
        print(f"  Factors: {result.factors}")
        print(f"  Reason: {result.reason}")
        print()

    print(f"\nStats: {scorer.stats}")
