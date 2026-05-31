"""TikTok data parser."""

import json
import logging
from pathlib import Path
from typing import AsyncIterator, Optional
from datetime import datetime
import aiofiles

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


class TikTokParser(BaseParser):
    """
    Parser for TikTok data exports.

    Handles:
    - Browsing History.json
    - Favorite Videos.json
    - Following List.json
    - Like List.json
    """

    source_name = "tiktok"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a TikTok data export."""
        if file_path.suffix.lower() != '.json':
            return False

        name = file_path.name.lower()
        tiktok_files = [
            "browsing history",
            "favorite videos",
            "following list",
            "like list",
            "tiktok"
        ]
        return any(f in name for f in tiktok_files)

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse TikTok data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        file_name = file_path.name.lower()

        if "browsing" in file_name or "history" in file_name:
            async for pref in self._parse_browsing(file_path, default_compartment):
                yield pref
        elif "favorite" in file_name:
            async for pref in self._parse_favorites(file_path, default_compartment):
                yield pref
        elif "following" in file_name:
            async for pref in self._parse_following(file_path, default_compartment):
                yield pref
        elif "like" in file_name:
            async for pref in self._parse_likes(file_path, default_compartment):
                yield pref

    async def _parse_browsing(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Browsing History.json.

        NOTE: TikTok exports only contain video URLs, not titles or descriptions.
        URLs like "https://vm.tiktok.com/Z8d4R..." are meaningless as preference
        subjects. The meaningful signal is the VOLUME of TikTok usage, which
        we log but don't yield as individual preferences.

        The following list (_parse_following) contains actual usernames and IS useful.
        """
        logger.info(f"Parsing TikTok browsing history from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        browsing_list = data.get('BrowsingHistory', {}).get('BrowsingHistoryList', [])

        logger.info(
            f"TikTok browsing history: {len(browsing_list)} videos viewed "
            "(skipped - exports only contain URLs, not video titles)"
        )

        # Don't yield - URLs are not meaningful subjects
        return
        yield  # Make this a generator

    async def _parse_favorites(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Favorite Videos.json.

        NOTE: Same issue as browsing - only contains URLs, not video titles.
        """
        logger.info(f"Parsing TikTok favorites from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        favorites_list = data.get('FavoriteVideos', {}).get('FavoriteVideosList', [])

        logger.info(
            f"TikTok favorites: {len(favorites_list)} videos "
            "(skipped - exports only contain URLs, not video titles)"
        )

        # Don't yield - URLs are not meaningful subjects
        return
        yield  # Make this a generator

    async def _parse_following(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Following List.json."""
        logger.info(f"Parsing TikTok following from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        following_list = data.get('Following', {}).get('FollowingList', [])

        for item in following_list:
            username = item.get('UserName', '').strip()
            if not username:
                continue

            # Following is a strong signal (0.8 strength)
            yield ParsedPreference(
                subject=f"@{username}",
                preference_type="Like",
                category="social_media",
                strength=0.25,  # V2: Like
                observed_at=None,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={"username": username, "following": True}
            )

    async def _parse_likes(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Like List.json.

        NOTE: Same issue as browsing/favorites - only contains URLs, not video titles.
        """
        logger.info(f"Parsing TikTok likes from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON: {e}")
            return

        like_list = data.get('Activity', {}).get('LikeList', {}).get('ItemFavoriteList', [])

        logger.info(
            f"TikTok likes: {len(like_list)} videos "
            "(skipped - exports only contain URLs, not video titles)"
        )

        # Don't yield - URLs are not meaningful subjects
        return
        yield  # Make this a generator
