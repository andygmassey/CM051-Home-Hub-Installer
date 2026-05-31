"""CrossRef API client for academic paper metadata from DOIs.

Enriches academic paper preferences with title, authors, abstract, journal,
subject areas, and keywords.

CrossRef API: https://api.crossref.org
- No API key required for polite pool (50 req/sec with email in User-Agent)
- Free tier with "mailto:" in query string gets better rate limits
"""

import logging
import re
from typing import Any, Dict, List, Optional
from urllib.parse import quote

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..models.enrichment import (
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    EntityResult,
    CrossRefAuthor,
    CrossRefMetadata,
)

logger = logging.getLogger(__name__)


def extract_doi(text: str) -> Optional[str]:
    """
    Extract DOI from various formats.

    Handles:
    - 10.xxxx/yyyy (bare DOI)
    - doi:10.xxxx/yyyy
    - https://doi.org/10.xxxx/yyyy
    - http://dx.doi.org/10.xxxx/yyyy

    Args:
        text: Text that may contain a DOI

    Returns:
        Extracted DOI or None
    """
    if not text:
        return None

    text = text.strip()

    # DOI pattern: 10.prefix/suffix (suffix can contain almost anything)
    # Standard format: 10.NNNN/something
    doi_pattern = r'10\.\d{4,}/[^\s]+'

    # Try to extract from URL first
    url_match = re.search(r'doi\.org/(10\.\d{4,}/[^\s]+)', text, re.IGNORECASE)
    if url_match:
        return url_match.group(1).rstrip('.')

    # Try to extract from doi: prefix
    prefix_match = re.search(r'doi:\s*(10\.\d{4,}/[^\s]+)', text, re.IGNORECASE)
    if prefix_match:
        return prefix_match.group(1).rstrip('.')

    # Try bare DOI
    bare_match = re.search(doi_pattern, text)
    if bare_match:
        return bare_match.group(0).rstrip('.')

    return None


def normalize_doi(doi: str) -> str:
    """
    Normalize a DOI to standard format.

    Args:
        doi: DOI in any format

    Returns:
        Normalized DOI (lowercase, no URL prefix)
    """
    extracted = extract_doi(doi)
    if extracted:
        return extracted.lower()
    return doi.lower()


# Map CrossRef types to human-readable labels
CROSSREF_TYPE_LABELS = {
    "journal-article": "Journal Article",
    "book-chapter": "Book Chapter",
    "proceedings-article": "Conference Paper",
    "book": "Book",
    "dissertation": "Dissertation",
    "report": "Report",
    "dataset": "Dataset",
    "posted-content": "Preprint",
    "peer-review": "Peer Review",
    "monograph": "Monograph",
    "reference-entry": "Reference Entry",
    "journal-issue": "Journal Issue",
    "component": "Component",
    "other": "Other",
}


class CrossRefClient(BaseClient[CrossRefMetadata]):
    """
    Client for CrossRef API.

    API Documentation: https://api.crossref.org/swagger-ui/index.html

    Features:
    - Get paper metadata by DOI
    - Search papers by title/query
    - Extract subjects, authors, citations
    - No API key required (polite pool with mailto)

    Rate limits:
    - Without mailto: ~50 req/sec (polite pool)
    - With mailto in query: Better rate limits
    """

    BASE_URL = "https://api.crossref.org"
    CACHE_PREFIX = "crossref"

    def __init__(
        self,
        mailto: Optional[str] = None,
        cache: Optional[InMemoryCache] = None
    ):
        """
        Initialize CrossRef client.

        Args:
            mailto: Email for polite pool (better rate limits)
            cache: Optional shared cache
        """
        super().__init__(
            rate_limit=settings.crossref_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.mailto = mailto or settings.crossref_mailto

    def _get_headers(self) -> Dict[str, str]:
        headers = {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0 (https://github.com/pwg; mailto:pwg@example.com)",
        }
        return headers

    async def _get(
        self,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        use_cache: bool = True,
        cache_key: Optional[str] = None,
    ) -> Optional[Dict[str, Any]]:
        """Override to add mailto parameter for polite pool."""
        if params is None:
            params = {}
        if self.mailto:
            params["mailto"] = self.mailto
        return await super()._get(endpoint, params, use_cache, cache_key)

    async def get_by_doi(self, doi: str) -> Optional[CrossRefMetadata]:
        """
        Get paper metadata by DOI.

        Args:
            doi: DOI in any format (bare, URL, or with doi: prefix)

        Returns:
            CrossRefMetadata or None if not found
        """
        # Normalize DOI
        normalized = normalize_doi(doi)
        if not normalized:
            logger.warning(f"Invalid DOI format: {doi}")
            return None

        # URL encode the DOI (it may contain special chars like < > [ ])
        encoded_doi = quote(normalized, safe='')

        result = await self._get(
            f"/works/{encoded_doi}",
            cache_key=f"doi:{normalized}"
        )

        if not result or "message" not in result:
            logger.debug(f"DOI not found: {normalized}")
            return None

        return self._parse_work(result["message"])

    async def search(self, query: str, rows: int = 5) -> List[CrossRefMetadata]:
        """
        Search for papers by query.

        Args:
            query: Search query (title, author, etc.)
            rows: Maximum results to return

        Returns:
            List of matching papers
        """
        params = {
            "query": query,
            "rows": rows,
            "select": "DOI,title,author,abstract,container-title,publisher,"
                      "published,type,subject,is-referenced-by-count,"
                      "references-count,URL,ISSN,ISBN,license,funder"
        }

        result = await self._get("/works", params=params, cache_key=f"search:{query}:{rows}")

        if not result or "message" not in result:
            return []

        items = result["message"].get("items", [])
        return [self._parse_work(item) for item in items if item]

    async def search_by_title(
        self,
        title: str,
        author: Optional[str] = None,
        rows: int = 5
    ) -> List[CrossRefMetadata]:
        """
        Search for papers by title with optional author filter.

        Args:
            title: Paper title
            author: Optional author name to filter by
            rows: Maximum results

        Returns:
            List of matching papers
        """
        params = {
            "query.title": title,
            "rows": rows,
            "select": "DOI,title,author,abstract,container-title,publisher,"
                      "published,type,subject,is-referenced-by-count,"
                      "references-count,URL,ISSN,ISBN,license,funder"
        }

        if author:
            params["query.author"] = author

        cache_key = f"title:{title}:author:{author}:{rows}"
        result = await self._get("/works", params=params, cache_key=cache_key)

        if not result or "message" not in result:
            return []

        items = result["message"].get("items", [])
        return [self._parse_work(item) for item in items if item]

    def _parse_work(self, item: Dict[str, Any]) -> CrossRefMetadata:
        """Parse a work item from CrossRef API response."""
        # Parse title (may be a list)
        title_data = item.get("title", [])
        title = title_data[0] if title_data else "Unknown"

        # Parse authors
        authors = []
        for author_data in item.get("author", []):
            author = CrossRefAuthor(
                given=author_data.get("given", ""),
                family=author_data.get("family", ""),
                orcid=author_data.get("ORCID"),
                affiliation=[
                    aff.get("name", "")
                    for aff in author_data.get("affiliation", [])
                ]
            )
            authors.append(author)

        # Parse abstract (remove JATS tags if present)
        abstract = item.get("abstract")
        if abstract:
            # Remove JATS XML tags like <jats:p>, <jats:title>, etc.
            abstract = re.sub(r'<[^>]+>', '', abstract)
            abstract = abstract.strip()

        # Parse published date
        published_date = None
        published = item.get("published") or item.get("published-print") or item.get("published-online")
        if published and "date-parts" in published:
            date_parts = published["date-parts"]
            if date_parts and date_parts[0]:
                parts = date_parts[0]
                if len(parts) >= 3:
                    published_date = f"{parts[0]:04d}-{parts[1]:02d}-{parts[2]:02d}"
                elif len(parts) >= 2:
                    published_date = f"{parts[0]:04d}-{parts[1]:02d}"
                elif len(parts) >= 1:
                    published_date = f"{parts[0]:04d}"

        # Parse container title (journal/conference name)
        container = item.get("container-title", [])
        container_title = container[0] if container else ""

        # Parse subjects
        subjects = item.get("subject", [])

        # Parse license
        license_data = item.get("license", [])
        license_url = license_data[0].get("URL") if license_data else None

        # Parse funders
        funders = [
            f.get("name", "")
            for f in item.get("funder", [])
            if f.get("name")
        ]

        return CrossRefMetadata(
            doi=item.get("DOI", ""),
            title=title,
            authors=authors,
            abstract=abstract,
            container_title=container_title,
            publisher=item.get("publisher", ""),
            published_date=published_date,
            type=item.get("type", ""),
            subjects=subjects,
            keywords=[],  # CrossRef doesn't typically have keywords
            issn=item.get("ISSN", []),
            isbn=item.get("ISBN", []),
            url=item.get("URL"),
            references_count=item.get("references-count", 0),
            is_referenced_by_count=item.get("is-referenced-by-count", 0),
            license=license_url,
            funder=funders,
        )

    def _normalize_topic(self, topic: str) -> str:
        """Normalize a topic string to a topic ID."""
        normalized = topic.lower().strip()

        # Check for custom mappings
        if normalized in settings.topic_mappings:
            return settings.topic_mappings[normalized]

        # Replace special chars and spaces
        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", "_", normalized)

        return normalized

    async def enrich_paper(
        self,
        preference_id: str,
        doi_or_title: str,
        min_confidence: float = 0.7
    ) -> EnrichmentResult:
        """
        Enrich an academic paper preference with metadata.

        Args:
            preference_id: PWG preference ID
            doi_or_title: DOI or paper title
            min_confidence: Minimum confidence for title search matches

        Returns:
            EnrichmentResult with topics, entities, and metadata
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=doi_or_title,
            source=EnrichmentSource.CROSSREF,
        )

        try:
            # Check if input is a DOI
            extracted_doi = extract_doi(doi_or_title)

            if extracted_doi:
                # Direct DOI lookup - high confidence
                metadata = await self.get_by_doi(extracted_doi)

                if metadata:
                    result.confidence = 0.95
                    result.match_type = MatchType.DIRECT_ID
                    result.exact_match = True
                else:
                    result.error = f"DOI not found: {extracted_doi}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result
            else:
                # Title search - lower confidence
                papers = await self.search_by_title(doi_or_title, rows=3)

                if not papers:
                    result.error = f"No papers found for: {doi_or_title}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

                # Take first result
                metadata = papers[0]

                # Calculate confidence based on title similarity
                from .validation import title_similarity
                similarity = title_similarity(doi_or_title, metadata.title)

                if similarity >= 0.9:
                    result.confidence = 0.85
                    result.match_type = MatchType.EXACT_TITLE
                    result.exact_match = True
                elif similarity >= 0.7:
                    result.confidence = similarity * 0.8
                    result.match_type = MatchType.FUZZY_TITLE
                else:
                    result.confidence = similarity * 0.6
                    result.match_type = MatchType.BEST_GUESS

                if result.confidence < min_confidence:
                    result.error = f"Low confidence match ({result.confidence:.2f}): {metadata.title}"
                    return result

            # Store metadata
            result.matched_title = metadata.title
            result.crossref_metadata = metadata

            # Add subjects as topics
            for subject in metadata.subjects:
                normalized = self._normalize_topic(subject)
                result.topics.append(TopicResult(
                    name=subject,
                    normalized=normalized,
                    confidence=0.9,
                    source_field="subjects"
                ))

            # Add paper type as topic
            if metadata.type:
                type_label = CROSSREF_TYPE_LABELS.get(metadata.type, metadata.type)
                result.topics.append(TopicResult(
                    name=type_label,
                    normalized=self._normalize_topic(type_label),
                    confidence=0.95,
                    source_field="type"
                ))

            # Add journal/conference as entity
            if metadata.container_title:
                result.entities.append(EntityResult(
                    name=metadata.container_title,
                    entity_type="journal" if "article" in metadata.type else "publication",
                    external_id=metadata.issn[0] if metadata.issn else None
                ))

            # Add authors as entities
            for author in metadata.authors[:5]:  # Limit to first 5 authors
                result.entities.append(EntityResult(
                    name=author.full_name,
                    entity_type="author",
                    external_id=author.orcid
                ))

            # Add publisher as entity
            if metadata.publisher:
                result.entities.append(EntityResult(
                    name=metadata.publisher,
                    entity_type="publisher"
                ))

            logger.info(
                f"Enriched paper '{metadata.title}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities, "
                f"{metadata.citation_count} citations"
            )

        except Exception as e:
            logger.error(f"Error enriching paper '{doi_or_title}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def get_details(self, item_id: str) -> Optional[CrossRefMetadata]:
        """Get paper details by DOI."""
        return await self.get_by_doi(item_id)
