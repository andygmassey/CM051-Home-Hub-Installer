"""Generic CSV parser for preferences."""

import csv
import logging
from pathlib import Path
from typing import AsyncIterator, Optional, Dict
from datetime import datetime
import aiofiles

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


class CSVParser(BaseParser):
    """
    Generic CSV parser for preference data.

    Expected columns (flexible - many alternatives supported):
    - subject: What the preference is about
      Alternatives: name, title, label, description, subreddit, destination,
                   product, track, artist, url, and many more
    - type/preference_type: Like, Dislike, Love, Hate, Neutral
    - strength/rating: Numeric strength 0-1 or 1-5 or 1-10
    - category: Category of the preference
    - compartment/compartment_level: Privacy level 0-6
    - context: Context for the preference
    - date/created_at/observed_at: When preference was recorded

    The parser auto-detects subject columns from a wide range of common names
    used in platform data exports (Reddit, Uber, Spotify, etc.).
    """

    source_name = "csv"

    # Column name mappings (lowercase)
    # Extended subject mappings to handle diverse CSV formats from various platforms
    COLUMN_MAPPINGS = {
        "subject": [
            "subject", "name", "item", "thing", "what", "preference",
            # Common column names from platform exports
            "title", "label", "description", "text", "content", "value",
            # Social media specific
            "subreddit", "topic", "hashtag", "tag",
            # Location/travel specific
            "destination", "location", "address", "place",
            # Product/media specific
            "product", "product_name", "product_type", "track", "artist", "album",
            "movie", "show", "book", "podcast", "episode",
            # URL/link content
            "url", "link", "uri",
        ],
        "type": ["type", "preference_type", "pref_type", "kind"],
        "strength": ["strength", "rating", "score", "value", "intensity"],
        "category": ["category", "cat", "group", "type", "genre"],
        "compartment": ["compartment", "compartment_level", "privacy", "level"],
        "context": ["context", "situation", "when", "where"],
        "date": ["date", "created_at", "observed_at", "timestamp", "time", "datetime"]
    }

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a CSV."""
        return file_path.suffix.lower() == ".csv"

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        default_category: Optional[str] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse a CSV file and yield preferences.

        Args:
            file_path: Path to CSV file
            default_compartment: Default compartment level if not in CSV
            default_category: Default category if not in CSV
        """
        if default_compartment is None:
            default_compartment = settings.default_compartment

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        # Parse CSV
        reader = csv.DictReader(content.splitlines())

        # Map actual columns to standard names
        column_map = self._map_columns(reader.fieldnames or [])

        if "subject" not in column_map:
            # Not an error: the generic CSV parser is the fallback for arbitrary
            # CSVs, and most (e.g. LinkedIn auxiliary exports -- Rich_Media,
            # PhoneNumbers, Ad_Targeting, SearchQueries, Logins, Registration,
            # Education, etc.) legitimately carry no preference "subject" column.
            # Log at DEBUG so a clean install does not spam WARNINGs; a genuinely
            # malformed preference CSV is still skipped (and visible at -v).
            logger.debug(
                f"CSV has no recognized subject column: {file_path}. "
                f"Available columns: {reader.fieldnames}. "
                f"Skipping (not a preference CSV)."
            )
            return

        row_count = 0
        for row in reader:
            try:
                pref = self._parse_row(row, column_map, default_compartment, default_category)
                if pref:
                    row_count += 1
                    yield pref
            except Exception as e:
                logger.warning(f"Failed to parse row: {e}")
                continue

        logger.info(f"Parsed {row_count} preferences from {file_path}")

    def _map_columns(self, fieldnames: list) -> Dict[str, str]:
        """Map actual column names to standard names."""
        column_map = {}
        fieldnames_lower = {f.lower(): f for f in fieldnames}

        for standard_name, possible_names in self.COLUMN_MAPPINGS.items():
            for possible in possible_names:
                if possible in fieldnames_lower:
                    column_map[standard_name] = fieldnames_lower[possible]
                    break

        return column_map

    def _parse_row(
        self,
        row: Dict[str, str],
        column_map: Dict[str, str],
        default_compartment: int,
        default_category: Optional[str]
    ) -> Optional[ParsedPreference]:
        """Parse a single CSV row into a preference."""
        # Get subject (required)
        subject = row.get(column_map.get("subject", ""), "").strip()
        if not subject:
            return None

        # Get preference type
        pref_type = row.get(column_map.get("type", ""), "Like").strip()
        if pref_type.lower() not in ("like", "dislike", "love", "hate", "neutral"):
            pref_type = "Like"

        # Get strength
        strength_str = row.get(column_map.get("strength", ""), "")
        strength = self.classify_strength(strength_str) if strength_str else 0.5

        # Get category
        category = row.get(column_map.get("category", ""), "").strip() or default_category

        # Get compartment level
        compartment_str = row.get(column_map.get("compartment", ""), "")
        try:
            compartment = int(compartment_str) if compartment_str else default_compartment
            compartment = max(0, min(6, compartment))
        except ValueError:
            compartment = default_compartment

        # Get context
        context = row.get(column_map.get("context", ""), "").strip() or None

        # Get date
        date_str = row.get(column_map.get("date", ""), "").strip()
        observed_at = None
        if date_str:
            for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%m/%d/%Y"):
                try:
                    observed_at = datetime.strptime(date_str, fmt)
                    break
                except ValueError:
                    continue

        # Classify size
        size = self.classify_size(subject, category)

        return ParsedPreference(
            subject=subject,
            preference_type=pref_type.capitalize(),
            strength=strength,
            compartment_level=compartment,
            source=self.source_name,
            category=category,
            context=context,
            observed_at=observed_at,
            size=size
        )
