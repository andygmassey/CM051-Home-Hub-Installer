"""External API clients for preference enrichment."""

from .base import BaseClient
from .openlibrary import OpenLibraryClient, extract_author_from_title
from .tmdb import TMDBClient
from .musicbrainz import MusicBrainzClient
from .wikidata import WikidataClient, WikidataEntity, NormalizationResult, BroaderConceptsResult
from .podcast_index import (
    PodcastIndexClient,
    PodcastSearchResult,
    EpisodeSearchResult,
    normalize_podcast_name,
    PODCAST_CATEGORIES,
)
from .youtube import (
    YouTubeClient,
    extract_video_id,
    extract_channel_id,
    parse_iso8601_duration,
    extract_topic_name,
    BatchVideoResult,
    BatchChannelResult,
    YOUTUBE_CATEGORIES,
)
from .url_fetcher import (
    URLFetcherClient,
    URLMetadata,
    extract_domain,
    infer_category_from_domain,
    DOMAIN_CATEGORIES,
)
from .geocoder import (
    GeocoderClient,
    GeocodingResult,
    normalize_venue_name,
    calculate_match_confidence,
    PLACE_TYPE_CATEGORIES,
    DEFAULT_VIEWBOX,
)
from .places import (
    PlacesClient,
    PlaceDetails,
    PlaceSearchResult,
    OpeningHours,
    extract_cuisines_from_types,
    normalize_venue_name as normalize_places_venue_name,
    PLACE_TYPE_TO_CUISINE,
    PRICE_LEVELS,
)
from .airports import AirportLookup, AirportInfo
from .crossref import (
    CrossRefClient,
    extract_doi,
    normalize_doi,
    CROSSREF_TYPE_LABELS,
)
from .semantic_scholar import (
    SemanticScholarClient,
    extract_s2_paper_id,
)
from .openfoodfacts import (
    OpenFoodFactsClient,
    normalize_barcode,
    extract_barcode,
    NUTRISCORE_DESCRIPTIONS,
    NOVA_DESCRIPTIONS,
)
from .asin import (
    ASINClient,
    extract_asin,
    get_amazon_url,
    AMAZON_CATEGORY_MAPPINGS,
)
from .upc import (
    UPCClient,
    normalize_upc,
    extract_upc,
    validate_upc_checksum,
    GPC_CATEGORIES,
)
from .foursquare import (
    FoursquareClient,
    extract_foursquare_id,
    FOURSQUARE_TOP_CATEGORIES,
)
from .recipes import (
    SpoonacularClient,
    extract_recipe_id,
    CUISINE_MAPPINGS,
    DISH_TYPE_MAPPINGS,
)
from .linkedin import (
    LinkedInClient,
    LinkedInPostMetadata,
    LinkedInEnrichmentResult,
    extract_hashtags_from_results,
    extract_authors_from_results,
    extract_topics_from_content,
)
from .brand import (
    BrandClient,
    BrandInfo,
    BrandLookupResult,
    lookup_brand,
    get_parent_company,
    BRAND_TYPE_QIDS,
    INDUSTRY_MAPPINGS,
)
from .events import (
    EventClient,
    TicketmasterClient,
    EventbriteClient,
    EventInfo,
    EventType,
    EventSource,
    Performer,
    Venue,
    EventSearchResult,
    EVENT_TYPE_KEYWORDS,
    extract_eventbrite_id,
)
from .validation import (
    calculate_confidence,
    should_accept_match,
    title_similarity,
    author_similarity,
    normalize_for_comparison,
)

__all__ = [
    # Clients
    "BaseClient",
    "OpenLibraryClient",
    "extract_author_from_title",  # Open Library helper
    "TMDBClient",
    "MusicBrainzClient",
    "WikidataClient",
    "PodcastIndexClient",
    "YouTubeClient",
    "URLFetcherClient",
    "GeocoderClient",
    "PlacesClient",
    # Wikidata models
    "WikidataEntity",
    "NormalizationResult",
    "BroaderConceptsResult",
    # Podcast Index models and utilities
    "PodcastSearchResult",
    "EpisodeSearchResult",
    "normalize_podcast_name",
    "PODCAST_CATEGORIES",
    # YouTube models and utilities
    "BatchVideoResult",
    "BatchChannelResult",
    "extract_video_id",
    "extract_channel_id",
    "parse_iso8601_duration",
    "extract_topic_name",
    "YOUTUBE_CATEGORIES",
    # URL Fetcher models and utilities
    "URLMetadata",
    "extract_domain",
    "infer_category_from_domain",
    "DOMAIN_CATEGORIES",
    # Geocoder models and utilities
    "GeocodingResult",
    "normalize_venue_name",
    "calculate_match_confidence",
    "PLACE_TYPE_CATEGORIES",
    "DEFAULT_VIEWBOX",
    # Places models and utilities
    "PlaceDetails",
    "PlaceSearchResult",
    "OpeningHours",
    "extract_cuisines_from_types",
    "normalize_places_venue_name",
    "PLACE_TYPE_TO_CUISINE",
    "PRICE_LEVELS",
    # Static lookups
    "AirportLookup",
    "AirportInfo",
    # CrossRef models and utilities
    "CrossRefClient",
    "extract_doi",
    "normalize_doi",
    "CROSSREF_TYPE_LABELS",
    # Semantic Scholar models and utilities
    "SemanticScholarClient",
    "extract_s2_paper_id",
    # Open Food Facts models and utilities
    "OpenFoodFactsClient",
    "normalize_barcode",
    "extract_barcode",
    "NUTRISCORE_DESCRIPTIONS",
    "NOVA_DESCRIPTIONS",
    # ASIN models and utilities
    "ASINClient",
    "extract_asin",
    "get_amazon_url",
    "AMAZON_CATEGORY_MAPPINGS",
    # UPC models and utilities
    "UPCClient",
    "normalize_upc",
    "extract_upc",
    "validate_upc_checksum",
    "GPC_CATEGORIES",
    # Foursquare models and utilities
    "FoursquareClient",
    "extract_foursquare_id",
    "FOURSQUARE_TOP_CATEGORIES",
    # Spoonacular/Recipe models and utilities
    "SpoonacularClient",
    "extract_recipe_id",
    "CUISINE_MAPPINGS",
    "DISH_TYPE_MAPPINGS",
    # Validation utilities
    "calculate_confidence",
    "should_accept_match",
    "title_similarity",
    "author_similarity",
    "normalize_for_comparison",
    # LinkedIn reaction enrichment
    "LinkedInClient",
    "LinkedInPostMetadata",
    "LinkedInEnrichmentResult",
    "extract_hashtags_from_results",
    "extract_authors_from_results",
    "extract_topics_from_content",
    # Brand recognition
    "BrandClient",
    "BrandInfo",
    "BrandLookupResult",
    "lookup_brand",
    "get_parent_company",
    "BRAND_TYPE_QIDS",
    "INDUSTRY_MAPPINGS",
    # Event/Ticket enrichment
    "EventClient",
    "TicketmasterClient",
    "EventbriteClient",
    "EventInfo",
    "EventType",
    "EventSource",
    "Performer",
    "Venue",
    "EventSearchResult",
    "EVENT_TYPE_KEYWORDS",
    "extract_eventbrite_id",
]
