"""Generic CSV parser for preferences."""

import csv
import logging
import re
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
        # NB: "type" deliberately removed from the category aliases. It also
        # appears under the "type" (preference-type) key above, so a CSV with a
        # `type` column (Like/Dislike/...) was wrongly mapping the preference
        # TYPE into the category field -- producing junk categories like "Like"
        # and pre-empting the subject inference below. A preference type is not
        # a category.
        "category": ["category", "cat", "group", "genre"],
        "compartment": ["compartment", "compartment_level", "privacy", "level"],
        "context": ["context", "situation", "when", "where"],
        "date": ["date", "created_at", "observed_at", "timestamp", "time", "datetime"]
    }

    # Subject-keyword -> canonical category fallback.
    #
    # A generic CSV with no `category` column previously produced points with
    # category=None. The wiki reads `category` off every preference: the Food
    # page filters category == "food", the Music page category == "music", and
    # each Topic page is one distinct category value. A None category reaches
    # NO page, so those points silently vanish from the wiki. This map gives an
    # uncategorised row a best-effort canonical category (the exact strings the
    # wiki readers expect) from keywords in its subject. It is intentionally
    # conservative -- only confident hits map to a specific category; everything
    # else falls back to "interest" (a real category that renders a Topic page)
    # rather than None. Categories here match the canonical vocabulary used by
    # the platform parsers (spotify/uber/etc.) and enrich's VALID_CATEGORIES.
    SUBJECT_CATEGORY_KEYWORDS = {
        "music": (
            "song", "album", "artist", "band", "track", "playlist", "spotify",
            "concert", "gig", "vinyl", "guitar", "jazz", "techno", "hip hop",
            "hip-hop",
        ),
        "food": (
            "restaurant", "cuisine", "dish", "recipe", "cafe", "café", "coffee",
            "pizza", "sushi", "ramen", "burger", "cooking", "dining", "bakery",
            "wine", "beer", "cocktail", "vegan", "vegetarian", "takeaway",
        ),
        "movie": ("movie", "film", "cinema", "documentary"),
        "tv": ("tv show", "tv series", "episode", "season", "netflix series"),
        "book": ("book", "novel", "author", "reading", "audiobook"),
        "podcast": ("podcast",),
        "place": (
            "travel", "destination", "city", "country", "hotel", "holiday",
            "vacation", "flight", "beach",
        ),
        "professional": (
            "career", "skill", "industry", "linkedin", "job", "profession",
            "certification", "conference",
        ),
    }

    def _infer_category(self, subject: str) -> str:
        """Best-effort canonical category from the subject text.

        Returns a specific category when a confident keyword matches, else
        "interest" -- never an empty/None value, so the point always reaches
        a wiki Topic page instead of silently disappearing.

        Matching is WORD-BOUNDARY, not substring: this stops accidental
        substring hits that mis-categorised real data, e.g. "techno" no longer
        fires inside "technology" (-> music) and "gig" no longer fires inside
        "Biggie". Multi-word keywords ("hip hop", "tv show") still match as
        phrases. ("director" was also removed from the movie list: it matched
        the job title "Director" far more often than a film director.)
        """
        text = (subject or "").lower()
        for category, keywords in self.SUBJECT_CATEGORY_KEYWORDS.items():
            for kw in keywords:
                if re.search(r"\b" + re.escape(kw) + r"\b", text):
                    return category
        return "interest"

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
            logger.warning(
                f"CSV has no recognized subject column: {file_path}. "
                f"Available columns: {reader.fieldnames}. "
                f"Add column mapping or use a platform-specific parser."
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

        # Get category: explicit CSV column wins, then the caller-supplied
        # default, then a subject-keyword inference so a row never lands with
        # no category (which would make it invisible to every wiki page).
        category = row.get(column_map.get("category", ""), "").strip() or default_category
        if not category:
            category = self._infer_category(subject)

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
