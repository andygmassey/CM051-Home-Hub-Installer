"""Preference filtering and deduplication with frequency aggregation."""

import logging
import re
import hashlib
import math
from typing import Set, List, Dict, Tuple
from dataclasses import replace
from .parsers.base import ParsedPreference

logger = logging.getLogger(__name__)


class PreferenceFilter:
    """
    Filters low-value preferences and handles deduplication with frequency tracking.

    Low-value entries include:
    - Empty or very short subjects
    - Generic subjects like "N/A", "liked a post"

    Deduplication:
    - Tracks frequency of duplicate entries
    - Aggregates counts to preserve preference strength signal
    - Higher frequency = stronger preference
    """

    # Patterns that indicate TRUE garbage (parsing artifacts, not meaningful data)
    # IMPORTANT: Be very conservative here. Even "liked a post" has meaning:
    # - Shows platform engagement frequency
    # - Activity patterns over time
    # - Aggregated frequency is a preference signal
    #
    # Only filter things that are genuinely empty/broken data, not engagement signals.
    LOW_VALUE_PATTERNS = [
        # Truly empty or placeholder values (parsing artifacts)
        r'^N/?A$',
        r'^n/?a$',
        r'^None$',
        r'^null$',
        r'^undefined$',
        r'^-$',
        r'^\s*$',
        r'^\.$',
        r'^#$',
        # Broken/incomplete URLs (not actual content)
        r'^https?://$',
        r'^http$',
        r'^https$',
        # Single word generic placeholders
        r'^unknown$',
        r'^untitled$',
        r'^no\s*title$',
        r'^no\s*name$',
        # NOTE: We intentionally DO NOT filter:
        # - "liked a post" - engagement frequency signal
        # - "LinkedIn post (LIKE)" - platform engagement
        # - Social interactions - relationship signals
        # These are aggregated by frequency to show engagement levels
    ]

    # Minimum subject length (after stripping)
    MIN_SUBJECT_LENGTH = 2

    # Categories dropped outright as preference noise (not garbage, but
    # low-signal social-graph chaff that crowds out real preferences).
    # "social" is the legacy Facebook reaction-owner category: a person's name
    # captured because you reacted to their post. That is a relationship signal,
    # not a preference, and the people pipeline (contact_syncer) is the right
    # home for it. Reaction-owner names landing as LikePreference rows balloon
    # the count and dilute genuine taste signals, so we drop them here.
    DROP_CATEGORIES = {"social"}

    # Per-source preference cap. A single noisy export (tens of thousands of
    # Facebook reactions, say) must not crowd out high-signal preferences from
    # every other source. When a source exceeds this many UNIQUE preferences,
    # the lowest-priority categories are trimmed first (see CATEGORY_PRIORITY).
    # No row is dropped silently: every trimmed row is logged (see cap_by_source).
    MAX_PREFS_PER_SOURCE = 5000

    # Category priority for the per-source cap. LOWER rank = higher signal =
    # kept first when the cap bites. Deliberate follows and declared interests
    # rank highest; the "saved"/media tail is trimmed first. Categories not
    # listed fall to DEFAULT_CATEGORY_PRIORITY (kept ahead of the explicit
    # low-value tail, behind the explicit high-signal set). Generic across all
    # sources: an unlisted source's categories simply sort by strength.
    CATEGORY_PRIORITY = {
        # High signal: deliberate follows / declared interests
        "page": 10,
        "follows": 10,
        "interest": 10,
        # Engagement with named creators / pages
        "instagram_creator": 20,
        "facebook_content": 20,
        "shared_link": 25,
        "event": 25,
        # Curated rich content (declared taste)
        "movie_tv": 30,
        "movies": 30,
        "book": 30,
        "books": 30,
        "music": 30,
        # Low-value tail: trimmed first when the cap is hit
        "saved": 80,
        "media": 85,
    }
    DEFAULT_CATEGORY_PRIORITY = 50

    def __init__(self, enable_dedup: bool = True, aggregate_frequency: bool = True):
        """
        Initialize the filter.

        Args:
            enable_dedup: Whether to enable deduplication
            aggregate_frequency: Whether to track frequency counts (requires enable_dedup)
        """
        self.enable_dedup = enable_dedup
        self.aggregate_frequency = aggregate_frequency and enable_dedup

        # For simple dedup mode: just track seen keys
        self._seen_keys: Set[str] = set()

        # For aggregation mode: track preference + count
        # Maps dedup_key -> (preference, count)
        self._aggregated: Dict[str, Tuple[ParsedPreference, int]] = {}

        # For cross-source reinforcement: subject-only index
        # Maps normalized_subject -> set of sources that have this subject
        self._subject_sources: Dict[str, Set[str]] = {}

        # For incremental mode optimization: track which keys were modified
        # so we can skip upserting unchanged preferences
        self._modified_keys: Set[str] = set()  # Keys that were updated (new or freq increased)
        self._warmed_keys: Set[str] = set()    # Keys loaded from existing DB data

        self._compiled_patterns = [re.compile(p, re.IGNORECASE) for p in self.LOW_VALUE_PATTERNS]

        # Stats
        self.stats = {
            "total_seen": 0,
            "filtered_low_value": 0,
            "filtered_dropped_category": 0,
            "filtered_duplicates": 0,
            "aggregated_count": 0,
            "passed": 0,
            "warmed_from_db": 0,
            "cross_source_reinforced": 0,
            "capped_by_source": 0
        }

    def _normalize_subject(self, subject: str) -> str:
        """Normalize a subject for comparison."""
        normalized = subject.lower().strip()
        normalized = re.sub(r'\s+', ' ', normalized)
        return normalized

    def _make_dedup_key(self, pref: ParsedPreference) -> str:
        """
        Create a deduplication key for a preference.

        Uses source + signal_type + normalized subject to identify duplicates.
        This allows different signal types (e.g., purchase vs watch) for the
        same item to be kept as separate preferences with different strengths.
        """
        normalized = self._normalize_subject(pref.subject)

        # Include signal_type to distinguish purchases from watches of same item
        signal_type = pref.extra.get('signal_type', 'unknown')

        # Include source in key to allow same subject from different sources
        key_str = f"{pref.source}:{signal_type}:{normalized}"

        # Hash for memory efficiency with large datasets
        return hashlib.md5(key_str.encode()).hexdigest()

    def is_low_value(self, pref: ParsedPreference) -> bool:
        """
        Check if a preference is low-value and should be filtered.

        Args:
            pref: Preference to check

        Returns:
            True if the preference should be filtered out
        """
        subject = pref.subject.strip()

        # Check minimum length
        if len(subject) < self.MIN_SUBJECT_LENGTH:
            return True

        # Check against low-value patterns
        for pattern in self._compiled_patterns:
            if pattern.match(subject):
                return True

        return False

    def is_dropped_category(self, pref: ParsedPreference) -> bool:
        """
        Check if a preference belongs to a category dropped as noise.

        This is a policy drop (distinct from is_low_value, which catches empty
        or broken data). DROP_CATEGORIES currently holds "social" -- the legacy
        Facebook reaction-owner names, which are a people signal rather than a
        preference and balloon the preference count. Called in every ingestion
        path (the streaming path via should_include, the aggregation path
        directly), so reaction-owner rows never reach the graph as preferences.

        Args:
            pref: Preference to check

        Returns:
            True if the preference's category is in DROP_CATEGORIES
        """
        category = (pref.category or "").strip().lower()
        return category in self.DROP_CATEGORIES

    def is_duplicate(self, pref: ParsedPreference) -> bool:
        """
        Check if a preference is a duplicate.

        In aggregation mode, this also tracks the count for later retrieval.
        Tracks cross-source reinforcement when preferences from different
        sources match (e.g., email "Nike" reinforces social "Nike").

        Args:
            pref: Preference to check

        Returns:
            True if this is a duplicate (already seen)
        """
        if not self.enable_dedup:
            return False

        key = self._make_dedup_key(pref)
        normalized_subject = self._normalize_subject(pref.subject)

        if self.aggregate_frequency:
            # Check for cross-source reinforcement FIRST (before marking as dup)
            # This uses subject-only matching across different sources
            if normalized_subject in self._subject_sources:
                existing_sources = self._subject_sources[normalized_subject]
                if pref.source not in existing_sources:
                    # This subject exists from a DIFFERENT source - cross-source match!
                    self.stats["cross_source_reinforced"] += 1
                    other_source = next(iter(existing_sources))
                    logger.debug(
                        f"Cross-source reinforcement: '{pref.subject[:40]}' "
                        f"({pref.source} reinforces {other_source})"
                    )
                    existing_sources.add(pref.source)
            else:
                # First time seeing this subject from any source
                self._subject_sources[normalized_subject] = {pref.source}

            # Now check for same-source duplicates
            if key in self._aggregated:
                # Increment count for existing preference (same source)
                existing_pref, count = self._aggregated[key]
                self._aggregated[key] = (existing_pref, count + 1)
                self.stats["aggregated_count"] += 1
                # Mark as modified since frequency increased
                self._modified_keys.add(key)
                return True
            else:
                # First time seeing this preference from this source
                self._aggregated[key] = (pref, 1)
                # New preference is also considered modified
                self._modified_keys.add(key)
                return False
        else:
            # Simple dedup mode
            if key in self._seen_keys:
                return True
            self._seen_keys.add(key)
            return False

    def get_aggregated_preferences(self, modified_only: bool = False) -> List[ParsedPreference]:
        """
        Get all preferences with frequency data applied.

        Call this after processing all input to get the final aggregated preferences
        with strength adjusted based on frequency, time decay, and cross-source reinforcement.

        Args:
            modified_only: If True, only return preferences that were modified
                          (new or frequency increased). Useful for incremental mode
                          to avoid re-upserting unchanged preferences.

        Returns:
            List of preferences with frequency metadata and adjusted strength
        """
        if not self.aggregate_frequency:
            logger.warning("get_aggregated_preferences called but aggregate_frequency is disabled")
            return []

        from datetime import datetime, timezone

        result = []
        now = datetime.now(timezone.utc)

        for key, (pref, count) in self._aggregated.items():
            # In modified_only mode, skip preferences that weren't changed
            if modified_only and key not in self._modified_keys:
                continue
            # Calculate days since last observation
            days_since_last = 0
            if pref.observed_at:
                try:
                    observed = pref.observed_at
                    if observed.tzinfo is None:
                        observed = observed.replace(tzinfo=timezone.utc)
                    delta = now - observed
                    days_since_last = max(0, delta.days)
                except (ValueError, TypeError):
                    days_since_last = 0

            # Get cross-source count for this subject
            normalized_subject = self._normalize_subject(pref.subject)
            source_count = len(self._subject_sources.get(normalized_subject, {pref.source}))

            # Calculate strength with V2 model
            adjusted_strength = self._calculate_strength(
                frequency=count,
                base_strength=pref.strength,
                days_since_last=days_since_last,
                source_count=source_count
            )

            # Derive preference_type from sign of strength
            if adjusted_strength > 0:
                preference_type = "Like"
            elif adjusted_strength < 0:
                preference_type = "Dislike"
            else:
                preference_type = "Neutral"

            # Create updated preference with frequency data
            updated_pref = replace(
                pref,
                strength=adjusted_strength,
                preference_type=preference_type,
                extra={
                    **pref.extra,
                    "frequency": count,
                    "frequency_boosted": count > 1,
                    "source_count": source_count,
                    "days_since_last": days_since_last,
                    "base_strength": pref.strength  # Preserve original for debugging
                }
            )
            result.append(updated_pref)

        return result

    def get_modified_preferences(self) -> List[ParsedPreference]:
        """
        Get only preferences that were modified (new or frequency increased).

        This is a convenience method equivalent to get_aggregated_preferences(modified_only=True).
        Useful for incremental ingestion to avoid re-upserting unchanged preferences.

        Returns:
            List of modified preferences with frequency metadata and adjusted strength
        """
        return self.get_aggregated_preferences(modified_only=True)

    def _calculate_strength(
        self,
        frequency: int,
        base_strength: float = 0.5,
        days_since_last: int = 0,
        source_count: int = 1
    ) -> float:
        """
        Calculate preference strength using the V2 model.

        Based on Hu-Koren-Volinsky confidence scaling with:
        - Bipolar scale: -1.0 to +1.0 (sign preserved, magnitude scaled)
        - Frequency boost: logarithmic, caps at 3x
        - Time decay: 10-year half-life, floor at 0.4 (preferences are VERY stable!)
        - Cross-source reinforcement: caps at 1.6x
        - Sigmoid ceiling: soft cap approaching ±0.95

        Args:
            frequency: Number of times this preference was observed
            base_strength: Base strength from parser (-1.0 to +1.0)
            days_since_last: Days since most recent observation
            source_count: Number of independent sources confirming this preference

        Returns:
            Adjusted strength between -0.95 and +0.95
        """
        # Preserve sign, work with magnitude
        sign = 1 if base_strength >= 0 else -1
        magnitude = abs(base_strength)

        # Step 1: Frequency multiplier (logarithmic, caps at 3x)
        # log1p(0)=0, log1p(1)≈0.69, log1p(9)≈2.3, log1p(49)≈3.9
        if frequency <= 1:
            freq_mult = 1.0
        else:
            freq_mult = min(1.0 + math.log1p(frequency - 1) * 0.5, 3.0)

        # Step 2: Time decay (configurable half-life, default 10 years)
        # Core preferences are remarkably stable - people who love beer at 20
        # still love beer at 50. Music tastes persist for decades.
        # exp(-0.693 * days / half_life_days) gives ~0.5 at half_life_days
        #
        # Configurable via settings:
        #   STRENGTH_HALF_LIFE_DAYS: default 3650 (10 years)
        #   STRENGTH_DECAY_FLOOR: default 0.4 (never below 40%)
        half_life_days = 3650  # 10 years default - preferences are VERY stable
        decay_floor = 0.4      # Never below 40% - old prefs still matter
        if days_since_last > 0:
            decay = max(math.exp(-0.693 * days_since_last / half_life_days), decay_floor)
        else:
            decay = 1.0  # Recent or no date info

        # Step 3: Cross-source boost (caps at 1.6x)
        # Each additional source adds diminishing confidence
        if source_count > 1:
            source_boost = min(1.0 + math.log1p(source_count - 1) * 0.3, 1.6)
        else:
            source_boost = 1.0

        # Step 4: Combine factors
        raw_magnitude = magnitude * freq_mult * decay * source_boost

        # Step 5: Sigmoid ceiling (maps to 0-0.95 range)
        # raw / (raw + 0.5) creates a natural ceiling that's hard to exceed
        final_magnitude = min(raw_magnitude / (raw_magnitude + 0.5), 0.95)

        return sign * final_magnitude

    def should_include(self, pref: ParsedPreference) -> bool:
        """
        Check if a preference should be included in the final output.

        Args:
            pref: Preference to check

        Returns:
            True if the preference should be included
        """
        self.stats["total_seen"] += 1

        # Check low-value first
        if self.is_low_value(pref):
            self.stats["filtered_low_value"] += 1
            logger.debug(f"Filtered low-value: {pref.subject[:50]}")
            return False

        # Drop policy-noise categories (e.g. Facebook reaction-owner names)
        if self.is_dropped_category(pref):
            self.stats["filtered_dropped_category"] += 1
            logger.debug(
                f"Dropped noise category '{pref.category}': {pref.subject[:50]}"
            )
            return False

        # Check duplicates
        if self.is_duplicate(pref):
            self.stats["filtered_duplicates"] += 1
            logger.debug(f"Filtered duplicate: {pref.subject[:50]}")
            return False

        self.stats["passed"] += 1
        return True

    def filter_batch(self, preferences: List[ParsedPreference]) -> List[ParsedPreference]:
        """
        Filter a batch of preferences.

        Args:
            preferences: List of preferences to filter

        Returns:
            Filtered list of preferences
        """
        return [p for p in preferences if self.should_include(p)]

    def _category_rank(self, pref: ParsedPreference) -> int:
        """Priority rank for a preference's category (lower = higher signal)."""
        category = (pref.category or "").strip().lower()
        return self.CATEGORY_PRIORITY.get(category, self.DEFAULT_CATEGORY_PRIORITY)

    def cap_by_source(
        self, preferences: List[ParsedPreference]
    ) -> Tuple[List[ParsedPreference], List[Dict[str, str]]]:
        """
        Apply the per-source priority cap to a list of (deduped) preferences.

        A single noisy export must not crowd out high-signal preferences from
        every other source, so each source is capped at MAX_PREFS_PER_SOURCE.
        When a source is over the cap, rows are ranked by category priority
        (CATEGORY_PRIORITY, high signal first), then by strength magnitude, then
        by observation frequency. The high-signal head is kept; the low-value
        tail (saved/media first) is trimmed.

        No row is dropped silently. Every trimmed row is recorded in the
        returned log AND emitted to the logger (per-row at DEBUG so a full audit
        trail exists without flooding a default install log; a per-source
        summary at WARNING so the operator always SEES that a cap fired and by
        how much). Sources under the cap pass through untouched.

        Args:
            preferences: Deduplicated/aggregated preferences to cap.

        Returns:
            (kept, capped_log) where kept is the surviving preferences and
            capped_log is a list of {"source", "category", "subject"} dicts,
            one per trimmed row.
        """
        # Group by source, preserving first-seen order for stable output.
        by_source: Dict[str, List[ParsedPreference]] = {}
        for pref in preferences:
            by_source.setdefault(pref.source or "unknown", []).append(pref)

        kept: List[ParsedPreference] = []
        capped_log: List[Dict[str, str]] = []

        for source, prefs in by_source.items():
            if len(prefs) <= self.MAX_PREFS_PER_SOURCE:
                kept.extend(prefs)
                continue

            # Rank: category priority asc, then strength magnitude desc, then
            # frequency desc. The strongest, highest-signal rows survive.
            def _sort_key(p: ParsedPreference):
                frequency = 1
                if isinstance(p.extra, dict):
                    try:
                        frequency = int(p.extra.get("frequency", 1))
                    except (TypeError, ValueError):
                        frequency = 1
                return (
                    self._category_rank(p),
                    -abs(p.strength or 0.0),
                    -frequency,
                )

            ranked = sorted(prefs, key=_sort_key)
            survivors = ranked[: self.MAX_PREFS_PER_SOURCE]
            trimmed = ranked[self.MAX_PREFS_PER_SOURCE :]
            kept.extend(survivors)

            trimmed_by_category: Dict[str, int] = {}
            for p in trimmed:
                category = p.category or "unknown"
                trimmed_by_category[category] = trimmed_by_category.get(category, 0) + 1
                capped_log.append(
                    {
                        "source": source,
                        "category": category,
                        "subject": p.subject,
                    }
                )
                # Per-row audit trail (no silent truncation). DEBUG so a 10k-row
                # trim does not flood the default install log; the WARNING below
                # is what the operator sees.
                logger.debug(
                    "Source cap trim: source=%s category=%s subject=%s",
                    source,
                    category,
                    p.subject[:60],
                )

            self.stats["capped_by_source"] += len(trimmed)
            logger.warning(
                "Per-source cap hit for '%s': kept %d of %d preferences "
                "(MAX_PREFS_PER_SOURCE=%d); trimmed %d lowest-priority rows "
                "by category: %s",
                source,
                len(survivors),
                len(prefs),
                self.MAX_PREFS_PER_SOURCE,
                len(trimmed),
                trimmed_by_category,
            )

        return kept, capped_log

    def reset(self):
        """Reset the filter state (clears seen keys, aggregated data, and stats)."""
        self._seen_keys.clear()
        self._aggregated.clear()
        self._subject_sources.clear()
        self._modified_keys.clear()
        self._warmed_keys.clear()
        self.stats = {
            "total_seen": 0,
            "filtered_low_value": 0,
            "filtered_dropped_category": 0,
            "filtered_duplicates": 0,
            "aggregated_count": 0,
            "passed": 0,
            "warmed_from_db": 0,
            "cross_source_reinforced": 0,
            "capped_by_source": 0
        }

    def warm_from_payloads(self, payloads: List[Dict]) -> int:
        """
        Warm the filter cache from existing database payloads.

        This enables cross-source preference reinforcement by loading
        existing preferences before ingesting new ones. When new preferences
        match existing ones, their strength will be boosted.

        Args:
            payloads: List of preference payloads from Qdrant

        Returns:
            Number of preferences loaded into cache
        """
        if not self.aggregate_frequency:
            logger.warning("warm_from_payloads called but aggregate_frequency is disabled")
            return 0

        count = 0
        for payload in payloads:
            # Extract subject and source to create dedup key
            subject = payload.get("subject", "")
            source = payload.get("source", "")

            if not subject:
                continue

            # Normalize subject for cross-source matching
            normalized = subject.lower().strip()
            normalized = re.sub(r'\s+', ' ', normalized)

            # Build cross-source subject index
            if normalized not in self._subject_sources:
                self._subject_sources[normalized] = set()
            self._subject_sources[normalized].add(source)

            # Create source-specific dedup key
            key_str = f"{source}:{normalized}"
            key = hashlib.md5(key_str.encode()).hexdigest()

            # Get existing frequency from payload
            existing_freq = payload.get("frequency", 1)
            if isinstance(payload.get("extra"), dict):
                existing_freq = payload["extra"].get("frequency", existing_freq)

            # Store in aggregated cache
            # We create a placeholder that will be replaced by actual prefs
            # The key thing is the frequency count is preserved
            if key not in self._aggregated:
                # Get base_strength from extra if available (the original strength
                # before frequency/decay adjustments), otherwise fall back to stored strength
                extra = payload.get("extra", {})
                base_strength = extra.get("base_strength", payload.get("strength", 0.5))

                # Create a minimal ParsedPreference to hold the data
                placeholder = ParsedPreference(
                    subject=subject,
                    preference_type=payload.get("preference_type", "Like"),
                    category=payload.get("category", "unknown"),
                    strength=base_strength,  # Use base_strength, not calculated strength
                    source=source,
                    source_id=payload.get("_id"),
                    observed_at=None,
                    compartment_level=payload.get("compartment_level", 2),
                    extra=extra
                )
                self._aggregated[key] = (placeholder, existing_freq)
                # Track this key as warmed from DB (not modified yet)
                self._warmed_keys.add(key)
                count += 1

        self.stats["warmed_from_db"] = count
        logger.info(f"Warmed filter cache with {count} existing preferences")
        return count

    def is_cross_source_reinforcement(self, pref: ParsedPreference) -> bool:
        """
        Check if this preference reinforces an existing one from a different source.

        Args:
            pref: New preference to check

        Returns:
            True if this reinforces an existing preference from another source
        """
        if not self.aggregate_frequency:
            return False

        key = self._make_dedup_key(pref)
        if key in self._aggregated:
            existing_pref, _ = self._aggregated[key]
            # Different source means cross-source reinforcement
            if existing_pref.source != pref.source:
                return True
        return False

    def get_stats(self) -> dict:
        """Get filtering statistics."""
        unique_count = len(self._aggregated) if self.aggregate_frequency else len(self._seen_keys)

        # Calculate frequency distribution if aggregating
        freq_dist = {}
        if self.aggregate_frequency and self._aggregated:
            for _, (_, count) in self._aggregated.items():
                bucket = "1x" if count == 1 else "2-5x" if count <= 5 else "6-10x" if count <= 10 else "11-20x" if count <= 20 else "20+x"
                freq_dist[bucket] = freq_dist.get(bucket, 0) + 1

        return {
            **self.stats,
            "unique_preferences": unique_count,
            "modified_count": len(self._modified_keys),
            "warmed_count": len(self._warmed_keys),
            "capped_count": self.stats.get("capped_by_source", 0),
            "frequency_distribution": freq_dist if freq_dist else None
        }
