"""Validation utilities for enrichment confidence scoring.

This module provides text similarity functions and confidence calculations
to ensure enrichment accuracy. The goal is to catch wrong matches before
they pollute the preference graph.
"""

import re
from difflib import SequenceMatcher
from typing import List, Optional, Tuple

from ..models.enrichment import ConfidenceBreakdown, MatchType


def normalize_for_comparison(text: str) -> str:
    """
    Normalize text for comparison.

    - Lowercase
    - Remove punctuation
    - Collapse whitespace
    - Remove common prefixes/suffixes (The, A, An)
    """
    if not text:
        return ""

    # Lowercase
    normalized = text.lower().strip()

    # Remove leading articles
    for article in ["the ", "a ", "an "]:
        if normalized.startswith(article):
            normalized = normalized[len(article):]

    # Remove punctuation except apostrophes in contractions
    normalized = re.sub(r"[^\w\s']", " ", normalized)

    # Collapse whitespace
    normalized = re.sub(r"\s+", " ", normalized).strip()

    return normalized


def title_similarity(query: str, result: str) -> float:
    """
    Calculate similarity between query and result titles.

    Returns a score from 0.0 to 1.0.

    Uses a combination of:
    - Exact match check
    - SequenceMatcher ratio
    - Word overlap (Jaccard similarity)
    """
    if not query or not result:
        return 0.0

    # Normalize both
    norm_query = normalize_for_comparison(query)
    norm_result = normalize_for_comparison(result)

    # Exact match after normalization
    if norm_query == norm_result:
        return 1.0

    # SequenceMatcher for character-level similarity
    seq_ratio = SequenceMatcher(None, norm_query, norm_result).ratio()

    # Word overlap (Jaccard)
    query_words = set(norm_query.split())
    result_words = set(norm_result.split())

    if query_words and result_words:
        intersection = query_words & result_words
        union = query_words | result_words
        jaccard = len(intersection) / len(union)
    else:
        jaccard = 0.0

    # Weighted combination (character similarity matters more)
    combined = (seq_ratio * 0.6) + (jaccard * 0.4)

    return round(combined, 3)


def author_similarity(query_author: Optional[str], result_authors: List[str]) -> float:
    """
    Check if the query author matches any result author.

    Returns 1.0 for exact match, 0.5-0.9 for partial, 0.0 for no match.
    """
    if not query_author or not result_authors:
        return 0.0

    norm_query = normalize_for_comparison(query_author)

    best_score = 0.0
    for author in result_authors:
        norm_author = normalize_for_comparison(author)

        # Exact match
        if norm_query == norm_author:
            return 1.0

        # Check if query is subset of author or vice versa
        # (handles "J.K. Rowling" vs "Rowling" cases)
        if norm_query in norm_author or norm_author in norm_query:
            best_score = max(best_score, 0.8)
            continue

        # Check last name match (common case)
        query_parts = norm_query.split()
        author_parts = norm_author.split()
        if query_parts and author_parts:
            if query_parts[-1] == author_parts[-1]:
                best_score = max(best_score, 0.7)
                continue

        # General similarity
        sim = SequenceMatcher(None, norm_query, norm_author).ratio()
        if sim > 0.7:
            best_score = max(best_score, sim * 0.8)

    return round(best_score, 3)


def year_is_plausible(
    result_year: Optional[int],
    preference_year: Optional[int] = None,
    max_future_years: int = 2
) -> bool:
    """
    Check if the result year is plausible.

    A book/movie/album can't be from the future (with small margin for
    pre-release preferences), and shouldn't be unreasonably old if we
    have a preference date to compare against.
    """
    if result_year is None:
        return True  # Can't validate, assume OK

    from datetime import datetime
    current_year = datetime.now().year

    # Can't be too far in the future
    if result_year > current_year + max_future_years:
        return False

    # If we have a preference timestamp, result should be from before or around that time
    if preference_year:
        # Allow 1 year grace (might have consumed something before official release)
        if result_year > preference_year + 1:
            return False

    return True


def calculate_confidence(
    query: str,
    result_title: str,
    result_authors: Optional[List[str]] = None,
    query_author: Optional[str] = None,
    result_year: Optional[int] = None,
    preference_year: Optional[int] = None,
    result_count: int = 1,
    has_direct_id: bool = False
) -> Tuple[float, MatchType, ConfidenceBreakdown]:
    """
    Calculate overall confidence score for an enrichment match.

    Returns:
        Tuple of (confidence_score, match_type, breakdown)

    Confidence scoring:
    - Direct ID lookup: 1.0 (no ambiguity)
    - Exact title match: 0.9-0.95
    - High title similarity + author match: 0.8-0.9
    - High title similarity only: 0.6-0.8
    - Low title similarity: 0.3-0.5 (flagged for review)
    """
    breakdown = ConfidenceBreakdown(
        result_count=result_count,
        has_direct_id=has_direct_id,
        single_result=(result_count == 1),
    )

    # Direct ID lookup is always highest confidence
    if has_direct_id:
        breakdown.title_similarity = 1.0
        return 1.0, MatchType.DIRECT_ID, breakdown

    # Calculate title similarity
    title_sim = title_similarity(query, result_title)
    breakdown.title_similarity = title_sim

    # Calculate author match if we have data
    author_sim = 0.0
    if query_author and result_authors:
        author_sim = author_similarity(query_author, result_authors)
        breakdown.author_match = author_sim

    # Check year plausibility
    year_ok = year_is_plausible(result_year, preference_year)
    breakdown.year_plausible = year_ok

    # Determine match type
    if title_sim >= 0.95:
        match_type = MatchType.EXACT_TITLE
    elif title_sim >= 0.6:
        match_type = MatchType.FUZZY_TITLE
    else:
        match_type = MatchType.BEST_GUESS

    # Calculate confidence score
    # Use a tiered approach based on title similarity
    if title_sim >= 0.95:
        # Exact match: start at 0.85, can go up to 0.98
        confidence = 0.85
    elif title_sim >= 0.8:
        # High similarity: 0.7-0.85
        confidence = 0.7 + (title_sim - 0.8) * 1.0  # 0.7 to 0.9
    elif title_sim >= 0.6:
        # Medium similarity: 0.5-0.7
        confidence = 0.5 + (title_sim - 0.6) * 1.0  # 0.5 to 0.7
    else:
        # Low similarity: 0.2-0.5
        confidence = title_sim * 0.8  # 0 to 0.48

    # Author match bonus (up to 0.1)
    if author_sim > 0:
        confidence += author_sim * 0.1
    elif query_author:
        # Author was expected but didn't match - penalty
        confidence -= 0.1

    # Year plausibility bonus (up to 0.05)
    if year_ok:
        confidence += 0.03
    else:
        # Year mismatch - significant penalty
        confidence -= 0.15

    # Single result bonus (up to 0.05)
    if result_count == 1:
        confidence += 0.05
    elif result_count > 5:
        # Many results means ambiguity - slight penalty
        confidence -= 0.03

    # Ensure confidence is in valid range
    confidence = max(0.0, min(1.0, confidence))

    # Apply match type ceiling
    # Even with perfect other factors, fuzzy matches shouldn't exceed 0.9
    if match_type == MatchType.FUZZY_TITLE:
        confidence = min(confidence, 0.9)
    elif match_type == MatchType.BEST_GUESS:
        confidence = min(confidence, 0.55)

    return round(confidence, 3), match_type, breakdown


def should_accept_match(
    confidence: float,
    match_type: MatchType,
    min_confidence: float = 0.5
) -> bool:
    """
    Determine if a match should be accepted based on confidence.

    Args:
        confidence: The calculated confidence score
        match_type: The type of match made
        min_confidence: Minimum confidence threshold

    Returns:
        True if the match should be accepted
    """
    # Direct ID matches are always accepted
    if match_type == MatchType.DIRECT_ID:
        return True

    # Exact title matches accepted if above low threshold
    if match_type == MatchType.EXACT_TITLE:
        return confidence >= 0.4

    # Fuzzy matches need higher confidence
    if match_type == MatchType.FUZZY_TITLE:
        return confidence >= min_confidence

    # Best guess matches need even higher confidence
    if match_type == MatchType.BEST_GUESS:
        return confidence >= min_confidence + 0.1

    return False
