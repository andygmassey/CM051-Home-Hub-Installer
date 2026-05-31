"""
Email Preference Parser - Ingest preferences from CM021 Email Intelligence.

Reads JSONL (JSON Lines) format where each line is one preference.
Outputs ParsedPreference objects for storage in Oxigraph/Qdrant.

This parser is designed to work with CM021's PWG formatter output.

Usage:
    from services.ingest.src.parsers.email import EmailParser

    parser = EmailParser()
    async for pref in parser.parse(Path('preferences.jsonl')):
        # Store preference
        pass
"""

import json
import logging
from datetime import datetime
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, Any, List

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)


class EmailParser(BaseParser):
    """
    Parser for CM021 Email Intelligence output.

    Accepts JSONL files with one preference per line.
    Each line should be a JSON object with fields matching ParsedPreference.

    Expected JSONL format:
    {"subject": "...", "preference_type": "Like", "category": "shopping",
     "strength": 0.8, "source": "email_order", "observed_at": "2025-06-15T10:30:00Z",
     "compartment_level": 2, "extra": {...}}
    """

    source_name = "email"

    # Valid preference types from CM021
    VALID_PREFERENCE_TYPES = {"Like", "Dislike", "Love", "Hate", "Neutral", "Pattern", "Experience"}

    # Valid source types from CM021
    VALID_SOURCES = {
        "email_order",
        "email_newsletter",
        "email_subscription",
        "email_travel",
        "email_recruiter",
        "email_receipt",
        "email_notification",
        "email_marketing",
    }

    # Category mappings (CM021 categories to CM019 categories)
    CATEGORY_MAP = {
        "shopping": "shopping",
        "brand": "brand",
        "topic": "topic",
        "service": "service",
        "travel": "travel",
        "career": "professional",
        "newsletter": "newsletter",
        "product": "shopping",
        "entity": "entity",
        "person": "person",
    }

    def can_parse(self, file_path: Path) -> bool:
        """Check if this parser can handle the given file."""
        # Accept .jsonl files
        if file_path.suffix.lower() == '.jsonl':
            return True

        # Accept .json files that look like JSONL (one object per line)
        if file_path.suffix.lower() == '.json':
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    first_line = f.readline().strip()
                    if first_line.startswith('{') and first_line.endswith('}'):
                        # Check if it has expected email preference fields
                        data = json.loads(first_line)
                        if 'subject' in data and 'source' in data:
                            source = data.get('source', '')
                            if source.startswith('email_') or 'email' in source.lower():
                                return True
            except (json.JSONDecodeError, IOError):
                pass

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse CM021 email preference output (JSONL format).

        Args:
            file_path: Path to JSONL file from CM021's PWG formatter
            default_compartment: Override compartment level for all preferences
            **kwargs: Additional options
                - min_strength: Minimum strength threshold (default: 0.0)
                - allowed_categories: List of categories to include (default: all)
                - allowed_sources: List of sources to include (default: all)

        Yields:
            ParsedPreference objects ready for storage
        """
        min_strength = kwargs.get('min_strength', 0.0)
        allowed_categories = kwargs.get('allowed_categories')
        allowed_sources = kwargs.get('allowed_sources')

        if not file_path.exists():
            logger.error(f"Email preferences file not found: {file_path}")
            return

        line_number = 0
        valid_count = 0
        error_count = 0
        skipped_count = 0

        logger.info(f"Parsing email preferences from: {file_path}")

        with open(file_path, 'r', encoding='utf-8') as f:
            for line in f:
                line_number += 1
                line = line.strip()

                if not line:
                    continue

                try:
                    data = json.loads(line)

                    # Validate required fields
                    subject = data.get('subject', '').strip()
                    if not subject:
                        logger.debug(f"Line {line_number}: Empty subject, skipping")
                        skipped_count += 1
                        continue

                    # Get and validate source
                    source = data.get('source', 'email')
                    if allowed_sources and source not in allowed_sources:
                        skipped_count += 1
                        continue

                    # Get and map category
                    category = data.get('category', 'unknown')
                    mapped_category = self.CATEGORY_MAP.get(category, category)
                    if allowed_categories and mapped_category not in allowed_categories:
                        skipped_count += 1
                        continue

                    # Get and validate strength
                    strength = self._validate_strength(data.get('strength', 0.5))
                    if strength < min_strength:
                        skipped_count += 1
                        continue

                    # Parse observed_at timestamp
                    observed_at = self._parse_timestamp(data.get('observed_at'))

                    # Get compartment level
                    compartment = default_compartment or data.get('compartment_level', 2)
                    compartment = max(0, min(6, int(compartment)))

                    # Get preference type
                    pref_type = data.get('preference_type', 'Like')
                    if pref_type not in self.VALID_PREFERENCE_TYPES:
                        pref_type = 'Like'

                    # Get extra metadata
                    extra = data.get('extra', {})
                    if not isinstance(extra, dict):
                        extra = {}

                    # Add source tracking
                    extra['email_source'] = source
                    extra['original_category'] = category

                    # Include email_id if present for deduplication
                    if 'email_id' in data:
                        extra['email_id'] = data['email_id']

                    # Calculate size based on subject specificity
                    size = self.classify_size(subject, mapped_category)

                    yield ParsedPreference(
                        subject=subject,
                        preference_type=pref_type,
                        category=mapped_category,
                        strength=strength,
                        observed_at=observed_at,
                        source=source,
                        source_id=extra.get('email_id'),
                        compartment_level=compartment,
                        size=size,
                        extra=extra,
                    )

                    valid_count += 1

                except json.JSONDecodeError as e:
                    logger.warning(f"Line {line_number}: JSON parse error: {e}")
                    error_count += 1
                    continue
                except Exception as e:
                    logger.warning(f"Line {line_number}: Unexpected error: {e}")
                    error_count += 1
                    continue

        logger.info(
            f"Email parsing complete: {valid_count} valid, "
            f"{skipped_count} skipped, {error_count} errors "
            f"(total lines: {line_number})"
        )

    def _validate_strength(self, value: Any) -> float:
        """Ensure strength is between 0 and 1."""
        try:
            strength = float(value)
            return max(0.0, min(1.0, strength))
        except (TypeError, ValueError):
            return 0.5

    def _parse_timestamp(self, value: Optional[str]) -> Optional[datetime]:
        """Parse ISO 8601 timestamp string to datetime."""
        if not value:
            return None

        formats = [
            "%Y-%m-%dT%H:%M:%SZ",
            "%Y-%m-%dT%H:%M:%S.%fZ",
            "%Y-%m-%dT%H:%M:%S%z",
            "%Y-%m-%dT%H:%M:%S.%f%z",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%d",
        ]

        # Handle 'Z' suffix
        if isinstance(value, str) and value.endswith('Z'):
            value = value[:-1] + '+00:00'

        for fmt in formats:
            try:
                return datetime.strptime(value.replace('+00:00', ''), fmt.replace('%z', ''))
            except ValueError:
                continue

        # Try fromisoformat as fallback
        try:
            return datetime.fromisoformat(value.replace('Z', '+00:00'))
        except ValueError:
            logger.debug(f"Could not parse timestamp: {value}")
            return None


def get_file_stats(file_path: str) -> Dict[str, Any]:
    """
    Get statistics about an email preferences file without fully parsing it.

    Useful for showing summary before ingestion.

    Args:
        file_path: Path to JSONL file

    Returns:
        Dict with total count, breakdown by category/source, date range
    """
    stats = {
        'total': 0,
        'valid': 0,
        'errors': 0,
        'by_category': {},
        'by_source': {},
        'by_preference_type': {},
        'date_range': {'earliest': None, 'latest': None},
    }

    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            stats['total'] += 1

            try:
                data = json.loads(line)

                # Check for required fields
                if not data.get('subject'):
                    stats['errors'] += 1
                    continue

                stats['valid'] += 1

                # Count by category
                cat = data.get('category', 'unknown')
                stats['by_category'][cat] = stats['by_category'].get(cat, 0) + 1

                # Count by source
                src = data.get('source', 'unknown')
                stats['by_source'][src] = stats['by_source'].get(src, 0) + 1

                # Count by preference type
                ptype = data.get('preference_type', 'unknown')
                stats['by_preference_type'][ptype] = stats['by_preference_type'].get(ptype, 0) + 1

                # Track date range
                observed = data.get('observed_at')
                if observed:
                    if stats['date_range']['earliest'] is None or observed < stats['date_range']['earliest']:
                        stats['date_range']['earliest'] = observed
                    if stats['date_range']['latest'] is None or observed > stats['date_range']['latest']:
                        stats['date_range']['latest'] = observed

            except (json.JSONDecodeError, Exception):
                stats['errors'] += 1

    return stats


def validate_file(file_path: str, sample_size: int = 100) -> Dict[str, Any]:
    """
    Validate an email preferences file by parsing a sample.

    Args:
        file_path: Path to JSONL file
        sample_size: Number of records to validate

    Returns:
        Validation report with sample records and any issues found
    """
    report = {
        'file': file_path,
        'sample_size': sample_size,
        'valid_count': 0,
        'error_count': 0,
        'issues': [],
        'sample_records': [],
    }

    required_fields = ['subject', 'preference_type', 'category', 'strength', 'source', 'observed_at', 'compartment_level']

    line_number = 0
    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            line_number += 1
            if line_number > sample_size:
                break

            try:
                data = json.loads(line)

                # Check for missing required fields
                missing = [f for f in required_fields if f not in data or not data[f]]
                if missing:
                    report['issues'].append(f"Line {line_number}: Missing fields: {missing}")
                    report['error_count'] += 1
                    continue

                # Validate strength range
                strength = data.get('strength', 0)
                if not (0 <= strength <= 1):
                    report['issues'].append(f"Line {line_number}: Invalid strength {strength} (must be 0-1)")

                # Validate compartment level
                compartment = data.get('compartment_level', 0)
                if not (0 <= compartment <= 6):
                    report['issues'].append(f"Line {line_number}: Invalid compartment {compartment} (must be 0-6)")

                report['valid_count'] += 1

                if len(report['sample_records']) < 5:
                    report['sample_records'].append(data)

            except json.JSONDecodeError as e:
                report['issues'].append(f"Line {line_number}: JSON error: {e}")
                report['error_count'] += 1

    return report
