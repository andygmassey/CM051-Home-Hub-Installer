"""Enrichment service configuration."""

from pydantic_settings import BaseSettings
from pydantic import Field
from typing import Optional, Dict, List


class Settings(BaseSettings):
    """Enrichment service settings."""

    # Oxigraph connection (for storing enrichment triples)
    oxigraph_host: str = Field(default="localhost", alias="OXIGRAPH_HOST")
    oxigraph_port: int = Field(default=7878, alias="OXIGRAPH_PORT")

    # Qdrant connection (for querying unenriched preferences)
    # Vendored for the single-Mac install: standardised on the `preferences`
    # collection that CM044 reads (upstream CM019 default was pwg_preferences).
    qdrant_host: str = Field(default="localhost", alias="QDRANT_HOST")
    qdrant_port: int = Field(default=6333, alias="QDRANT_PORT")
    qdrant_collection: str = Field(default="preferences", alias="QDRANT_COLLECTION")

    # API Keys
    tmdb_api_key: Optional[str] = Field(default=None, alias="TMDB_API_KEY")
    youtube_api_key: Optional[str] = Field(default=None, alias="YOUTUBE_API_KEY")
    google_places_api_key: Optional[str] = Field(default=None, alias="GOOGLE_PLACES_API_KEY")
    podcast_index_api_key: Optional[str] = Field(default=None, alias="PODCAST_INDEX_API_KEY")
    podcast_index_api_secret: Optional[str] = Field(default=None, alias="PODCAST_INDEX_API_SECRET")
    semantic_scholar_api_key: Optional[str] = Field(default=None, alias="SEMANTIC_SCHOLAR_API_KEY")
    foursquare_api_key: Optional[str] = Field(default=None, alias="FOURSQUARE_API_KEY")
    spoonacular_api_key: Optional[str] = Field(default=None, alias="SPOONACULAR_API_KEY")
    crossref_mailto: Optional[str] = Field(default=None, alias="CROSSREF_MAILTO")

    # Rate limiting (requests per second)
    openlibrary_rate_limit: float = Field(default=1.0, alias="OPENLIBRARY_RATE_LIMIT")
    tmdb_rate_limit: float = Field(default=4.0, alias="TMDB_RATE_LIMIT")  # 40 req/10sec
    musicbrainz_rate_limit: float = Field(default=0.4, alias="MUSICBRAINZ_RATE_LIMIT")  # Slower to avoid 503s
    youtube_rate_limit: float = Field(default=5.0, alias="YOUTUBE_RATE_LIMIT")  # Conservative for quota
    google_places_rate_limit: float = Field(default=10.0, alias="GOOGLE_PLACES_RATE_LIMIT")  # Pay per request
    podcast_index_rate_limit: float = Field(default=2.0, alias="PODCAST_INDEX_RATE_LIMIT")  # Reasonable default
    crossref_rate_limit: float = Field(default=10.0, alias="CROSSREF_RATE_LIMIT")  # 50 req/sec polite pool
    semantic_scholar_rate_limit: float = Field(default=1.0, alias="SEMANTIC_SCHOLAR_RATE_LIMIT")  # 100 req/5min
    openfoodfacts_rate_limit: float = Field(default=2.0, alias="OPENFOODFACTS_RATE_LIMIT")  # Be polite
    foursquare_rate_limit: float = Field(default=2.0, alias="FOURSQUARE_RATE_LIMIT")  # 120 req/hour free tier
    spoonacular_rate_limit: float = Field(default=1.0, alias="SPOONACULAR_RATE_LIMIT")  # Free tier limits

    # Retry settings
    max_retries: int = Field(default=3, alias="MAX_RETRIES")
    retry_base_delay: float = Field(default=1.0, alias="RETRY_BASE_DELAY")
    retry_max_delay: float = Field(default=30.0, alias="RETRY_MAX_DELAY")

    # Caching
    cache_dir: str = Field(default="/tmp/pwg_enrich_cache", alias="CACHE_DIR")
    cache_ttl_days: int = Field(default=30, alias="CACHE_TTL_DAYS")

    # Processing
    batch_size: int = Field(default=50, alias="ENRICH_BATCH_SIZE")
    request_timeout: float = Field(default=30.0, alias="REQUEST_TIMEOUT")

    # MusicBrainz User-Agent (required by their API)
    musicbrainz_app_name: str = Field(
        default="PWG-Enrichment",
        alias="MUSICBRAINZ_APP_NAME"
    )
    musicbrainz_app_version: str = Field(
        default="0.1.0",
        alias="MUSICBRAINZ_APP_VERSION"
    )
    musicbrainz_contact: str = Field(
        default="",
        alias="MUSICBRAINZ_CONTACT"
    )

    # Topic mapping - map external API genres/subjects to PWG topics
    topic_mappings: Dict[str, str] = Field(
        default={
            # Book subject mappings
            "behavioral economics": "behavioral_economics",
            "psychology": "psychology",
            "cognitive science": "cognitive_science",
            "decision making": "decision_making",
            "self-help": "self_improvement",
            "personal development": "self_improvement",
            "biography & autobiography": "biography",
            "business & economics": "business",
            # Movie genre mappings
            "science fiction": "sci_fi",
            "action": "action",
            "drama": "drama",
            "comedy": "comedy",
            "thriller": "thriller",
            "documentary": "documentary",
            # Music genre mappings
            "alternative rock": "alternative_rock",
            "electronic": "electronic",
            "indie rock": "indie",
            "hip hop": "hip_hop",
            "classical": "classical",
        },
        alias="TOPIC_MAPPINGS"
    )

    # Categories that need enrichment
    enrichable_categories: List[str] = Field(
        default=["book", "books", "movie", "movies", "music", "podcast", "podcasts"],
        alias="ENRICHABLE_CATEGORIES"
    )

    @property
    def oxigraph_url(self) -> str:
        return f"http://{self.oxigraph_host}:{self.oxigraph_port}"

    @property
    def qdrant_url(self) -> str:
        return f"http://{self.qdrant_host}:{self.qdrant_port}"

    @property
    def musicbrainz_user_agent(self) -> str:
        """Generate User-Agent string for MusicBrainz API."""
        parts = [f"{self.musicbrainz_app_name}/{self.musicbrainz_app_version}"]
        if self.musicbrainz_contact:
            parts.append(f"( {self.musicbrainz_contact} )")
        return " ".join(parts)

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
