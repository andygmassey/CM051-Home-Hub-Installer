"""Reddit data parser."""

import csv
import logging
from pathlib import Path
from typing import AsyncIterator, Optional
from datetime import datetime
import aiofiles
import zipfile
import tempfile
import re

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


class RedditParser(BaseParser):
    """
    Parser for Reddit data exports.

    Handles:
    - post_votes.csv (upvotes/downvotes on posts)
    - comment_votes.csv (upvotes/downvotes on comments)
    - saved_posts.csv (saved posts)
    - saved_comments.csv (saved comments)
    - subscribed_subreddits.csv (subscribed subreddits)
    - comments.csv (user comments)
    - posts.csv (user posts)
    """

    source_name = "reddit"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a Reddit data export."""
        if file_path.suffix.lower() == ".zip":
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    # Check for characteristic Reddit export files
                    reddit_files = [
                        "post_votes.csv",
                        "comment_votes.csv",
                        "subscribed_subreddits.csv"
                    ]
                    return any(f in names for f in reddit_files)
            except Exception:
                return False

        name = file_path.name.lower()
        reddit_files = [
            "post_votes.csv",
            "comment_votes.csv",
            "saved_posts.csv",
            "saved_comments.csv",
            "subscribed_subreddits.csv",
            "comments.csv",
            "posts.csv"
        ]
        return any(name == f for f in reddit_files) or \
               name.startswith("export_") and name.endswith(".zip")

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Reddit data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        if file_path.suffix.lower() == ".zip":
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        else:
            async for pref in self._parse_csv(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        zip_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a Reddit data export zip file."""
        logger.info(f"Parsing Reddit export zip: {zip_path}")

        with tempfile.TemporaryDirectory() as tmpdir:
            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(tmpdir)

            tmpdir_path = Path(tmpdir)

            # Parse post votes
            post_votes_file = tmpdir_path / "post_votes.csv"
            if post_votes_file.exists():
                async for pref in self._parse_post_votes(post_votes_file, default_compartment):
                    yield pref

            # Parse comment votes
            comment_votes_file = tmpdir_path / "comment_votes.csv"
            if comment_votes_file.exists():
                async for pref in self._parse_comment_votes(comment_votes_file, default_compartment):
                    yield pref

            # Parse saved posts
            saved_posts_file = tmpdir_path / "saved_posts.csv"
            if saved_posts_file.exists():
                async for pref in self._parse_saved_posts(saved_posts_file, default_compartment):
                    yield pref

            # Parse saved comments
            saved_comments_file = tmpdir_path / "saved_comments.csv"
            if saved_comments_file.exists():
                async for pref in self._parse_saved_comments(saved_comments_file, default_compartment):
                    yield pref

            # Parse subscribed subreddits
            subscribed_file = tmpdir_path / "subscribed_subreddits.csv"
            if subscribed_file.exists():
                async for pref in self._parse_subscribed_subreddits(subscribed_file, default_compartment):
                    yield pref

    async def _parse_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a single Reddit CSV file."""
        file_name = file_path.name.lower()

        if "post_votes.csv" in file_name:
            async for pref in self._parse_post_votes(file_path, default_compartment):
                yield pref
        elif "comment_votes.csv" in file_name:
            async for pref in self._parse_comment_votes(file_path, default_compartment):
                yield pref
        elif "saved_posts.csv" in file_name:
            async for pref in self._parse_saved_posts(file_path, default_compartment):
                yield pref
        elif "saved_comments.csv" in file_name:
            async for pref in self._parse_saved_comments(file_path, default_compartment):
                yield pref
        elif "subscribed_subreddits.csv" in file_name:
            async for pref in self._parse_subscribed_subreddits(file_path, default_compartment):
                yield pref

    async def _parse_post_votes(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Reddit post_votes.csv.

        Format: id,permalink,direction
        Direction: "up" or "down"
        """
        logger.info(f"Parsing Reddit post votes from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                post_id = row.get('id', '').strip()
                permalink = row.get('permalink', '').strip()
                direction = row.get('direction', '').strip().lower()

                if not post_id or not permalink:
                    continue

                # Only create preferences for upvotes (downvotes are negative signals)
                if direction != 'up':
                    continue

                # Extract subreddit from permalink
                subreddit = self._extract_subreddit(permalink)

                yield ParsedPreference(
                    subject=f"Reddit post in r/{subreddit}" if subreddit else "Reddit post",
                    preference_type="Like",
                    category="social_media",
                    strength=0.20,  # V2: Comment
                    source=self.source_name,
                    source_id=post_id,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "subreddit": subreddit,
                        "post_url": permalink,
                        "vote_direction": direction,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing post vote row: {e}")
                continue

    async def _parse_comment_votes(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Reddit comment_votes.csv.

        Format: id,permalink,direction
        """
        logger.info(f"Parsing Reddit comment votes from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                comment_id = row.get('id', '').strip()
                permalink = row.get('permalink', '').strip()
                direction = row.get('direction', '').strip().lower()

                if not comment_id or not permalink:
                    continue

                # Only create preferences for upvotes
                if direction != 'up':
                    continue

                # Extract subreddit from permalink
                subreddit = self._extract_subreddit(permalink)

                yield ParsedPreference(
                    subject=f"Reddit comment in r/{subreddit}" if subreddit else "Reddit comment",
                    preference_type="Like",
                    category="social_media",
                    strength=0.18,  # V2
                    source=self.source_name,
                    source_id=comment_id,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "subreddit": subreddit,
                        "comment_url": permalink,
                        "vote_direction": direction,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing comment vote row: {e}")
                continue

    async def _parse_saved_posts(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Reddit saved_posts.csv.

        Saving posts is a strong signal of interest.
        Format: id,permalink
        """
        logger.info(f"Parsing Reddit saved posts from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                post_id = row.get('id', '').strip()
                permalink = row.get('permalink', '').strip()

                if not post_id or not permalink:
                    continue

                # Extract subreddit
                subreddit = self._extract_subreddit(permalink)

                # Saved posts are stronger signals than upvotes
                yield ParsedPreference(
                    subject=f"Reddit saved post from r/{subreddit}" if subreddit else "Reddit saved post",
                    preference_type="Like",
                    category="social_media",
                    strength=0.30,  # V2: Saved
                    source=self.source_name,
                    source_id=post_id,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "subreddit": subreddit,
                        "post_url": permalink,
                        "saved": True,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing saved post row: {e}")
                continue

    async def _parse_saved_comments(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Reddit saved_comments.csv.

        Format: id,permalink
        """
        logger.info(f"Parsing Reddit saved comments from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                comment_id = row.get('id', '').strip()
                permalink = row.get('permalink', '').strip()

                if not comment_id or not permalink:
                    continue

                # Extract subreddit
                subreddit = self._extract_subreddit(permalink)

                yield ParsedPreference(
                    subject=f"Reddit saved comment from r/{subreddit}" if subreddit else "Reddit saved comment",
                    preference_type="Like",
                    category="social_media",
                    strength=0.25,  # V2: Upvote
                    source=self.source_name,
                    source_id=comment_id,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "subreddit": subreddit,
                        "comment_url": permalink,
                        "saved": True,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing saved comment row: {e}")
                continue

    async def _parse_subscribed_subreddits(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Reddit subscribed_subreddits.csv.

        Subscriptions indicate strong topical interests.
        Format: subreddit
        """
        logger.info(f"Parsing Reddit subscribed subreddits from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                subreddit = row.get('subreddit', '').strip()

                if not subreddit:
                    continue

                # Remove r/ prefix if present
                if subreddit.startswith('r/'):
                    subreddit = subreddit[2:]

                # Subreddit subscriptions are strong signals
                yield ParsedPreference(
                    subject=f"r/{subreddit}",
                    preference_type="Like",
                    category="social_media",
                    strength=0.35,  # V2: Subscribe
                    source=self.source_name,
                    source_id=subreddit,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "subreddit": subreddit,
                        "subscription": True,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing subscribed subreddit row: {e}")
                continue

    def _extract_subreddit(self, permalink: str) -> Optional[str]:
        """Extract subreddit name from permalink."""
        # Example: https://www.reddit.com/r/homeassistant/comments/1k0epeg/...
        match = re.search(r'/r/([^/]+)/', permalink)
        if match:
            return match.group(1)
        return None
