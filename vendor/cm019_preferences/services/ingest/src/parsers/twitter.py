"""Twitter/X data parser."""

import csv
import json
import logging
import zipfile
import tempfile
import re
from pathlib import Path
from typing import AsyncIterator, Optional, List, Set
from datetime import datetime
import aiofiles

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


def extract_twitter_signals(text: str) -> dict:
    """
    Extract meaningful signals from tweet text.

    Returns dict with:
    - hashtags: list of hashtags (without #)
    - mentions: list of @usernames (without @)
    - urls: list of URLs
    - has_signals: True if any signals were extracted
    """
    # Extract hashtags
    hashtags = re.findall(r'#(\w+)', text)

    # Extract @mentions
    mentions = re.findall(r'@(\w+)', text)

    # Extract URLs (simplified pattern)
    urls = re.findall(r'https?://[^\s]+', text)

    # Extract domains from URLs
    domains = []
    for url in urls:
        match = re.search(r'https?://(?:www\.)?([^/\s]+)', url)
        if match:
            domain = match.group(1)
            # Skip Twitter's URL shortener
            if domain not in ('t.co', 'twitter.com', 'x.com'):
                domains.append(domain)

    return {
        'hashtags': hashtags,
        'mentions': mentions,
        'urls': urls,
        'domains': domains,
        'has_signals': bool(hashtags or mentions or domains)
    }


class TwitterParser(BaseParser):
    """
    Parser for Twitter/X data exports.

    Handles:
    - tweets.js (posted tweets)
    - like.js (liked tweets)
    - follower.js and following.js (connections)
    - personalization.js (inferred interests and shows)
    - tweet.js in zip archives

    Twitter exports come as JS files with JSON data.
    Format: window.YTD.tweets.part0 = [...]
    """

    source_name = "twitter"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a Twitter data export."""
        if file_path.suffix.lower() == ".zip":
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    twitter_files = [
                        "tweet.js",
                        "like.js",
                        "follower.js",
                        "following.js",
                        "personalization.js"
                    ]
                    return any(f in n for n in names for f in twitter_files)
            except Exception:
                return False

        name = file_path.name.lower()
        twitter_files = [
            "tweet.js",
            "tweets.js",
            "like.js",
            "likes.js",
            "follower.js",
            "following.js",
            "personalization.js"
        ]
        return any(f in name for f in twitter_files)

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Twitter data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        if file_path.suffix.lower() == ".zip":
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        else:
            async for pref in self._parse_js_file(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        zip_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a Twitter data export zip file."""
        logger.info(f"Parsing Twitter export zip: {zip_path}")

        with tempfile.TemporaryDirectory() as tmpdir:
            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(tmpdir)

            tmpdir_path = Path(tmpdir)

            # Find and parse supported files
            for file in tmpdir_path.rglob("*.js"):
                async for pref in self._parse_js_file(file, default_compartment):
                    yield pref

    async def _parse_js_file(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a single Twitter JS file."""
        file_name = file_path.name.lower()

        if "personalization" in file_name:
            async for pref in self._parse_personalization(file_path, default_compartment):
                yield pref
        elif "tweet" in file_name:
            async for pref in self._parse_tweets(file_path, default_compartment):
                yield pref
        elif "like" in file_name:
            async for pref in self._parse_likes(file_path, default_compartment):
                yield pref
        elif "follower" in file_name or "following" in file_name:
            async for pref in self._parse_follows(file_path, default_compartment):
                yield pref

    def _extract_json_from_js(self, content: str) -> list:
        """
        Extract JSON data from Twitter's JS format.

        Twitter exports use format: window.YTD.tweets.part0 = [...]
        """
        try:
            # Find the JSON array
            start_idx = content.find('[')
            if start_idx == -1:
                return []

            # Extract from [ to end
            json_str = content[start_idx:]
            return json.loads(json_str)
        except Exception as e:
            logger.warning(f"Failed to extract JSON from JS file: {e}")
            return []

    async def _parse_tweets(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse tweets.js or tweet.js.

        Extracts meaningful signals from tweets:
        - Hashtags -> topic interests
        - @mentions -> people/accounts of interest
        - URLs -> content interests

        Skips tweets with no extractable signals (just plain text is not useful).
        """
        logger.info(f"Parsing Twitter tweets from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        tweets = self._extract_json_from_js(content)

        # Track seen signals to aggregate frequency
        hashtag_counts: dict[str, int] = {}
        mention_counts: dict[str, int] = {}
        hashtag_timestamps: dict[str, datetime] = {}
        mention_timestamps: dict[str, datetime] = {}

        for item in tweets:
            try:
                tweet = item.get('tweet', {})
                full_text = tweet.get('full_text', '').strip()
                created_at_str = tweet.get('created_at', '')

                if not full_text:
                    continue

                # Skip retweets - focus on original content
                if full_text.startswith('RT @'):
                    continue

                # Parse timestamp
                timestamp = None
                if created_at_str:
                    try:
                        timestamp = datetime.strptime(created_at_str, '%a %b %d %H:%M:%S %z %Y')
                    except ValueError:
                        pass

                # Extract structured signals from entities (more reliable than regex)
                entities = tweet.get('entities', {})
                hashtags = [tag['text'] for tag in entities.get('hashtags', [])]
                mentions = [m['screen_name'] for m in entities.get('user_mentions', [])]

                # Aggregate hashtag usage
                for tag in hashtags:
                    tag_lower = tag.lower()
                    hashtag_counts[tag_lower] = hashtag_counts.get(tag_lower, 0) + 1
                    if timestamp and (tag_lower not in hashtag_timestamps or
                                      timestamp > hashtag_timestamps[tag_lower]):
                        hashtag_timestamps[tag_lower] = timestamp

                # Aggregate mention usage
                for mention in mentions:
                    mention_lower = mention.lower()
                    mention_counts[mention_lower] = mention_counts.get(mention_lower, 0) + 1
                    if timestamp and (mention_lower not in mention_timestamps or
                                      timestamp > mention_timestamps[mention_lower]):
                        mention_timestamps[mention_lower] = timestamp

            except Exception as e:
                logger.warning(f"Error parsing tweet: {e}")
                continue

        # Yield preferences for hashtags (topics)
        for tag, count in hashtag_counts.items():
            # Calculate strength based on usage frequency
            if count >= 10:
                strength = 0.85
            elif count >= 5:
                strength = 0.75
            elif count >= 3:
                strength = 0.65
            else:
                strength = 0.55

            yield ParsedPreference(
                subject=f"#{tag}",
                preference_type="Like",
                category="interest",
                strength=strength,
                observed_at=hashtag_timestamps.get(tag),
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "twitter_hashtag",
                    "usage_count": count,
                }
            )

        # Yield preferences for frequently mentioned accounts
        for mention, count in mention_counts.items():
            # Only yield if mentioned multiple times (signal of interest)
            if count < 2:
                continue

            if count >= 10:
                strength = 0.8
            elif count >= 5:
                strength = 0.7
            else:
                strength = 0.6

            yield ParsedPreference(
                subject=f"@{mention}",
                preference_type="Like",
                category="social_media",
                strength=strength,
                observed_at=mention_timestamps.get(mention),
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "twitter_mention",
                    "mention_count": count,
                }
            )

        logger.info(f"Extracted {len(hashtag_counts)} hashtags, {len([m for m, c in mention_counts.items() if c >= 2])} mentions from tweets")

    async def _parse_likes(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse like.js or likes.js.

        Extracts meaningful signals from liked tweets:
        - Hashtags -> topic interests (liking = endorsing the topic)
        - @mentions -> people/accounts of interest

        Likes are stronger signals than own tweets (0.7+ strength).
        Aggregates by signal to show preference strength.
        """
        logger.info(f"Parsing Twitter likes from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        likes = self._extract_json_from_js(content)

        # Aggregate signals from liked content
        hashtag_counts: dict[str, int] = {}
        mention_counts: dict[str, int] = {}

        for item in likes:
            try:
                like = item.get('like', {})
                full_text = like.get('fullText', '').strip()

                if not full_text:
                    continue

                # Extract signals using regex (likes don't have structured entities)
                signals = extract_twitter_signals(full_text)

                for tag in signals['hashtags']:
                    tag_lower = tag.lower()
                    hashtag_counts[tag_lower] = hashtag_counts.get(tag_lower, 0) + 1

                for mention in signals['mentions']:
                    mention_lower = mention.lower()
                    mention_counts[mention_lower] = mention_counts.get(mention_lower, 0) + 1

            except Exception as e:
                logger.warning(f"Error parsing like: {e}")
                continue

        # Yield preferences for liked hashtags (endorsement = stronger signal)
        for tag, count in hashtag_counts.items():
            if count >= 10:
                strength = 0.9
            elif count >= 5:
                strength = 0.8
            elif count >= 2:
                strength = 0.7
            else:
                strength = 0.65

            yield ParsedPreference(
                subject=f"#{tag}",
                preference_type="Like",
                category="interest",
                strength=strength,
                observed_at=None,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "twitter_liked_hashtag",
                    "like_count": count,
                }
            )

        # Yield preferences for frequently liked accounts
        for mention, count in mention_counts.items():
            # Only yield if liked multiple times
            if count < 2:
                continue

            if count >= 10:
                strength = 0.85
            elif count >= 5:
                strength = 0.75
            else:
                strength = 0.65

            yield ParsedPreference(
                subject=f"@{mention}",
                preference_type="Like",
                category="social_media",
                strength=strength,
                observed_at=None,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "twitter_liked_account",
                    "like_count": count,
                }
            )

        logger.info(f"Extracted {len(hashtag_counts)} liked hashtags, {len([m for m, c in mention_counts.items() if c >= 2])} liked accounts")

    async def _parse_follows(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse follower.js or following.js.

        NOTE: Twitter exports only contain numeric account IDs, not screen names.
        These are not useful for preference extraction since "Twitter user 12345678"
        is meaningless. We skip individual follow preferences but log the count
        for reference.

        The personalization.js file (parsed separately) contains Twitter's
        inferred interests which ARE useful.
        """
        logger.info(f"Parsing Twitter follows from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        follows = self._extract_json_from_js(content)

        following_count = 0
        follower_count = 0

        for item in follows:
            try:
                if 'following' in item:
                    following_count += 1
                elif 'follower' in item:
                    follower_count += 1
            except Exception:
                continue

        # Log counts for reference but don't yield useless preferences
        logger.info(
            f"Twitter follows: {following_count} following, {follower_count} followers "
            "(skipped - exports only contain numeric IDs, not screen names)"
        )

        # Don't yield anything - numeric account IDs aren't useful preferences
        return
        yield  # Make this a generator

    async def _parse_personalization(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse personalization.js for Twitter-inferred interests.

        This file contains interests that Twitter has inferred from user behavior.
        These are pre-computed preference signals with high value.
        """
        logger.info(f"Parsing Twitter personalization from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        data = self._extract_json_from_js(content)
        if not data:
            return

        p13n_data = data[0].get('p13nData', {}) if data else {}
        interests_section = p13n_data.get('interests', {})

        # Parse inferred interests (high value - Twitter's ML-derived interests)
        interests = interests_section.get('interests', [])
        for item in interests:
            try:
                name = item.get('name', '').strip()
                is_disabled = item.get('isDisabled', False)

                if not name or is_disabled:
                    continue

                # V2: Twitter-inferred interests are ML noise - very weak signal
                yield ParsedPreference(
                    subject=name,
                    preference_type="Like",
                    category="interest",
                    strength=0.05,  # V2: ML inference, not explicit action
                    observed_at=None,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "type": "inferred_interest",
                        "source": "twitter_personalization",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing interest: {e}")
                continue

        # Parse shows (TV shows, events the user is interested in)
        shows = interests_section.get('shows', [])
        for show_name in shows:
            try:
                if not show_name or not isinstance(show_name, str):
                    continue

                show_name = show_name.strip()
                if not show_name:
                    continue

                yield ParsedPreference(
                    subject=show_name,
                    preference_type="Like",
                    category="movie_tv",
                    strength=0.05,  # V2: ML inference, not explicit action
                    observed_at=None,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "inferred_show",
                        "source": "twitter_personalization",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing show: {e}")
                continue

        logger.info(f"Parsed {len(interests)} interests and {len(shows)} shows from personalization")
