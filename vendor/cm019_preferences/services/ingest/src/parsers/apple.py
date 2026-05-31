"""Apple data parser."""

import csv
import json
import logging
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, List
from datetime import datetime
from collections import defaultdict
import aiofiles
import zipfile
import tempfile
import re
import xml.etree.ElementTree as ET

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


# Apple Health record types - ALLOWLIST (aggregate patterns only)
# These are safe to expose as patterns, not individual readings
APPLE_HEALTH_ALLOWED_TYPES = {
    # Activity (aggregate step counts, distance, calories)
    "HKQuantityTypeIdentifierStepCount",
    "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierActiveEnergyBurned",
    "HKQuantityTypeIdentifierFlightsClimbed",
    "HKQuantityTypeIdentifierAppleExerciseTime",
    # Heart (aggregate patterns only)
    "HKQuantityTypeIdentifierHeartRate",
    "HKQuantityTypeIdentifierRestingHeartRate",
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    # Body (weight trends)
    "HKQuantityTypeIdentifierBodyMass",
    # Sleep (aggregate patterns)
    "HKCategoryTypeIdentifierSleepAnalysis",
}

# Apple Health record types - BLOCKLIST (sensitive medical data)
# These should NEVER be parsed or stored
APPLE_HEALTH_BLOCKED_TYPES = {
    # Blood pressure / cardiovascular clinical
    "HKQuantityTypeIdentifierBloodPressureSystolic",
    "HKQuantityTypeIdentifierBloodPressureDiastolic",
    # Medications
    "HKCategoryTypeIdentifierMedications",
    # Reproductive health
    "HKCategoryTypeIdentifierMenstrualFlow",
    "HKCategoryTypeIdentifierCervicalMucusQuality",
    "HKCategoryTypeIdentifierOvulationTestResult",
    "HKCategoryTypeIdentifierSexualActivity",
    "HKCategoryTypeIdentifierIntermenstrualBleeding",
    # Lab/clinical results
    "HKQuantityTypeIdentifierBloodGlucose",
    "HKQuantityTypeIdentifierBloodAlcoholContent",
    "HKQuantityTypeIdentifierInsulinDelivery",
    # Any clinical record type
}

# Workout types to friendly names
APPLE_HEALTH_WORKOUT_NAMES = {
    "HKWorkoutActivityTypeSwimming": "Swimming",
    "HKWorkoutActivityTypeWalking": "Walking",
    "HKWorkoutActivityTypeRunning": "Running",
    "HKWorkoutActivityTypeCycling": "Cycling",
    "HKWorkoutActivityTypeElliptical": "Elliptical",
    "HKWorkoutActivityTypeHiking": "Hiking",
    "HKWorkoutActivityTypeGolf": "Golf",
    "HKWorkoutActivityTypeOther": "Other Workout",
    "HKWorkoutActivityTypeUnderwaterDiving": "Diving",
    "HKWorkoutActivityTypeYoga": "Yoga",
    "HKWorkoutActivityTypeStrengthTraining": "Strength Training",
}


# Apple Books file patterns
APPLE_BOOKS_PATTERNS = {
    "global_annotations": "apple books global annotations",
    "collection_info": "apple books collection information",
    "user_annotations": "apple books user annotations",
    "bookstore_click": "bookstore click activity",
}

# Sensitive keywords for privacy filtering in iCloud Notes
# Notes containing these keywords in title OR content will be skipped
ICLOUD_NOTES_SENSITIVE_KEYWORDS = [
    # Medical
    "doctor", "diagnosis", "prescription", "hospital", "medical", "health",
    "symptoms", "surgery", "medication", "therapy", "counseling", "treatment",
    "clinic", "physician", "specialist", "gp",
    # Financial
    "password", "pin", "account number", "bank", "credit card", "salary",
    "tax", "ssn", "social security", "routing number", "investment", "portfolio",
    "barclays", "hsbc", "mortgage",
    # Personal/Legal
    "divorce", "affair", "will", "testament", "custody", "lawyer", "legal",
    # Identity
    "passport", "id number", "driver license", "licence",
]

# iCloud Calendar activity patterns for categorization
# Used to classify recurring events without storing specific event titles
CALENDAR_ACTIVITY_CATEGORIES = {
    "sports": [
        "rugby", "football", "soccer", "swimming", "gym", "training", "workout",
        "running", "cycling", "tennis", "golf", "yoga", "pilates", "crossfit",
        "basketball", "volleyball", "hockey", "cricket", "badminton", "squash",
        "dragon boat", "water polo", "hiking", "climbing", "fitness",
    ],
    "education": [
        "tutor", "tutoring", "class", "lesson", "school", "course", "workshop",
        "coding", "minecraft", "lego", "study", "homework", "learning", "lecture",
        "maths", "english", "chinese", "spanish", "french", "music lesson",
    ],
    "martial_arts": [
        "karate", "judo", "taekwondo", "kung fu", "martial arts",
        "boxing", "kickboxing", "bjj", "jiu jitsu", "aikido", "fencing",
    ],
    "social": [
        "dinner", "lunch", "breakfast", "drinks", "coffee", "party", "birthday",
        "anniversary", "reunion", "meetup", "gathering", "brunch", "bbq",
    ],
    "creative": [
        "art", "painting", "drawing", "music", "band", "choir", "orchestra",
        "dance", "ballet", "photography", "craft", "pottery", "writing",
    ],
    "wellness": [
        "massage", "spa", "meditation", "mindfulness", "therapy",
    ],
}

# Calendar event keywords to SKIP (sensitive/medical)
CALENDAR_SENSITIVE_KEYWORDS = [
    "doctor", "hospital", "clinic", "medical", "appointment", "injection",
    "surgery", "dentist", "physio", "physiotherapy", "therapy", "counseling",
    "blood", "scan", "test results", "prescription", "medication",
    "lawyer", "solicitor", "court", "legal",
    "interview", "meeting with", "call with",  # May contain sensitive work info
]


class AppleParser(BaseParser):
    """
    Parser for Apple data exports.

    Handles:
    - Apple Music - Favorites.csv (liked artists/playlists/albums)
    - Apple Music - Track Play History.csv (played tracks)
    - Apple Music - Play History Daily Tracks.csv (daily listening stats)
    - Store Transaction Purchase and Free Apps History.csv (App Store purchases)
      * Free apps: Like, strength=0.7 (just trying)
      * Paid apps: Like, strength=0.8 (financial commitment)
      * Subscription renewals: skipped (handled by Subscription History)
    - Subscription History.csv (Apple service & in-app subscriptions)
      * Active subscriptions: Like, strength=0.85
      * Inactive subscriptions: Like, strength=0.8
    - Reviews.csv (app/content reviews)
    - Your Podcasts.csv (podcast subscriptions) -> Like, strength=0.8
    - Podcasts Playstate.csv (episode plays) -> Experience, strength based on progress
    - Your Podcast Episode Bookmarks.csv (saved episodes) -> Like, strength=0.85
    - Apple Books Global Annotations.json (books with reading position/timestamps)
    - Apple Books Collection Information.json (book collections)
    - Apple Books User Annotations.json (user highlights/notes)
    - Bookstore Click Activity.csv (book browsing behavior)
    - iCloud Notes.zip (personal notes with privacy filtering)
    - iCloud Bookmarks.zip (Safari bookmarks with folder categorization)
    - Apple TV Bookmarks.csv (watched movies/shows) -> Like, strength=0.75
    - Apple TV Favorites and Wishlist.csv (saved movies/shows) -> Like, strength=0.8
    - Apple Health export.zip (health data with strict privacy controls)
      * Activity: steps, distance, calories, workouts
      * Heart: HR, HRV (aggregated patterns only)
      * Body: weight trends
      * Sleep: analysis patterns
      * All health data: compartment_level=5 (highest privacy)
    - iCloud Calendars and Reminders.zip (calendar patterns with privacy controls)
      * Calendar categories used (Work, Home, Family, etc.)
      * Subscribed calendars as interests (AI Tinkerers, Sports teams)
      * Recurring event patterns (categorized, not individual titles)
      * compartment_level=3 for calendar data
    """

    source_name = "apple"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is an Apple data export."""
        if file_path.suffix.lower() == ".zip":
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    # Check for characteristic Apple export files
                    apple_files = [
                        "apple music - favorites.csv",
                        "apple music - track play history.csv",
                        "apple music play activity.csv",
                        "podcasts playstate.csv",
                        "store transaction purchase",
                        "itunes and app-book re-download",
                        "online purchase history",
                        "marketing communications",
                        "video play activity",
                        "apple_media_services",
                        "apple books",
                    ]
                    # Check for iCloud Notes structure
                    has_icloud_notes = any(
                        "icloud notes/notes/" in n.lower() and n.endswith('.txt')
                        for n in zf.namelist()
                    )
                    # Check for iCloud Bookmarks structure (nested ZIP or direct CSVs)
                    has_icloud_bookmarks = any(
                        "icloud bookmarks/" in n.lower() and (n.endswith('.csv') or n.endswith('.zip'))
                        for n in zf.namelist()
                    )
                    # Check for Apple Health export structure
                    has_health_export = any(
                        "apple_health_export/export.xml" in n.lower() or
                        (n.endswith('export.xml') and 'health' in str(file_path).lower())
                        for n in zf.namelist()
                    )
                    # Check for iCloud Calendars structure (.ics files with Calendar Metadata)
                    has_icloud_calendars = any(
                        n.endswith('.ics') for n in zf.namelist()
                    ) and any(
                        'calendar metadata.json' in n.lower() for n in zf.namelist()
                    )
                    return has_icloud_notes or has_icloud_bookmarks or has_health_export or has_icloud_calendars or any(f in n for n in names for f in apple_files)
            except Exception:
                return False

        name = file_path.name.lower()

        # Check for Apple JSON files (Books, TV App)
        if file_path.suffix.lower() == ".json":
            for pattern in APPLE_BOOKS_PATTERNS.values():
                if pattern in name:
                    return True
            # TV App Favorites and Activity
            if "tv app favorites and activity" in name:
                return True

        apple_files = [
            "apple music - favorites.csv",
            "apple music - track play history.csv",
            "apple music - play history daily tracks.csv",
            "apple music - top content.csv",
            "apple music - container details.csv",
            "apple music - container origin.csv",
            "apple music - feature statistics.csv",
            "apple music play activity.csv",
            "apple music click activity.csv",
            "app store click activity.csv",
            "purchase server events.csv",
            "playback activity.csv",
            "itunes match re-download history.csv",
            "podcasts playstate.csv",
            "store transaction purchase",
            "itunes and app-book re-download",
            "online purchase history.csv",
            "marketing communications response.csv",
            "video play activity.csv",
            "your podcasts.csv",
            "your podcast episode bookmarks.csv",
            "reviews.csv",
            "bookstore click activity.csv",
            "apple tv bookmarks.csv",
            "apple tv favorites and wishlist.csv",
            "subscription history.csv",
        ]
        # Check standard patterns
        if any(f in name for f in apple_files):
            return True
        # Special check for TV App file (name contains "with Channel Support" in middle)
        if "tv app" in name and "click activity" in name:
            return True
        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Apple data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        if file_path.suffix.lower() == ".zip":
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == ".json":
            async for pref in self._parse_json(file_path, default_compartment):
                yield pref
        else:
            async for pref in self._parse_csv(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        zip_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse an Apple data export zip file."""
        logger.info(f"Parsing Apple export zip: {zip_path}")

        # Check for Apple Health export FIRST (before extraction)
        # Health exports can be 4GB+ so we stream-parse directly from ZIP
        with zipfile.ZipFile(zip_path, 'r') as zf:
            health_xml_path = None
            for name in zf.namelist():
                if name.lower().endswith('export.xml') and 'health' in zip_path.name.lower():
                    health_xml_path = name
                    break
                elif 'apple_health_export/export.xml' in name.lower():
                    health_xml_path = name
                    break

            if health_xml_path:
                logger.info(f"Detected Apple Health export: {health_xml_path}")
                async for pref in self._parse_health_export(zf, health_xml_path):
                    yield pref
                return  # Health exports are standalone

        with tempfile.TemporaryDirectory() as tmpdir:
            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(tmpdir)

            tmpdir_path = Path(tmpdir)

            # Check for iCloud Bookmarks structure (nested ZIP or direct CSVs)
            icloud_bookmarks_dir = tmpdir_path / "iCloud Bookmarks"
            if icloud_bookmarks_dir.exists():
                async for pref in self._parse_icloud_bookmarks(tmpdir_path, default_compartment):
                    yield pref
                return  # iCloud Bookmarks zips don't contain other Apple data

            # Check for iCloud Notes structure
            icloud_notes_dir = tmpdir_path / "iCloud Notes" / "Notes"
            if icloud_notes_dir.exists():
                async for pref in self._parse_icloud_notes(tmpdir_path, default_compartment):
                    yield pref
                return  # iCloud Notes zips don't contain other Apple data

            # Check for iCloud Calendars structure
            # Look for Calendar Metadata.json AND .ics files
            calendar_metadata = list(tmpdir_path.rglob("Calendar Metadata.json"))
            ics_files = list(tmpdir_path.rglob("*.ics"))
            if calendar_metadata and ics_files:
                async for pref in self._parse_icloud_calendars(tmpdir_path, default_compartment):
                    yield pref
                return  # iCloud Calendars zips don't contain other Apple data

            # Find and parse supported CSV files
            for file in tmpdir_path.rglob("*.csv"):
                async for pref in self._parse_csv(file, default_compartment):
                    yield pref

            # Find and parse supported JSON files (Apple Books)
            for file in tmpdir_path.rglob("*.json"):
                async for pref in self._parse_json(file, default_compartment):
                    yield pref

    async def _parse_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse a single Apple CSV file."""
        file_name = file_path.name.lower()

        if "apple music - favorites" in file_name:
            async for pref in self._parse_music_favorites(file_path, default_compartment):
                yield pref
        elif "apple music - top content" in file_name:
            async for pref in self._parse_top_content(file_path, default_compartment):
                yield pref
        elif "apple music - container details" in file_name:
            async for pref in self._parse_container_details(file_path, default_compartment):
                yield pref
        elif "apple music - container origin" in file_name:
            async for pref in self._parse_container_origin(file_path, default_compartment):
                yield pref
        elif "apple music - feature statistics" in file_name:
            async for pref in self._parse_feature_statistics(file_path, default_compartment):
                yield pref
        elif "apple music click activity" in file_name:
            async for pref in self._parse_music_click_activity(file_path, default_compartment):
                yield pref
        elif "app store click activity" in file_name:
            async for pref in self._parse_app_click_activity(file_path, default_compartment):
                yield pref
        elif "tv app" in file_name and "click activity" in file_name:
            async for pref in self._parse_tv_app_click_activity(file_path, default_compartment):
                yield pref
        elif "purchase server events" in file_name:
            async for pref in self._parse_purchase_events(file_path, default_compartment):
                yield pref
        elif "playback activity" in file_name:
            async for pref in self._parse_playback_activity(file_path, default_compartment):
                yield pref
        elif "itunes match re-download" in file_name:
            async for pref in self._parse_itunes_match_redownload(file_path, default_compartment):
                yield pref
        elif "apple music play activity" in file_name:
            # Priority: comprehensive play activity file
            async for pref in self._parse_play_activity(file_path, default_compartment):
                yield pref
        elif "track play history" in file_name:
            async for pref in self._parse_track_play_history(file_path, default_compartment):
                yield pref
        elif "play history daily tracks" in file_name:
            async for pref in self._parse_daily_tracks(file_path, default_compartment):
                yield pref
        elif "store transaction purchase" in file_name:
            async for pref in self._parse_app_purchases(file_path, default_compartment):
                yield pref
        elif "your podcasts" in file_name:
            async for pref in self._parse_podcasts(file_path, default_compartment):
                yield pref
        elif "podcasts playstate" in file_name:
            async for pref in self._parse_podcast_playstate(file_path, default_compartment):
                yield pref
        elif "podcast episode bookmarks" in file_name:
            async for pref in self._parse_podcast_bookmarks(file_path, default_compartment):
                yield pref
        elif "re-download" in file_name:
            async for pref in self._parse_redownload_history(file_path, default_compartment):
                yield pref
        elif "online purchase history" in file_name:
            async for pref in self._parse_online_purchases(file_path, default_compartment):
                yield pref
        elif "marketing communications response" in file_name:
            async for pref in self._parse_marketing_response(file_path, default_compartment):
                yield pref
        elif "video play activity" in file_name:
            async for pref in self._parse_video_activity(file_path, default_compartment):
                yield pref
        elif file_name == "reviews.csv":
            async for pref in self._parse_reviews(file_path, default_compartment):
                yield pref
        elif "bookstore click activity" in file_name:
            async for pref in self._parse_bookstore_click_activity(file_path, default_compartment):
                yield pref
        elif "apple tv bookmarks" in file_name:
            async for pref in self._parse_apple_tv_bookmarks(file_path, default_compartment):
                yield pref
        elif "apple tv favorites" in file_name:
            async for pref in self._parse_apple_tv_favorites(file_path, default_compartment):
                yield pref
        elif "subscription history" in file_name:
            async for pref in self._parse_subscription_history(file_path, default_compartment):
                yield pref

    async def _parse_json(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Apple JSON files (Books, TV App)."""
        file_name = file_path.name.lower()

        if APPLE_BOOKS_PATTERNS["global_annotations"] in file_name:
            async for pref in self._parse_books_global_annotations(file_path, default_compartment):
                yield pref
        elif APPLE_BOOKS_PATTERNS["collection_info"] in file_name:
            async for pref in self._parse_books_collections(file_path, default_compartment):
                yield pref
        elif APPLE_BOOKS_PATTERNS["user_annotations"] in file_name:
            async for pref in self._parse_books_user_annotations(file_path, default_compartment):
                yield pref
        elif "tv app favorites and activity" in file_name:
            async for pref in self._parse_tv_app_activity(file_path, default_compartment):
                yield pref

    async def _parse_music_favorites(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music - Favorites.csv.

        Format: Favorite Type, Item Reference, Item Description, Last Modified, Preference
        Types: Playlist, Artist, Album, Song
        """
        logger.info(f"Parsing Apple Music favorites from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                fav_type = row.get('Favorite Type', '').strip()
                item_ref = row.get('Item Reference', '').strip()
                item_desc = row.get('Item Description', '').strip()
                last_modified = row.get('Last Modified', '').strip()
                preference = row.get('Preference', 'LIKE').strip()

                if not item_desc or item_desc == 'N/A':
                    continue

                # Parse timestamp
                timestamp = None
                if last_modified:
                    try:
                        # Format: 2017-02-01T09:06:40.529Z
                        timestamp = datetime.fromisoformat(last_modified.replace('Z', '+00:00'))
                    except ValueError:
                        logger.warning(f"Could not parse date: {last_modified}")

                # Determine strength based on favorite type
                strength = 0.8 if preference == 'LIKE' else 0.5
                if fav_type == 'Artist':
                    strength = 0.85  # Artists are stronger signals than playlists

                yield ParsedPreference(
                    subject=item_desc,
                    preference_type="Like",
                    category="music",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    source_id=item_ref,
                    compartment_level=default_compartment,
                    size="Small" if fav_type == "Song" else "Medium",
                    extra={
                        "favorite_type": fav_type,
                        "preference": preference,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing music favorite row: {e}")
                continue

    async def _parse_track_play_history(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music - Track Play History.csv.

        Format: Track Name, Last Played Date, Is User Initiated
        Playing a track is a weaker signal than favoriting it.
        """
        logger.info(f"Parsing Apple Music play history from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Track counts for each song
        play_counts = {}

        for row in reader:
            try:
                track_name = row.get('Track Name', '').strip()
                last_played_str = row.get('Last Played Date', '').strip()
                is_user_initiated = row.get('Is User Initiated', 'false').strip().lower() == 'true'

                if not track_name:
                    continue

                # Only count user-initiated plays as preferences
                if not is_user_initiated:
                    continue

                # Count plays
                if track_name not in play_counts:
                    play_counts[track_name] = {
                        'count': 0,
                        'last_played': None
                    }

                play_counts[track_name]['count'] += 1

                # Parse timestamp
                if last_played_str and play_counts[track_name]['last_played'] is None:
                    try:
                        # Timestamp is in milliseconds since epoch
                        timestamp_ms = int(last_played_str)
                        timestamp = datetime.fromtimestamp(timestamp_ms / 1000.0)
                        play_counts[track_name]['last_played'] = timestamp
                    except (ValueError, OSError):
                        pass

            except Exception as e:
                logger.warning(f"Error parsing play history row: {e}")
                continue

        # Create preferences from play counts
        for track_name, data in play_counts.items():
            # Base strength 0.5, increase with play count
            # Cap at 0.75 to keep it below favorites
            strength = min(0.5 + (data['count'] * 0.05), 0.75)

            yield ParsedPreference(
                subject=track_name,
                preference_type="Like",
                category="music",
                strength=strength,
                observed_at=data['last_played'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "play_count": data['count'],
                    "content_type": "track",
                }
            )

    async def _parse_play_activity(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music Play Activity.csv.

        This is the comprehensive play activity file with detailed metadata.
        Format includes: Song Name, Album Name, Event Timestamp, Play Duration, etc.
        166K+ plays - much more detailed than Track Play History.

        Uses memory-efficient line-by-line reading for large files.
        """
        logger.info(f"Parsing comprehensive Apple Music play activity from {file_path}")

        # Memory-efficient: read line-by-line instead of loading entire file
        # Use synchronous reading in executor for csv.DictReader compatibility
        import asyncio

        def read_and_aggregate():
            play_counts = {}
            row_count = 0
            with open(file_path, mode='r', encoding='utf-8-sig', newline='') as f:
                reader = csv.DictReader(f)
                for row in reader:
                    row_count += 1
                    if row_count % 100000 == 0:
                        logger.info(f"Play activity progress: {row_count:,} rows processed")
                    try:
                        song_name = row.get('Song Name', '').strip()
                        album_name = row.get('Album Name', '').strip()
                        event_timestamp = row.get('Event Timestamp', '').strip()
                        event_type = row.get('Event Type', '').strip()
                        play_duration_ms = row.get('Play Duration Milliseconds', '').strip()

                        # Only count PLAY_END events (completed plays)
                        if event_type != 'PLAY_END':
                            continue

                        if not song_name:
                            continue

                        # Create composite key with album for better deduplication
                        key = f"{song_name}|||{album_name}" if album_name else song_name

                        if key not in play_counts:
                            play_counts[key] = {
                                'song_name': song_name,
                                'album_name': album_name,
                                'count': 0,
                                'last_played': None,
                                'total_duration_ms': 0
                            }

                        play_counts[key]['count'] += 1

                        # Track duration
                        if play_duration_ms:
                            try:
                                play_counts[key]['total_duration_ms'] += int(play_duration_ms)
                            except ValueError:
                                pass

                        # Parse timestamp for last played
                        if event_timestamp and play_counts[key]['last_played'] is None:
                            try:
                                timestamp = datetime.fromisoformat(event_timestamp.replace('Z', '+00:00'))
                                play_counts[key]['last_played'] = timestamp
                            except ValueError:
                                pass

                    except Exception as e:
                        logger.warning(f"Error parsing play activity row: {e}")
                        continue

            logger.info(f"Play activity complete: {row_count:,} rows, {len(play_counts):,} unique songs")
            return play_counts

        # Run synchronous file reading in executor
        loop = asyncio.get_event_loop()
        play_counts = await loop.run_in_executor(None, read_and_aggregate)

        # Create preferences from aggregated data
        for key, data in play_counts.items():
            # Base strength 0.5, increase with play count
            # More generous than track history since these are completed plays
            strength = min(0.5 + (data['count'] * 0.03), 0.8)

            subject = data['song_name']
            if data['album_name']:
                subject = f"{data['song_name']} - {data['album_name']}"

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                category="music",
                strength=strength,
                observed_at=data['last_played'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "play_count": data['count'],
                    "total_duration_ms": data['total_duration_ms'],
                    "content_type": "song",
                    "album": data['album_name'],
                }
            )

    async def _parse_daily_tracks(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music - Play History Daily Tracks.csv.

        96K+ records with daily aggregated listening stats.
        Includes play counts, skip counts, and play duration.
        """
        logger.info(f"Parsing daily music listening from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate by track to get total plays
        track_plays = {}

        for row in reader:
            try:
                track_desc = row.get('Track Description', '').strip()
                play_count_str = row.get('Play Count', '').strip()
                skip_count_str = row.get('Skip Count', '').strip()
                date_played_str = row.get('Date Played', '').strip()

                if not track_desc:
                    continue

                # Parse counts
                play_count = 1
                skip_count = 0
                if play_count_str:
                    try:
                        play_count = int(play_count_str)
                    except ValueError:
                        pass

                if skip_count_str:
                    try:
                        skip_count = int(skip_count_str)
                    except ValueError:
                        pass

                # Aggregate by track
                if track_desc not in track_plays:
                    track_plays[track_desc] = {
                        'play_count': 0,
                        'skip_count': 0,
                        'last_played': None
                    }

                track_plays[track_desc]['play_count'] += play_count
                track_plays[track_desc]['skip_count'] += skip_count

                # Parse timestamp (format: 20150702)
                if date_played_str and track_plays[track_desc]['last_played'] is None:
                    try:
                        timestamp = datetime.strptime(date_played_str, '%Y%m%d')
                        track_plays[track_desc]['last_played'] = timestamp
                    except ValueError:
                        pass

            except Exception as e:
                logger.warning(f"Error parsing daily tracks row: {e}")
                continue

        # Create preferences from play data
        for track_desc, data in track_plays.items():
            # Calculate strength based on play count and skip ratio
            # Base: 0.5, increase with play count, decrease if skipped often
            play_count = data['play_count']
            skip_count = data['skip_count']
            total = play_count + skip_count
            skip_ratio = skip_count / total if total > 0 else 0

            # Start at 0.5, add up to 0.3 for many plays, subtract up to 0.2 for high skip ratio
            strength = 0.5 + min(play_count * 0.02, 0.3) - (skip_ratio * 0.2)
            strength = max(0.3, min(strength, 0.8))  # Clamp between 0.3 and 0.8

            yield ParsedPreference(
                subject=track_desc,
                preference_type="Like" if strength >= 0.5 else "Neutral",
                category="music",
                strength=strength,
                observed_at=data['last_played'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "play_count": play_count,
                    "skip_count": skip_count,
                    "skip_ratio": round(skip_ratio, 2),
                    "content_type": "song",
                }
            )

    async def _parse_app_purchases(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Store Transaction Purchase and Free Apps History.csv.

        Format: Item Purchased Date, Content Type, Item Description, Invoice Item Total, ...

        Strength calibration:
        - Free app downloads: 0.7 (just trying it)
        - Paid app purchases: 0.8 (financial commitment)
        - Subscription renewals: skipped (handled by _parse_subscription_history)

        Deduplicates by Item Reference Number to avoid counting re-downloads.
        """
        logger.info(f"Parsing App Store purchases from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Track seen apps to avoid duplicates from re-downloads
        seen_items = set()
        app_count = 0
        subscription_skipped = 0

        for row in reader:
            try:
                item_desc = row.get('Item Description', '').strip()
                purchased_date_str = row.get('Item Purchased Date', '').strip()
                content_type = row.get('Content Type', '').strip()
                item_ref = row.get('Item Reference Number', '').strip()
                invoice_total = row.get('Invoice Item Total', '').strip()

                if not item_desc:
                    continue

                # Skip subscription renewals (handled by subscription history)
                if 'subscription' in content_type.lower():
                    subscription_skipped += 1
                    continue

                # Deduplicate by item reference (avoid re-download duplicates)
                if item_ref and item_ref in seen_items:
                    continue
                if item_ref:
                    seen_items.add(item_ref)

                # Parse timestamp
                timestamp = None
                if purchased_date_str:
                    try:
                        # Format: 2025-12-29T22:16:08.820Z
                        timestamp = datetime.fromisoformat(purchased_date_str.replace('Z', '+00:00'))
                    except ValueError:
                        logger.warning(f"Could not parse date: {purchased_date_str}")

                # Determine if paid purchase
                is_paid = bool(invoice_total and invoice_total not in ('', '0', '£0', '$0', '€0'))

                # Determine category and strength based on content type
                category = "app"
                if "Mac Apps" in content_type:
                    category = "mac_app"
                elif "iOS" in content_type or "tvOS" in content_type:
                    category = "ios_app"
                elif "Music" in content_type:
                    category = "music"
                elif "Books" in content_type:
                    category = "book"

                # Strength based on financial commitment
                if is_paid:
                    strength = 0.8  # Paid = stronger commitment
                else:
                    strength = 0.7  # Free download = trying it out

                app_count += 1
                yield ParsedPreference(
                    subject=item_desc,
                    preference_type="Like",
                    category=category,
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    source_id=item_ref,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": content_type,
                        "purchase_type": "paid" if is_paid else "free",
                        "price": invoice_total if is_paid else None,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing app purchase row: {e}")
                continue

        logger.info(f"Parsed {app_count} unique app purchases, skipped {subscription_skipped} subscription renewals")

    async def _parse_subscription_history(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Subscription History.csv.

        Columns: Subscription Initiated Date, Content Type, Item Description,
                 Container Description (app name), Automatic Renewal?, ...

        Subscriptions indicate ongoing commitment (strength=0.8).
        Active subscriptions (Automatic Renewal? = Yes) get higher strength (0.85).

        Content types include:
        - In-App Subscription (app-based subscriptions)
        - Apple Music Subscription
        - Apple News+ Subscription
        - Apple TV+ Direct Purchase
        - Apple Fitness+ Subscription
        - iCloud Storage Subscription
        """
        logger.info(f"Parsing subscription history from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Track unique subscriptions (by item reference)
        seen_subscriptions = set()
        subscription_count = 0

        for row in reader:
            try:
                item_desc = row.get('Item Description', '').strip()
                container_desc = row.get('Container Description', '').strip()
                content_type = row.get('Content Type', '').strip()
                item_ref = row.get('Item Reference Number', '').strip()
                initiated_date_str = row.get('Subscription Initiated Date', '').strip()
                auto_renewal = row.get('Automatic Renewal?', '').strip().lower() == 'yes'

                # Use container (app name) if available, otherwise item description
                subject = container_desc or item_desc
                if not subject:
                    continue

                # Deduplicate by item reference
                if item_ref and item_ref in seen_subscriptions:
                    continue
                if item_ref:
                    seen_subscriptions.add(item_ref)

                # Parse timestamp
                timestamp = None
                if initiated_date_str:
                    try:
                        timestamp = datetime.fromisoformat(initiated_date_str.replace('Z', '+00:00'))
                    except ValueError:
                        logger.warning(f"Could not parse date: {initiated_date_str}")

                # Determine category based on content type
                category = "subscription"
                if "Music" in content_type:
                    category = "music_subscription"
                elif "News" in content_type:
                    category = "news_subscription"
                elif "TV" in content_type:
                    category = "tv_subscription"
                elif "Fitness" in content_type:
                    category = "fitness_subscription"
                elif "iCloud" in content_type or "Storage" in content_type:
                    category = "storage_subscription"
                elif "In-App" in content_type:
                    category = "app_subscription"

                # Strength: V2 - active subscriptions are stronger signals
                strength = 0.50 if auto_renewal else 0.45  # V2: Ongoing/past payment

                subscription_count += 1
                yield ParsedPreference(
                    subject=subject,
                    preference_type="Like",
                    category=category,
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    source_id=item_ref,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": content_type,
                        "subscription_name": item_desc,
                        "app_name": container_desc,
                        "is_active": auto_renewal,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing subscription row: {e}")
                continue

        logger.info(f"Parsed {subscription_count} unique subscriptions")

    async def _parse_podcasts(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Your Podcasts.csv.

        Columns: Last updated, Added on, Feed URL, Title, Subscribed?, Last touched on,
                 Show type, Sort, Playback newest to oldest

        Podcast subscriptions indicate interests.
        - Subscribed podcasts: preference_type="Like", strength=0.8 (explicit subscription)
        - Non-subscribed (in library): preference_type="Like", strength=0.65 (weaker signal)
        """
        logger.info(f"Parsing podcast subscriptions from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())
        subscribed_count = 0
        library_count = 0

        for row in reader:
            try:
                # Format varies, look for common fields
                podcast_name = row.get('Show Title', '') or row.get('Podcast Name', '') or row.get('Title', '')
                podcast_name = podcast_name.strip()

                if not podcast_name:
                    continue

                # Extract additional fields
                feed_url = row.get('Feed URL', '').strip()
                is_subscribed = row.get('Subscribed?', '').strip().lower() == 'yes'
                added_on = row.get('Added on', '').strip()
                last_touched = row.get('Last touched on', '').strip()

                # Parse timestamp
                timestamp = None
                date_str = added_on or last_touched
                if date_str:
                    try:
                        timestamp = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
                    except ValueError:
                        pass

                # V2: Subscribed podcasts are stronger signals
                if is_subscribed:
                    strength = 0.40  # V2: Commitment
                    subscribed_count += 1
                else:
                    strength = 0.25  # V2: Interest
                    library_count += 1

                yield ParsedPreference(
                    subject=podcast_name,
                    preference_type="Like",
                    category="podcast",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": "podcast_subscription",
                        "feed_url": feed_url,
                        "is_subscribed": is_subscribed,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing podcast row: {e}")
                continue

        logger.info(f"Podcast subscriptions: {subscribed_count} subscribed, {library_count} in library")

    async def _parse_podcast_playstate(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Podcasts Playstate.csv.

        Columns: Feed URL, Episode ID, Visible?, Marked as played on, Manually set,
                 Is New?, Last played on, Playback position, Play count, Has been played?

        Each played episode becomes a preference with:
        - preference_type="Experience" (episode listening experience)
        - strength based on play progress: 0.5 (started) to 0.75 (completed/high play count)
        - category: "podcast"
        """
        logger.info(f"Parsing podcast playstate from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Track both individual episodes and aggregate by podcast
        episode_plays = []
        podcast_aggregates = {}
        played_count = 0
        skipped_count = 0

        for row in reader:
            try:
                feed_url = row.get('Feed URL', '').strip()
                episode_id = row.get('Episode ID', '').strip()
                has_been_played = row.get('Has been played?', '').strip().lower() == 'yes'
                play_count_str = row.get('Play count', '').strip()
                playback_position_str = row.get('Playback position', '').strip()
                last_played_str = row.get('Last played on', '').strip()

                if not feed_url:
                    continue

                # Skip episodes that haven't been played
                if not has_been_played:
                    skipped_count += 1
                    continue

                played_count += 1

                # Extract podcast name from feed URL
                podcast_name = self._extract_podcast_name(feed_url)

                # Parse play count
                play_count = 1
                if play_count_str:
                    try:
                        play_count = max(1, int(play_count_str))
                    except ValueError:
                        pass

                # Parse playback position (in seconds)
                playback_position = 0.0
                if playback_position_str:
                    try:
                        playback_position = float(playback_position_str)
                    except ValueError:
                        pass

                # Parse last played timestamp
                last_played = None
                if last_played_str:
                    try:
                        last_played = datetime.fromisoformat(last_played_str.replace('Z', '+00:00'))
                    except ValueError:
                        pass

                # Calculate strength based on engagement
                # Base: 0.5 for any played episode
                # Bonus for play count and position
                strength = 0.5
                if play_count >= 2:
                    strength += 0.1
                if playback_position >= 600:  # 10+ minutes listened
                    strength += 0.1
                if playback_position >= 1800:  # 30+ minutes listened
                    strength += 0.05
                strength = min(strength, 0.75)

                # Store episode play
                episode_plays.append({
                    'podcast_name': podcast_name,
                    'episode_id': episode_id,
                    'feed_url': feed_url,
                    'play_count': play_count,
                    'playback_position': playback_position,
                    'last_played': last_played,
                    'strength': strength,
                })

                # Aggregate by podcast
                if podcast_name not in podcast_aggregates:
                    podcast_aggregates[podcast_name] = {
                        'episode_count': 0,
                        'total_plays': 0,
                        'feed_url': feed_url,
                        'last_played': None,
                    }
                podcast_aggregates[podcast_name]['episode_count'] += 1
                podcast_aggregates[podcast_name]['total_plays'] += play_count
                if last_played:
                    current = podcast_aggregates[podcast_name]['last_played']
                    if not current or last_played > current:
                        podcast_aggregates[podcast_name]['last_played'] = last_played

            except Exception as e:
                logger.warning(f"Error parsing podcast playstate row: {e}")
                continue

        # Yield individual episode experiences
        for ep in episode_plays:
            # Extract episode title from episode_id if possible
            episode_title = self._extract_episode_title(ep['episode_id'])
            subject = f"{ep['podcast_name']}: {episode_title}" if episode_title else ep['podcast_name']

            yield ParsedPreference(
                subject=subject,
                preference_type="Experience",
                category="podcast",
                strength=ep['strength'],
                observed_at=ep['last_played'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",  # Individual episode
                extra={
                    "content_type": "podcast_episode",
                    "podcast_name": ep['podcast_name'],
                    "episode_id": ep['episode_id'],
                    "feed_url": ep['feed_url'],
                    "play_count": ep['play_count'],
                    "playback_position_sec": ep['playback_position'],
                }
            )

        # Yield podcast-level aggregates (Pattern type for frequent listening)
        for podcast_name, data in podcast_aggregates.items():
            if data['episode_count'] >= 3:  # Only emit pattern for 3+ episodes
                # Strength based on engagement depth
                strength = min(0.6 + (data['episode_count'] * 0.03), 0.85)

                yield ParsedPreference(
                    subject=f"{podcast_name} (podcast listening pattern)",
                    preference_type="Pattern",
                    category="podcast",
                    strength=strength,
                    observed_at=data['last_played'],
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": "podcast_pattern",
                        "episode_count": data['episode_count'],
                        "total_plays": data['total_plays'],
                        "feed_url": data['feed_url'],
                    }
                )

        logger.info(
            f"Podcast playstate: {played_count} played episodes, "
            f"{skipped_count} skipped, {len(podcast_aggregates)} unique podcasts"
        )

    def _extract_episode_title(self, episode_id: str) -> str:
        """Extract a readable episode title from episode ID."""
        if not episode_id:
            return ""

        # Episode IDs often contain readable titles
        # e.g., "businessoffashion.podbean.com/inside-doug-stephens-0cac6ac4cff97995678ff8f447b844f4"
        # or GUID format: "16549227-7642-40a1-838f-c944668f1e11"

        # If it looks like a GUID, return empty
        import re
        if re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', episode_id, re.I):
            return ""
        if re.match(r'^tag:', episode_id, re.I):
            return ""

        # Try to extract readable part after last /
        if '/' in episode_id:
            last_part = episode_id.split('/')[-1]
            # Remove hash suffixes (32+ char hex at end)
            last_part = re.sub(r'-[0-9a-f]{32,}$', '', last_part, flags=re.I)
            # Convert dashes/underscores to spaces and title case
            title = last_part.replace('-', ' ').replace('_', ' ')
            # Clean up common patterns
            title = re.sub(r'\s+', ' ', title).strip()
            if len(title) > 5:
                return title.title()

        return ""

    def _extract_podcast_name(self, feed_url: str) -> str:
        """Extract a readable podcast name from feed URL."""
        import re

        # Try to extract meaningful path segments first
        # e.g., "https://feeds.transistor.fm/acquired" -> "acquired"
        path_match = re.search(r'(?:https?://)?[^/]+/(.+?)(?:/rss|/feed|/podcast\.rss)?/?$', feed_url)
        if path_match:
            path_part = path_match.group(1)
            # Skip generic path segments
            if path_part and path_part not in ('rss', 'feed', 'podcast', 'main', 'xml'):
                # Handle paths like "s/69dd91f4/podcast/rss" -> skip
                if not re.match(r'^s/[0-9a-f]+', path_part):
                    # Clean up the path
                    name = path_part.split('/')[-1]  # Take last segment
                    # Remove file extensions
                    name = re.sub(r'\.(xml|rss|json)$', '', name, flags=re.I)
                    if name and name not in ('rss', 'feed', 'podcast', 'main'):
                        # Skip pure numeric IDs
                        if not name.isdigit():
                            name = name.replace('-', ' ').replace('_', ' ').title()
                            if len(name) > 3:
                                return name

        # Fall back to domain extraction
        match = re.search(r'(?:https?://)?([^/]+)', feed_url)
        if match:
            domain = match.group(1)
            # Remove common podcast hosting domains
            hosting_domains = [
                '.podbean.com', '.libsyn.com', '.simplecast.com',
                '.transistor.fm', '.feedburner.com', '.acast.com',
                '.art19.com', '.megaphone.fm', '.omnycontent.com',
                '.soundcloud.com', '.anchor.fm', '.buzzsprout.com',
                '.spreaker.com', '.podomatic.com', '.blubrry.com',
                '.rthk.hk', '.entale.co', '.podbean.com'
            ]
            for hd in hosting_domains:
                domain = domain.replace(hd, '')

            # Remove 'feeds.' prefix and common subdomains
            domain = re.sub(r'^(feeds?|www|podcast|podcasts|rss)\.', '', domain)

            # If we're left with just a hosting domain, try original domain
            if not domain or domain in ('com', 'fm', 'co', 'io', 'hk'):
                # Last resort: use original without protocol
                domain = re.sub(r'^https?://', '', feed_url).split('/')[0]

            # Convert to title case
            name = domain.replace('-', ' ').replace('_', ' ').title()
            return name

        return feed_url

    async def _parse_podcast_bookmarks(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Your Podcast Episode Bookmarks.csv.

        Columns: Feed URL, Episode GUID, Created on

        Bookmarked episodes are strong signals - user explicitly saved them.
        - preference_type="Like"
        - strength=0.85 (explicit save action)
        - category: "podcast"
        """
        logger.info(f"Parsing podcast bookmarks from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())
        bookmark_count = 0

        for row in reader:
            try:
                feed_url = row.get('Feed URL', '').strip()
                episode_guid = row.get('Episode GUID', '').strip()
                created_on = row.get('Created on', '').strip()

                if not feed_url:
                    continue

                # Extract podcast name from feed URL
                podcast_name = self._extract_podcast_name(feed_url)

                # Parse created timestamp
                timestamp = None
                if created_on:
                    try:
                        timestamp = datetime.fromisoformat(created_on.replace('Z', '+00:00'))
                    except ValueError:
                        pass

                # Bookmarked episodes are strong signals (saved for later)
                bookmark_count += 1

                yield ParsedPreference(
                    subject=f"{podcast_name} (bookmarked episode)",
                    preference_type="Like",
                    category="podcast",
                    strength=0.45,  # V2: Strong intent (explicit save)
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "content_type": "podcast_bookmark",
                        "podcast_name": podcast_name,
                        "episode_guid": episode_guid,
                        "feed_url": feed_url,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing podcast bookmark row: {e}")
                continue

        logger.info(f"Podcast bookmarks: {bookmark_count} bookmarked episodes")

    async def _parse_reviews(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Reviews.csv.

        Reviews indicate strong opinions (positive or negative).
        """
        logger.info(f"Parsing reviews from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                item_name = row.get('Item Name', '') or row.get('Title', '')
                item_name = item_name.strip()
                rating = row.get('Rating', '').strip()
                review_date = row.get('Review Date', '') or row.get('Date', '')
                review_date = review_date.strip()

                if not item_name:
                    continue

                # Parse rating (V2: 1-5 stars to bipolar scale)
                # 5 stars = +0.55, 4 = +0.40, 3 = +0.15, 2 = -0.25, 1 = -0.45
                strength = 0.0
                pref_type = "Neutral"
                if rating:
                    try:
                        rating_value = int(rating)
                        rating_map = {5: 0.55, 4: 0.40, 3: 0.15, 2: -0.25, 1: -0.45}
                        strength = rating_map.get(rating_value, 0.0)
                        pref_type = "Like" if strength > 0 else "Dislike" if strength < 0 else "Neutral"
                    except ValueError:
                        pass

                # Parse timestamp
                timestamp = None
                if review_date:
                    try:
                        timestamp = datetime.fromisoformat(review_date.replace('Z', '+00:00'))
                    except ValueError:
                        pass

                yield ParsedPreference(
                    subject=item_name,
                    preference_type=pref_type,
                    category="reviews",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "rating": rating,
                        "review_type": "app_review",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing review row: {e}")
                continue

    async def _parse_redownload_history(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse iTunes and App-Book Re-download and Update History.csv.

        114K+ records showing app re-downloads and updates.
        Each download indicates continued engagement with the app.
        """
        logger.info(f"Parsing app re-download history from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate by app to count re-downloads
        app_downloads = {}

        for row in reader:
            try:
                item_desc = row.get('Item Description', '').strip()
                content_type = row.get('Content Type', '').strip()
                activity_date_str = row.get('Activity Date', '').strip()
                seller = row.get('Seller', '').strip()

                if not item_desc or not content_type:
                    continue

                # Skip music downloads - focus on apps
                if content_type in ['Songs', 'Atlas Air']:
                    continue

                # Create composite key
                key = f"{content_type}|||{item_desc}"

                if key not in app_downloads:
                    app_downloads[key] = {
                        'content_type': content_type,
                        'item_desc': item_desc,
                        'seller': seller,
                        'count': 0,
                        'last_download': None
                    }

                app_downloads[key]['count'] += 1

                # Parse timestamp
                if activity_date_str and app_downloads[key]['last_download'] is None:
                    try:
                        # Format: 2017-11-26T19:40:04
                        timestamp = datetime.fromisoformat(activity_date_str.replace('Z', '+00:00'))
                        app_downloads[key]['last_download'] = timestamp
                    except ValueError:
                        pass

            except Exception as e:
                logger.warning(f"Error parsing re-download row: {e}")
                continue

        # Create preferences from download counts
        for key, data in app_downloads.items():
            # Base strength 0.6, increase with re-download count
            # Multiple downloads show strong continued interest
            strength = min(0.6 + (data['count'] * 0.05), 0.85)

            yield ParsedPreference(
                subject=f"{data['item_desc']} ({data['content_type']})",
                preference_type="Like",
                category="apps",
                strength=strength,
                observed_at=data['last_download'],
                source=self.source_name,
                source_id=key,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "download_count": data['count'],
                    "content_type": data['content_type'],
                    "seller": data['seller'],
                }
            )

    async def _parse_online_purchases(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Online Purchase History.csv (Apple Store hardware purchases).

        Format: Invoice Number, Order Date, Description, Qty, Price
        Hardware purchases indicate strong product preferences.
        """
        logger.info(f"Parsing Apple Store online purchases from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                description = row.get('Description', '').strip()
                order_date_str = row.get('Order Date', '').strip()
                qty_str = row.get('Qty', '').strip()
                price_str = row.get('Price Including Tax', '').strip()
                currency = row.get('Currency', '').strip()

                if not description:
                    continue

                # Parse timestamp
                timestamp = None
                if order_date_str:
                    try:
                        # Format: 2020-02-09
                        timestamp = datetime.fromisoformat(order_date_str)
                    except ValueError:
                        pass

                # Parse quantity
                qty = 1
                if qty_str:
                    try:
                        qty = float(qty_str)
                    except ValueError:
                        pass

                # Hardware purchases are strong preference signals
                # Base: 0.75, +0.1 for multiple quantities
                strength = min(0.75 + (0.1 if qty > 1 else 0), 0.85)

                yield ParsedPreference(
                    subject=description,
                    preference_type="Like",
                    category="hardware",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Large",
                    extra={
                        "quantity": qty,
                        "price": price_str,
                        "currency": currency,
                        "purchase_type": "hardware",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing online purchase row: {e}")
                continue

    async def _parse_marketing_response(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Marketing Communications Response.csv.

        Format: Communication Name, Response Type, Response Time
        Email clicks indicate engagement with Apple services.
        """
        logger.info(f"Parsing marketing response data from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                comm_name = row.get('Communication Name', '').strip()
                response_type = row.get('Response Type', '').strip()
                response_time_str = row.get('Response Time', '').strip()

                if not comm_name or response_type.lower() != 'click':
                    continue

                # Parse timestamp
                timestamp = None
                if response_time_str:
                    try:
                        # Format: 2025-10-25 04:35:39
                        timestamp = datetime.strptime(response_time_str, '%Y-%m-%d %H:%M:%S')
                    except ValueError:
                        pass

                # Email clicks show moderate engagement (0.5 strength)
                yield ParsedPreference(
                    subject=comm_name,
                    preference_type="Like",
                    category="marketing",
                    strength=0.5,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "response_type": response_type,
                        "engagement": "email_click",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing marketing response row: {e}")
                continue

    async def _parse_video_activity(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Video Play Activity.csv (Apple TV+ viewing).

        Format: Title, Content Type, Play Date, Duration
        Video views indicate content preferences.
        """
        logger.info(f"Parsing video play activity from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate by title to count views
        video_views = {}

        for row in reader:
            try:
                # Check various possible column names for title
                title = (row.get('Title', '') or
                        row.get('Item Title', '') or
                        row.get('Content Title', '')).strip()

                play_date_str = (row.get('Play Date', '') or
                                row.get('Event Date', '') or
                                row.get('Activity Date', '')).strip()

                if not title:
                    continue

                # Aggregate views
                if title not in video_views:
                    video_views[title] = {
                        'count': 0,
                        'last_viewed': None
                    }

                video_views[title]['count'] += 1

                # Parse timestamp
                if play_date_str and video_views[title]['last_viewed'] is None:
                    try:
                        # Try multiple timestamp formats
                        for fmt in ['%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M:%S', '%Y-%m-%d']:
                            try:
                                timestamp = datetime.strptime(play_date_str.replace('Z', ''), fmt)
                                video_views[title]['last_viewed'] = timestamp
                                break
                            except ValueError:
                                continue
                    except Exception:
                        pass

            except Exception as e:
                logger.warning(f"Error parsing video activity row: {e}")
                continue

        # Create preferences from view counts
        for title, data in video_views.items():
            # Base strength 0.6, increase with multiple views
            strength = min(0.6 + (data['count'] * 0.05), 0.8)

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                category="video",
                strength=strength,
                observed_at=data['last_viewed'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "view_count": data['count'],
                    "content_type": "video",
                }
            )

    async def _parse_top_content(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music - Top Content.csv.

        This file shows most-played artists/content ranked by total play duration.
        Very strong preference signals.
        Format: Country, Content, Play Duration Milliseconds, First Played, Last Played, Rankings
        """
        logger.info(f"Parsing Apple Music top content from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                content_name = row.get('Content', '').strip()
                play_duration_ms_str = row.get('Play Duration Milliseconds', '').strip()
                rankings_str = row.get('Rankings', '').strip()
                last_played_str = row.get('Last Played', '').strip()

                if not content_name:
                    continue

                # Parse play duration
                play_duration_ms = 0
                if play_duration_ms_str:
                    try:
                        play_duration_ms = int(play_duration_ms_str)
                    except ValueError:
                        pass

                # Parse ranking
                ranking = 999
                if rankings_str:
                    try:
                        ranking = int(rankings_str)
                    except ValueError:
                        pass

                # Parse last played timestamp (milliseconds since epoch)
                timestamp = None
                if last_played_str:
                    try:
                        timestamp_ms = int(last_played_str)
                        timestamp = datetime.fromtimestamp(timestamp_ms / 1000.0)
                    except (ValueError, OSError):
                        pass

                # Top content is a very strong signal
                # Base: 0.75, increase for top rankings, massive play time
                # Top 10 get bonus, #1 gets highest
                strength = 0.75
                if ranking == 1:
                    strength = 0.95
                elif ranking <= 5:
                    strength = 0.9
                elif ranking <= 10:
                    strength = 0.85

                # Also factor in play duration (hours)
                hours = play_duration_ms / (1000 * 60 * 60)
                if hours > 100:
                    strength = min(strength + 0.05, 0.95)

                yield ParsedPreference(
                    subject=content_name,
                    preference_type="Like",
                    category="music",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "ranking": ranking,
                        "play_duration_ms": play_duration_ms,
                        "play_hours": round(hours, 1),
                        "top_content": True,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing top content row: {e}")
                continue

    async def _parse_music_click_activity(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music Click Activity.csv.

        This file tracks user clicks on artists/albums/songs in Apple Music interface.
        Browsing behavior is a moderate signal (weaker than purchase/play).

        Format: Many columns including Artist Name, Album Name, Song Name, Event Date Time,
        Click Target, Click Target Type, Page Type, etc.
        """
        logger.info(f"Parsing Apple Music click activity from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate clicks by content to count engagement
        content_clicks = {}

        for row in reader:
            try:
                artist_name = row.get('Artist Name', '').strip()
                album_name = row.get('Album Name', '').strip()
                song_name = row.get('Song Name', '').strip()
                event_datetime_str = row.get('Event Date Time', '').strip()
                click_target = row.get('Click Target', '').strip()
                page_type = row.get('Page Type', '').strip()

                # Determine what was clicked
                subject = None
                category = "music"

                if song_name:
                    subject = f"{artist_name} - {song_name}" if artist_name else song_name
                elif album_name:
                    subject = f"{artist_name} - {album_name}" if artist_name else album_name
                elif artist_name:
                    subject = artist_name
                elif click_target:
                    subject = click_target
                else:
                    continue

                # Parse timestamp
                timestamp = None
                if event_datetime_str:
                    try:
                        # Format: 2025-07-26T06:18:19.155Z
                        timestamp = datetime.fromisoformat(event_datetime_str.replace('Z', '+00:00'))
                    except (ValueError, AttributeError):
                        pass

                # Track clicks per content
                if subject not in content_clicks:
                    content_clicks[subject] = {
                        'count': 0,
                        'last_click': timestamp,
                        'page_type': page_type,
                        'artist': artist_name,
                        'album': album_name,
                        'song': song_name
                    }
                content_clicks[subject]['count'] += 1
                if timestamp and (not content_clicks[subject]['last_click'] or timestamp > content_clicks[subject]['last_click']):
                    content_clicks[subject]['last_click'] = timestamp

            except Exception as e:
                logger.warning(f"Error parsing music click row: {e}")
                continue

        # Emit aggregated preferences
        for subject, data in content_clicks.items():
            # Click activity is moderate signal (0.5 base + bonus for multiple clicks)
            strength = min(0.5 + (data['count'] * 0.02), 0.65)

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                category=category,
                strength=strength,
                observed_at=data['last_click'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "click_count": data['count'],
                    "page_type": data['page_type'],
                    "artist": data['artist'],
                    "album": data['album'],
                    "song": data['song'],
                    "browsing_activity": True
                }
            )

    async def _parse_app_click_activity(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse App Store Click Activity.csv.

        This file tracks user clicks on apps in the App Store.
        Browsing behavior indicates interest.

        Format: Application Name, Purchased Item Descriptions, Event Date Time, Is Purchase, etc.
        """
        logger.info(f"Parsing App Store click activity from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate clicks by app
        app_clicks = {}

        for row in reader:
            try:
                app_name = row.get('Application Name', '').strip()
                event_datetime_str = row.get('Event Date Time', '').strip()
                is_purchase = row.get('Is Purchase', '').strip().lower() == 'true'
                is_redownload = row.get('Is Redownload', '').strip().lower() == 'true'
                item_desc = row.get('Purchased Item Descriptions', '').strip()

                if not app_name and not item_desc:
                    continue

                subject = app_name or item_desc

                # Parse timestamp
                timestamp = None
                if event_datetime_str:
                    try:
                        timestamp = datetime.fromisoformat(event_datetime_str.replace('Z', '+00:00'))
                    except (ValueError, AttributeError):
                        pass

                # Track clicks per app
                if subject not in app_clicks:
                    app_clicks[subject] = {
                        'count': 0,
                        'last_click': timestamp,
                        'has_purchase': is_purchase,
                        'has_redownload': is_redownload
                    }
                app_clicks[subject]['count'] += 1
                if is_purchase:
                    app_clicks[subject]['has_purchase'] = True
                if is_redownload:
                    app_clicks[subject]['has_redownload'] = True
                if timestamp and (not app_clicks[subject]['last_click'] or timestamp > app_clicks[subject]['last_click']):
                    app_clicks[subject]['last_click'] = timestamp

            except Exception as e:
                logger.warning(f"Error parsing app click row: {e}")
                continue

        # Emit aggregated preferences
        for subject, data in app_clicks.items():
            # Base: 0.5 for browsing, +0.15 if purchase, +0.1 if redownload
            strength = 0.5 + (data['count'] * 0.02)
            if data['has_purchase']:
                strength += 0.15
            if data['has_redownload']:
                strength += 0.1
            strength = min(strength, 0.8)

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                category="apps",
                strength=strength,
                observed_at=data['last_click'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "click_count": data['count'],
                    "has_purchase": data['has_purchase'],
                    "has_redownload": data['has_redownload'],
                    "browsing_activity": True
                }
            )

    async def _parse_purchase_events(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Purchase Server Events.csv.

        Server-side transaction events including purchases, subscriptions, and updates.
        Strong preference signals.

        Format: Purchased Items Name, Purchased Items Content Type, Event Date,
        Total Purchase Paid, Transaction Types, etc.
        """
        logger.info(f"Parsing purchase server events from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate by item to count purchases
        item_purchases = {}

        for row in reader:
            try:
                # Purchased Items Name is pipe-delimited
                purchased_items_str = row.get('Purchased Items Name', '').strip()
                content_type = row.get('Purchased Items Content Type', '').strip()
                event_date_str = row.get('Event Date', '').strip()
                price_paid_str = row.get('Total Purchase Paid', '').strip()
                event_type = row.get('Event Type', '').strip()

                if not purchased_items_str:
                    continue

                # Parse event date
                timestamp = None
                if event_date_str:
                    try:
                        timestamp = datetime.strptime(event_date_str, '%Y-%m-%d')
                    except (ValueError, AttributeError):
                        pass

                # Parse price
                price_paid = 0.0
                if price_paid_str and price_paid_str != 'null':
                    try:
                        price_paid = float(price_paid_str)
                    except ValueError:
                        pass

                # Parse items (pipe-delimited)
                items = [i.strip() for i in purchased_items_str.split('|') if i.strip()]

                for item_name in items:
                    if item_name == 'null':
                        continue

                    # Track purchases per item
                    if item_name not in item_purchases:
                        item_purchases[item_name] = {
                            'count': 0,
                            'last_purchase': timestamp,
                            'total_spent': 0.0,
                            'content_type': content_type,
                            'event_type': event_type
                        }

                    item_purchases[item_name]['count'] += 1
                    item_purchases[item_name]['total_spent'] += price_paid
                    if timestamp and (not item_purchases[item_name]['last_purchase'] or timestamp > item_purchases[item_name]['last_purchase']):
                        item_purchases[item_name]['last_purchase'] = timestamp

            except Exception as e:
                logger.warning(f"Error parsing purchase event row: {e}")
                continue

        # Emit aggregated preferences
        for item_name, data in item_purchases.items():
            # Purchases are strong signals (0.75 base + bonus for repeat purchases and spending)
            strength = 0.75
            if data['count'] > 1:
                strength += 0.05  # Repeat purchase bonus
            if data['total_spent'] > 10:
                strength += 0.05  # Spending bonus
            strength = min(strength, 0.85)

            # Determine category
            category = "apps"
            if data['content_type'] and 'music' in data['content_type'].lower():
                category = "music"

            yield ParsedPreference(
                subject=item_name,
                preference_type="Like",
                category=category,
                strength=strength,
                observed_at=data['last_purchase'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "purchase_count": data['count'],
                    "total_spent": round(data['total_spent'], 2),
                    "content_type": data['content_type'],
                    "event_type": data['event_type'],
                    "server_event": True
                }
            )

    async def _parse_itunes_match_redownload(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse iTunes Match Re-download History.csv.

        Music re-downloads indicate sustained interest in songs/albums.

        Format: Apple ID Number, Activity Date, Content Type, Item Reference Number,
        Item Description, Seller, Device Details, Device IP Address, Device Identifier
        """
        logger.info(f"Parsing iTunes Match re-download history from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate by item to count re-downloads
        music_downloads = {}

        for row in reader:
            try:
                item_desc = row.get('Item Description', '').strip()
                content_type = row.get('Content Type', '').strip()
                activity_date_str = row.get('Activity Date', '').strip()
                seller = row.get('Seller', '').strip()

                if not item_desc:
                    continue

                # Parse timestamp
                timestamp = None
                if activity_date_str:
                    try:
                        timestamp = datetime.fromisoformat(activity_date_str.replace('Z', '+00:00'))
                    except (ValueError, AttributeError):
                        pass

                # Track downloads per item
                if item_desc not in music_downloads:
                    music_downloads[item_desc] = {
                        'count': 0,
                        'last_download': timestamp,
                        'content_type': content_type,
                        'seller': seller
                    }

                music_downloads[item_desc]['count'] += 1
                if timestamp and (not music_downloads[item_desc]['last_download'] or timestamp > music_downloads[item_desc]['last_download']):
                    music_downloads[item_desc]['last_download'] = timestamp

            except Exception as e:
                logger.warning(f"Error parsing iTunes Match row: {e}")
                continue

        # Emit aggregated preferences
        for item_desc, data in music_downloads.items():
            # Re-downloads are moderately strong signals (0.7 base + bonus for multiple downloads)
            strength = 0.7
            if data['count'] > 1:
                strength = min(0.7 + (data['count'] * 0.03), 0.8)

            yield ParsedPreference(
                subject=item_desc,
                preference_type="Like",
                category="music",
                strength=strength,
                observed_at=data['last_download'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "redownload_count": data['count'],
                    "content_type": data['content_type'],
                    "seller": data['seller'],
                    "itunes_match": True
                }
            )

    async def _parse_container_details(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music - Container Details.csv.

        Playlists and radio stations with play counts, duration, and artist lists.
        Strong signal for music preferences.

        Format: Container Description, Container Type, Origin, Date Created,
        Play Duration Milliseconds, Artist Name, Last Played, Play Count, Genres, Artists
        """
        logger.info(f"Parsing Apple Music container details from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                container_desc = row.get('Container Description', '').strip()
                container_type = row.get('Container Type', '').strip()
                play_count_str = row.get('Play Count', '').strip()
                play_duration_ms_str = row.get('Play Duration Milliseconds', '').strip()
                last_played_str = row.get('Last Played', '').strip()
                artists_str = row.get('Artists', '').strip()
                genres_str = row.get('Genres', '').strip()

                if not container_desc or container_desc == 'N/A':
                    continue

                # Parse play count
                play_count = 0
                if play_count_str:
                    try:
                        play_count = int(play_count_str)
                    except ValueError:
                        pass

                # Parse play duration
                play_duration_ms = 0
                if play_duration_ms_str:
                    try:
                        play_duration_ms = int(play_duration_ms_str)
                    except ValueError:
                        pass

                # Parse last played timestamp (milliseconds since epoch)
                timestamp = None
                if last_played_str:
                    try:
                        timestamp_ms = int(last_played_str)
                        timestamp = datetime.fromtimestamp(timestamp_ms / 1000.0)
                    except (ValueError, OSError):
                        pass

                # Container with high play count is strong signal
                # Base: 0.7, bonus for play count
                strength = 0.7
                if play_count > 10:
                    strength += 0.05
                if play_count > 50:
                    strength += 0.05
                strength = min(strength, 0.85)

                # Parse hours
                hours = play_duration_ms / (1000 * 60 * 60) if play_duration_ms > 0 else 0

                yield ParsedPreference(
                    subject=container_desc,
                    preference_type="Like",
                    category="music",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "container_type": container_type,
                        "play_count": play_count,
                        "play_hours": round(hours, 1),
                        "artists": artists_str,
                        "genres": genres_str,
                        "playlist": True
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing container details row: {e}")
                continue

    async def _parse_feature_statistics(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music - Feature Statistics.csv.

        Usage statistics for Apple Music features.
        Moderate signal for feature preferences.

        Format: Feature Name, Play Duration Milliseconds, First Played, Last Played,
        Source Type, Date Created
        """
        logger.info(f"Parsing Apple Music feature statistics from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                feature_name = row.get('Feature Name', '').strip()
                play_duration_ms_str = row.get('Play Duration Milliseconds', '').strip()
                last_played_str = row.get('Last Played', '').strip()
                source_type = row.get('Source Type', '').strip()

                if not feature_name:
                    continue

                # Parse play duration
                play_duration_ms = 0
                if play_duration_ms_str:
                    try:
                        play_duration_ms = int(play_duration_ms_str)
                    except ValueError:
                        pass

                # Parse last played timestamp (milliseconds since epoch)
                timestamp = None
                if last_played_str:
                    try:
                        timestamp_ms = int(last_played_str)
                        timestamp = datetime.fromtimestamp(timestamp_ms / 1000.0)
                    except (ValueError, OSError):
                        pass

                # Feature usage is moderate signal (0.6 base + bonus for heavy usage)
                hours = play_duration_ms / (1000 * 60 * 60) if play_duration_ms > 0 else 0
                strength = 0.6
                if hours > 10:
                    strength += 0.05
                if hours > 100:
                    strength += 0.05
                strength = min(strength, 0.7)

                yield ParsedPreference(
                    subject=f"Apple Music Feature: {feature_name}",
                    preference_type="Like",
                    category="apps",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "feature_name": feature_name,
                        "play_hours": round(hours, 1),
                        "source_type": source_type,
                        "feature_usage": True
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing feature statistics row: {e}")
                continue

    async def _parse_playback_activity(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Playback Activity.csv.

        Video/movie playback with position tracking and play counts.
        Moderate to strong signal.

        Format: Item Reference, Item Description, Last activity timestamp,
        Playback position, Play count, Has been played?
        """
        logger.info(f"Parsing playback activity from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                item_desc = row.get('Item Description', '').strip()
                play_count_str = row.get('Play count', '').strip()
                last_activity_str = row.get('Last activity timestamp', '').strip()
                playback_position_str = row.get('Playback position', '').strip()
                has_been_played = row.get('Has been played?', '').strip().lower() == 'yes'

                if not item_desc:
                    continue

                # Parse play count
                play_count = 1
                if play_count_str:
                    try:
                        play_count = int(play_count_str)
                    except ValueError:
                        pass

                # Parse playback position
                playback_position = 0.0
                if playback_position_str:
                    try:
                        playback_position = float(playback_position_str)
                    except ValueError:
                        pass

                # Parse timestamp
                timestamp = None
                if last_activity_str and last_activity_str != '1904-01-01T00:00:00Z':
                    try:
                        timestamp = datetime.fromisoformat(last_activity_str.replace('Z', '+00:00'))
                    except (ValueError, AttributeError):
                        pass

                # Playback is moderate signal (0.65 base + bonus for multiple plays)
                strength = 0.65
                if play_count > 1:
                    strength = min(0.65 + (play_count * 0.03), 0.75)

                yield ParsedPreference(
                    subject=item_desc,
                    preference_type="Like",
                    category="video",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "play_count": play_count,
                        "playback_position": playback_position,
                        "has_been_played": has_been_played,
                        "video_playback": True
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing playback activity row: {e}")
                continue

    async def _parse_container_origin(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Music - Container Origin.csv.

        Contains artist radio station data with play counts, duration, genres, and artist names.
        Strong signal for artist preferences with rich genre metadata.

        Format: Origin, Date Created, Play Duration Milliseconds, Artist Name, Last Played,
        Play Count, Genres, Artists
        """
        logger.info(f"Parsing Apple Music container origin from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate by artist to combine multiple radio station entries
        artist_data = {}

        for row in reader:
            try:
                origin = row.get('Origin', '').strip()
                artists = row.get('Artists', '').strip()
                genres_str = row.get('Genres', '').strip()
                play_count_str = row.get('Play Count', '').strip()
                play_duration_ms_str = row.get('Play Duration Milliseconds', '').strip()
                last_played_str = row.get('Last Played', '').strip()

                # Only process radio stations with valid artist data
                if not artists or artists == 'N/A':
                    continue

                # Parse genres
                genres = [g.strip() for g in genres_str.split(',') if g.strip() and g.strip() != 'Music']

                # Parse play count
                play_count = 0
                if play_count_str:
                    try:
                        play_count = int(play_count_str)
                    except ValueError:
                        pass

                # Parse play duration
                play_duration_ms = 0
                if play_duration_ms_str:
                    try:
                        play_duration_ms = int(play_duration_ms_str)
                    except ValueError:
                        pass

                # Parse last played timestamp (milliseconds since epoch)
                timestamp = None
                if last_played_str:
                    try:
                        timestamp_ms = int(last_played_str)
                        timestamp = datetime.fromtimestamp(timestamp_ms / 1000.0)
                    except (ValueError, OSError):
                        pass

                # Aggregate by artist
                if artists not in artist_data:
                    artist_data[artists] = {
                        'total_play_count': 0,
                        'total_duration_ms': 0,
                        'genres': set(),
                        'last_played': None,
                        'origin_type': origin
                    }

                artist_data[artists]['total_play_count'] += play_count
                artist_data[artists]['total_duration_ms'] += play_duration_ms
                artist_data[artists]['genres'].update(genres)
                if timestamp and (not artist_data[artists]['last_played'] or timestamp > artist_data[artists]['last_played']):
                    artist_data[artists]['last_played'] = timestamp

            except Exception as e:
                logger.warning(f"Error parsing container origin row: {e}")
                continue

        # Emit aggregated artist preferences
        for artist, data in artist_data.items():
            # Radio station play is strong signal - user actively chose this artist
            # Base: 0.75, bonus for high play count and duration
            strength = 0.75
            if data['total_play_count'] > 10:
                strength += 0.05
            if data['total_play_count'] > 50:
                strength += 0.05
            hours = data['total_duration_ms'] / (1000 * 60 * 60)
            if hours > 5:
                strength += 0.05
            strength = min(strength, 0.9)

            yield ParsedPreference(
                subject=artist,
                preference_type="Like",
                category="music",
                strength=strength,
                observed_at=data['last_played'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "play_count": data['total_play_count'],
                    "play_hours": round(hours, 1),
                    "genres": list(data['genres']),
                    "origin_type": data['origin_type'],
                    "artist_radio": True
                }
            )

    async def _parse_tv_app_click_activity(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse TV App with Channel Support Click Activity.csv.

        Contains streaming service usage data - which services are installed,
        consented, and actively used on Apple TV and other devices.

        Extracts preferences for streaming services like Disney+, Prime Video,
        BBC iPlayer, etc.
        """
        logger.info(f"Parsing TV App click activity from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate streaming service mentions
        streaming_services = {}

        for row in reader:
            try:
                event_datetime_str = row.get('Event Date Time', '').strip()
                consented_providers = row.get('Consented TV Provider', '').strip()
                non_consented = row.get('Non Consented TV Provider', '').strip()
                subscription_app = row.get('Subscription App Name', '').strip()

                # Parse timestamp
                timestamp = None
                if event_datetime_str:
                    try:
                        timestamp = datetime.fromisoformat(event_datetime_str.replace('Z', '+00:00'))
                    except (ValueError, AttributeError):
                        pass

                # Extract streaming services from consented providers
                if consented_providers:
                    services = [s.strip() for s in consented_providers.split('|') if s.strip()]
                    for service in services:
                        if service not in streaming_services:
                            streaming_services[service] = {
                                'count': 0,
                                'consented': True,
                                'last_seen': None
                            }
                        streaming_services[service]['count'] += 1
                        streaming_services[service]['consented'] = True
                        if timestamp and (not streaming_services[service]['last_seen'] or timestamp > streaming_services[service]['last_seen']):
                            streaming_services[service]['last_seen'] = timestamp

                # Extract non-consented (but present) services
                if non_consented:
                    services = [s.strip() for s in non_consented.split('|') if s.strip()]
                    for service in services:
                        if service not in streaming_services:
                            streaming_services[service] = {
                                'count': 0,
                                'consented': False,
                                'last_seen': None
                            }
                        streaming_services[service]['count'] += 1
                        if timestamp and (not streaming_services[service]['last_seen'] or timestamp > streaming_services[service]['last_seen']):
                            streaming_services[service]['last_seen'] = timestamp

                # Also capture subscription apps
                if subscription_app:
                    if subscription_app not in streaming_services:
                        streaming_services[subscription_app] = {
                            'count': 0,
                            'consented': True,
                            'last_seen': None
                        }
                    streaming_services[subscription_app]['count'] += 1
                    streaming_services[subscription_app]['consented'] = True
                    if timestamp and (not streaming_services[subscription_app]['last_seen'] or timestamp > streaming_services[subscription_app]['last_seen']):
                        streaming_services[subscription_app]['last_seen'] = timestamp

            except Exception as e:
                logger.warning(f"Error parsing TV app click row: {e}")
                continue

        # Emit streaming service preferences
        for service, data in streaming_services.items():
            # Consented services are stronger signals
            # Base: 0.7 for consented, 0.5 for non-consented
            # Bonus for frequent appearances
            strength = 0.7 if data['consented'] else 0.5
            if data['count'] > 10:
                strength += 0.05
            if data['count'] > 50:
                strength += 0.05
            strength = min(strength, 0.85)

            yield ParsedPreference(
                subject=service,
                preference_type="Like",
                category="streaming",
                strength=strength,
                observed_at=data['last_seen'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "appearance_count": data['count'],
                    "consented": data['consented'],
                    "streaming_service": True
                }
            )

    # ========== Apple Books Parsing Methods ==========

    async def _parse_books_global_annotations(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Books Global Annotations.json.

        Contains book entries with IDs, descriptions (titles), and annotation
        timestamps. Books with actual titles (not "N/A") indicate books in the
        library. Annotations indicate reading engagement.

        Format: Array of objects with id, description, annotations[]
        """
        logger.info(f"Parsing Apple Books global annotations from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.warning(f"Could not parse Apple Books JSON: {e}")
            return

        for book in data:
            try:
                book_id = book.get('id', '').strip()
                description = book.get('description', '').strip()
                annotations = book.get('annotations', [])

                # Skip entries without valid titles
                if not description or description == 'N/A':
                    continue

                # Skip non-book items (user guides, etc.)
                skip_patterns = ['user guide', 'quick start', 'manual']
                if any(pattern in description.lower() for pattern in skip_patterns):
                    continue

                # Parse timestamps from annotations
                earliest_timestamp = None
                latest_timestamp = None
                annotation_count = len(annotations)
                has_location = False  # Indicates reading progress

                for annotation in annotations:
                    created_str = annotation.get('created', '')
                    location = annotation.get('location')

                    if location:
                        has_location = True

                    if created_str:
                        try:
                            timestamp = datetime.fromisoformat(created_str.replace('Z', '+00:00'))
                            if earliest_timestamp is None or timestamp < earliest_timestamp:
                                earliest_timestamp = timestamp
                            if latest_timestamp is None or timestamp > latest_timestamp:
                                latest_timestamp = timestamp
                        except ValueError:
                            pass

                # Calculate strength based on engagement
                # Base: 0.65 for having the book
                # +0.1 if has reading position (actually read)
                # +0.05 for multiple annotations
                strength = 0.65
                if has_location:
                    strength += 0.1
                if annotation_count > 1:
                    strength += min(annotation_count * 0.02, 0.1)
                strength = min(strength, 0.85)

                yield ParsedPreference(
                    subject=description,
                    preference_type="Like",
                    category="books",
                    strength=strength,
                    observed_at=latest_timestamp or earliest_timestamp,
                    source=self.source_name,
                    source_id=book_id,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": "book",
                        "annotation_count": annotation_count,
                        "has_reading_position": has_location,
                        "first_opened": earliest_timestamp.isoformat() if earliest_timestamp else None,
                        "last_opened": latest_timestamp.isoformat() if latest_timestamp else None,
                        "apple_books": True
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing Apple Books entry: {e}")
                continue

    async def _parse_books_collections(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Books Collection Information.json.

        Contains user-created book collections/shelves. Collections themselves
        are preferences showing organizational patterns. Books within collections
        have already been processed by global annotations.

        Format: Array of objects with title, lastModification, deleted, contents[]
        """
        logger.info(f"Parsing Apple Books collections from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.warning(f"Could not parse Apple Books collections JSON: {e}")
            return

        for collection in data:
            try:
                title = collection.get('title', '').strip()
                last_modified_str = collection.get('lastModification', '')
                deleted = collection.get('deleted', False)
                contents = collection.get('contents', [])

                # Skip deleted collections or default system collections
                if deleted:
                    continue

                # Skip empty or default collections
                if not title or title in ('Books', 'PDFs'):
                    continue

                # Skip collections with no content
                if not contents:
                    continue

                # Parse timestamp
                timestamp = None
                if last_modified_str:
                    try:
                        timestamp = datetime.fromisoformat(last_modified_str.replace('Z', '+00:00'))
                    except ValueError:
                        pass

                # Collections show intentional organization (moderate signal)
                # Strength based on collection size
                book_count = len(contents)
                strength = min(0.6 + (book_count * 0.02), 0.75)

                yield ParsedPreference(
                    subject=f"Book Collection: {title}",
                    preference_type="Pattern",
                    category="books",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": "book_collection",
                        "book_count": book_count,
                        "collection_name": title,
                        "apple_books": True
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing Apple Books collection: {e}")
                continue

    async def _parse_books_user_annotations(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Books User Annotations.json.

        Contains user-created highlights, notes, and bookmarks within books.
        Books with multiple user annotations show deeper engagement.

        Format: Array of objects with id, description, annotations[]
        Each annotation has created, lastModification, type, selectedText, note, location
        """
        logger.info(f"Parsing Apple Books user annotations from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.warning(f"Could not parse Apple Books user annotations JSON: {e}")
            return

        for book in data:
            try:
                book_id = book.get('id', '').strip()
                description = book.get('description', '').strip()
                annotations = book.get('annotations', [])

                # Skip entries with no annotations or invalid titles
                if not annotations:
                    continue

                # Count annotation types
                highlight_count = 0
                note_count = 0
                bookmark_count = 0
                latest_timestamp = None

                for annotation in annotations:
                    anno_type = annotation.get('type', '')
                    selected_text = annotation.get('selectedText')
                    note = annotation.get('note')
                    created_str = annotation.get('created', '')

                    if selected_text:
                        highlight_count += 1
                    if note:
                        note_count += 1
                    if anno_type in ('Point', 'Global'):
                        bookmark_count += 1

                    if created_str:
                        try:
                            timestamp = datetime.fromisoformat(created_str.replace('Z', '+00:00'))
                            if latest_timestamp is None or timestamp > latest_timestamp:
                                latest_timestamp = timestamp
                        except ValueError:
                            pass

                total_annotations = len(annotations)

                # User annotations are strong engagement signals
                # Base: 0.7, increase with annotation count
                strength = 0.7
                if total_annotations > 3:
                    strength += 0.05
                if total_annotations > 10:
                    strength += 0.05
                if note_count > 0:  # Notes show deepest engagement
                    strength += 0.05
                strength = min(strength, 0.9)

                subject = description if description and description != 'N/A' else f"Book {book_id[:8]}"

                yield ParsedPreference(
                    subject=subject,
                    preference_type="Like",
                    category="books",
                    strength=strength,
                    observed_at=latest_timestamp,
                    source=self.source_name,
                    source_id=book_id,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": "book_with_annotations",
                        "total_annotations": total_annotations,
                        "highlight_count": highlight_count,
                        "note_count": note_count,
                        "bookmark_count": bookmark_count,
                        "deep_engagement": True,
                        "apple_books": True
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing Apple Books user annotation entry: {e}")
                continue

    async def _parse_bookstore_click_activity(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Bookstore Click Activity.csv.

        Contains browsing activity in the Apple Books store.
        Click activity shows interest but is a weaker signal than purchase/reading.

        Format: Many columns including Item Description, Event Date Time, Click Target, etc.
        """
        logger.info(f"Parsing Apple Bookstore click activity from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Aggregate clicks by item
        book_clicks = {}

        for row in reader:
            try:
                item_desc = row.get('Item Description', '').strip()
                event_datetime_str = row.get('Event Date Time', '').strip()
                click_target = row.get('Click Target', '').strip()
                search_term = row.get('Search Term', '').strip()

                # Try to find a meaningful subject
                subject = None
                if item_desc and item_desc not in ('', 'null', 'N/A'):
                    subject = item_desc
                elif click_target and click_target not in ('', 'null', 'N/A'):
                    subject = click_target

                if not subject:
                    # Track search terms separately
                    if search_term and search_term not in ('', 'null', 'N/A'):
                        subject = f"Search: {search_term}"
                    else:
                        continue

                # Parse timestamp
                timestamp = None
                if event_datetime_str:
                    try:
                        timestamp = datetime.fromisoformat(event_datetime_str.replace('Z', '+00:00'))
                    except (ValueError, AttributeError):
                        pass

                # Aggregate clicks
                if subject not in book_clicks:
                    book_clicks[subject] = {
                        'count': 0,
                        'last_click': timestamp,
                        'is_search': subject.startswith('Search: ')
                    }

                book_clicks[subject]['count'] += 1
                if timestamp and (not book_clicks[subject]['last_click'] or timestamp > book_clicks[subject]['last_click']):
                    book_clicks[subject]['last_click'] = timestamp

            except Exception as e:
                logger.warning(f"Error parsing bookstore click row: {e}")
                continue

        # Emit preferences for clicked items
        for subject, data in book_clicks.items():
            # Click activity is moderate signal (0.5 base + bonus for repeated clicks)
            strength = min(0.5 + (data['count'] * 0.03), 0.65)

            # Searches are weaker signals
            if data['is_search']:
                strength = min(0.4 + (data['count'] * 0.02), 0.55)

            yield ParsedPreference(
                subject=subject,
                preference_type="Neutral" if data['is_search'] else "Like",
                category="books",
                strength=strength,
                observed_at=data['last_click'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "click_count": data['count'],
                    "is_search": data['is_search'],
                    "browsing_activity": True,
                    "apple_books": True
                }
            )

    async def _parse_icloud_bookmarks(
        self,
        extract_dir: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse iCloud Bookmarks export.

        Structure: iCloud Bookmarks.zip contains nested iCloud Bookmarks/iCloud Bookmarks.zip
        which contains CSV files with columns: Title, URL, modifiedOn, favorite, deleted

        Each bookmark becomes a preference with:
        - preference_type: "Like" (explicitly saved)
        - category: "bookmark"
        - strength: 0.75 for favorites, 0.70 for regular bookmarks
        """
        bookmarks_dir = extract_dir / "iCloud Bookmarks"
        if not bookmarks_dir.exists():
            logger.warning(f"iCloud Bookmarks directory not found: {bookmarks_dir}")
            return

        logger.info(f"Parsing iCloud Bookmarks from: {bookmarks_dir}")

        # Handle nested ZIP structure
        inner_zip = bookmarks_dir / "iCloud Bookmarks.zip"
        if inner_zip.exists():
            with tempfile.TemporaryDirectory() as inner_tmpdir:
                with zipfile.ZipFile(inner_zip, 'r') as zf:
                    zf.extractall(inner_tmpdir)
                inner_path = Path(inner_tmpdir)
                csv_files = list(inner_path.rglob("*.csv"))
                async for pref in self._parse_bookmark_csvs(csv_files, default_compartment):
                    yield pref
        else:
            # Direct CSV files in the directory
            csv_files = list(bookmarks_dir.rglob("*.csv"))
            async for pref in self._parse_bookmark_csvs(csv_files, default_compartment):
                yield pref

    async def _parse_bookmark_csvs(
        self,
        csv_files: list,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse iCloud bookmark CSV files."""
        parsed_count = 0
        skipped_deleted = 0
        favorite_count = 0
        seen_urls = set()  # Deduplicate by URL

        for csv_file in csv_files:
            try:
                async with aiofiles.open(csv_file, mode='r', encoding='utf-8-sig') as f:
                    content = await f.read()

                reader = csv.DictReader(content.splitlines())

                for row in reader:
                    try:
                        title = row.get('Title', '').strip()
                        url = row.get('URL', '').strip()
                        modified_on = row.get('modifiedOn', '').strip()
                        is_favorite = row.get('favorite', 'no').lower() == 'yes'
                        is_deleted = row.get('deleted', 'no').lower() == 'yes'

                        # Skip deleted bookmarks
                        if is_deleted:
                            skipped_deleted += 1
                            continue

                        # Skip empty entries or duplicates
                        if not url or url in seen_urls:
                            continue

                        seen_urls.add(url)

                        # Use title or extract domain from URL
                        if not title:
                            try:
                                from urllib.parse import urlparse
                                parsed_url = urlparse(url)
                                title = parsed_url.netloc.replace('www.', '')
                            except Exception:
                                title = url[:50]

                        # Parse timestamp
                        observed_at = self._parse_bookmark_date(modified_on)

                        # Determine strength (favorites are stronger signals)
                        if is_favorite:
                            strength = 0.75
                            favorite_count += 1
                        else:
                            strength = 0.70

                        # Extract domain for extra metadata
                        domain = ""
                        try:
                            from urllib.parse import urlparse
                            parsed_url = urlparse(url)
                            domain = parsed_url.netloc.replace('www.', '')
                        except Exception:
                            pass

                        yield ParsedPreference(
                            subject=title,
                            preference_type="Like",
                            category="bookmark",
                            strength=strength,
                            observed_at=observed_at,
                            source=self.source_name,
                            compartment_level=default_compartment,
                            size=self.classify_size(title, "bookmark"),
                            extra={
                                "url": url,
                                "domain": domain,
                                "is_favorite": is_favorite,
                                "source_type": "icloud_bookmarks"
                            }
                        )
                        parsed_count += 1

                    except Exception as e:
                        logger.warning(f"Error parsing bookmark row: {e}")
                        continue

            except Exception as e:
                logger.warning(f"Error reading bookmark CSV {csv_file}: {e}")
                continue

        logger.info(
            f"iCloud Bookmarks parsing complete: {parsed_count} parsed, "
            f"{favorite_count} favorites, {skipped_deleted} deleted skipped"
        )

    def _parse_bookmark_date(self, date_str: str) -> Optional[datetime]:
        """
        Parse iCloud bookmark date format.

        Format: "Friday April 13,2018 1:44 AM GMT"
        """
        if not date_str:
            return None

        try:
            # Remove the day name and timezone, parse the rest
            # "Friday April 13,2018 1:44 AM GMT" -> "April 13,2018 1:44 AM"
            parts = date_str.split()
            if len(parts) >= 5:
                # Skip day name, join month onwards, skip timezone
                date_part = ' '.join(parts[1:-1])  # "April 13,2018 1:44 AM"
                return datetime.strptime(date_part, "%B %d,%Y %I:%M %p")
        except ValueError:
            pass

        # Try alternative formats
        formats = [
            "%A %B %d,%Y %I:%M %p %Z",  # With timezone
            "%B %d,%Y %I:%M %p",         # Without day/timezone
            "%Y-%m-%d %H:%M:%S",         # ISO format
            "%Y-%m-%dT%H:%M:%S",         # ISO with T
        ]
        for fmt in formats:
            try:
                return datetime.strptime(date_str.strip(), fmt)
            except ValueError:
                continue

        logger.debug(f"Could not parse bookmark date: {date_str}")
        return None

    async def _parse_apple_tv_bookmarks(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple TV Bookmarks.csv.

        This file contains viewing history for movies/shows.

        Columns: Item Reference, Last activity timestamp, Item Description,
                 Marked as unwatched?, Has been played?, Playback position,
                 Play count, Has been rented?

        - preference_type="Like"
        - strength=0.75 base (watched content indicates interest)
        - category: "movie_tv"
        """
        logger.info(f"Parsing Apple TV bookmarks from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())
        watched_count = 0
        rented_count = 0

        for row in reader:
            try:
                item_ref = row.get('Item Reference', '').strip()
                timestamp_str = row.get('Last activity timestamp', '').strip()
                item_desc = row.get('Item Description', '').strip()
                has_been_played = row.get('Has been played?', '').strip().lower() == 'yes'
                play_count_str = row.get('Play count', '').strip()
                has_been_rented = row.get('Has been rented?', '').strip().lower() == 'yes'

                if not item_desc:
                    continue

                # Parse timestamp
                timestamp = None
                if timestamp_str:
                    try:
                        timestamp = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00'))
                    except ValueError:
                        pass

                # Parse play count
                play_count = 1
                if play_count_str:
                    try:
                        play_count = int(play_count_str)
                    except ValueError:
                        play_count = 1

                # Calculate strength:
                # - Base: 0.75 (watched content)
                # - Bonus for multiple plays: +0.05 per additional play (max +0.15)
                # - Rented content shows willingness to pay: +0.05
                strength = 0.75
                if play_count > 1:
                    strength += min((play_count - 1) * 0.05, 0.15)
                if has_been_rented:
                    strength += 0.05
                    rented_count += 1
                strength = min(strength, 0.95)

                watched_count += 1

                yield ParsedPreference(
                    subject=item_desc,
                    preference_type="Like",
                    category="movie_tv",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    source_id=item_ref,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": "apple_tv_watched",
                        "play_count": play_count,
                        "has_been_played": has_been_played,
                        "has_been_rented": has_been_rented,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing Apple TV bookmark row: {e}")
                continue

        logger.info(f"Apple TV Bookmarks: {watched_count} watched ({rented_count} rented)")

    async def _parse_apple_tv_favorites(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple TV Favorites and Wishlist.csv.

        This file contains movies/shows saved to favorites or wishlist.

        Columns: Item Reference, Created, Item Description, Type

        - preference_type="Like"
        - strength=0.8 (explicit save action indicates strong interest)
        - category: "movie_tv"
        """
        logger.info(f"Parsing Apple TV favorites from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())
        favorites_count = 0

        for row in reader:
            try:
                item_ref = row.get('Item Reference', '').strip()
                created_str = row.get('Created', '').strip()
                item_desc = row.get('Item Description', '').strip()
                content_type = row.get('Type', '').strip()

                if not item_desc:
                    continue

                # Parse timestamp
                timestamp = None
                if created_str:
                    try:
                        timestamp = datetime.fromisoformat(created_str.replace('Z', '+00:00'))
                    except ValueError:
                        pass

                # Strength: 0.8 for favorites/wishlist (explicit save action)
                # User explicitly added this to their list
                strength = 0.8

                favorites_count += 1

                yield ParsedPreference(
                    subject=item_desc,
                    preference_type="Like",
                    category="movie_tv",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    source_id=item_ref,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "content_type": "apple_tv_favorite",
                        "media_type": content_type,
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing Apple TV favorite row: {e}")
                continue

        logger.info(f"Apple TV Favorites: {favorites_count} saved items")

    async def _parse_tv_app_activity(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse TV App Favorites and Activity.json from Apple GDPR export.

        This file contains detailed viewing history from the Apple TV app,
        including movies and TV shows watched across HBO Max, Apple TV+, etc.

        Structure:
        {
          "events": [
            {
              "stored_event": {
                "media_type": "MOVIE" or "TV",
                "timestamp": 1768483526049,
                "statistics": {
                  "max_progress_percentage": 92.9,
                  "start_play_event_statistics": {"count": 8}
                }
              },
              "event_interpretation": {
                "media_description": "Harry Potter... (Directed by: [X], Released in: [2005])",
                "channel_name": "HBO Max"
              }
            }
          ]
        }
        """
        import json
        import re
        from collections import defaultdict

        logger.info(f"Parsing TV App Activity from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
            content = await f.read()

        try:
            data = json.loads(content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse TV App Activity JSON: {e}")
            return

        events = data.get('events', [])
        logger.info(f"Found {len(events)} TV app events")

        # Aggregate by title for frequency tracking
        title_stats = defaultdict(lambda: {
            'count': 0,
            'max_progress': 0,
            'media_type': None,
            'channel': None,
            'year': None,
            'director': None,
            'show_name': None,
            'latest_timestamp': 0
        })

        movies_count = 0
        tv_count = 0
        skipped = 0

        for event in events:
            try:
                stored = event.get('stored_event', {})
                interp = event.get('event_interpretation', {})

                media_type = stored.get('media_type', '').upper()
                description = interp.get('media_description', '')
                channel = interp.get('channel_name', '')
                timestamp = stored.get('timestamp', 0)

                if not description or not media_type:
                    skipped += 1
                    continue

                # Extract title and metadata from description
                # Movie: "Title (Directed by: [Director], Released in: [Year])"
                # TV: "Show (Episode Number: [X], Episode Title: [Y], Season Number: [Z])"

                title = description
                year = None
                director = None
                show_name = None

                if media_type == 'MOVIE':
                    # Parse movie description
                    movie_match = re.match(r'^(.+?)\s*\(Directed by:', description)
                    if movie_match:
                        title = movie_match.group(1).strip()

                    year_match = re.search(r'Released in:\s*\[(\d{4})\]', description)
                    if year_match:
                        year = int(year_match.group(1))

                    director_match = re.search(r'Directed by:\s*\[([^\]]+)\]', description)
                    if director_match:
                        director = director_match.group(1)

                    movies_count += 1

                elif media_type == 'TV':
                    # Parse TV description - extract show name
                    tv_match = re.match(r'^(.+?)\s*\(Episode Number:', description)
                    if tv_match:
                        show_name = tv_match.group(1).strip()
                        title = show_name  # Use show name as the title for aggregation

                    tv_count += 1

                else:
                    skipped += 1
                    continue

                # Get viewing stats
                stats = stored.get('statistics', {})
                max_progress = stats.get('max_progress_percentage', 0)
                play_count = stats.get('start_play_event_statistics', {}).get('count', 1)

                # Update aggregated stats
                key = title.lower().strip()
                title_stats[key]['count'] += play_count
                title_stats[key]['max_progress'] = max(title_stats[key]['max_progress'], max_progress)
                title_stats[key]['media_type'] = media_type
                title_stats[key]['channel'] = channel or title_stats[key]['channel']
                title_stats[key]['year'] = year or title_stats[key]['year']
                title_stats[key]['director'] = director or title_stats[key]['director']
                title_stats[key]['show_name'] = show_name or title_stats[key]['show_name']
                title_stats[key]['latest_timestamp'] = max(title_stats[key]['latest_timestamp'], timestamp)
                title_stats[key]['title'] = title  # Keep original casing

            except Exception as e:
                logger.warning(f"Error parsing TV app event: {e}")
                skipped += 1
                continue

        logger.info(f"TV App: {movies_count} movie events, {tv_count} TV events, {skipped} skipped")
        logger.info(f"Aggregated to {len(title_stats)} unique titles")

        # Yield preferences for each unique title
        for key, stats in title_stats.items():
            title = stats.get('title', key)
            media_type = stats['media_type']
            count = stats['count']
            max_progress = stats['max_progress']

            # Calculate strength based on engagement
            # Higher progress = stronger signal
            # Multiple plays = stronger signal
            base_strength = 0.6
            progress_bonus = (max_progress / 100) * 0.2  # Up to 0.2 for 100% completion
            count_bonus = min(count * 0.02, 0.15)  # Up to 0.15 for frequent rewatches
            strength = min(base_strength + progress_bonus + count_bonus, 0.95)

            # Determine category
            category = 'movie' if media_type == 'MOVIE' else 'tv_show'

            # Parse timestamp
            observed_at = None
            if stats['latest_timestamp']:
                try:
                    observed_at = datetime.fromtimestamp(stats['latest_timestamp'] / 1000)
                except:
                    pass

            yield ParsedPreference(
                subject=title,
                preference_type="Like",
                category=category,
                strength=strength,
                observed_at=observed_at,
                source="apple_tv",
                source_id=f"apple_tv_{key[:50]}",
                compartment_level=default_compartment or 2,
                size="Medium",
                extra={
                    "content_type": "apple_tv_watched",
                    "play_count": count,
                    "max_progress_percentage": max_progress,
                    "channel": stats['channel'],
                    "year": stats['year'],
                    "director": stats['director'],
                }
            )

        logger.info(f"Apple TV Activity: {len(title_stats)} unique titles yielded")

    async def _parse_icloud_notes(
        self,
        extract_dir: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse iCloud Notes export with strict privacy filtering.

        PRIVACY CONTROLS:
        - compartment_level=5 (highest privacy) for ALL notes
        - Skips notes with sensitive keywords in title OR content
        - Does NOT store content preview - only word count
        - Skips "Recently Deleted" folder

        Each note becomes a preference revealing an interest or topic the user
        cared enough to write down.
        """
        notes_dir = extract_dir / "iCloud Notes" / "Notes"
        if not notes_dir.exists():
            logger.warning(f"iCloud Notes directory not found: {notes_dir}")
            return

        logger.info(f"Parsing iCloud Notes from: {notes_dir}")

        # Track statistics for logging
        total_notes = 0
        skipped_deleted = 0
        skipped_sensitive = 0
        parsed_notes = 0

        # Walk through all folders looking for .txt files
        for txt_file in extract_dir.rglob("*.txt"):
            total_notes += 1

            # Skip "Recently Deleted" folder
            if "recently deleted" in str(txt_file).lower():
                skipped_deleted += 1
                continue

            try:
                # Extract note title from parent folder name (iCloud Notes structure)
                # Structure: iCloud Notes/Notes/<Note Title>/<Note Title>.txt
                note_folder = txt_file.parent
                note_title = note_folder.name

                # Get folder path relative to Notes directory for context
                try:
                    relative_path = note_folder.relative_to(notes_dir)
                    folder_path = str(relative_path.parent) if relative_path.parent != Path('.') else ""
                except ValueError:
                    folder_path = ""

                # Read content to check for sensitive keywords and count words
                async with aiofiles.open(txt_file, mode='r', encoding='utf-8') as f:
                    content = await f.read()

                word_count = len(content.split())

                # Check for sensitive keywords in title AND content
                title_lower = note_title.lower()
                content_lower = content.lower()
                is_sensitive = False

                for keyword in ICLOUD_NOTES_SENSITIVE_KEYWORDS:
                    if keyword in title_lower or keyword in content_lower:
                        is_sensitive = True
                        break

                if is_sensitive:
                    skipped_sensitive += 1
                    continue

                # Check for attachments in the same folder
                attachments = list(note_folder.glob("*.png")) + \
                              list(note_folder.glob("*.jpg")) + \
                              list(note_folder.glob("*.jpeg")) + \
                              list(note_folder.glob("*.gif")) + \
                              list(note_folder.glob("*.pdf"))
                has_attachments = len(attachments) > 0
                attachment_count = len(attachments)

                # Calculate strength:
                # - Base: 0.6
                # - Boost for longer notes (500+ words): +0.1
                # - Boost for notes with attachments: +0.1
                # - Max: 0.8
                strength = 0.6
                if word_count >= 500:
                    strength += 0.1
                if has_attachments:
                    strength += 0.1
                strength = min(strength, 0.8)

                # Size based on content length
                if word_count < 50:
                    size = "Micro"
                elif word_count < 200:
                    size = "Small"
                elif word_count < 500:
                    size = "Medium"
                else:
                    size = "Large"

                parsed_notes += 1

                yield ParsedPreference(
                    subject=note_title,
                    preference_type="Experience",  # User wrote this
                    category="personal_notes",
                    strength=strength,
                    observed_at=None,  # iCloud Notes export doesn't include timestamps in file structure
                    source=self.source_name,
                    compartment_level=5,  # HIGHEST PRIVACY - notes contain personal info
                    size=size,
                    extra={
                        "folder_path": folder_path,
                        "word_count": word_count,
                        "has_attachments": has_attachments,
                        "attachment_count": attachment_count,
                        "icloud_notes": True
                        # NO content_preview - privacy requirement
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing iCloud Note {txt_file}: {e}")
                continue

        logger.info(
            f"iCloud Notes parsing complete: {parsed_notes} parsed, "
            f"{skipped_deleted} in Recently Deleted, "
            f"{skipped_sensitive} filtered for privacy "
            f"(out of {total_notes} total)"
        )

    async def _parse_health_export(
        self,
        zf: zipfile.ZipFile,
        xml_path: str
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Apple Health export.xml with STRICT privacy controls.

        PRIVACY REQUIREMENTS:
        - compartment_level=5 for ALL health data (highest privacy)
        - Only aggregate patterns, NOT individual readings
        - BLOCKED: blood pressure, medications, lab results, reproductive health
        - ALLOWED: activity, heart rate patterns, weight, sleep, workouts

        SOURCE DEDUPLICATION:
        - Multiple devices (Apple Watch, Whoop, Ultrahuman) track overlapping data
        - For each (date, metric), select only the highest priority source
        - Prevents double-counting sleep, HR, steps, etc.

        This method stream-parses the XML to handle large files (4GB+) efficiently.
        Records are aggregated to weekly patterns to protect privacy.
        """
        logger.info("Parsing Apple Health export (privacy-protected, source-deduplicated)")

        # Statistics tracking
        stats = {
            'total_records': 0,
            'allowed_records': 0,
            'blocked_records': 0,
            'clinical_blocked': 0,
            'workouts': 0,
            'sources_detected': set(),
        }

        # Phase 1: Collect data by (record_type, date, source) for deduplication
        # Key: record_type -> date -> source -> list of values
        raw_data: Dict[str, Dict[str, Dict[str, List[float]]]] = defaultdict(
            lambda: defaultdict(lambda: defaultdict(list))
        )

        # Sleep data by (date, source)
        # Key: date -> source -> {'in_bed_minutes': float, 'asleep_minutes': float}
        raw_sleep: Dict[str, Dict[str, Dict[str, float]]] = defaultdict(
            lambda: defaultdict(lambda: {'in_bed_minutes': 0, 'asleep_minutes': 0})
        )

        # Workout aggregation (workouts don't need deduplication - they're unique events)
        workout_data: Dict[str, Dict] = defaultdict(lambda: {
            'count': 0, 'total_duration_min': 0, 'dates': []
        })

        # Stream parse the XML from ZIP
        with zf.open(xml_path) as xml_file:
            # Use iterparse for memory-efficient parsing
            context = ET.iterparse(xml_file, events=('end',))

            for event, elem in context:
                try:
                    if elem.tag == 'Record':
                        stats['total_records'] += 1
                        record_type = elem.get('type', '')
                        source_name = elem.get('sourceName', 'Unknown')

                        # Track sources
                        stats['sources_detected'].add(source_name)

                        # BLOCKED: Skip clinical and sensitive records
                        if record_type.startswith('HKClinicalTypeIdentifier'):
                            stats['clinical_blocked'] += 1
                            elem.clear()
                            continue

                        if record_type in APPLE_HEALTH_BLOCKED_TYPES:
                            stats['blocked_records'] += 1
                            elem.clear()
                            continue

                        # ALLOWED: Process allowed record types
                        if record_type in APPLE_HEALTH_ALLOWED_TYPES:
                            stats['allowed_records'] += 1
                            self._collect_health_record(
                                elem, record_type, source_name, raw_data, raw_sleep
                            )

                        # Clear element to free memory
                        elem.clear()

                    elif elem.tag == 'Workout':
                        stats['workouts'] += 1
                        self._aggregate_workout(elem, workout_data)
                        elem.clear()

                except Exception as e:
                    logger.warning(f"Error parsing health record: {e}")
                    elem.clear()
                    continue

                # Log progress and manage memory every 500K records
                if stats['total_records'] % 500000 == 0:
                    import gc
                    import sys
                    # Force garbage collection to free memory
                    gc.collect()
                    # Estimate memory usage
                    raw_data_size = sys.getsizeof(raw_data)
                    raw_sleep_size = sys.getsizeof(raw_sleep)
                    workout_size = sys.getsizeof(workout_data)
                    logger.info(
                        f"Health export progress: {stats['total_records']:,} records, "
                        f"allowed={stats['allowed_records']:,}, "
                        f"mem_est=~{(raw_data_size + raw_sleep_size + workout_size) // 1024 // 1024}MB"
                    )

        # Log detected sources
        logger.info(f"Health sources detected: {sorted(stats['sources_detected'])}")
        logger.info(
            f"Health export scan complete: {stats['total_records']:,} total, "
            f"{stats['allowed_records']:,} allowed, {stats['blocked_records']:,} blocked, "
            f"{stats['clinical_blocked']:,} clinical blocked, {stats['workouts']:,} workouts"
        )

        # Free memory from parsing before deduplication
        import gc
        gc.collect()
        logger.info("Memory freed after XML parsing, starting deduplication")

        # Phase 2: Apply source priority deduplication
        weekly_data, dedup_stats = self._deduplicate_health_data(raw_data)
        sleep_data, sleep_dedup_stats = self._deduplicate_sleep_data(raw_sleep)

        logger.info(
            f"Deduplication complete - Activity: {dedup_stats['dates_with_multiple_sources']} dates had multiple sources, "
            f"Sleep: {sleep_dedup_stats['dates_with_multiple_sources']} dates deduplicated"
        )

        # Phase 3: Yield aggregated patterns as preferences
        async for pref in self._yield_activity_patterns(weekly_data):
            yield pref

        # Yield workout patterns
        async for pref in self._yield_workout_patterns(workout_data):
            yield pref

        # Yield sleep patterns
        async for pref in self._yield_sleep_patterns(sleep_data):
            yield pref

    def _collect_health_record(
        self,
        elem: ET.Element,
        record_type: str,
        source_name: str,
        raw_data: Dict[str, Dict[str, Dict[str, List[float]]]],
        raw_sleep: Dict[str, Dict[str, Dict[str, float]]]
    ) -> None:
        """Collect a health record for later deduplication."""
        try:
            start_date_str = elem.get('startDate', '')
            end_date_str = elem.get('endDate', '')
            value_str = elem.get('value', '')

            if not start_date_str:
                return

            # Parse timestamp
            try:
                start_date = datetime.strptime(start_date_str[:19], '%Y-%m-%d %H:%M:%S')
            except ValueError:
                return

            date_key = start_date.strftime('%Y-%m-%d')

            # Handle sleep analysis specially
            if record_type == 'HKCategoryTypeIdentifierSleepAnalysis':
                try:
                    end_date = datetime.strptime(end_date_str[:19], '%Y-%m-%d %H:%M:%S')
                    duration_min = (end_date - start_date).total_seconds() / 60
                except (ValueError, TypeError):
                    return

                sleep_value = value_str
                if 'Asleep' in sleep_value:
                    raw_sleep[date_key][source_name]['asleep_minutes'] += duration_min
                elif 'InBed' in sleep_value:
                    raw_sleep[date_key][source_name]['in_bed_minutes'] += duration_min
                return

            # Parse numeric value
            if not value_str:
                return

            try:
                value = float(value_str)
            except ValueError:
                return

            # Collect by (type, date, source)
            raw_data[record_type][date_key][source_name].append(value)

        except Exception as e:
            logger.debug(f"Error collecting health record: {e}")

    def _deduplicate_health_data(
        self,
        raw_data: Dict[str, Dict[str, Dict[str, List[float]]]]
    ) -> tuple:
        """Apply source priority deduplication to health data."""
        # Result: record_type -> date -> list of values (from selected source only)
        deduped: Dict[str, Dict[str, List[float]]] = defaultdict(lambda: defaultdict(list))

        stats = {
            'dates_with_multiple_sources': 0,
            'source_selections': defaultdict(int)
        }

        # Map record types to priority categories
        type_to_priority = {
            "HKQuantityTypeIdentifierStepCount": "steps",
            "HKQuantityTypeIdentifierDistanceWalkingRunning": "distance",
            "HKQuantityTypeIdentifierActiveEnergyBurned": "active_energy",
            "HKQuantityTypeIdentifierFlightsClimbed": "steps",  # Use steps priority
            "HKQuantityTypeIdentifierAppleExerciseTime": "active_energy",
            "HKQuantityTypeIdentifierHeartRate": "heart_rate",
            "HKQuantityTypeIdentifierRestingHeartRate": "resting_heart_rate",
            "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "hrv",
            "HKQuantityTypeIdentifierBodyMass": "weight",
        }

        for record_type, dates in raw_data.items():
            priority_key = type_to_priority.get(record_type, "steps")

            for date_key, sources in dates.items():
                if len(sources) > 1:
                    stats['dates_with_multiple_sources'] += 1

                # Select best source for this date
                selected_source = self._select_best_source(sources.keys(), priority_key)
                stats['source_selections'][selected_source] += 1

                # Use only data from selected source
                deduped[record_type][date_key] = sources[selected_source]

        return deduped, stats

    def _deduplicate_sleep_data(
        self,
        raw_sleep: Dict[str, Dict[str, Dict[str, float]]]
    ) -> tuple:
        """Apply source priority deduplication to sleep data."""
        # Result: date -> {'in_bed_minutes': float, 'asleep_minutes': float}
        deduped: Dict[str, Dict[str, float]] = defaultdict(lambda: {
            'in_bed_minutes': 0, 'asleep_minutes': 0
        })

        stats = {
            'dates_with_multiple_sources': 0,
            'source_selections': defaultdict(int)
        }

        for date_key, sources in raw_sleep.items():
            if len(sources) > 1:
                stats['dates_with_multiple_sources'] += 1

            # Select best source for this date
            selected_source = self._select_best_source(sources.keys(), "sleep")
            stats['source_selections'][selected_source] += 1

            # Use only data from selected source
            deduped[date_key] = sources[selected_source]

        return deduped, stats

    def _select_best_source(self, available_sources: set, priority_key: str) -> str:
        """Select the best source based on priority configuration."""
        priority_list = settings.health_source_priority.get(priority_key, [])

        # Try to match sources in priority order
        for preferred in priority_list:
            for source in available_sources:
                # Case-insensitive partial match
                if preferred.lower() in source.lower():
                    return source

        # If no priority match, return first available source
        return next(iter(available_sources))

    def _aggregate_workout(
        self,
        elem: ET.Element,
        workout_data: Dict[str, Dict]
    ) -> None:
        """Aggregate a workout record."""
        try:
            workout_type = elem.get('workoutActivityType', '')
            duration_str = elem.get('duration', '')
            duration_unit = elem.get('durationUnit', 'min')
            start_date_str = elem.get('startDate', '')

            if not workout_type:
                return

            # Parse duration
            duration_min = 0.0
            if duration_str:
                try:
                    duration = float(duration_str)
                    # Convert to minutes
                    if duration_unit == 'min':
                        duration_min = duration
                    elif duration_unit == 'sec':
                        duration_min = duration / 60
                    elif duration_unit == 'hr':
                        duration_min = duration * 60
                    else:
                        duration_min = duration  # Assume minutes
                except ValueError:
                    pass

            # Parse date
            date_str = None
            if start_date_str:
                try:
                    start_date = datetime.strptime(start_date_str[:19], '%Y-%m-%d %H:%M:%S')
                    date_str = start_date.strftime('%Y-%m-%d')
                except ValueError:
                    pass

            # Aggregate
            workout_data[workout_type]['count'] += 1
            workout_data[workout_type]['total_duration_min'] += duration_min
            if date_str:
                workout_data[workout_type]['dates'].append(date_str)

        except Exception as e:
            logger.debug(f"Error aggregating workout: {e}")

    async def _yield_activity_patterns(
        self,
        weekly_data: Dict[str, Dict[str, List[float]]]
    ) -> AsyncIterator[ParsedPreference]:
        """Yield aggregated activity patterns as preferences."""

        # Cumulative metrics should be summed per day, then averaged
        cumulative_types = {
            "HKQuantityTypeIdentifierStepCount",
            "HKQuantityTypeIdentifierActiveEnergyBurned",
            "HKQuantityTypeIdentifierDistanceWalkingRunning",
            "HKQuantityTypeIdentifierFlightsClimbed",
            "HKQuantityTypeIdentifierAppleExerciseTime",
        }

        # Calculate overall patterns per metric
        for record_type, days in weekly_data.items():
            if not days:
                continue

            # For cumulative metrics: sum each day's values, then average daily totals
            # For instantaneous metrics (HR, weight): average all values
            if record_type in cumulative_types:
                # Sum values per day to get daily totals
                daily_totals = []
                for date_key, values in days.items():
                    if values:
                        daily_totals.append(sum(values))

                if not daily_totals:
                    continue

                avg_value = sum(daily_totals) / len(daily_totals)
                total_value = sum(daily_totals)
                num_days = len(daily_totals)
            else:
                # For instantaneous metrics, average all readings
                all_values = []
                for day_values in days.values():
                    all_values.extend(day_values)

                if not all_values:
                    continue

                avg_value = sum(all_values) / len(all_values)
                total_value = sum(all_values)
                num_days = len(days)

            # Generate human-readable pattern name
            pattern_name, unit_name = self._health_pattern_name(record_type, avg_value, total_value, num_days)

            if not pattern_name:
                continue

            # Calculate strength based on consistency
            # More days of data = more consistent pattern
            consistency = min(num_days / 365, 1.0)  # Normalize to 1 year
            strength = 0.6 + (consistency * 0.2)  # 0.6 to 0.8

            yield ParsedPreference(
                subject=pattern_name,
                preference_type="Pattern",
                category="health",
                strength=strength,
                observed_at=None,  # Aggregate pattern, no single date
                source=self.source_name,
                compartment_level=5,  # HIGHEST PRIVACY for health data
                size="Medium",
                extra={
                    "health_metric": record_type,
                    "days_tracked": num_days,
                    "average_value": round(avg_value, 1),
                    "total_value": round(total_value, 1),
                    "unit": unit_name,
                    "data_type": "aggregated_pattern"
                }
            )

    def _health_pattern_name(
        self,
        record_type: str,
        avg_value: float,
        total_value: float,
        num_days: int
    ) -> tuple:
        """Generate human-readable pattern name for health metric."""
        patterns = {
            "HKQuantityTypeIdentifierStepCount": (
                f"Activity pattern: ~{int(avg_value):,} steps/day average",
                "steps"
            ),
            "HKQuantityTypeIdentifierDistanceWalkingRunning": (
                f"Activity pattern: ~{avg_value:.2f} km walked/run per day",
                "km"
            ),
            "HKQuantityTypeIdentifierActiveEnergyBurned": (
                f"Activity pattern: ~{int(avg_value):,} active calories/day",
                "kcal"
            ),
            "HKQuantityTypeIdentifierFlightsClimbed": (
                f"Activity pattern: ~{avg_value:.1f} flights climbed/day",
                "flights"
            ),
            "HKQuantityTypeIdentifierAppleExerciseTime": (
                f"Activity pattern: ~{int(avg_value)} exercise minutes/day",
                "min"
            ),
            "HKQuantityTypeIdentifierHeartRate": (
                f"Heart rate pattern: ~{int(avg_value)} bpm average",
                "bpm"
            ),
            "HKQuantityTypeIdentifierRestingHeartRate": (
                f"Resting heart rate pattern: ~{int(avg_value)} bpm",
                "bpm"
            ),
            "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": (
                f"HRV pattern: ~{avg_value:.1f} ms average",
                "ms"
            ),
            "HKQuantityTypeIdentifierBodyMass": (
                f"Weight pattern: ~{avg_value:.1f} kg average",
                "kg"
            ),
        }

        return patterns.get(record_type, ("", ""))

    async def _yield_workout_patterns(
        self,
        workout_data: Dict[str, Dict]
    ) -> AsyncIterator[ParsedPreference]:
        """Yield workout patterns as preferences."""

        for workout_type, data in workout_data.items():
            count = data['count']
            if count == 0:
                continue

            # Get friendly name
            friendly_name = APPLE_HEALTH_WORKOUT_NAMES.get(workout_type, workout_type.replace('HKWorkoutActivityType', ''))

            # Calculate average duration
            avg_duration = data['total_duration_min'] / count if count > 0 else 0

            # Calculate strength based on frequency
            # More workouts = stronger pattern
            strength = min(0.6 + (count * 0.005), 0.9)

            # Generate pattern name
            if avg_duration > 0:
                pattern_name = f"Workout pattern: {friendly_name} ({count} sessions, ~{int(avg_duration)} min avg)"
            else:
                pattern_name = f"Workout pattern: {friendly_name} ({count} sessions)"

            yield ParsedPreference(
                subject=pattern_name,
                preference_type="Pattern",
                category="fitness",
                strength=strength,
                observed_at=None,
                source=self.source_name,
                compartment_level=5,  # HIGHEST PRIVACY
                size="Medium",
                extra={
                    "workout_type": workout_type,
                    "workout_name": friendly_name,
                    "session_count": count,
                    "total_duration_min": round(data['total_duration_min'], 1),
                    "avg_duration_min": round(avg_duration, 1),
                    "data_type": "workout_pattern"
                }
            )

    async def _yield_sleep_patterns(
        self,
        sleep_data: Dict[str, Dict[str, float]]
    ) -> AsyncIterator[ParsedPreference]:
        """Yield sleep patterns as preferences."""

        if not sleep_data:
            return

        # Calculate overall sleep averages
        total_in_bed = 0
        total_asleep = 0
        days_tracked = 0

        for date_key, data in sleep_data.items():
            if data['in_bed_minutes'] > 0 or data['asleep_minutes'] > 0:
                days_tracked += 1
                total_in_bed += data['in_bed_minutes']
                total_asleep += data['asleep_minutes']

        if days_tracked == 0:
            return

        avg_in_bed_hours = (total_in_bed / days_tracked) / 60
        avg_asleep_hours = (total_asleep / days_tracked) / 60

        # Yield sleep pattern
        if avg_asleep_hours > 0:
            pattern_name = f"Sleep pattern: ~{avg_asleep_hours:.1f} hours sleep average"
            strength = min(0.6 + (days_tracked / 365) * 0.2, 0.8)

            yield ParsedPreference(
                subject=pattern_name,
                preference_type="Pattern",
                category="wellness",
                strength=strength,
                observed_at=None,
                source=self.source_name,
                compartment_level=5,  # HIGHEST PRIVACY
                size="Medium",
                extra={
                    "avg_sleep_hours": round(avg_asleep_hours, 2),
                    "avg_in_bed_hours": round(avg_in_bed_hours, 2),
                    "days_tracked": days_tracked,
                    "data_type": "sleep_pattern"
                }
            )

    async def _parse_icloud_calendars(
        self,
        extract_dir: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse iCloud Calendars with privacy-focused pattern extraction.

        PRIVACY CONTROLS (compartment_level=3):
        - Does NOT store individual event titles (may contain meeting info, names)
        - Skips events with sensitive keywords (medical, legal, work meetings)
        - Only stores: calendar categories, subscribed calendar interests,
          recurring activity patterns (categorized)

        Extracts:
        1. Calendar categories used (Work, Home, Family) -> reveals life organization
        2. Subscribed calendars -> reveals interests (AI groups, sports teams)
        3. Recurring event patterns -> reveals lifestyle habits

        ICS format reference:
        - VEVENT = calendar event, VTODO = reminder
        - RRULE = recurrence rule (FREQ=WEEKLY, FREQ=MONTHLY, etc.)
        - SUMMARY = event title
        """
        logger.info(f"Parsing iCloud Calendars from: {extract_dir}")

        # Statistics for logging
        stats = {
            'calendars_found': 0,
            'personal_calendars': 0,
            'subscribed_calendars': 0,
            'total_events': 0,
            'recurring_events': 0,
            'skipped_sensitive': 0,
            'categorized_activities': 0,
        }

        # Track calendar metadata
        calendar_info = {}  # calendar_name -> {'type': str, 'subscribed_url': str, 'storage': int}

        # Track recurring activity patterns
        # Key: (calendar_name, activity_category, frequency) -> count
        activity_patterns = defaultdict(int)

        # Track subscribed calendars that reveal interests
        subscribed_interests = []

        # 1. Parse Calendar Metadata.json
        metadata_files = list(extract_dir.rglob("Calendar Metadata.json"))
        if metadata_files:
            try:
                async with aiofiles.open(metadata_files[0], mode='r', encoding='utf-8') as f:
                    content = await f.read()
                    metadata = json.loads(content)

                for cal in metadata:
                    display_name = cal.get('Calendar Display Name', '').strip()
                    if not display_name:
                        continue

                    collection_type = cal.get('Original Calendar Collection Type', '')
                    subscribed_url = cal.get('Calendar Collection Subscribed To Public URL', '')
                    storage = cal.get('Calendar Collection Total Storage', 0)

                    calendar_info[display_name] = {
                        'type': collection_type,
                        'subscribed_url': subscribed_url,
                        'storage': int(storage) if storage else 0,
                    }
                    stats['calendars_found'] += 1

                    if subscribed_url:
                        stats['subscribed_calendars'] += 1
                        # Subscribed calendars reveal interests
                        # (AI Tinkerers, Leicester Tigers, etc.)
                        subscribed_interests.append({
                            'name': display_name,
                            'url': subscribed_url,
                        })
                    else:
                        stats['personal_calendars'] += 1

            except Exception as e:
                logger.warning(f"Error parsing Calendar Metadata.json: {e}")

        # 2. Parse ICS files for recurring events
        ics_files = list(extract_dir.rglob("*.ics"))

        for ics_file in ics_files:
            try:
                async with aiofiles.open(ics_file, mode='r', encoding='utf-8') as f:
                    content = await f.read()

                calendar_name = ics_file.stem  # Filename without extension
                events = content.split('BEGIN:VEVENT')

                for event_block in events[1:]:  # Skip first split (before first VEVENT)
                    event_block = event_block.split('END:VEVENT')[0]
                    stats['total_events'] += 1

                    # Only process recurring events
                    if 'RRULE:' not in event_block:
                        continue

                    stats['recurring_events'] += 1

                    # Extract SUMMARY (event title)
                    summary = ''
                    lines = event_block.split('\n')
                    for i, line in enumerate(lines):
                        if line.startswith('SUMMARY:'):
                            summary = line.replace('SUMMARY:', '').strip()
                            # Handle multi-line (continuation with space/tab)
                            for j in range(i + 1, min(i + 3, len(lines))):
                                if lines[j].startswith((' ', '\t')):
                                    summary += lines[j].strip()
                                else:
                                    break
                            break

                    if not summary:
                        continue

                    summary_lower = summary.lower()

                    # Skip sensitive events
                    is_sensitive = any(
                        kw in summary_lower
                        for kw in CALENDAR_SENSITIVE_KEYWORDS
                    )
                    if is_sensitive:
                        stats['skipped_sensitive'] += 1
                        continue

                    # Extract RRULE frequency
                    rrule_match = re.search(r'RRULE:[^\n]*FREQ=(\w+)', event_block)
                    frequency = rrule_match.group(1).lower() if rrule_match else 'unknown'

                    # Categorize the activity
                    activity_category = None
                    for category, keywords in CALENDAR_ACTIVITY_CATEGORIES.items():
                        if any(kw in summary_lower for kw in keywords):
                            activity_category = category
                            break

                    if activity_category:
                        stats['categorized_activities'] += 1
                        pattern_key = (calendar_name, activity_category, frequency)
                        activity_patterns[pattern_key] += 1

            except Exception as e:
                logger.warning(f"Error parsing ICS file {ics_file}: {e}")
                continue

        # 3. Yield preferences

        # 3a. Emit calendar category preferences
        # Personal calendars reveal life organization patterns
        personal_calendar_names = [
            name for name, info in calendar_info.items()
            if not info['subscribed_url'] and info['type'] == 'VEVENT'
            and name.lower() not in ('inbox', 'notification', '')
        ]

        for cal_name in personal_calendar_names:
            info = calendar_info[cal_name]
            # Strength based on usage (storage size as proxy)
            strength = 0.6
            if info['storage'] > 100000:  # 100KB+
                strength = 0.7
            if info['storage'] > 500000:  # 500KB+
                strength = 0.75

            yield ParsedPreference(
                subject=f"Calendar: {cal_name}",
                preference_type="Pattern",
                category="organization",
                strength=strength,
                observed_at=None,
                source=self.source_name,
                compartment_level=3,  # Calendar data privacy
                size="Medium",
                extra={
                    "calendar_type": "personal",
                    "collection_type": info['type'],
                    "storage_bytes": info['storage'],
                }
            )

        # 3b. Emit subscribed calendar interests
        for sub in subscribed_interests:
            name = sub['name']
            url = sub['url']

            # Skip generic/system calendars
            if any(skip in name.lower() for skip in [
                'holiday', 'holidays', 'parents evening', 'untitled'
            ]):
                continue

            # Subscribed calendars show active interest
            yield ParsedPreference(
                subject=f"Interest: {name}",
                preference_type="Like",
                category="subscription",
                strength=0.75,  # Active subscription = clear interest
                observed_at=None,
                source=self.source_name,
                compartment_level=3,
                size="Small",
                extra={
                    "calendar_type": "subscribed",
                    "subscription_url": url[:100] if url else None,
                }
            )

        # 3c. Emit activity pattern aggregates
        # Group by activity category across all calendars
        category_totals = defaultdict(lambda: {'weekly': 0, 'daily': 0, 'monthly': 0, 'yearly': 0, 'other': 0})

        for (cal_name, category, freq), count in activity_patterns.items():
            if freq in ('weekly', 'daily', 'monthly', 'yearly'):
                category_totals[category][freq] += count
            else:
                category_totals[category]['other'] += count

        for category, freq_counts in category_totals.items():
            total = sum(freq_counts.values())
            if total == 0:
                continue

            # Determine primary frequency
            primary_freq = max(freq_counts, key=freq_counts.get)
            # primary_count available via freq_counts[primary_freq] if needed

            # Build pattern description
            category_display = category.replace('_', ' ').title()
            if primary_freq == 'weekly':
                pattern_desc = f"Weekly {category_display} activities"
            elif primary_freq == 'daily':
                pattern_desc = f"Daily {category_display} activities"
            elif primary_freq == 'monthly':
                pattern_desc = f"Monthly {category_display} activities"
            elif primary_freq == 'yearly':
                pattern_desc = f"Yearly {category_display} events"
            else:
                pattern_desc = f"{category_display} activities"

            # Strength based on frequency count
            strength = min(0.6 + (total * 0.03), 0.85)

            yield ParsedPreference(
                subject=pattern_desc,
                preference_type="Pattern",
                category="lifestyle",
                strength=strength,
                observed_at=None,
                source=self.source_name,
                compartment_level=3,
                size="Medium",
                extra={
                    "activity_category": category,
                    "total_recurring_events": total,
                    "weekly_count": freq_counts['weekly'],
                    "daily_count": freq_counts['daily'],
                    "monthly_count": freq_counts['monthly'],
                    "yearly_count": freq_counts['yearly'],
                    "primary_frequency": primary_freq,
                }
            )

        logger.info(
            f"iCloud Calendars parsing complete: "
            f"{stats['calendars_found']} calendars ({stats['personal_calendars']} personal, "
            f"{stats['subscribed_calendars']} subscribed), "
            f"{stats['recurring_events']}/{stats['total_events']} recurring events, "
            f"{stats['categorized_activities']} categorized, "
            f"{stats['skipped_sensitive']} skipped (sensitive)"
        )
