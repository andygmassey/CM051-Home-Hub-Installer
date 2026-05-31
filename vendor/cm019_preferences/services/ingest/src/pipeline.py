"""Main ingest pipeline orchestration."""

import logging
import asyncio
from pathlib import Path
from typing import List, Optional, Dict, Any, AsyncIterator
from datetime import datetime
import uuid

from .config import settings
from .vectorizer import vectorizer
from .loaders import OxigraphLoader, QdrantLoader
from .filters import PreferenceFilter
from .parsers import (
    BaseParser,
    ParsedPreference,
    CSVParser,
    GoogleTakeoutParser,
    SpotifyParser,
    MetaParser,
    AmazonParser,
    LinkedInParser,
    RedditParser,
    AppleParser,
    TwitterParser,
    YouTubeParser,
    eBayParser,
    TikTokParser,
    PinterestParser,
    UberParser,
    WhoopParser,
    DisneyPlusParser,
    WhatsAppParser,
    DiscordParser,
    NetflixParser,
    EmailParser,
    FoursquareParser
)
from .rml import RMLMapper

logger = logging.getLogger(__name__)


class IngestPipeline:
    """
    Main ingestion pipeline for processing data exports.

    Workflow:
    1. Detect source type and select parser
    2. Parse source data into preferences
    3. Generate embeddings for preferences
    4. Load RDF triples into Oxigraph
    5. Load vectors into Qdrant
    6. Emit events to Kafka (optional)
    """

    def __init__(self):
        """Initialize the pipeline."""
        self.oxigraph = OxigraphLoader()
        self.qdrant = QdrantLoader()
        self.rml_mapper = RMLMapper()

        # Available parsers (ordered from most specific to least specific)
        self.parsers: List[BaseParser] = [
            EmailParser(),  # Email preferences from CM021 - specific .jsonl format
            GoogleTakeoutParser(),
            SpotifyParser(),
            AmazonParser(),
            LinkedInParser(),
            RedditParser(),  # Before Meta - Reddit has specific file patterns
            AppleParser(),
            TwitterParser(),
            YouTubeParser(),
            eBayParser(),
            TikTokParser(),
            PinterestParser(),
            UberParser(),
            WhoopParser(),
            FoursquareParser(),  # Before Netflix - both may match venueRatings
            NetflixParser(),  # Before Disney+ - both have ViewingActivity.csv
            DisneyPlusParser(),
            WhatsAppParser(),
            DiscordParser(),
            MetaParser(),
            CSVParser(),  # CSV last as fallback
        ]

        # Preference filter for low-value entries and deduplication
        self.filter = PreferenceFilter(enable_dedup=True)

        # Statistics
        self.stats = {
            "files_processed": 0,
            "preferences_created": 0,
            "preferences_filtered": 0,
            "preferences_date_excluded": 0,
            "triples_inserted": 0,
            "vectors_inserted": 0,
            "sources_excluded": 0,
            "errors": 0
        }

    async def initialize(self) -> bool:
        """Initialize connections and collections."""
        try:
            # Check Oxigraph health
            if not await self.oxigraph.health_check():
                logger.warning("Oxigraph not available")

            # Ensure Qdrant collection exists
            await self.qdrant.ensure_collection(dimension=vectorizer.dimension)

            logger.info("Ingest pipeline initialized")
            return True

        except Exception as e:
            logger.error(f"Failed to initialize pipeline: {e}")
            return False

    async def warm_existing_preferences(self, user_id: str) -> int:
        """
        Warm the filter cache with existing preferences from Qdrant.

        This enables incremental ingestion by loading existing preferences
        so new data can be merged with them (frequencies combined,
        cross-source reinforcement tracked).

        Args:
            user_id: User whose preferences to load

        Returns:
            Number of preferences loaded
        """
        logger.info(f"Warming preference cache from existing data for user {user_id}...")

        # Retrieve all existing preferences for user
        existing = await self.qdrant.get_all_for_user(user_id)

        # Warm the filter cache
        count = self.filter.warm_from_payloads(existing)

        logger.info(f"Loaded {count} existing preferences into cache")
        return count

    async def ingest_file(
        self,
        file_path: Path,
        user_id: str,
        compartment_level: Optional[int] = None,
        category: Optional[str] = None,
        batch_size: int = 32
    ) -> Dict[str, Any]:
        """
        Ingest a single file.

        Args:
            file_path: Path to file to ingest
            user_id: User ID to associate preferences with
            compartment_level: Default compartment level
            category: Default category for preferences
            batch_size: Batch size for processing

        Returns:
            Ingestion statistics
        """
        start_time = datetime.utcnow()
        result = {
            "file": str(file_path),
            "user_id": user_id,
            "preferences_created": 0,
            "preferences_filtered": 0,
            "preferences_date_excluded": 0,
            "triples_inserted": 0,
            "vectors_inserted": 0,
            "errors": [],
            "duration_seconds": 0
        }

        # Find appropriate parser
        parser = self._get_parser(file_path)
        if not parser:
            result["errors"].append(f"No parser found for file: {file_path}")
            return result

        logger.info(f"Processing {file_path} with {parser.source_name} parser")

        # Process in batches
        batch: List[ParsedPreference] = []

        try:
            filtered_count = 0
            date_excluded_count = 0
            async for pref in parser.parse(
                file_path,
                default_compartment=compartment_level or settings.default_compartment,
                default_category=category
            ):
                # Check date range exclusions first
                if settings.is_date_excluded(pref.source, pref.observed_at):
                    date_excluded_count += 1
                    continue

                # Apply filtering (low-value entries and deduplication)
                if not self.filter.should_include(pref):
                    filtered_count += 1
                    continue

                batch.append(pref)

                if len(batch) >= batch_size:
                    batch_result = await self._process_batch(batch, user_id)
                    result["preferences_created"] += batch_result["preferences"]
                    result["triples_inserted"] += batch_result["triples"]
                    result["vectors_inserted"] += batch_result["vectors"]
                    result["errors"].extend(batch_result["errors"])
                    batch = []

            # Process remaining batch
            if batch:
                batch_result = await self._process_batch(batch, user_id)
                result["preferences_created"] += batch_result["preferences"]
                result["triples_inserted"] += batch_result["triples"]
                result["vectors_inserted"] += batch_result["vectors"]
                result["errors"].extend(batch_result["errors"])

            result["preferences_filtered"] = filtered_count
            result["preferences_date_excluded"] = date_excluded_count

        except Exception as e:
            logger.error(f"Error processing file: {e}")
            result["errors"].append(str(e))

        result["duration_seconds"] = (datetime.utcnow() - start_time).total_seconds()

        # Update global stats
        self.stats["files_processed"] += 1
        self.stats["preferences_created"] += result["preferences_created"]
        self.stats["preferences_filtered"] += result["preferences_filtered"]
        self.stats["preferences_date_excluded"] += result["preferences_date_excluded"]
        self.stats["triples_inserted"] += result["triples_inserted"]
        self.stats["vectors_inserted"] += result["vectors_inserted"]
        self.stats["errors"] += len(result["errors"])

        logger.info(
            f"Completed {file_path}: {result['preferences_created']} preferences "
            f"({result['preferences_filtered']} filtered, {result['preferences_date_excluded']} date-excluded), "
            f"{result['duration_seconds']:.2f}s"
        )

        return result

    async def ingest_file_with_aggregation(
        self,
        file_path: Path,
        user_id: str,
        compartment_level: Optional[int] = None,
        incremental: bool = False
    ) -> Dict[str, Any]:
        """
        Ingest a single file with two-phase frequency aggregation.

        This is the preferred method for large files (like email exports) where
        frequency aggregation and cross-source reinforcement are important.

        Phase 1: Parse all preferences, track frequencies in filter
        Phase 2: Get aggregated preferences with strength adjustments, then insert

        Args:
            file_path: Path to file to ingest
            user_id: User ID to associate preferences with
            compartment_level: Default compartment level
            incremental: Whether to merge with existing preferences (top-up mode)

        Returns:
            Ingestion statistics with frequency data
        """
        start_time = datetime.utcnow()
        result = {
            "file": str(file_path),
            "user_id": user_id,
            "preferences_created": 0,
            "preferences_filtered": 0,
            "preferences_date_excluded": 0,
            "triples_inserted": 0,
            "vectors_inserted": 0,
            "errors": [],
            "duration_seconds": 0,
            "frequency_stats": None,
            "warmed_from_db": 0
        }

        # Find appropriate parser
        parser = self._get_parser(file_path)
        if not parser:
            result["errors"].append(f"No parser found for file: {file_path}")
            return result

        logger.info(f"Processing {file_path} with {parser.source_name} parser (aggregation mode)")

        # Ensure filter is in aggregation mode
        self.filter = PreferenceFilter(enable_dedup=True, aggregate_frequency=True)

        # In incremental mode, warm the cache with existing preferences
        if incremental:
            warmed_count = await self.warm_existing_preferences(user_id)
            result["warmed_from_db"] = warmed_count

        # Phase 1: Parse all preferences, accumulate in filter
        logger.info("Phase 1: Parsing file for frequency aggregation...")
        low_value_filtered = 0
        date_excluded = 0

        try:
            async for pref in parser.parse(
                file_path,
                default_compartment=compartment_level or settings.default_compartment
            ):
                # Check date range exclusions first
                if settings.is_date_excluded(pref.source, pref.observed_at):
                    date_excluded += 1
                    continue

                # Filter checks low-value and tracks frequency
                if self.filter.is_low_value(pref):
                    low_value_filtered += 1
                    continue

                # is_duplicate tracks frequency in aggregation mode
                self.filter.is_duplicate(pref)

        except Exception as e:
            logger.error(f"Error parsing {file_path}: {e}")
            result["errors"].append(f"{file_path}: {e}")

        # Get aggregation stats
        filter_stats = self.filter.get_stats()
        result["preferences_filtered"] = low_value_filtered + filter_stats.get("aggregated_count", 0)
        result["preferences_date_excluded"] = date_excluded
        result["frequency_stats"] = filter_stats.get("frequency_distribution")

        # Phase 2: Get aggregated preferences and insert
        # In incremental mode, only insert modified preferences
        if incremental:
            aggregated_prefs = self.filter.get_modified_preferences()
            logger.info(f"Phase 2: Inserting {len(aggregated_prefs)} modified preferences (incremental mode)...")
        else:
            aggregated_prefs = self.filter.get_aggregated_preferences()
            logger.info(f"Phase 2: Inserting {filter_stats['unique_preferences']} unique preferences with frequency data...")

        batch_size = 32
        for i in range(0, len(aggregated_prefs), batch_size):
            batch = aggregated_prefs[i:i + batch_size]
            batch_result = await self._process_batch(batch, user_id)
            result["preferences_created"] += batch_result["preferences"]
            result["triples_inserted"] += batch_result["triples"]
            result["vectors_inserted"] += batch_result["vectors"]
            result["errors"].extend(batch_result["errors"])

        result["duration_seconds"] = (datetime.utcnow() - start_time).total_seconds()

        logger.info(
            f"Aggregated ingestion complete: {result['preferences_created']} preferences, "
            f"{result['preferences_filtered']} filtered, {result['preferences_date_excluded']} date-excluded, "
            f"{result['duration_seconds']:.1f}s"
        )
        logger.info(f"Frequency distribution: {result['frequency_stats']}")

        return result

    async def ingest_directory(
        self,
        dir_path: Path,
        user_id: str,
        compartment_level: Optional[int] = None,
        recursive: bool = True,
        aggregate_frequency: bool = True,
        incremental: bool = False
    ) -> Dict[str, Any]:
        """
        Ingest all supported files in a directory.

        When aggregate_frequency is True (default), this uses a two-phase approach:
        1. Parse all files and collect preferences (no insertion yet)
        2. Aggregate frequencies across all files, then insert with strength adjusted

        This ensures that a song played 21 times across multiple export files
        gets proper frequency tracking.

        When incremental is True, existing preferences are loaded from Qdrant
        first, allowing new data to merge with existing data (frequencies combined,
        cross-source reinforcement tracked). This enables "top-up" ingestion
        without requiring full re-ingestion.

        Args:
            dir_path: Directory to process
            user_id: User ID
            compartment_level: Default compartment level
            recursive: Whether to process subdirectories
            aggregate_frequency: Whether to aggregate frequency across all files
            incremental: Whether to merge with existing preferences (top-up mode)

        Returns:
            Aggregated ingestion statistics
        """
        result = {
            "directory": str(dir_path),
            "files_processed": 0,
            "total_preferences": 0,
            "total_filtered": 0,
            "total_date_excluded": 0,
            "total_triples": 0,
            "total_vectors": 0,
            "file_results": [],
            "errors": [],
            "frequency_stats": None,
            "warmed_from_db": 0
        }

        # Find all files
        pattern = "**/*" if recursive else "*"
        files = [f for f in dir_path.glob(pattern) if f.is_file()]

        if aggregate_frequency:
            # Two-phase approach for proper frequency tracking
            result = await self._ingest_directory_with_aggregation(
                dir_path, files, user_id, compartment_level, result, incremental
            )
        else:
            # Original per-file approach
            for file_path in files:
                if file_path.name.startswith('.'):
                    continue
                if not self._get_parser(file_path):
                    continue

                file_result = await self.ingest_file(
                    file_path, user_id, compartment_level=compartment_level
                )

                result["files_processed"] += 1
                result["total_preferences"] += file_result["preferences_created"]
                result["total_filtered"] += file_result["preferences_filtered"]
                result["total_triples"] += file_result["triples_inserted"]
                result["total_vectors"] += file_result["vectors_inserted"]
                result["file_results"].append(file_result)
                result["errors"].extend(file_result["errors"])

        return result

    async def _ingest_directory_with_aggregation(
        self,
        dir_path: Path,
        files: List[Path],
        user_id: str,
        compartment_level: Optional[int],
        result: Dict[str, Any],
        incremental: bool = False
    ) -> Dict[str, Any]:
        """
        Two-phase ingestion with frequency aggregation.

        Phase 1: Parse all files, filter collects and counts preferences
        Phase 2: Get aggregated preferences and insert with frequency data

        When incremental is True, existing preferences are loaded first
        to enable merging with new data.
        """
        from datetime import datetime
        start_time = datetime.utcnow()

        # Ensure filter is in aggregation mode
        self.filter = PreferenceFilter(enable_dedup=True, aggregate_frequency=True)

        # In incremental mode, warm the cache with existing preferences
        if incremental:
            warmed_count = await self.warm_existing_preferences(user_id)
            result["warmed_from_db"] = warmed_count

        # Phase 1: Parse all files, accumulate in filter
        logger.info(f"Phase 1: Parsing {len(files)} files for frequency aggregation...")
        low_value_filtered = 0
        date_excluded = 0

        for file_path in files:
            if file_path.name.startswith('.'):
                continue

            parser = self._get_parser(file_path)
            if not parser:
                continue

            result["files_processed"] += 1

            try:
                async for pref in parser.parse(
                    file_path,
                    default_compartment=compartment_level or settings.default_compartment
                ):
                    # Check date range exclusions first
                    if settings.is_date_excluded(pref.source, pref.observed_at):
                        date_excluded += 1
                        continue

                    # Filter checks low-value and tracks frequency
                    if self.filter.is_low_value(pref):
                        low_value_filtered += 1
                        continue

                    # is_duplicate now tracks frequency in aggregation mode
                    self.filter.is_duplicate(pref)

            except Exception as e:
                logger.error(f"Error parsing {file_path}: {e}")
                result["errors"].append(f"{file_path}: {e}")

        # Get aggregation stats
        filter_stats = self.filter.get_stats()
        result["total_filtered"] = low_value_filtered + filter_stats.get("aggregated_count", 0)
        result["total_date_excluded"] = date_excluded
        result["frequency_stats"] = filter_stats.get("frequency_distribution")

        # Phase 2: Get aggregated preferences and insert
        # In incremental mode, only insert modified preferences (new or frequency increased)
        if incremental:
            aggregated_prefs = self.filter.get_modified_preferences()
            logger.info(f"Phase 2: Inserting {len(aggregated_prefs)} modified preferences (incremental mode)...")
        else:
            aggregated_prefs = self.filter.get_aggregated_preferences()
            logger.info(f"Phase 2: Inserting {filter_stats['unique_preferences']} unique preferences with frequency data...")

        batch_size = 32

        for i in range(0, len(aggregated_prefs), batch_size):
            batch = aggregated_prefs[i:i + batch_size]
            batch_result = await self._process_batch(batch, user_id)
            result["total_preferences"] += batch_result["preferences"]
            result["total_triples"] += batch_result["triples"]
            result["total_vectors"] += batch_result["vectors"]
            result["errors"].extend(batch_result["errors"])

        duration = (datetime.utcnow() - start_time).total_seconds()
        logger.info(
            f"Aggregated ingestion complete: {result['total_preferences']} preferences, "
            f"{result['total_filtered']} filtered, {result['total_date_excluded']} date-excluded, {duration:.1f}s"
        )
        logger.info(f"Frequency distribution: {result['frequency_stats']}")

        return result

    async def _process_batch(
        self,
        preferences: List[ParsedPreference],
        user_id: str
    ) -> Dict[str, Any]:
        """Process a batch of preferences."""
        result = {
            "preferences": len(preferences),
            "triples": 0,
            "vectors": 0,
            "errors": []
        }

        if not preferences:
            return result

        # Generate embeddings
        texts = [p.embedding_text for p in preferences]
        try:
            embeddings = vectorizer.embed_batch(texts)
        except Exception as e:
            logger.error(f"Embedding generation failed: {e}")
            result["errors"].append(f"Embedding error: {e}")
            embeddings = [[0.0] * vectorizer.dimension] * len(preferences)

        # Build RDF triples
        turtle_lines = [
            "@prefix pwg: <https://pwg.dev/ontology#> .",
            "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .",
            "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .",
            ""
        ]

        for pref in preferences:
            turtle_lines.append(pref.to_turtle(user_id))
            turtle_lines.append("")

        turtle_content = "\n".join(turtle_lines)

        # Insert into Oxigraph
        try:
            success = await self.oxigraph.insert_triples(turtle_content)
            if success:
                result["triples"] = len(preferences)
        except Exception as e:
            logger.error(f"Oxigraph insert failed: {e}")
            result["errors"].append(f"Oxigraph error: {e}")

        # Insert into Qdrant
        try:
            payloads = [p.to_payload(user_id) for p in preferences]
            ids = [p.id for p in preferences]

            success = await self.qdrant.upsert_vectors(
                vectors=embeddings,
                payloads=payloads,
                ids=ids
            )
            if success:
                result["vectors"] = len(preferences)
        except Exception as e:
            logger.error(f"Qdrant insert failed: {e}")
            result["errors"].append(f"Qdrant error: {e}")

        return result

    def _get_parser(self, file_path: Path) -> Optional[BaseParser]:
        """Find a parser that can handle the given file.

        Respects settings.excluded_sources to skip certain source types.
        """
        for parser in self.parsers:
            if parser.can_parse(file_path):
                # Check if this source is excluded
                if parser.source_name.lower() in [s.lower() for s in settings.excluded_sources]:
                    logger.debug(f"Skipping {file_path}: source '{parser.source_name}' is excluded")
                    self.stats["sources_excluded"] += 1
                    return None
                return parser
        return None

    async def search_similar(
        self,
        query: str,
        user_id: str,
        compartment_level: int = 4,
        limit: int = 10
    ) -> List[Dict[str, Any]]:
        """
        Search for similar preferences.

        Args:
            query: Search query text
            user_id: User to search for
            compartment_level: Maximum compartment level to include
            limit: Max results

        Returns:
            List of matching preferences with scores
        """
        # Generate query embedding
        query_vector = vectorizer.embed(query)

        # Search Qdrant
        results = await self.qdrant.search(
            vector=query_vector,
            limit=limit,
            compartment_level=compartment_level,
            user_id=user_id
        )

        return results

    def get_stats(self) -> Dict[str, Any]:
        """Get pipeline statistics."""
        return {
            **self.stats,
            "filter_stats": self.filter.get_stats(),
            "vectorizer_dimension": vectorizer.dimension,
            "embedding_model": settings.embedding_model
        }

    def reset_filter(self):
        """Reset the filter state for a fresh ingestion run."""
        self.filter.reset()


# Global pipeline instance
pipeline = IngestPipeline()
