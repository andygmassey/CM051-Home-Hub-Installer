"""Open Library API client for book metadata."""

import logging
import re
from dataclasses import dataclass
from typing import List, Optional

from .base import BaseClient, InMemoryCache
from .validation import calculate_confidence, should_accept_match
from ..config import settings
from ..models.enrichment import (
    BookMetadata,
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    GenreResult,
    EntityResult,
)

logger = logging.getLogger(__name__)


@dataclass
class SearchResult:
    """Wrapper for search results with metadata for confidence scoring."""
    metadata: BookMetadata
    result_count: int  # Total number of results returned


def extract_author_from_title(title: str) -> tuple[str, Optional[str]]:
    """
    Extract author name from book title strings.

    Common patterns in our data:
    - "Title by Author Name" -> ("Title", "Author Name")
    - "Author's Title" -> ("Title", "Author")
    - "Title [Format] by Author" -> ("Title", "Author")

    Returns:
        Tuple of (cleaned_title, extracted_author or None)
    """
    if not title:
        return title, None

    original = title
    extracted_author = None

    # FIRST: Clean up title - remove prefixes and format indicators
    # This must happen before pattern matching so "Purchased Anthony Bourdain's..." works
    title = re.sub(r'^Purchased\s+', '', title, flags=re.IGNORECASE)
    title = re.sub(r'\s*\[(Paperback|Hardcover|Kindle Edition|Audio CD)\]\s*', ' ', title, flags=re.IGNORECASE)
    title = re.sub(r'\s*\(Paperback|Hardcover\)\s*', ' ', title, flags=re.IGNORECASE)
    title = re.sub(r'\s+', ' ', title).strip()

    # Pattern 1: "by Author Name" at end (most common)
    # Handles: "Corporate Identity by Olins, Wally"
    by_match = re.search(r'\s+by\s+([A-Z][^,\[\]]+(?:,\s*[A-Z][a-z]+)?)\s*$', title, re.IGNORECASE)
    if by_match:
        extracted_author = by_match.group(1).strip()
        title = title[:by_match.start()].strip()
        # Handle "Last, First" -> "First Last" format
        if ',' in extracted_author:
            parts = [p.strip() for p in extracted_author.split(',', 1)]
            if len(parts) == 2 and len(parts[1]) > 1:
                extracted_author = f"{parts[1]} {parts[0]}"

    # Pattern 2: "Author's Title" (possessive at start)
    # Handles: "Anthony Bourdain's Les Halles Cookbook"
    # But NOT: "The Innovator's Dilemma" (The is an article, not an author)
    if not extracted_author:
        poss_match = re.match(r"^([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)'s\s+(.+)$", title)
        if poss_match:
            potential_author = poss_match.group(1).strip()
            # Reject common articles/nouns that aren't author names
            non_author_words = {'The', 'A', 'An', "One", "Someone", "Everyone", "Nobody",
                               "Innovator", "Entrepreneur", "Leader", "Manager", "Founder",
                               "Artist", "Writer", "Author", "Reader", "Student", "Teacher",
                               "Beginner", "Expert", "Professional", "Amateur"}
            # Also reject single words that are likely part of title
            first_word = potential_author.split()[0] if potential_author else ""
            if first_word not in non_author_words and len(potential_author.split()) >= 2:
                extracted_author = potential_author
                title = poss_match.group(2).strip()

    if extracted_author:
        logger.debug(f"[AUTHOR-EXTRACT] '{original}' -> title='{title}', author='{extracted_author}'")

    return title, extracted_author


class OpenLibraryClient(BaseClient[BookMetadata]):
    """
    Client for Open Library API.

    API Documentation: https://openlibrary.org/developers/api

    Features:
    - Search books by title/author
    - Get book details including subjects and descriptions
    - Map subjects to PWG topic ontology
    - No API key required (open API)
    - Auto-extracts author from title strings when not provided

    Rate limit: Be respectful (~1 req/sec)
    """

    BASE_URL = "https://openlibrary.org"
    CACHE_PREFIX = "openlibrary"

    # Subject categories to filter/normalize
    SUBJECT_BLOCKLIST = {
        "accessible book",
        "protected daisy",
        "in library",
        "overdrive",
        "lending library",
        "internet archive wishlist",
        "large type books",
        "fiction",  # Too generic
        "nonfiction",  # Too generic
    }

    def __init__(self, cache: Optional[InMemoryCache] = None):
        super().__init__(
            rate_limit=settings.openlibrary_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )

    def _get_headers(self):
        return {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0 (Personal World Graph project)",
        }

    def _normalize_subject(self, subject: str) -> str:
        """Normalize a subject string to a topic ID."""
        # Convert to lowercase
        normalized = subject.lower().strip()

        # Check for custom mappings
        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        # Replace spaces and special characters with underscores
        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    def _filter_subjects(self, subjects: List[str]) -> List[str]:
        """Filter out low-value subjects."""
        filtered = []
        seen = set()

        for subject in subjects:
            lower = subject.lower().strip()

            # Skip blocklisted
            if lower in self.SUBJECT_BLOCKLIST:
                continue

            # Skip duplicates (case-insensitive)
            if lower in seen:
                continue

            # Skip very short subjects
            if len(lower) < 3:
                continue

            # Skip subjects that are just dates
            if re.match(r"^\d{4}$", lower):
                continue

            seen.add(lower)
            filtered.append(subject)

        return filtered[:15]  # Limit to top 15 subjects

    async def search(self, query: str, author: Optional[str] = None) -> Optional[SearchResult]:
        """
        Search for a book by title (and optionally author).

        Args:
            query: Book title
            author: Optional author name for better matching

        Returns:
            SearchResult with BookMetadata and result count if found, None otherwise
        """
        params = {"title": query, "limit": 10}  # Get more results for confidence scoring
        if author:
            params["author"] = author

        result = await self._get("/search.json", params=params)

        if not result or not result.get("docs"):
            logger.debug(f"No results for book: {query}")
            return None

        docs = result["docs"]
        result_count = len(docs)

        # Find best match
        best_match = None
        for doc in docs:
            # Prefer exact title matches
            title = doc.get("title", "")
            if title.lower() == query.lower():
                best_match = doc
                break

            # Otherwise use first result with subjects
            if best_match is None and doc.get("subject"):
                best_match = doc

        if best_match is None:
            best_match = docs[0]

        # Extract metadata
        metadata = BookMetadata(
            title=best_match.get("title", query),
            authors=best_match.get("author_name", []),
            subjects=self._filter_subjects(best_match.get("subject", [])),
            publish_year=best_match.get("first_publish_year"),
            open_library_key=best_match.get("key"),
            isbn=(best_match.get("isbn", [None])[0] if best_match.get("isbn") else None),
            cover_url=(
                f"https://covers.openlibrary.org/b/id/{best_match['cover_i']}-M.jpg"
                if best_match.get("cover_i")
                else None
            ),
            number_of_pages=best_match.get("number_of_pages_median"),
        )

        return SearchResult(metadata=metadata, result_count=result_count)

    async def get_details(self, work_key: str) -> Optional[BookMetadata]:
        """
        Get detailed book info by Open Library work key.

        Args:
            work_key: Open Library work key (e.g., "/works/OL45804W")

        Returns:
            BookMetadata with full details
        """
        # Get work details
        result = await self._get(f"{work_key}.json")

        if not result:
            return None

        # Get description
        description = None
        desc_raw = result.get("description")
        if isinstance(desc_raw, str):
            description = desc_raw
        elif isinstance(desc_raw, dict):
            description = desc_raw.get("value")

        # Get first sentence
        first_sentence = None
        fs_raw = result.get("first_sentence")
        if isinstance(fs_raw, str):
            first_sentence = fs_raw
        elif isinstance(fs_raw, dict):
            first_sentence = fs_raw.get("value")

        # Extract subjects from various fields
        subjects = []
        for field in ["subjects", "subject_places", "subject_people", "subject_times"]:
            subjects.extend(result.get(field, []))

        # Get author names (requires additional calls)
        authors = []
        author_keys = result.get("authors", [])
        for author_ref in author_keys[:3]:  # Limit to 3 authors
            author_key = author_ref.get("author", {}).get("key")
            if author_key:
                author_data = await self._get(f"{author_key}.json")
                if author_data:
                    authors.append(author_data.get("name", "Unknown"))

        return BookMetadata(
            title=result.get("title", ""),
            authors=authors,
            subjects=self._filter_subjects(subjects),
            description=description,
            first_sentence=first_sentence,
            open_library_key=work_key,
        )

    async def enrich(
        self,
        preference_id: str,
        title: str,
        author: Optional[str] = None,
        preference_year: Optional[int] = None,
        isbn: Optional[str] = None,
        min_confidence: float = 0.5
    ) -> EnrichmentResult:
        """
        Enrich a book preference with topics and metadata.

        Args:
            preference_id: PWG preference ID
            title: Book title
            author: Optional author name for validation
            preference_year: Optional year the preference was recorded
            isbn: Optional ISBN for direct lookup (highest confidence)
            min_confidence: Minimum confidence to accept match

        Returns:
            EnrichmentResult with topics, genres, and entities
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=title,
            source=EnrichmentSource.OPEN_LIBRARY,
        )

        try:
            # Try direct ISBN lookup first (highest confidence)
            has_direct_id = False
            metadata = None
            result_count = 1

            if isbn:
                # TODO: Implement ISBN lookup endpoint
                # For now, fall through to title search
                pass

            # ENHANCEMENT: Extract author from title if not provided
            search_title = title
            search_author = author
            extracted_author = None

            if not author:
                search_title, extracted_author = extract_author_from_title(title)
                if extracted_author:
                    search_author = extracted_author
                    logger.info(f"[BOOK-ENRICH] Extracted author '{extracted_author}' from title '{title}'")

            # Search for the book - try with author first if available
            search_result = await self.search(search_title, search_author)

            # ENHANCEMENT: Two-pass search - if author search fails, try without author
            if not search_result and extracted_author:
                logger.info(f"[BOOK-ENRICH] No results with author, trying without: '{search_title}'")
                search_result = await self.search(search_title, None)

            # ENHANCEMENT: If still no results and title has a subtitle, try without subtitle
            # Books like "Business Model You: A One-Page Method..." often only match on main title
            if not search_result and ':' in search_title:
                main_title = search_title.split(':')[0].strip()
                if len(main_title) > 3:  # Avoid searching for very short titles
                    logger.info(f"[BOOK-ENRICH] No results with subtitle, trying main title only: '{main_title}'")
                    search_result = await self.search(main_title, search_author)
                    if search_result:
                        # Update search_title for confidence calculation
                        search_title = main_title

            if not search_result:
                result.error = f"Book not found: {title}"
                result.confidence = 0.0
                result.match_type = MatchType.NONE
                return result

            metadata = search_result.metadata
            result_count = search_result.result_count

            # Calculate confidence score using validation module
            # Use the cleaned search_title for comparison, not the original messy title
            confidence, match_type, breakdown = calculate_confidence(
                query=search_title,  # Use cleaned title for better matching
                result_title=metadata.title,
                result_authors=metadata.authors,
                query_author=search_author,  # Use extracted author for validation
                result_year=metadata.publish_year,
                preference_year=preference_year,
                result_count=result_count,
                has_direct_id=has_direct_id
            )

            result.confidence = confidence
            result.match_type = match_type
            result.confidence_breakdown = breakdown
            result.matched_title = metadata.title
            result.exact_match = (match_type == MatchType.EXACT_TITLE)

            # Check if we should accept this match
            if not should_accept_match(confidence, match_type, min_confidence):
                result.error = f"Low confidence match ({confidence:.2f}): '{title}' -> '{metadata.title}'"
                logger.warning(
                    f"Rejecting low-confidence match for '{title}': "
                    f"matched '{metadata.title}' with confidence {confidence:.2f}"
                )
                return result

            result.book_metadata = metadata

            # Get additional details if we have a work key
            if metadata.open_library_key:
                detailed = await self.get_details(metadata.open_library_key)
                if detailed:
                    # Merge subjects
                    all_subjects = set(metadata.subjects)
                    all_subjects.update(detailed.subjects)
                    metadata.subjects = list(all_subjects)[:15]

                    # Add description if missing
                    if not metadata.description and detailed.description:
                        metadata.description = detailed.description
                    if not metadata.first_sentence and detailed.first_sentence:
                        metadata.first_sentence = detailed.first_sentence

                    # Merge authors
                    if detailed.authors:
                        metadata.authors = detailed.authors

            # Convert subjects to topics (confidence based on overall match)
            topic_confidence = min(0.95, confidence + 0.05)  # Slightly boost if match is good
            for subject in metadata.subjects:
                normalized = self._normalize_subject(subject)
                result.topics.append(TopicResult(
                    name=subject,
                    normalized=normalized,
                    confidence=topic_confidence,
                    source_field="subjects"
                ))

            # Add genre based on subject patterns
            genre_keywords = {
                "fiction": "fiction",
                "non-fiction": "nonfiction",
                "nonfiction": "nonfiction",
                "biography": "biography",
                "autobiography": "autobiography",
                "memoir": "memoir",
                "history": "history",
                "science": "science",
                "fantasy": "fantasy",
                "mystery": "mystery",
                "thriller": "thriller",
                "romance": "romance",
                "horror": "horror",
            }

            for subject in metadata.subjects:
                lower = subject.lower()
                for keyword, genre in genre_keywords.items():
                    if keyword in lower:
                        result.genres.append(GenreResult(
                            name=subject,
                            normalized=genre,
                            confidence=topic_confidence * 0.9
                        ))
                        break

            # Add authors as entities
            for author_name in metadata.authors:
                result.entities.append(EntityResult(
                    name=author_name,
                    entity_type="author"
                ))

            logger.info(
                f"Enriched book '{title}' -> '{metadata.title}': "
                f"confidence={confidence:.2f}, match_type={match_type.value}, "
                f"{len(result.topics)} topics, {len(result.genres)} genres"
            )

        except Exception as e:
            logger.error(f"Error enriching book '{title}': {e}")
            result.error = str(e)

        return result
