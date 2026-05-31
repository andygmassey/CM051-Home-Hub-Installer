"""Meta (Facebook/Instagram) data parser."""

import json
import logging
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, Any
from datetime import datetime
import aiofiles
import zipfile
import tempfile

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


class MetaParser(BaseParser):
    """
    Parser for Meta (Facebook/Instagram) data exports.

    Handles:
    - Facebook likes and reactions
    - Facebook pages liked
    - Instagram likes
    - Instagram saved posts
    - Events responses
    """

    source_name = "meta"

    SUPPORTED_PATTERNS = [
        # Reactions and engagement
        "likes_and_reactions",
        "pages_you've_liked",
        "liked_posts",
        "saved_posts",
        "your_event_responses",
        "posts_and_comments",
        # Rich content preferences (actual titles/content)
        "movies_and_tv",
        "books",
        "music",
        "your_posts",
        "check_ins",
    ]

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a Meta data export."""
        if file_path.suffix.lower() == ".zip":
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = zf.namelist()
                    return any(
                        any(pattern in n.lower() for pattern in self.SUPPORTED_PATTERNS)
                        for n in names
                    )
            except Exception:
                return False

        if file_path.suffix.lower() == ".json":
            name = file_path.name.lower()
            return any(pattern in name for pattern in self.SUPPORTED_PATTERNS)

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Meta data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        if file_path.suffix.lower() == ".zip":
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        else:
            async for pref in self._parse_json(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        zip_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a Meta data export zip file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(tmpdir)

            # Find and process all relevant files
            for pattern in self.SUPPORTED_PATTERNS:
                for file in Path(tmpdir).rglob(f"*{pattern}*.json"):
                    async for pref in self._parse_json(file, default_compartment):
                        yield pref

    async def _parse_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a single Meta JSON file."""
        file_name = file_path.name.lower()

        async with aiofiles.open(file_path, 'r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON {file_path}: {e}")
            return

        # Route to appropriate parser based on file name
        if "likes_and_reactions" in file_name or "liked_posts" in file_name:
            async for pref in self._parse_likes(data, default_compartment):
                yield pref
        elif "pages" in file_name and "liked" in file_name:
            async for pref in self._parse_pages(data, default_compartment):
                yield pref
        elif "saved" in file_name:
            async for pref in self._parse_saved(data, default_compartment):
                yield pref
        elif "event" in file_name:
            async for pref in self._parse_events(data, default_compartment):
                yield pref
        # Rich content files
        elif "movies_and_tv" in file_name:
            async for pref in self._parse_movies_tv(data, default_compartment):
                yield pref
        elif "books" in file_name:
            async for pref in self._parse_books(data, default_compartment):
                yield pref
        elif "music" in file_name and "apple" not in file_name.lower():
            async for pref in self._parse_music(data, default_compartment):
                yield pref
        elif "your_posts" in file_name or "check_ins" in file_name:
            async for pref in self._parse_posts(data, default_compartment):
                yield pref

    async def _parse_likes(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse likes and reactions."""
        # Handle different data structures
        items = []
        if isinstance(data, dict):
            # Facebook format (old)
            items = data.get("likes_and_reactions", [])
            if not items:
                items = data.get("reactions_v2", [])
            # Instagram format
            if not items:
                items = data.get("likes_media_likes", [])
        elif isinstance(data, list):
            # New Facebook format (2026) - array at root
            items = data

        for item in items:
            if not isinstance(item, dict):
                continue

            # Detect format and parse accordingly
            if "label_values" in item:
                # New Facebook format (2026)
                async for pref in self._parse_facebook_2026_reaction(item, default_compartment):
                    yield pref
            elif "string_list_data" in item:
                # Instagram format
                async for pref in self._parse_instagram_like(item, default_compartment):
                    yield pref
            else:
                # Old Facebook format (pre-2026)
                async for pref in self._parse_facebook_legacy_reaction(item, default_compartment):
                    yield pref

    async def _parse_facebook_2026_reaction(
        self,
        item: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse new Facebook reaction format (2026)."""
        try:
            # Extract data from label_values array
            reaction_type = None
            owner_name = None
            url = None
            timestamp = item.get("timestamp", 0)

            for label_value in item.get("label_values", []):
                label = label_value.get("label", "")

                if label == "Reaction":
                    reaction_type = label_value.get("value")
                elif label == "URL":
                    url = label_value.get("value")
                elif label_value.get("title") == "Owner":
                    # Navigate nested dict structure for owner name
                    dicts = label_value.get("dict", [])
                    if dicts and len(dicts) > 0:
                        inner_dict = dicts[0].get("dict", [])
                        if inner_dict and len(inner_dict) > 0:
                            for field in inner_dict:
                                if field.get("label") == "Name":
                                    owner_name = field.get("value")
                                    break

            if not owner_name or not reaction_type:
                return

            # Map reaction to preference (V2: bipolar scale -1 to +1)
            reaction_map = {
                "Like": ("Like", 0.15),     # Low effort positive
                "Love": ("Like", 0.30),     # Deliberate strong positive
                "Haha": ("Like", 0.10),     # Entertained
                "Wow": ("Like", 0.08),      # Surprised (near neutral)
                "Sad": ("Dislike", -0.05),  # Empathy for sad content
                "Angry": ("Dislike", -0.35),  # Clear dislike!
            }
            pref_type, strength = reaction_map.get(reaction_type, ("Like", 0.15))

            # Parse timestamp
            observed_at = None
            if timestamp:
                try:
                    observed_at = datetime.fromtimestamp(timestamp)
                except Exception:
                    pass

            yield ParsedPreference(
                subject=owner_name,
                preference_type=pref_type,
                strength=strength,
                compartment_level=default_compartment,
                source="facebook",
                category="facebook_content",
                observed_at=observed_at,
                size=self.classify_size(owner_name, "social"),
                extra={
                    "reaction": reaction_type,
                    "url": url,
                    "fbid": item.get("fbid")
                }
            )

        except Exception as e:
            logger.warning(f"Failed to parse Facebook 2026 reaction: {e}")

    async def _parse_instagram_like(
        self,
        item: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Instagram liked posts format."""
        try:
            username = item.get("title", "")
            if not username:
                return

            for string_data in item.get("string_list_data", []):
                href = string_data.get("href", "")
                timestamp = string_data.get("timestamp", 0)

                observed_at = None
                if timestamp:
                    try:
                        observed_at = datetime.fromtimestamp(timestamp)
                    except Exception:
                        pass

                yield ParsedPreference(
                    subject=username,
                    preference_type="Like",
                    strength=0.15,  # V2: Low effort like
                    compartment_level=default_compartment,
                    source="instagram",
                    category="instagram_creator",
                    observed_at=observed_at,
                    size="Small",
                    extra={
                        "url": href,
                        "type": "post_like"
                    }
                )

        except Exception as e:
            logger.warning(f"Failed to parse Instagram like: {e}")

    async def _parse_facebook_legacy_reaction(
        self,
        item: Dict,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse old Facebook reaction format (pre-2026)."""
        try:
            title = item.get("title", "")
            reaction = item.get("data", [{}])[0].get("reaction", {}).get("reaction", "LIKE")
            timestamp = item.get("timestamp", 0)

            if not title:
                return

            # Map reaction to preference type (V2: bipolar scale -1 to +1)
            reaction_map = {
                "LIKE": ("Like", 0.15),     # Low effort positive
                "LOVE": ("Like", 0.30),     # Deliberate strong positive
                "HAHA": ("Like", 0.10),     # Entertained
                "WOW": ("Like", 0.08),      # Surprised (near neutral)
                "SAD": ("Dislike", -0.05),  # Empathy for sad content
                "ANGRY": ("Dislike", -0.35),  # Clear dislike!
            }
            pref_type, strength = reaction_map.get(reaction.upper(), ("Like", 0.15))

            # Parse timestamp
            observed_at = None
            if timestamp:
                try:
                    observed_at = datetime.fromtimestamp(timestamp)
                except Exception:
                    pass

            # Clean up title (Meta often prefixes with action)
            subject = self._clean_title(title)
            if not subject:
                return

            yield ParsedPreference(
                subject=subject,
                preference_type=pref_type,
                strength=strength,
                compartment_level=default_compartment,
                source="facebook",
                category="social",
                observed_at=observed_at,
                size=self.classify_size(subject, "social"),
                extra={"reaction": reaction}
            )

        except Exception as e:
            logger.warning(f"Failed to parse Facebook legacy reaction: {e}")

    async def _parse_pages(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse liked pages."""
        items = []
        if isinstance(data, dict):
            items = data.get("page_likes_v2", [])
            if not items:
                items = data.get("pages", [])
        elif isinstance(data, list):
            items = data

        for item in items:
            if isinstance(item, dict):
                name = item.get("name", "") or item.get("title", "")
                timestamp = item.get("timestamp", 0)
            elif isinstance(item, str):
                name = item
                timestamp = 0
            else:
                continue

            if not name:
                continue

            observed_at = None
            if timestamp:
                try:
                    observed_at = datetime.fromtimestamp(timestamp)
                except Exception:
                    pass

            yield ParsedPreference(
                subject=name,
                preference_type="Like",
                strength=0.25,  # V2: Deliberate follow
                compartment_level=default_compartment,
                source=self.source_name,
                category="page",
                observed_at=observed_at,
                size="Small"
            )

    async def _parse_saved(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse saved posts/items."""
        items = []
        if isinstance(data, dict):
            items = data.get("saved_saved_media", [])
            if not items:
                items = data.get("saved_posts", [])
        elif isinstance(data, list):
            items = data

        for item in items:
            if not isinstance(item, dict):
                continue

            title = item.get("title", "")

            # Handle Instagram 2026 format with string_map_data
            timestamp = item.get("timestamp", 0)
            href = None
            string_map_data = item.get("string_map_data", {})
            if string_map_data:
                # Look for "Saved on" key which contains timestamp and href
                saved_on = string_map_data.get("Saved on", {})
                if saved_on:
                    timestamp = saved_on.get("timestamp", timestamp)
                    href = saved_on.get("href", "")

            if not title:
                continue

            subject = self._clean_title(title)
            if not subject:
                continue

            observed_at = None
            if timestamp:
                try:
                    observed_at = datetime.fromtimestamp(timestamp)
                except Exception:
                    pass

            extra = {}
            if href:
                extra["url"] = href

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                strength=0.35,  # V2: Explicit save
                compartment_level=default_compartment,
                source=self.source_name,
                category="saved",
                observed_at=observed_at,
                size=self.classify_size(subject, "saved"),
                extra=extra if extra else None
            )

    async def _parse_events(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse event responses."""
        items = []
        if isinstance(data, dict):
            items = data.get("event_responses_v2", [])
            if not items:
                items = data.get("events", [])
        elif isinstance(data, list):
            items = data

        for item in items:
            if isinstance(item, dict):
                name = item.get("name", "")
                response = item.get("response", "interested")
                timestamp = item.get("start_timestamp", 0)
            else:
                continue

            if not name:
                continue

            # Map response to preference (V2: bipolar scale)
            response_lower = response.lower()
            if "going" in response_lower:
                pref_type, strength = "Like", 0.50   # V2: Strong commitment
            elif "interested" in response_lower:
                pref_type, strength = "Like", 0.25   # V2: Weak intent
            elif "declined" in response_lower or "not" in response_lower:
                pref_type, strength = "Dislike", -0.15  # V2: Mild rejection
            else:
                pref_type, strength = "Neutral", 0.0

            observed_at = None
            if timestamp:
                try:
                    observed_at = datetime.fromtimestamp(timestamp)
                except Exception:
                    pass

            yield ParsedPreference(
                subject=name,
                preference_type=pref_type,
                strength=strength,
                compartment_level=default_compartment,
                source=self.source_name,
                category="event",
                observed_at=observed_at,
                size="Small",
                extra={"response": response}
            )

    def _clean_title(self, title: str) -> str:
        """Clean up Meta-style titles."""
        # Remove common prefixes
        prefixes = [
            "You liked ",
            "You reacted to ",
            "You saved ",
            "Liked ",
            "Reacted to ",
        ]
        cleaned = title
        for prefix in prefixes:
            if cleaned.startswith(prefix):
                cleaned = cleaned[len(prefix):]
                break

        # Remove "'s post" suffix
        if "'s post" in cleaned:
            cleaned = cleaned.split("'s post")[0]

        # Remove "photo" suffix
        if "'s photo" in cleaned:
            cleaned = cleaned.split("'s photo")[0]

        return cleaned.strip()

    async def _parse_movies_tv(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse movies and TV shows from Facebook profile."""
        items = []
        if isinstance(data, dict):
            items = data.get("profile_movies_tv", [])
        elif isinstance(data, list):
            items = data

        for item in items:
            if not isinstance(item, dict):
                continue

            # Extract title from attachments -> external_context -> name
            title = None
            attachments = item.get("attachments", [])
            for attachment in attachments:
                for data_item in attachment.get("data", []):
                    ext_context = data_item.get("external_context", {})
                    title = ext_context.get("name")
                    if title:
                        break
                if title:
                    break

            if not title:
                continue

            timestamp = item.get("timestamp", 0)
            observed_at = None
            if timestamp:
                try:
                    observed_at = datetime.fromtimestamp(timestamp)
                except Exception:
                    pass

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                strength=0.45,  # V2: Deliberate curation = strong signal
                compartment_level=default_compartment,
                source="facebook",
                category="movie_tv",
                observed_at=observed_at,
                size=self.classify_size(title, "media"),
                extra={"type": "watched"}
            )

    async def _parse_books(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse books from Facebook profile."""
        items = []
        if isinstance(data, dict):
            items = data.get("profile_books", [])
        elif isinstance(data, list):
            items = data

        for item in items:
            if not isinstance(item, dict):
                continue

            # Extract title from attachments -> external_context -> name
            title = None
            attachments = item.get("attachments", [])
            for attachment in attachments:
                for data_item in attachment.get("data", []):
                    ext_context = data_item.get("external_context", {})
                    title = ext_context.get("name")
                    if title:
                        break
                if title:
                    break

            if not title:
                continue

            timestamp = item.get("timestamp", 0)
            observed_at = None
            if timestamp:
                try:
                    observed_at = datetime.fromtimestamp(timestamp)
                except Exception:
                    pass

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                strength=0.45,  # V2: Deliberate curation
                compartment_level=default_compartment,
                source="facebook",
                category="book",
                observed_at=observed_at,
                size=self.classify_size(title, "media"),
                extra={"type": "read"}
            )

    async def _parse_music(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse music from Facebook profile."""
        items = []
        if isinstance(data, dict):
            items = data.get("profile_music", [])
        elif isinstance(data, list):
            items = data

        for item in items:
            if not isinstance(item, dict):
                continue

            # Extract from attachments or direct name
            title = None
            attachments = item.get("attachments", [])
            for attachment in attachments:
                for data_item in attachment.get("data", []):
                    ext_context = data_item.get("external_context", {})
                    title = ext_context.get("name")
                    if title:
                        break
                if title:
                    break

            if not title:
                title = item.get("name", "") or item.get("title", "")

            if not title:
                continue

            timestamp = item.get("timestamp", 0)
            observed_at = None
            if timestamp:
                try:
                    observed_at = datetime.fromtimestamp(timestamp)
                except Exception:
                    pass

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                strength=0.45,  # V2: Deliberate curation
                compartment_level=default_compartment,
                source="facebook",
                category="music",
                observed_at=observed_at,
                size=self.classify_size(title, "music")
            )

    async def _parse_posts(
        self,
        data: Any,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse your own posts to extract topics/interests.

        Only yields preferences for:
        1. Shared links with titles (the external content name is meaningful)
        2. Posts with clear, short content (not truncated garbage)

        Skips:
        - Long posts that would be truncated to meaningless "..."
        - Posts with no extractable subject
        """
        items = []
        if isinstance(data, dict):
            items = (data.get("your_posts_1", []) or
                     data.get("your_posts", []) or
                     data.get("status_updates", []))
        elif isinstance(data, list):
            items = data

        for item in items:
            if not isinstance(item, dict):
                continue

            # Extract shared link title (preferred - this is curated content)
            url = None
            link_title = None

            attachments = item.get("attachments", [])
            for attachment in attachments:
                for data_item in attachment.get("data", []):
                    ext_context = data_item.get("external_context", {})
                    url = ext_context.get("url")
                    link_title = ext_context.get("name")
                    if url and link_title:
                        break
                if url and link_title:
                    break

            # If we have a shared link with a title, use that
            if url and link_title and len(link_title) <= 150:
                timestamp = item.get("timestamp", 0)
                observed_at = None
                if timestamp:
                    try:
                        observed_at = datetime.fromtimestamp(timestamp)
                    except Exception:
                        pass

                yield ParsedPreference(
                    subject=link_title,
                    preference_type="Like",
                    strength=0.30,  # V2: Active sharing
                    compartment_level=default_compartment,
                    source="facebook",
                    category="shared_link",
                    observed_at=observed_at,
                    size=self.classify_size(link_title, "content"),
                    extra={
                        "type": "shared_link",
                        "url": url
                    }
                )
                # Don't also yield post content - the link is the signal

            # Skip raw post text - truncating user text creates garbage
            # The actual meaningful signals from posts are:
            # - Shared links (handled above)
            # - Check-ins (handled by _parse_saved or separate check-in file)
            # - Tagged pages/places (in other Meta exports)
