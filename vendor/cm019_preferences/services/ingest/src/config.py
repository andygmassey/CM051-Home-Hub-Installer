"""Ingest service configuration."""

from pydantic_settings import BaseSettings
from pydantic import Field
from typing import List, Dict
from datetime import date


class Settings(BaseSettings):
    """Ingest service settings."""

    # Oxigraph connection
    oxigraph_host: str = Field(default="localhost", alias="OXIGRAPH_HOST")
    oxigraph_port: int = Field(default=7878, alias="OXIGRAPH_PORT")

    # Qdrant connection
    qdrant_host: str = Field(default="localhost", alias="QDRANT_HOST")
    qdrant_port: int = Field(default=6333, alias="QDRANT_PORT")
    qdrant_collection: str = Field(default="preferences", alias="QDRANT_COLLECTION")

    # Kafka connection
    kafka_bootstrap_servers: str = Field(default="localhost:9092", alias="KAFKA_BOOTSTRAP_SERVERS")
    kafka_ingest_topic: str = Field(default="pwg.ingest.requests", alias="KAFKA_INGEST_TOPIC")
    kafka_events_topic: str = Field(default="pwg.events", alias="KAFKA_EVENTS_TOPIC")
    kafka_consumer_group: str = Field(default="ingest-service", alias="KAFKA_CONSUMER_GROUP")

    # RML Mapper
    rml_mapper_url: str = Field(default="http://localhost:8080", alias="RML_MAPPER_URL")

    # Vectorizer settings.
    # Vendored for the single-Mac install: embeddings come from the local
    # Ollama (nomic-embed-text, 768-dim) that the rest of the stack already
    # uses (people / safari_history / conversations), NOT sentence-transformers
    # (no torch). 768-dim is required to match the pre-created `preferences`
    # collection and keep one embedding space stack-wide.
    embedding_model: str = Field(default="nomic-embed-text", alias="EMBED_MODEL")
    embedding_dim: int = Field(default=768, alias="EMBEDDING_DIM")
    batch_size: int = Field(default=64, alias="INGEST_BATCH_SIZE")
    ollama_url: str = Field(default="http://localhost:11434", alias="EMBED_OLLAMA_URL")

    # Data directories
    data_dir: str = Field(default="/data/ingest", alias="INGEST_DATA_DIR")
    mappings_dir: str = Field(default="/app/mappings", alias="RML_MAPPINGS_DIR")

    # Processing settings
    default_compartment: int = Field(default=2, alias="DEFAULT_COMPARTMENT")
    max_file_size_mb: int = Field(default=100, alias="MAX_FILE_SIZE_MB")

    # Source exclusion - skip these sources during ingestion
    # Allows parsers to exist for productization while excluding personal data
    excluded_sources: List[str] = Field(
        default=[],
        alias="EXCLUDED_SOURCES",
        description="List of source names to skip during ingestion"
    )

    # Date range exclusions - filter out preferences from specific time periods
    # Useful for excluding event playlists, anomalous listening periods, etc.
    # Format: [{"source": "spotify", "start": "2016-08-01", "end": "2016-10-31", "reason": "Event playlist"}]
    excluded_date_ranges: List[Dict[str, str]] = Field(
        default=[
            {
                "source": "spotify",
                "start": "2016-08-01",
                "end": "2016-10-31",
                "reason": "Event playlist period - anomalous 2,833 plays in 3 months"
            }
        ],
        alias="EXCLUDED_DATE_RANGES",
        description="List of date ranges to exclude by source"
    )

    # Apple Health source priority for deduplication
    # When multiple devices track the same metric for the same date,
    # use only the highest priority source to avoid double-counting
    # Priority order: first in list = highest priority
    health_source_priority: Dict[str, List[str]] = Field(
        default={
            "sleep": ["Whoop", "WHOOP", "Ultrahuman", "Apple Watch", "AutoSleep"],
            "heart_rate": ["Apple Watch", "Whoop", "WHOOP", "Ultrahuman"],
            "hrv": ["Whoop", "WHOOP", "Ultrahuman", "Apple Watch"],
            "resting_heart_rate": ["Whoop", "WHOOP", "Apple Watch"],
            "steps": ["Apple Watch", "iPhone"],
            "active_energy": ["Apple Watch", "iPhone"],
            "distance": ["Apple Watch", "iPhone"],
            "weight": ["YUNMAI", "Withings", "Apple Watch"],
        },
        alias="HEALTH_SOURCE_PRIORITY",
        description="Priority order for health data sources when deduplicating"
    )

    def is_date_excluded(self, source: str, observed_at) -> bool:
        """Check if a date falls within an excluded range for the given source."""
        if observed_at is None:
            return False

        from datetime import datetime
        if isinstance(observed_at, datetime):
            check_date = observed_at.date()
        elif isinstance(observed_at, date):
            check_date = observed_at
        else:
            return False

        for exclusion in self.excluded_date_ranges:
            if exclusion.get("source", "").lower() != source.lower():
                continue

            try:
                start = date.fromisoformat(exclusion["start"])
                end = date.fromisoformat(exclusion["end"])
                if start <= check_date <= end:
                    return True
            except (ValueError, KeyError):
                continue

        return False

    @property
    def oxigraph_url(self) -> str:
        return f"http://{self.oxigraph_host}:{self.oxigraph_port}"

    @property
    def qdrant_url(self) -> str:
        return f"http://{self.qdrant_host}:{self.qdrant_port}"

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
