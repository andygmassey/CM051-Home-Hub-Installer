"""YouTube data parser."""

import csv
import json
import logging
from pathlib import Path
from typing import AsyncIterator, Optional
from datetime import datetime
import aiofiles

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


def _takeout_records(data: object, file_path: Path) -> list:
    """Return the dict records from a parsed Google Takeout payload.

    Every Takeout JSON export this parser handles is a top-level ARRAY of
    objects, and every limb below reads each record with ``item.get(...)``.

    When a file is claimed on its NAME and turns out to hold something else,
    ``for item in data`` iterates whatever the payload actually is. For a
    top-level object that means iterating its KEYS -- strings -- and the
    first ``.get`` raises ``AttributeError: 'str' object has no attribute
    'get'``, which pipeline.py logs at ERROR and which discards the ENTIRE
    file. That is exactly what three Facebook activity exports did on a real
    customer box.

    ``can_parse`` no longer claims those files, so this is the second line
    rather than the first. It exists because a name-based claim can always be
    surprised by a payload, and the failure mode should be a warning plus the
    usable records, never a discarded file.
    """
    if not isinstance(data, list):
        logger.warning(
            "%s is not a Google Takeout array (top level is %s); no records read",
            file_path, type(data).__name__,
        )
        return []

    records = [item for item in data if isinstance(item, dict)]
    skipped = len(data) - len(records)
    if skipped:
        logger.warning(
            "%s: skipped %d of %d entries that were not objects",
            file_path, skipped, len(data),
        )
    return records


class YouTubeParser(BaseParser):
    """
    Parser for YouTube/Google Takeout data exports.

    Handles:
    - watch-history.json or watch-history.html
    - like.json (liked videos)
    - subscriptions.json or subscriptions.csv (channel subscriptions)
    - comments.json (video comments)
    """

    source_name = "youtube"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a YouTube data export."""
        name = file_path.name.lower()
        suffix = file_path.suffix.lower()

        # YouTube-specific file patterns (Google Takeout format)
        # Be specific to avoid matching Facebook "likes_and_reactions" files
        youtube_patterns = [
            ("watch-history", [".json", ".html"]),
            ("like.json", [".json"]),  # Exact match for YouTube liked videos
            ("subscriptions", [".json", ".csv"]),
            ("comments", [".json"]),
        ]

        for pattern, valid_suffixes in youtube_patterns:
            if pattern in name and suffix in valid_suffixes:
                # Exclude Facebook-style files
                if "likes_and_reactions" in name:
                    return False
                # "comments" is a SUBSTRING match, and Facebook ships three
                # files whose names contain it:
                #   comments_and_reactions/comments.json
                #   groups/group_posts_and_comments.json
                #   groups/your_comments_in_groups.json
                # This parser is registered ahead of MetaParser, so claiming
                # on the name alone took all three off Meta before Meta was
                # ever asked -- and MetaParser's own shape check, written to
                # let a YouTube export "fall through to the YouTube parser",
                # could never run. Measured on a real customer box: three
                # ERROR lines, three whole files discarded.
                if pattern == "comments" and not self._looks_like_youtube_json(file_path):
                    return False
                return True

        return False

    @staticmethod
    def _looks_like_youtube_json(file_path: Path) -> bool:
        """Return True if the JSON file is shaped like a Google Takeout export.

        Takeout exports are a top-level ARRAY of records. Facebook activity
        exports are a top-level OBJECT keyed by "*_v2". Only the top-level
        shape is read, and the mirror of this check already lives in
        MetaParser._looks_like_facebook_activity_json.

        An unreadable or malformed file is NOT claimed. Both parsers then
        decline it, which is the correct outcome: a file nothing can identify
        is left alone rather than handed to a parser that will raise on it.
        """
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return False

        return isinstance(data, list)

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse YouTube data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        file_name = file_path.name.lower()

        if "watch-history" in file_name:
            if file_path.suffix.lower() == '.json':
                async for pref in self._parse_watch_history_json(file_path, default_compartment):
                    yield pref
            elif file_path.suffix.lower() == '.html':
                async for pref in self._parse_watch_history_html(file_path, default_compartment):
                    yield pref
        elif "like" in file_name and file_path.suffix.lower() == '.json':
            async for pref in self._parse_likes(file_path, default_compartment):
                yield pref
        elif "subscriptions" in file_name:
            if file_path.suffix.lower() == '.json':
                async for pref in self._parse_subscriptions_json(file_path, default_compartment):
                    yield pref
            elif file_path.suffix.lower() == '.csv':
                async for pref in self._parse_subscriptions_csv(file_path, default_compartment):
                    yield pref
        elif "comments" in file_name and file_path.suffix.lower() == '.json':
            async for pref in self._parse_comments(file_path, default_compartment):
                yield pref

    async def _parse_watch_history_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse watch-history.json.

        Format: [{"header": "YouTube", "title": "Watched X", "titleUrl": "...", "time": "..."}]
        """
        logger.info(f"Parsing YouTube watch history from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        # Aggregate by video to count views
        video_views = {}

        for item in _takeout_records(data, file_path):
            try:
                title = item.get('title', '').strip()
                title_url = item.get('titleUrl', '').strip()
                time_str = item.get('time', '').strip()

                # Extract video title from "Watched X" format
                if title.startswith('Watched '):
                    video_title = title[8:]  # Remove "Watched "
                else:
                    video_title = title

                if not video_title:
                    continue

                # Aggregate views
                if video_title not in video_views:
                    video_views[video_title] = {
                        'count': 0,
                        'url': title_url,
                        'last_watched': None
                    }

                video_views[video_title]['count'] += 1

                # Parse timestamp
                if time_str and video_views[video_title]['last_watched'] is None:
                    try:
                        # Format: "2023-11-15T14:23:45.678Z"
                        timestamp = datetime.fromisoformat(time_str.replace('Z', '+00:00'))
                        video_views[video_title]['last_watched'] = timestamp
                    except ValueError:
                        pass

            except Exception as e:
                logger.warning(f"Error parsing watch history item: {e}")
                continue

        # Create preferences from view counts
        for video_title, data in video_views.items():
            # Base strength 0.5, increase with multiple views
            strength = min(0.5 + (data['count'] * 0.05), 0.75)

            yield ParsedPreference(
                subject=video_title,
                preference_type="Like",
                category="video",
                strength=strength,
                observed_at=data['last_watched'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "view_count": data['count'],
                    "url": data['url'],
                }
            )

    async def _parse_watch_history_html(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse watch-history.html (older format)."""
        # HTML parsing would require BeautifulSoup - skip for now
        logger.info(f"Skipping HTML watch history (JSON format recommended): {file_path}")
        return
        yield  # Make this a generator

    async def _parse_likes(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse like.json (liked videos).

        Likes are stronger signals than views.
        """
        logger.info(f"Parsing YouTube likes from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        for item in _takeout_records(data, file_path):
            try:
                title = item.get('title', '').strip()
                title_url = item.get('titleUrl', '').strip()
                time_str = item.get('time', '')

                if not title:
                    continue

                # Parse timestamp
                timestamp = None
                if time_str:
                    try:
                        timestamp = datetime.fromisoformat(time_str.replace('Z', '+00:00'))
                    except ValueError:
                        pass

                # V2: Likes are explicit positive signals
                yield ParsedPreference(
                    subject=title,
                    preference_type="Like",
                    category="video",
                    strength=0.30,  # V2: Explicit like
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "url": title_url,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing like: {e}")
                continue

    async def _parse_subscriptions_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse subscriptions.json (channel subscriptions)."""
        logger.info(f"Parsing YouTube subscriptions from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        for item in _takeout_records(data, file_path):
            try:
                snippet = item.get('snippet', {})
                channel_title = snippet.get('title', '').strip()
                channel_id = snippet.get('resourceId', {}).get('channelId', '')

                if not channel_title:
                    continue

                # Subscriptions are strong interest signals
                yield ParsedPreference(
                    subject=channel_title,
                    preference_type="Like",
                    category="video",
                    strength=0.40,  # V2: Subscription
                    observed_at=None,
                    source=self.source_name,
                    source_id=channel_id,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "channel_id": channel_id,
                        "subscription": True,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing subscription: {e}")
                continue

    async def _parse_subscriptions_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse subscriptions.csv."""
        logger.info(f"Parsing YouTube subscriptions from CSV {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                channel_title = row.get('Channel Title', '').strip()
                channel_id = row.get('Channel Id', '').strip()

                if not channel_title:
                    continue

                yield ParsedPreference(
                    subject=channel_title,
                    preference_type="Like",
                    category="video",
                    strength=0.40,  # V2: Subscription
                    observed_at=None,
                    source=self.source_name,
                    source_id=channel_id,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "channel_id": channel_id,
                        "subscription": True,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing subscription row: {e}")
                continue

    async def _parse_comments(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse comments.json (video comments).

        NOTE: Comment text itself isn't a useful preference subject.
        Truncated text like "Commented on video: This is my thoughts..." is garbage.

        The signal is engagement with certain videos, but without video titles
        in the export, we can only log the activity.
        """
        logger.info(f"Parsing YouTube comments from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        # Count comments by video
        video_comment_counts: dict[str, int] = {}
        for item in _takeout_records(data, file_path):
            video_id = item.get('snippet', {}).get('videoId', '')
            if video_id:
                video_comment_counts[video_id] = video_comment_counts.get(video_id, 0) + 1

        total_comments = sum(video_comment_counts.values())
        logger.info(
            f"YouTube comments: {total_comments} comments on {len(video_comment_counts)} videos "
            "(skipped - comment text isn't a useful preference subject)"
        )

        # Don't yield - truncated comment text creates garbage preferences
        return
        yield  # Make this a generator
