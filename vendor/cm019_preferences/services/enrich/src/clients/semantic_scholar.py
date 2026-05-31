"""Semantic Scholar API client for academic paper enrichment.

Provides citation networks, paper topics, influential citations, and TLDR summaries.
Complements CrossRef with more ML-specific paper analysis.

Semantic Scholar API: https://api.semanticscholar.org/
- API key optional (higher limits with key)
- Rate limit: 100 req/5min without key, higher with key
"""

import logging
import re
from typing import Any, Dict, List, Optional

from .base import BaseClient, InMemoryCache
from ..config import settings
from ..models.enrichment import (
    EnrichmentResult,
    EnrichmentSource,
    MatchType,
    TopicResult,
    EntityResult,
    SemanticScholarAuthor,
    SemanticScholarPaper,
)

logger = logging.getLogger(__name__)


def extract_s2_paper_id(text: str) -> Optional[str]:
    """
    Extract Semantic Scholar paper ID from various formats.

    Handles:
    - Bare S2 ID (40-char hex)
    - CorpusId:NNNNNN
    - DOI:10.xxxx/yyyy
    - ArXiv:NNNN.NNNNN
    - PMID:NNNNNNNN
    - URL: https://www.semanticscholar.org/paper/xxx/ID

    Args:
        text: Text that may contain a paper identifier

    Returns:
        Extracted identifier in API format or None
    """
    if not text:
        return None

    text = text.strip()

    # S2 URL pattern
    url_match = re.search(r'semanticscholar\.org/paper/[^/]+/([a-f0-9]{40})', text, re.IGNORECASE)
    if url_match:
        return url_match.group(1)

    # Bare S2 ID (40-char hex)
    if re.match(r'^[a-f0-9]{40}$', text, re.IGNORECASE):
        return text

    # CorpusId format
    corpus_match = re.match(r'^(?:corpusid:)?(\d+)$', text, re.IGNORECASE)
    if corpus_match:
        return f"CorpusId:{corpus_match.group(1)}"

    # DOI format
    doi_match = re.search(r'(10\.\d{4,}/[^\s]+)', text)
    if doi_match:
        return f"DOI:{doi_match.group(1)}"

    # ArXiv format
    arxiv_match = re.search(r'(?:arxiv:)?(\d{4}\.\d{4,5}(?:v\d+)?)', text, re.IGNORECASE)
    if arxiv_match:
        return f"ArXiv:{arxiv_match.group(1)}"

    # PMID format
    pmid_match = re.match(r'^(?:pmid:)?(\d{7,8})$', text, re.IGNORECASE)
    if pmid_match:
        return f"PMID:{pmid_match.group(1)}"

    return None


class SemanticScholarClient(BaseClient[SemanticScholarPaper]):
    """
    Client for Semantic Scholar API.

    API Documentation: https://api.semanticscholar.org/api-docs/

    Features:
    - Get paper details by various IDs (S2, DOI, ArXiv, PMID)
    - Search papers by query
    - Get citation network and influential citations
    - Access TLDR summaries (ML-generated abstracts)
    - Get author details and h-index

    Rate limits:
    - Without API key: 100 requests per 5 minutes
    - With API key: Higher limits (apply at semanticscholar.org)
    """

    BASE_URL = "https://api.semanticscholar.org/graph/v1"
    CACHE_PREFIX = "semantic_scholar"

    # Fields to request from API
    PAPER_FIELDS = [
        "paperId", "title", "abstract", "year", "venue", "url",
        "citationCount", "influentialCitationCount", "referenceCount",
        "fieldsOfStudy", "s2FieldsOfStudy", "publicationTypes",
        "authors", "authors.authorId", "authors.name", "authors.url",
        "tldr", "isOpenAccess", "openAccessPdf",
        "externalIds"
    ]

    AUTHOR_FIELDS = [
        "authorId", "name", "url", "hIndex", "paperCount", "citationCount"
    ]

    def __init__(
        self,
        api_key: Optional[str] = None,
        cache: Optional[InMemoryCache] = None
    ):
        """
        Initialize Semantic Scholar client.

        Args:
            api_key: Optional API key for higher rate limits
            cache: Optional shared cache
        """
        super().__init__(
            rate_limit=settings.semantic_scholar_rate_limit,
            max_retries=settings.max_retries,
            timeout=settings.request_timeout,
            cache=cache,
        )
        self.api_key = api_key or settings.semantic_scholar_api_key

    def _get_headers(self) -> Dict[str, str]:
        headers = {
            "Accept": "application/json",
            "User-Agent": "PWG-Enrichment/0.1.0",
        }
        if self.api_key:
            headers["x-api-key"] = self.api_key
        return headers

    async def get_paper(self, paper_id: str) -> Optional[SemanticScholarPaper]:
        """
        Get paper details by ID.

        Args:
            paper_id: Paper ID in any supported format:
                - S2 ID (40-char hex)
                - CorpusId:NNNNNN
                - DOI:10.xxxx/yyyy
                - ArXiv:NNNN.NNNNN
                - PMID:NNNNNNNN

        Returns:
            SemanticScholarPaper or None if not found
        """
        # Try to normalize the ID
        normalized_id = extract_s2_paper_id(paper_id) or paper_id

        params = {
            "fields": ",".join(self.PAPER_FIELDS)
        }

        result = await self._get(
            f"/paper/{normalized_id}",
            params=params,
            cache_key=f"paper:{normalized_id}"
        )

        if not result:
            logger.debug(f"Paper not found: {paper_id}")
            return None

        return self._parse_paper(result)

    async def search(self, query: str, limit: int = 10) -> List[SemanticScholarPaper]:
        """
        Search for papers by query.

        Args:
            query: Search query
            limit: Maximum results (max 100)

        Returns:
            List of matching papers
        """
        params = {
            "query": query,
            "limit": min(limit, 100),
            "fields": ",".join(self.PAPER_FIELDS)
        }

        result = await self._get(
            "/paper/search",
            params=params,
            cache_key=f"search:{query}:{limit}"
        )

        if not result or "data" not in result:
            return []

        return [self._parse_paper(item) for item in result["data"] if item]

    async def get_paper_citations(
        self,
        paper_id: str,
        limit: int = 50
    ) -> List[SemanticScholarPaper]:
        """
        Get papers that cite this paper.

        Args:
            paper_id: Paper ID
            limit: Maximum citations to return

        Returns:
            List of citing papers
        """
        normalized_id = extract_s2_paper_id(paper_id) or paper_id

        params = {
            "limit": min(limit, 1000),
            "fields": "paperId,title,year,citationCount,authors"
        }

        result = await self._get(
            f"/paper/{normalized_id}/citations",
            params=params,
            cache_key=f"citations:{normalized_id}:{limit}"
        )

        if not result or "data" not in result:
            return []

        papers = []
        for item in result["data"]:
            citing_paper = item.get("citingPaper")
            if citing_paper:
                papers.append(self._parse_paper(citing_paper))

        return papers

    async def get_paper_references(
        self,
        paper_id: str,
        limit: int = 50
    ) -> List[SemanticScholarPaper]:
        """
        Get papers referenced by this paper.

        Args:
            paper_id: Paper ID
            limit: Maximum references to return

        Returns:
            List of referenced papers
        """
        normalized_id = extract_s2_paper_id(paper_id) or paper_id

        params = {
            "limit": min(limit, 1000),
            "fields": "paperId,title,year,citationCount,authors"
        }

        result = await self._get(
            f"/paper/{normalized_id}/references",
            params=params,
            cache_key=f"references:{normalized_id}:{limit}"
        )

        if not result or "data" not in result:
            return []

        papers = []
        for item in result["data"]:
            cited_paper = item.get("citedPaper")
            if cited_paper:
                papers.append(self._parse_paper(cited_paper))

        return papers

    async def get_author(self, author_id: str) -> Optional[SemanticScholarAuthor]:
        """
        Get author details.

        Args:
            author_id: Semantic Scholar author ID

        Returns:
            SemanticScholarAuthor or None
        """
        params = {
            "fields": ",".join(self.AUTHOR_FIELDS)
        }

        result = await self._get(
            f"/author/{author_id}",
            params=params,
            cache_key=f"author:{author_id}"
        )

        if not result:
            return None

        return SemanticScholarAuthor(
            author_id=result.get("authorId"),
            name=result.get("name", ""),
            url=result.get("url"),
            h_index=result.get("hIndex"),
            paper_count=result.get("paperCount"),
            citation_count=result.get("citationCount"),
        )

    def _parse_paper(self, item: Dict[str, Any]) -> SemanticScholarPaper:
        """Parse a paper item from API response."""
        # Parse authors
        authors = []
        for author_data in item.get("authors", []):
            author = SemanticScholarAuthor(
                author_id=author_data.get("authorId"),
                name=author_data.get("name", ""),
                url=author_data.get("url"),
            )
            authors.append(author)

        # Parse external IDs
        external_ids = item.get("externalIds", {}) or {}

        # Parse TLDR
        tldr = None
        tldr_data = item.get("tldr")
        if tldr_data and isinstance(tldr_data, dict):
            tldr = tldr_data.get("text")

        # Parse open access PDF
        open_access_pdf = None
        pdf_data = item.get("openAccessPdf")
        if pdf_data and isinstance(pdf_data, dict):
            open_access_pdf = pdf_data.get("url")

        return SemanticScholarPaper(
            paper_id=item.get("paperId", ""),
            title=item.get("title", "Unknown"),
            abstract=item.get("abstract"),
            year=item.get("year"),
            venue=item.get("venue", ""),
            url=item.get("url"),
            doi=external_ids.get("DOI"),
            citation_count=item.get("citationCount", 0),
            influential_citation_count=item.get("influentialCitationCount", 0),
            reference_count=item.get("referenceCount", 0),
            fields_of_study=item.get("fieldsOfStudy") or [],
            s2_fields_of_study=item.get("s2FieldsOfStudy") or [],
            publication_types=item.get("publicationTypes") or [],
            authors=authors,
            tldr=tldr,
            is_open_access=item.get("isOpenAccess", False),
            open_access_pdf=open_access_pdf,
            arxiv_id=external_ids.get("ArXiv"),
            pubmed_id=external_ids.get("PubMed"),
            corpus_id=external_ids.get("CorpusId"),
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
        paper_id_or_title: str,
        min_confidence: float = 0.7
    ) -> EnrichmentResult:
        """
        Enrich an academic paper preference with Semantic Scholar data.

        Args:
            preference_id: PWG preference ID
            paper_id_or_title: Paper ID (S2, DOI, ArXiv) or title
            min_confidence: Minimum confidence for title matches

        Returns:
            EnrichmentResult with topics, entities, and metadata
        """
        result = EnrichmentResult(
            preference_id=preference_id,
            original_subject=paper_id_or_title,
            source=EnrichmentSource.SEMANTIC_SCHOLAR,
        )

        try:
            # Check if input looks like an ID
            extracted_id = extract_s2_paper_id(paper_id_or_title)

            if extracted_id:
                # Direct ID lookup
                metadata = await self.get_paper(extracted_id)

                if metadata:
                    result.confidence = 0.95
                    result.match_type = MatchType.DIRECT_ID
                    result.exact_match = True
                else:
                    result.error = f"Paper ID not found: {extracted_id}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result
            else:
                # Title search
                papers = await self.search(paper_id_or_title, limit=5)

                if not papers:
                    result.error = f"No papers found for: {paper_id_or_title}"
                    result.confidence = 0.0
                    result.match_type = MatchType.NONE
                    return result

                # Take best matching result
                metadata = papers[0]

                # Calculate confidence based on title similarity
                from .validation import title_similarity
                similarity = title_similarity(paper_id_or_title, metadata.title)

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
            result.semantic_scholar_metadata = metadata

            # Add fields of study as topics
            for field_name in metadata.top_fields(limit=10):
                normalized = self._normalize_topic(field_name)
                result.topics.append(TopicResult(
                    name=field_name,
                    normalized=normalized,
                    confidence=0.9,
                    source_field="fieldsOfStudy"
                ))

            # Add publication type as topic
            for pub_type in metadata.publication_types[:2]:
                result.topics.append(TopicResult(
                    name=pub_type,
                    normalized=self._normalize_topic(pub_type),
                    confidence=0.85,
                    source_field="publicationTypes"
                ))

            # Add venue as entity
            if metadata.venue:
                result.entities.append(EntityResult(
                    name=metadata.venue,
                    entity_type="venue",
                ))

            # Add authors as entities
            for author in metadata.authors[:5]:
                entity = EntityResult(
                    name=author.name,
                    entity_type="author",
                    external_id=author.author_id
                )
                result.entities.append(entity)

            # Add citation info as a special topic
            if metadata.citation_count > 0:
                citation_tier = "highly_cited" if metadata.citation_count > 100 else "cited"
                result.topics.append(TopicResult(
                    name=f"{citation_tier} ({metadata.citation_count} citations)",
                    normalized=citation_tier,
                    confidence=0.95,
                    source_field="citationCount"
                ))

            # Add TLDR if available
            if metadata.has_tldr:
                result.entities.append(EntityResult(
                    name=metadata.tldr[:200] if metadata.tldr else "",
                    entity_type="tldr_summary"
                ))

            logger.info(
                f"Enriched paper '{metadata.title}': "
                f"{len(result.topics)} topics, {len(result.entities)} entities, "
                f"{metadata.citation_count} citations, {metadata.influential_citation_count} influential"
            )

        except Exception as e:
            logger.error(f"Error enriching paper '{paper_id_or_title}': {e}")
            result.error = str(e)

        return result

    # Required abstract method implementations
    async def get_details(self, item_id: str) -> Optional[SemanticScholarPaper]:
        """Get paper details by ID."""
        return await self.get_paper(item_id)
