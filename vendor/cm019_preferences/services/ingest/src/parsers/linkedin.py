"""LinkedIn data parser."""

import csv
import logging
from pathlib import Path
from typing import AsyncIterator, Optional
from datetime import datetime
import aiofiles
import re

from .base import BaseParser, ParsedPreference
from ..config import settings

logger = logging.getLogger(__name__)


class LinkedInParser(BaseParser):
    """
    Parser for LinkedIn data exports.

    Handles:
    - Reactions.csv (LIKE, LOVE, EMPATHY, etc.)
    - Comments.csv (comments on posts)
    - Company Follows.csv (companies followed)
    - Member_Follows.csv (people followed)
    - Learning.csv (courses completed)
    """

    source_name = "linkedin"

    REACTION_STRENGTH = {
        "LIKE": 0.6,
        "LOVE": 0.8,
        "EMPATHY": 0.7,
        "SUPPORT": 0.7,
        "CELEBRATE": 0.75,
        "FUNNY": 0.65,
        "INTEREST": 0.7,
        "PRAISE": 0.8,
        "APPRECIATION": 0.8,
        "MAYBE": 0.4,
        "ENTERTAINMENT": 0.6,
    }

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a LinkedIn data export."""
        name = file_path.name.lower()

        # Check if it's one of the supported LinkedIn files
        supported_files = [
            "reactions.csv",
            "comments.csv",
            "company follows.csv",
            "member_follows.csv",
            "learning.csv",
            "endorsement_received_info.csv",
            "endorsement_given_info.csv",
            "saved_items.csv",
            "inferences_about_you.csv",
            "skills.csv",
        ]

        return any(name == f for f in supported_files) or \
               name.startswith("complete_linkedindataexport")

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse LinkedIn data export."""
        if default_compartment is None:
            default_compartment = settings.default_compartment

        file_name = file_path.name.lower()

        # Route to appropriate parser based on filename
        if "reactions.csv" in file_name:
            async for pref in self._parse_reactions(file_path, default_compartment):
                yield pref
        elif "comments.csv" in file_name:
            async for pref in self._parse_comments(file_path, default_compartment):
                yield pref
        elif "company follows.csv" in file_name or "company_follows.csv" in file_name:
            async for pref in self._parse_company_follows(file_path, default_compartment):
                yield pref
        elif "member_follows.csv" in file_name:
            async for pref in self._parse_member_follows(file_path, default_compartment):
                yield pref
        elif "learning.csv" in file_name:
            async for pref in self._parse_learning(file_path, default_compartment):
                yield pref
        elif "endorsement" in file_name:
            async for pref in self._parse_endorsements(file_path, default_compartment):
                yield pref
        elif "saved_items.csv" in file_name:
            async for pref in self._parse_saved_items(file_path, default_compartment):
                yield pref
        elif "inferences_about_you.csv" in file_name:
            async for pref in self._parse_inferences(file_path, default_compartment):
                yield pref
        elif "skills.csv" in file_name:
            async for pref in self._parse_skills(file_path, default_compartment):
                yield pref
        else:
            # Check if it's a directory export - look for Reactions.csv inside
            if file_path.is_dir():
                reactions_file = file_path / "Reactions.csv"
                if reactions_file.exists():
                    async for pref in self._parse_reactions(reactions_file, default_compartment):
                        yield pref

                comments_file = file_path / "Comments.csv"
                if comments_file.exists():
                    async for pref in self._parse_comments(comments_file, default_compartment):
                        yield pref

                company_follows_file = file_path / "Company Follows.csv"
                if company_follows_file.exists():
                    async for pref in self._parse_company_follows(company_follows_file, default_compartment):
                        yield pref

    async def _parse_reactions(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn Reactions.csv.

        NOTE: LinkedIn exports only contain reaction type and post URL, not the
        actual post content. Creating preferences like "LinkedIn post (LIKE)"
        is useless - there's no meaningful subject.

        Instead, we aggregate reactions by type and log for reference.
        The actual preference signals come from:
        - Company Follows.csv (company names)
        - Member_Follows.csv (people names)
        - Learning.csv (course titles)
        - Skills.csv (skill names)
        - Inferences_about_you.csv (LinkedIn's inferred interests)

        Format: Date,Type,Link
        """
        logger.info(f"Parsing LinkedIn reactions from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        reaction_counts = {}
        for row in reader:
            try:
                reaction_type = row.get('Type', '').strip().upper()
                if reaction_type:
                    reaction_counts[reaction_type] = reaction_counts.get(reaction_type, 0) + 1
            except Exception:
                continue

        total = sum(reaction_counts.values())
        logger.info(
            f"LinkedIn reactions: {total} total ({reaction_counts}) "
            "(skipped - exports don't include post content, only links)"
        )

        # Don't yield useless preferences - return early
        return
        yield  # Make this a generator

    async def _parse_comments(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn Comments.csv.

        NOTE: Comments contain the user's own message text, but NOT what they
        commented on. Creating preferences from your own comment text is not
        useful - it would just be random text snippets.

        The comment activity is logged for reference but no preferences yielded.
        Format: Date,Link,Message
        """
        logger.info(f"Parsing LinkedIn comments from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        comment_count = 0
        for row in reader:
            try:
                if row.get('Link', '').strip():
                    comment_count += 1
            except Exception:
                continue

        logger.info(
            f"LinkedIn comments: {comment_count} total "
            "(skipped - comment text isn't a useful preference subject)"
        )

        # Don't yield useless preferences
        return
        yield  # Make this a generator

    async def _parse_company_follows(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn Company Follows.csv.

        Following companies indicates professional interests.
        Format: Organization,Followed On
        """
        logger.info(f"Parsing LinkedIn company follows from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                organization = row.get('Organization', '').strip()
                followed_on = row.get('Followed On', '').strip()

                if not organization:
                    continue

                # Parse timestamp
                timestamp = None
                if followed_on:
                    try:
                        # Parse "Fri Nov 28 08:59:24 UTC 2025" format
                        timestamp = datetime.strptime(followed_on, "%a %b %d %H:%M:%S UTC %Y")
                    except ValueError:
                        logger.warning(f"Could not parse date: {followed_on}")

                yield ParsedPreference(
                    subject=organization,
                    preference_type="Like",
                    category="professional",
                    strength=0.22,  # V2
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "company_name": organization,
                        "follow_type": "company",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing company follow row: {e}")
                continue

    async def _parse_member_follows(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn Member_Follows.csv.

        Following people indicates professional interests.
        Format: Member,Followed On
        """
        logger.info(f"Parsing LinkedIn member follows from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                member = row.get('Member', '').strip()
                followed_on = row.get('Followed On', '').strip()

                if not member:
                    continue

                # Parse timestamp
                timestamp = None
                if followed_on:
                    try:
                        timestamp = datetime.strptime(followed_on, "%a %b %d %H:%M:%S UTC %Y")
                    except ValueError:
                        logger.warning(f"Could not parse date: {followed_on}")

                yield ParsedPreference(
                    subject=member,
                    preference_type="Like",
                    category="social_media",
                    strength=0.18,  # V2
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "member_name": member,
                        "follow_type": "member",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing member follow row: {e}")
                continue

    async def _parse_learning(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn Learning.csv.

        Completed courses indicate professional development interests.
        """
        logger.info(f"Parsing LinkedIn learning from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                # Learning.csv format varies - check multiple column names
                title = (row.get('Content Title', '') or row.get('Title', '') or
                         row.get('Course Title', '') or row.get('Name', ''))
                title = title.strip()

                completed_date = (row.get('Content Completed At (if completed)', '') or
                                  row.get('Completed Date', '') or row.get('Completed', ''))
                completed_date = completed_date.strip()

                # Also capture last watched date if no completion date
                last_watched = row.get('Content Last Watched Date (if viewed)', '').strip()

                if not title:
                    continue

                # Skip if "N/A" completion and no watch date
                if completed_date == 'N/A':
                    completed_date = last_watched if last_watched and last_watched != 'N/A' else ''

                # Parse timestamp
                timestamp = None
                if completed_date:
                    # Handle various date formats
                    date_formats = [
                        "%Y-%m-%d %H:%M UTC",  # 2025-06-14 09:48 UTC
                        "%Y-%m-%d",
                        "%m/%d/%Y",
                    ]
                    for fmt in date_formats:
                        try:
                            timestamp = datetime.strptime(completed_date, fmt)
                            break
                        except ValueError:
                            continue
                    if not timestamp:
                        logger.warning(f"Could not parse date: {completed_date}")

                # Course completion is a strong signal of interest
                strength = 0.8

                yield ParsedPreference(
                    subject=title,
                    preference_type="Like",
                    category="education",
                    strength=strength,
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "course_title": title,
                        "learning_type": "course",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing learning row: {e}")
                continue

    def _extract_post_id(self, link: str) -> Optional[str]:
        """Extract post/activity ID from LinkedIn URL."""
        # Extract URN or activity ID from link
        # Examples:
        # - urn:li:activity:7396866605940572160
        # - urn:li:ugcPost:7411951962360872960
        match = re.search(r'urn%3Ali%3A(?:activity|ugcPost)%3A(\d+)', link)
        if match:
            return match.group(1)

        match = re.search(r'urn:li:(?:activity|ugcPost):(\d+)', link)
        if match:
            return match.group(1)

        return None

    async def _parse_endorsements(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn endorsement CSVs.

        Endorsement_Received_Info.csv - skills others endorsed you for
        Endorsement_Given_Info.csv - skills you endorsed others for

        Both indicate professional interests/expertise.
        """
        logger.info(f"Parsing LinkedIn endorsements from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())
        is_received = "received" in file_path.name.lower()

        # Aggregate endorsements by skill
        skill_counts = {}

        for row in reader:
            try:
                skill = row.get('Skill Name', '').strip()
                if not skill:
                    continue

                if skill not in skill_counts:
                    skill_counts[skill] = {
                        'count': 0,
                        'last_date': None
                    }

                skill_counts[skill]['count'] += 1

                # Parse date
                date_str = row.get('Endorsement Date', '').strip()
                if date_str:
                    try:
                        # Format: 2023/10/03 10:37:18 UTC
                        date_str = date_str.replace(' UTC', '')
                        timestamp = datetime.strptime(date_str, "%Y/%m/%d %H:%M:%S")
                        if not skill_counts[skill]['last_date'] or timestamp > skill_counts[skill]['last_date']:
                            skill_counts[skill]['last_date'] = timestamp
                    except ValueError:
                        pass

            except Exception as e:
                logger.warning(f"Error parsing endorsement row: {e}")
                continue

        # Emit preferences for each skill
        for skill, data in skill_counts.items():
            # Received endorsements are stronger signals (others validate your skill)
            # Given endorsements show interest in the topic
            base_strength = 0.75 if is_received else 0.6

            # Bonus for multiple endorsements
            if data['count'] >= 5:
                base_strength += 0.1
            elif data['count'] >= 2:
                base_strength += 0.05

            yield ParsedPreference(
                subject=skill,
                preference_type="Like",
                category="professional",
                strength=min(base_strength, 0.9),
                observed_at=data['last_date'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "skill_name": skill,
                    "endorsement_count": data['count'],
                    "endorsement_type": "received" if is_received else "given"
                }
            )

    async def _parse_saved_items(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn Saved_Items.csv.

        NOTE: LinkedIn exports only contain post URLs, not the actual content.
        Creating preferences like "LinkedIn post 12345678" is useless.

        The saved item count is logged for reference but no preferences yielded.
        """
        logger.info(f"Parsing LinkedIn saved items from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        saved_count = 0
        for row in reader:
            try:
                if row.get('savedItem', '').strip():
                    saved_count += 1
            except Exception:
                continue

        logger.info(
            f"LinkedIn saved items: {saved_count} total "
            "(skipped - exports don't include post content, only URLs)"
        )

        # Don't yield useless preferences
        return
        yield  # Make this a generator

    async def _parse_inferences(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn Inferences_about_you.csv.

        LinkedIn's pre-computed inferences about user interests and characteristics.
        Format: Category,Type of inference,Description,Inference

        Categories include:
        - Career inferences
        - Inferred interests
        - Inferred personal characteristics
        - Job search inferences
        - LinkedIn activity inferences
        """
        logger.info(f"Parsing LinkedIn inferences from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        # Map inference categories to preference categories
        category_mapping = {
            "career inferences": "professional",
            "inferred interests": "inferred_interest",
            "inferred personal characteristics": "personal",
            "job search inferences": "professional",
            "linkedin activity inferences": "social_media",
        }

        for row in reader:
            try:
                category = row.get('Category', '').strip().lower()
                inference_type = row.get('Type of inference', '').strip()
                description = row.get('Description', '').strip()
                inference_value = row.get('Inference', '').strip().lower()

                if not inference_type:
                    continue

                # Skip negative inferences
                if inference_value in ('no', 'false', 'n/a', ''):
                    continue

                # Map to preference category
                pref_category = category_mapping.get(category, "inferred_interest")

                # Skip personal characteristics (like gender) - these aren't preferences
                if category == "inferred personal characteristics":
                    continue

                # Determine strength based on the inference being "true"
                # These are pre-computed by LinkedIn so we trust them moderately
                strength = 0.7

                yield ParsedPreference(
                    subject=inference_type,
                    preference_type="Like",
                    category=pref_category,
                    strength=strength,
                    observed_at=None,  # Inferences don't have timestamps
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "inference_category": category,
                        "inference_description": description,
                        "inference_value": inference_value,
                        "data_type": "linkedin_inference",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing inference row: {e}")
                continue

    async def _parse_skills(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse LinkedIn Skills.csv.

        User's self-declared professional skills.
        Format: Name (single column with skill names)
        """
        logger.info(f"Parsing LinkedIn skills from {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                skill_name = row.get('Name', '').strip()

                if not skill_name:
                    continue

                # Skills are self-declared, so they represent strong signals
                # of professional identity and interest
                strength = 0.8

                yield ParsedPreference(
                    subject=skill_name,
                    preference_type="Like",
                    category="professional",
                    strength=strength,
                    observed_at=None,  # Skills don't have timestamps
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "skill_name": skill_name,
                        "data_type": "linkedin_skill",
                    }
                )

            except Exception as e:
                logger.warning(f"Error parsing skill row: {e}")
                continue
