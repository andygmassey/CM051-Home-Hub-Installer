"""Data models for enrichment results."""

from dataclasses import dataclass, field
from typing import List, Optional
from datetime import datetime
from enum import Enum


class EnrichmentSource(str, Enum):
    """External API sources for enrichment."""
    OPEN_LIBRARY = "open_library"
    TMDB = "tmdb"
    MUSICBRAINZ = "musicbrainz"
    WIKIDATA = "wikidata"
    YOUTUBE = "youtube"
    GEOCODER = "geocoder"
    PLACES = "places"
    PODCAST_INDEX = "podcast_index"
    CROSSREF = "crossref"
    SEMANTIC_SCHOLAR = "semantic_scholar"
    OPENFOODFACTS = "openfoodfacts"
    FOURSQUARE = "foursquare"
    SPOONACULAR = "spoonacular"
    TICKETMASTER = "ticketmaster"
    EVENTBRITE = "eventbrite"
    BRAND_WIKIDATA = "brand_wikidata"
    DOMAIN_MAPPING = "domain_mapping"  # Domain-based topic inference (no API)
    UNKNOWN = "unknown"


class MatchType(str, Enum):
    """How the enrichment match was made."""
    DIRECT_ID = "direct_id"       # Looked up by ID (ISBN, TMDB ID, etc.) - highest confidence
    EXACT_TITLE = "exact_title"   # Exact title match
    FUZZY_TITLE = "fuzzy_title"   # Fuzzy/partial title match
    BEST_GUESS = "best_guess"     # First result, no validation
    NONE = "none"                 # No match found


@dataclass
class TopicResult:
    """A single topic extracted from enrichment."""
    name: str
    normalized: str  # Normalized topic ID (e.g., "behavioral_economics")
    confidence: float = 1.0
    source_field: str = ""  # Which API field this came from (e.g., "subjects")


@dataclass
class GenreResult:
    """A single genre extracted from enrichment."""
    name: str
    normalized: str
    confidence: float = 1.0


@dataclass
class EntityResult:
    """A named entity (person, organization, etc.)."""
    name: str
    entity_type: str  # "author", "director", "artist", "actor", etc.
    external_id: Optional[str] = None  # ID in external system


@dataclass
class BookMetadata:
    """Metadata from Open Library for a book."""
    title: str
    authors: List[str] = field(default_factory=list)
    subjects: List[str] = field(default_factory=list)
    description: Optional[str] = None
    publish_year: Optional[int] = None
    isbn: Optional[str] = None
    open_library_key: Optional[str] = None
    cover_url: Optional[str] = None
    first_sentence: Optional[str] = None
    number_of_pages: Optional[int] = None


@dataclass
class WatchProvider:
    """A streaming/rental provider for a movie or TV show."""
    provider_id: int
    provider_name: str
    logo_path: Optional[str] = None
    display_priority: int = 0


@dataclass
class SimilarTitle:
    """A similar or recommended movie/TV show."""
    tmdb_id: int
    title: str
    media_type: str  # "movie" or "tv"
    overview: Optional[str] = None
    release_date: Optional[str] = None
    vote_average: Optional[float] = None
    poster_path: Optional[str] = None
    genres: List[str] = field(default_factory=list)


@dataclass
class MovieMetadata:
    """Metadata from TMDB for a movie or TV show."""
    title: str
    media_type: str  # "movie" or "tv"
    genres: List[str] = field(default_factory=list)
    keywords: List[str] = field(default_factory=list)
    overview: Optional[str] = None
    release_date: Optional[str] = None
    tmdb_id: Optional[int] = None
    poster_path: Optional[str] = None
    vote_average: Optional[float] = None
    vote_count: Optional[int] = None
    cast: List[str] = field(default_factory=list)
    director: Optional[str] = None
    production_companies: List[str] = field(default_factory=list)

    # New fields for enhanced recommendations
    runtime: Optional[int] = None  # Minutes for movies, avg episode length for TV
    episode_count: Optional[int] = None  # For TV shows
    season_count: Optional[int] = None  # For TV shows
    status: Optional[str] = None  # "Released", "Ended", "Returning Series", etc.

    # Content ratings and warnings
    content_rating: Optional[str] = None  # "PG-13", "R", "TV-MA", etc.
    content_rating_description: Optional[str] = None  # Reason for rating if available

    # Streaming availability
    watch_providers_flatrate: List[WatchProvider] = field(default_factory=list)  # Subscription (Netflix, etc.)
    watch_providers_rent: List[WatchProvider] = field(default_factory=list)  # Rental
    watch_providers_buy: List[WatchProvider] = field(default_factory=list)  # Purchase

    # Discovery - similar and recommended titles
    similar_titles: List[SimilarTitle] = field(default_factory=list)
    recommendations: List[SimilarTitle] = field(default_factory=list)

    # Additional useful fields
    tagline: Optional[str] = None
    original_language: Optional[str] = None
    spoken_languages: List[str] = field(default_factory=list)
    imdb_id: Optional[str] = None

    @property
    def is_horror(self) -> bool:
        """Check if this is a horror title (for filtering)."""
        horror_keywords = {"horror", "slasher", "gore", "scary", "nightmare", "demon", "possessed"}
        genres_lower = {g.lower() for g in self.genres}
        keywords_lower = {k.lower() for k in self.keywords}
        return "horror" in genres_lower or bool(horror_keywords & keywords_lower)

    @property
    def runtime_display(self) -> str:
        """Get human-readable runtime."""
        if not self.runtime:
            return ""
        if self.runtime < 60:
            return f"{self.runtime}m"
        hours = self.runtime // 60
        mins = self.runtime % 60
        return f"{hours}h {mins}m" if mins else f"{hours}h"

    @property
    def available_on_streaming(self) -> List[str]:
        """Get list of streaming service names where available."""
        return [p.provider_name for p in self.watch_providers_flatrate]


@dataclass
class MusicMetadata:
    """Metadata from MusicBrainz for music."""
    name: str  # Artist or track name
    entity_type: str  # "artist", "recording", "release"
    tags: List[str] = field(default_factory=list)
    genres: List[str] = field(default_factory=list)
    country: Optional[str] = None
    begin_date: Optional[str] = None
    end_date: Optional[str] = None
    musicbrainz_id: Optional[str] = None
    disambiguation: Optional[str] = None
    related_artists: List[str] = field(default_factory=list)
    wikidata_id: Optional[str] = None  # Wikidata Q-ID (e.g., "Q44190" for Radiohead)


@dataclass
class YouTubeVideoMetadata:
    """Metadata from YouTube Data API for a video."""
    video_id: str
    title: str
    description: Optional[str] = None
    channel_id: Optional[str] = None
    channel_title: Optional[str] = None
    category_id: Optional[int] = None
    category_name: Optional[str] = None
    tags: List[str] = field(default_factory=list)
    duration: Optional[str] = None  # ISO 8601 duration (e.g., "PT5M30S")
    duration_seconds: Optional[int] = None
    published_at: Optional[str] = None
    view_count: Optional[int] = None
    like_count: Optional[int] = None
    thumbnail_url: Optional[str] = None
    default_language: Optional[str] = None
    topic_categories: List[str] = field(default_factory=list)  # Wikipedia URLs from topicDetails


@dataclass
class YouTubeChannelMetadata:
    """Metadata from YouTube Data API for a channel."""
    channel_id: str
    title: str
    description: Optional[str] = None
    custom_url: Optional[str] = None
    country: Optional[str] = None
    published_at: Optional[str] = None
    subscriber_count: Optional[int] = None
    video_count: Optional[int] = None
    view_count: Optional[int] = None
    topic_categories: List[str] = field(default_factory=list)  # Wikipedia URLs
    keywords: List[str] = field(default_factory=list)
    thumbnail_url: Optional[str] = None


@dataclass
class PodcastMetadata:
    """Metadata from Podcast Index for a podcast."""
    feed_id: int
    title: str
    author: str = ""
    description: str = ""
    categories: List[str] = field(default_factory=list)  # Category names
    language: str = ""
    explicit: bool = False
    episode_count: int = 0
    keywords: List[str] = field(default_factory=list)
    image_url: str = ""
    website: str = ""
    itunes_id: Optional[int] = None
    confidence: float = 0.0


@dataclass
class PodcastEpisodeMetadata:
    """Metadata from Podcast Index for a podcast episode."""
    episode_id: int
    title: str
    description: str = ""
    feed_id: Optional[int] = None
    podcast_title: str = ""
    duration_seconds: Optional[int] = None
    published_at: Optional[int] = None  # Unix timestamp
    episode_number: Optional[int] = None
    season_number: Optional[int] = None
    link: str = ""
    enclosure_url: str = ""


@dataclass
class CrossRefAuthor:
    """Author information from CrossRef."""
    given: str = ""
    family: str = ""
    orcid: Optional[str] = None
    affiliation: List[str] = field(default_factory=list)

    @property
    def full_name(self) -> str:
        """Get full name as 'Given Family'."""
        parts = []
        if self.given:
            parts.append(self.given)
        if self.family:
            parts.append(self.family)
        return " ".join(parts) if parts else "Unknown"


@dataclass
class CrossRefMetadata:
    """Metadata from CrossRef for an academic paper."""
    doi: str
    title: str
    authors: List[CrossRefAuthor] = field(default_factory=list)
    abstract: Optional[str] = None
    container_title: str = ""  # Journal/conference name
    publisher: str = ""
    published_date: Optional[str] = None  # YYYY-MM-DD or YYYY-MM or YYYY
    type: str = ""  # journal-article, book-chapter, proceedings-article, etc.
    subjects: List[str] = field(default_factory=list)
    keywords: List[str] = field(default_factory=list)
    issn: List[str] = field(default_factory=list)
    isbn: List[str] = field(default_factory=list)
    url: Optional[str] = None
    references_count: int = 0
    is_referenced_by_count: int = 0  # Citation count
    license: Optional[str] = None
    funder: List[str] = field(default_factory=list)

    @property
    def citation_count(self) -> int:
        """Alias for is_referenced_by_count."""
        return self.is_referenced_by_count


@dataclass
class SemanticScholarAuthor:
    """Author information from Semantic Scholar."""
    author_id: Optional[str] = None
    name: str = ""
    url: Optional[str] = None
    h_index: Optional[int] = None
    paper_count: Optional[int] = None
    citation_count: Optional[int] = None


@dataclass
class SemanticScholarPaper:
    """Paper metadata from Semantic Scholar."""
    paper_id: str
    title: str
    abstract: Optional[str] = None
    year: Optional[int] = None
    venue: str = ""
    url: Optional[str] = None
    doi: Optional[str] = None
    citation_count: int = 0
    influential_citation_count: int = 0
    reference_count: int = 0
    fields_of_study: List[str] = field(default_factory=list)
    s2_fields_of_study: List[dict] = field(default_factory=list)
    publication_types: List[str] = field(default_factory=list)
    authors: List[SemanticScholarAuthor] = field(default_factory=list)
    tldr: Optional[str] = None
    is_open_access: bool = False
    open_access_pdf: Optional[str] = None
    arxiv_id: Optional[str] = None
    pubmed_id: Optional[str] = None
    corpus_id: Optional[int] = None

    @property
    def has_tldr(self) -> bool:
        """Check if paper has a TLDR summary."""
        return self.tldr is not None and len(self.tldr) > 0

    def top_fields(self, limit: int = 5) -> List[str]:
        """Get top fields of study by confidence score."""
        if self.s2_fields_of_study:
            sorted_fields = sorted(
                self.s2_fields_of_study,
                key=lambda x: x.get("score", 0),
                reverse=True
            )
            return [f["category"] for f in sorted_fields[:limit] if "category" in f]
        return self.fields_of_study[:limit]


@dataclass
class NutrientInfo:
    """Nutritional information for a product."""
    energy_kcal: Optional[float] = None
    fat: Optional[float] = None
    saturated_fat: Optional[float] = None
    carbohydrates: Optional[float] = None
    sugars: Optional[float] = None
    fiber: Optional[float] = None
    proteins: Optional[float] = None
    salt: Optional[float] = None
    sodium: Optional[float] = None


@dataclass
class FoodProductMetadata:
    """Metadata from Open Food Facts for a food product."""
    barcode: str
    product_name: str
    brand: str = ""
    brands_tags: List[str] = field(default_factory=list)
    categories: List[str] = field(default_factory=list)
    categories_hierarchy: List[str] = field(default_factory=list)
    ingredients_text: str = ""
    ingredients_tags: List[str] = field(default_factory=list)
    allergens: List[str] = field(default_factory=list)
    traces: List[str] = field(default_factory=list)
    nutriscore_grade: Optional[str] = None
    nutriscore_score: Optional[int] = None
    nova_group: Optional[int] = None
    ecoscore_grade: Optional[str] = None
    labels: List[str] = field(default_factory=list)
    labels_tags: List[str] = field(default_factory=list)
    countries: List[str] = field(default_factory=list)
    origins: List[str] = field(default_factory=list)
    packaging: List[str] = field(default_factory=list)
    image_url: Optional[str] = None
    image_front_url: Optional[str] = None
    nutrients: Optional[NutrientInfo] = None
    serving_size: Optional[str] = None
    quantity: Optional[str] = None

    @property
    def is_organic(self) -> bool:
        """Check if product is organic."""
        organic_labels = {"en:organic", "en:eu-organic", "en:usda-organic"}
        return bool(organic_labels & set(self.labels_tags))

    @property
    def is_vegan(self) -> bool:
        """Check if product is vegan."""
        return "en:vegan" in self.labels_tags

    @property
    def is_vegetarian(self) -> bool:
        """Check if product is vegetarian."""
        return "en:vegetarian" in self.labels_tags or self.is_vegan

    @property
    def is_gluten_free(self) -> bool:
        """Check if product is gluten-free."""
        return "en:gluten-free" in self.labels_tags


@dataclass
class AmazonProductMetadata:
    """Metadata for an Amazon product."""
    asin: str
    title: str
    brand: str = ""
    category: str = ""
    category_hierarchy: List[str] = field(default_factory=list)
    price: Optional[str] = None
    rating: Optional[float] = None
    review_count: Optional[int] = None
    description: str = ""
    features: List[str] = field(default_factory=list)
    image_url: Optional[str] = None
    amazon_url: str = ""
    product_type: str = ""
    is_available: bool = True


@dataclass
class UPCProductMetadata:
    """Metadata for a product from UPC/barcode lookup."""
    barcode: str
    title: str
    brand: str = ""
    manufacturer: str = ""
    category: str = ""
    description: str = ""
    size: str = ""
    weight: str = ""
    image_url: Optional[str] = None
    source: str = ""
    gpc_code: Optional[str] = None
    gpc_category: str = ""


@dataclass
class FoursquareCategory:
    """A Foursquare venue category."""
    id: int
    name: str
    short_name: str = ""
    plural_name: str = ""
    icon_prefix: str = ""
    icon_suffix: str = ""


@dataclass
class FoursquareLocation:
    """Location details from Foursquare."""
    address: str = ""
    address_extended: str = ""
    locality: str = ""
    region: str = ""
    postcode: str = ""
    country: str = ""
    cross_street: str = ""
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    formatted_address: str = ""


@dataclass
class FoursquareVenueMetadata:
    """Metadata from Foursquare for a venue."""
    fsq_id: str
    name: str
    categories: List[FoursquareCategory] = field(default_factory=list)
    location: Optional[FoursquareLocation] = None
    description: str = ""
    tel: str = ""
    website: str = ""
    email: str = ""
    hours_display: str = ""
    rating: Optional[float] = None
    price: Optional[int] = None
    popularity: Optional[float] = None
    tips_count: int = 0
    photos_count: int = 0
    verified: bool = False
    closed_bucket: str = ""
    menu_url: str = ""

    @property
    def primary_category(self) -> Optional[FoursquareCategory]:
        """Get the primary category."""
        return self.categories[0] if self.categories else None

    @property
    def price_symbol(self) -> str:
        """Get price as dollar signs."""
        return "$" * self.price if self.price else ""

    @property
    def formatted_rating(self) -> str:
        """Get formatted rating string."""
        return f"{self.rating:.1f}/10" if self.rating else ""


@dataclass
class RecipeIngredient:
    """An ingredient in a recipe."""
    id: Optional[int] = None
    name: str = ""
    original: str = ""
    amount: float = 0
    unit: str = ""
    aisle: str = ""


@dataclass
class RecipeNutrition:
    """Nutritional information for a recipe."""
    calories: Optional[float] = None
    carbs: Optional[str] = None
    fat: Optional[str] = None
    protein: Optional[str] = None


@dataclass
class RecipeMetadata:
    """Metadata from Spoonacular for a recipe."""
    recipe_id: int
    title: str
    summary: str = ""
    instructions: str = ""
    source_url: str = ""
    source_name: str = ""
    image_url: str = ""
    cuisines: List[str] = field(default_factory=list)
    dish_types: List[str] = field(default_factory=list)
    diets: List[str] = field(default_factory=list)
    occasions: List[str] = field(default_factory=list)
    ingredients: List[RecipeIngredient] = field(default_factory=list)
    ingredient_names: List[str] = field(default_factory=list)
    ready_in_minutes: int = 0
    servings: int = 0
    cooking_minutes: int = 0
    preparation_minutes: int = 0
    health_score: Optional[float] = None
    spoonacular_score: Optional[float] = None
    price_per_serving: Optional[float] = None
    vegetarian: bool = False
    vegan: bool = False
    gluten_free: bool = False
    dairy_free: bool = False
    very_healthy: bool = False
    cheap: bool = False
    sustainable: bool = False
    nutrition: Optional[RecipeNutrition] = None

    @property
    def dietary_labels(self) -> List[str]:
        """Get list of dietary labels."""
        labels = []
        if self.vegan:
            labels.append("Vegan")
        elif self.vegetarian:
            labels.append("Vegetarian")
        if self.gluten_free:
            labels.append("Gluten-Free")
        if self.dairy_free:
            labels.append("Dairy-Free")
        if self.very_healthy:
            labels.append("Very Healthy")
        return labels

    @property
    def difficulty(self) -> str:
        """Estimate difficulty based on time and ingredients."""
        if self.ready_in_minutes <= 20 and len(self.ingredients) <= 5:
            return "Easy"
        elif self.ready_in_minutes <= 45 and len(self.ingredients) <= 10:
            return "Medium"
        return "Advanced"


@dataclass
class ConfidenceBreakdown:
    """Detailed breakdown of how confidence was calculated."""
    title_similarity: float = 0.0      # How similar the titles are (0.0-1.0)
    author_match: float = 0.0          # Author/artist match score (0.0-1.0)
    year_plausible: bool = False       # Is the year reasonable?
    single_result: bool = False        # Was this the only result?
    has_direct_id: bool = False        # Did we have a direct ID lookup?
    result_count: int = 0              # How many results were returned

    def to_dict(self) -> dict:
        """Convert to dictionary for storage."""
        return {
            "title_similarity": round(self.title_similarity, 3),
            "author_match": round(self.author_match, 3),
            "year_plausible": self.year_plausible,
            "single_result": self.single_result,
            "has_direct_id": self.has_direct_id,
            "result_count": self.result_count,
        }


@dataclass
class EnrichmentResult:
    """Complete enrichment result for a preference."""
    preference_id: str
    original_subject: str

    # Enrichment metadata
    source: EnrichmentSource = EnrichmentSource.UNKNOWN
    confidence: float = 0.0
    enriched_at: datetime = field(default_factory=datetime.utcnow)
    exact_match: bool = False

    # Enhanced confidence tracking
    match_type: MatchType = MatchType.NONE
    confidence_breakdown: Optional[ConfidenceBreakdown] = None
    matched_title: Optional[str] = None  # What we actually matched to

    # Extracted data
    topics: List[TopicResult] = field(default_factory=list)
    genres: List[GenreResult] = field(default_factory=list)
    entities: List[EntityResult] = field(default_factory=list)

    # Raw metadata (type depends on source)
    book_metadata: Optional[BookMetadata] = None
    movie_metadata: Optional[MovieMetadata] = None
    music_metadata: Optional[MusicMetadata] = None
    youtube_metadata: Optional["YouTubeVideoMetadata"] = None
    youtube_channel_metadata: Optional["YouTubeChannelMetadata"] = None
    podcast_metadata: Optional["PodcastMetadata"] = None
    podcast_episode_metadata: Optional["PodcastEpisodeMetadata"] = None
    crossref_metadata: Optional["CrossRefMetadata"] = None
    semantic_scholar_metadata: Optional["SemanticScholarPaper"] = None
    openfoodfacts_metadata: Optional["FoodProductMetadata"] = None
    asin_metadata: Optional["AmazonProductMetadata"] = None
    upc_metadata: Optional["UPCProductMetadata"] = None
    foursquare_metadata: Optional["FoursquareVenueMetadata"] = None
    recipe_metadata: Optional["RecipeMetadata"] = None

    # Error tracking
    error: Optional[str] = None

    def is_successful(self) -> bool:
        """
        Check if enrichment found a match (even if no topics/genres).

        Returns True if we matched the item, so it gets marked as processed
        and won't be retried infinitely.
        """
        return self.error is None and (
            len(self.topics) > 0 or
            len(self.genres) > 0 or
            len(self.entities) > 0 or
            self.matched_title is not None  # Found a match, just no tags
        )

    def has_semantic_value(self) -> bool:
        """
        Check if enrichment produced actual semantic data (topics/genres).

        Use this to distinguish high-value enrichments from ones that just
        matched but got no tags.
        """
        return len(self.topics) > 0 or len(self.genres) > 0

    def is_high_confidence(self, threshold: float = 0.8) -> bool:
        """Check if this is a high-confidence match."""
        return self.confidence >= threshold and self.error is None

    def needs_review(self, threshold: float = 0.6) -> bool:
        """Check if this enrichment should be flagged for human review."""
        return (
            self.is_successful() and
            self.confidence < threshold and
            self.match_type not in (MatchType.DIRECT_ID, MatchType.EXACT_TITLE)
        )

    def to_turtle(self, preference_uri: str) -> str:
        """Generate Turtle format RDF triples for this enrichment."""
        triples = []

        # Enrichment metadata
        triples.append(f'<{preference_uri}> pwg:enrichedAt "{self.enriched_at.isoformat()}"^^xsd:dateTime .')
        triples.append(f'<{preference_uri}> pwg:enrichmentSource "{self.source.value}" .')
        triples.append(f'<{preference_uri}> pwg:enrichmentConfidence "{self.confidence}"^^xsd:decimal .')
        triples.append(f'<{preference_uri}> pwg:matchType "{self.match_type.value}" .')
        # Track whether we got actual topics/genres (for later re-processing if needed)
        has_semantic = "true" if self.has_semantic_value() else "false"
        triples.append(f'<{preference_uri}> pwg:hasSemanticValue "{has_semantic}"^^xsd:boolean .')
        if self.matched_title:
            # Escape quotes in matched title
            safe_title = self.matched_title.replace('"', '\\"')
            triples.append(f'<{preference_uri}> pwg:matchedTitle "{safe_title}" .')

        # Topics
        for topic in self.topics:
            topic_uri = f"pwg:topic_{topic.normalized}"
            triples.append(f'<{preference_uri}> pwg:hasTopic <{topic_uri}> .')
            triples.append(f'<{topic_uri}> rdfs:label "{topic.name}" .')
            triples.append(f'<{topic_uri}> a pwg:Topic .')

        # Genres
        for genre in self.genres:
            genre_uri = f"pwg:genre_{genre.normalized}"
            triples.append(f'<{preference_uri}> pwg:hasGenre <{genre_uri}> .')
            triples.append(f'<{genre_uri}> rdfs:label "{genre.name}" .')
            triples.append(f'<{genre_uri}> a pwg:Genre .')

        # Entities
        for entity in self.entities:
            entity_id = entity.name.lower().replace(" ", "_").replace(".", "")
            entity_uri = f"pwg:entity_{entity_id}"
            triples.append(f'<{preference_uri}> pwg:hasEntity <{entity_uri}> .')
            triples.append(f'<{entity_uri}> rdfs:label "{entity.name}" .')
            triples.append(f'<{entity_uri}> pwg:entityType "{entity.entity_type}" .')
            triples.append(f'<{entity_uri}> a pwg:Entity .')

        return "\n".join(triples)
