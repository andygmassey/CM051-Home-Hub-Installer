"""Whoop fitness data parser - comprehensive extraction."""

import csv
import io
import logging
import zipfile
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, List, Any
from datetime import datetime
from collections import defaultdict
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)


class WhoopParser(BaseParser):
    """
    Comprehensive parser for Whoop fitness tracker data exports.

    Handles all Whoop data files:
    - workouts.csv: Individual workout activities with strain, HR zones, duration
    - sleeps.csv: Sleep records with stages, efficiency, performance
    - physiological_cycles.csv: Daily recovery, HRV, strain, vitals
    - journal_entries.csv: Daily behavior tracking (caffeine, medications, etc.)
    """

    source_name = "whoop"

    # Activity name mappings for cleaner subjects
    ACTIVITY_NAMES = {
        "Activity": "General Activity",
        "Other": "Other Activity",
    }

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is a Whoop data export."""
        name = file_path.name.lower()

        # Check for ZIP file with Whoop naming convention
        if file_path.suffix.lower() == '.zip':
            if 'whoop' in name:
                return True
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    whoop_files = ['workouts.csv', 'sleeps.csv', 'physiological_cycles.csv']
                    return any(wf in names for wf in whoop_files)
            except:
                return False

        # Handle individual CSV files
        if file_path.suffix.lower() == '.csv':
            whoop_csvs = ['workouts', 'sleeps', 'physiological_cycles', 'journal_entries']
            return any(wc in name for wc in whoop_csvs)

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Whoop data export comprehensively."""
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted - health data

        logger.info(f"Parsing Whoop data from {file_path}")

        if file_path.suffix.lower() == '.zip':
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.csv':
            name = file_path.name.lower()
            async with aiofiles.open(file_path, mode='r', encoding='utf-8') as f:
                content = await f.read()

            if 'workouts' in name:
                async for pref in self._parse_workouts(content, default_compartment):
                    yield pref
            elif 'sleeps' in name:
                async for pref in self._parse_sleeps(content, default_compartment):
                    yield pref
            elif 'physiological_cycles' in name:
                async for pref in self._parse_physiological_cycles(content, default_compartment):
                    yield pref
            elif 'journal_entries' in name:
                async for pref in self._parse_journal_entries(content, default_compartment):
                    yield pref

    async def _parse_zip(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse Whoop ZIP archive - all files."""
        with zipfile.ZipFile(file_path, 'r') as zf:
            for name in zf.namelist():
                name_lower = name.lower()
                if not name_lower.endswith('.csv'):
                    continue

                content = zf.read(name).decode('utf-8')

                if 'workouts' in name_lower:
                    async for pref in self._parse_workouts(content, default_compartment):
                        yield pref
                elif 'sleeps' in name_lower:
                    async for pref in self._parse_sleeps(content, default_compartment):
                        yield pref
                elif 'physiological_cycles' in name_lower:
                    async for pref in self._parse_physiological_cycles(content, default_compartment):
                        yield pref
                elif 'journal_entries' in name_lower:
                    async for pref in self._parse_journal_entries(content, default_compartment):
                        yield pref

    # =========================================================================
    # WORKOUTS PARSING
    # =========================================================================

    async def _parse_workouts(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Whoop workouts comprehensively.

        Yields:
        - Individual workout records (each workout as a preference)
        - Aggregated activity preferences (for frequently done activities)
        """
        reader = csv.DictReader(io.StringIO(content))
        workouts = []
        activity_stats = defaultdict(lambda: {
            'count': 0,
            'total_duration': 0,
            'total_strain': 0,
            'total_calories': 0,
            'max_hr_list': [],
            'avg_hr_list': [],
        })

        for row in reader:
            try:
                activity_name = row.get('Activity name', '').strip()
                if not activity_name or activity_name == 'Activity name':
                    continue

                # Parse workout data
                workout_start = row.get('Workout start time', '').strip()
                duration = self._parse_float(row.get('Duration (min)', '0'))
                strain = self._parse_float(row.get('Activity Strain', '0'))
                calories = self._parse_float(row.get('Energy burned (cal)', '0'))
                max_hr = self._parse_float(row.get('Max HR (bpm)', '0'))
                avg_hr = self._parse_float(row.get('Average HR (bpm)', '0'))

                # HR Zone percentages
                hr_zones = {
                    'zone1': self._parse_float(row.get('HR Zone 1 %', '0')),
                    'zone2': self._parse_float(row.get('HR Zone 2 %', '0')),
                    'zone3': self._parse_float(row.get('HR Zone 3 %', '0')),
                    'zone4': self._parse_float(row.get('HR Zone 4 %', '0')),
                    'zone5': self._parse_float(row.get('HR Zone 5 %', '0')),
                }

                # Parse timestamp
                timestamp = self._parse_timestamp(workout_start)

                # Clean activity name
                display_name = self.ACTIVITY_NAMES.get(activity_name, activity_name)

                # Store for individual and aggregate processing
                workout = {
                    'activity': display_name,
                    'raw_activity': activity_name,
                    'timestamp': timestamp,
                    'duration': duration,
                    'strain': strain,
                    'calories': calories,
                    'max_hr': max_hr,
                    'avg_hr': avg_hr,
                    'hr_zones': hr_zones,
                }
                workouts.append(workout)

                # Aggregate stats
                activity_stats[display_name]['count'] += 1
                activity_stats[display_name]['total_duration'] += duration
                activity_stats[display_name]['total_strain'] += strain
                activity_stats[display_name]['total_calories'] += calories
                if max_hr > 0:
                    activity_stats[display_name]['max_hr_list'].append(max_hr)
                if avg_hr > 0:
                    activity_stats[display_name]['avg_hr_list'].append(avg_hr)

            except Exception as e:
                logger.warning(f"Error parsing workout row: {e}")
                continue

        logger.info(f"Parsed {len(workouts)} Whoop workouts")

        # Yield individual workout preferences
        for workout in workouts:
            # Determine workout intensity from strain
            if workout['strain'] >= 15:
                intensity = "high-intensity"
                strength = 0.85
            elif workout['strain'] >= 10:
                intensity = "moderate"
                strength = 0.75
            elif workout['strain'] >= 5:
                intensity = "light"
                strength = 0.65
            else:
                intensity = "very light"
                strength = 0.55

            # Create descriptive subject
            subject = f"{workout['activity']} workout"
            if workout['duration'] >= 60:
                subject += f" ({int(workout['duration'])} min, {intensity})"
            elif workout['duration'] >= 30:
                subject += f" ({int(workout['duration'])} min)"

            yield ParsedPreference(
                subject=subject,
                preference_type="Like",
                category="fitness",
                strength=strength,
                observed_at=workout['timestamp'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "workout",
                    "activity": workout['activity'],
                    "duration_min": round(workout['duration'], 1),
                    "strain": round(workout['strain'], 1),
                    "calories": round(workout['calories'], 0),
                    "max_hr": round(workout['max_hr'], 0) if workout['max_hr'] else None,
                    "avg_hr": round(workout['avg_hr'], 0) if workout['avg_hr'] else None,
                    "hr_zones": workout['hr_zones'],
                }
            )

        # Yield aggregated activity preferences (for activities done 3+ times)
        for activity, stats in activity_stats.items():
            if stats['count'] < 3:
                continue

            count = stats['count']
            avg_duration = stats['total_duration'] / count
            avg_strain = stats['total_strain'] / count
            avg_max_hr = sum(stats['max_hr_list']) / len(stats['max_hr_list']) if stats['max_hr_list'] else 0

            # Higher frequency = stronger preference
            strength = min(0.6 + (count * 0.01) + (avg_strain * 0.01), 0.95)

            yield ParsedPreference(
                subject=f"{activity} (regular activity)",
                preference_type="Like",
                category="fitness",
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "activity_preference",
                    "activity": activity,
                    "workout_count": count,
                    "avg_duration_min": round(avg_duration, 1),
                    "avg_strain": round(avg_strain, 1),
                    "total_calories": round(stats['total_calories'], 0),
                    "avg_max_hr": round(avg_max_hr, 0) if avg_max_hr else None,
                }
            )

    # =========================================================================
    # SLEEP PARSING
    # =========================================================================

    async def _parse_sleeps(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Whoop sleep data comprehensively.

        Yields:
        - Individual sleep records (each night as a preference)
        - Sleep pattern preferences (aggregate insights)
        """
        reader = csv.DictReader(io.StringIO(content))
        sleep_records = []
        nap_count = 0

        # Aggregate metrics
        total_performance = 0
        total_efficiency = 0
        total_duration = 0
        total_deep = 0
        total_rem = 0
        valid_records = 0
        sleep_times = []
        wake_times = []

        for row in reader:
            try:
                is_nap = row.get('Nap', '').lower() == 'true'

                # Parse common fields
                sleep_onset = row.get('Sleep onset', '').strip()
                wake_onset = row.get('Wake onset', '').strip()
                performance = self._parse_float(row.get('Sleep performance %', ''))
                efficiency = self._parse_float(row.get('Sleep efficiency %', ''))
                asleep_duration = self._parse_float(row.get('Asleep duration (min)', '0'))
                in_bed_duration = self._parse_float(row.get('In bed duration (min)', '0'))
                light_duration = self._parse_float(row.get('Light sleep duration (min)', '0'))
                deep_duration = self._parse_float(row.get('Deep (SWS) duration (min)', '0'))
                rem_duration = self._parse_float(row.get('REM duration (min)', '0'))
                awake_duration = self._parse_float(row.get('Awake duration (min)', '0'))
                sleep_need = self._parse_float(row.get('Sleep need (min)', '0'))
                sleep_debt = self._parse_float(row.get('Sleep debt (min)', '0'))
                consistency = self._parse_float(row.get('Sleep consistency %', ''))
                respiratory_rate = self._parse_float(row.get('Respiratory rate (rpm)', ''))

                sleep_timestamp = self._parse_timestamp(sleep_onset)
                wake_timestamp = self._parse_timestamp(wake_onset)

                if is_nap:
                    nap_count += 1
                    # Still record naps as preferences
                    if asleep_duration >= 10:  # At least 10 min nap
                        yield ParsedPreference(
                            subject=f"Nap ({int(asleep_duration)} min)",
                            preference_type="Like",
                            category="wellness",
                            strength=0.20,  # V2: Activity
                            observed_at=sleep_timestamp,
                            source=self.source_name,
                            compartment_level=default_compartment,
                            size="Micro",
                            extra={
                                "type": "nap",
                                "duration_min": round(asleep_duration, 0),
                                "efficiency": round(efficiency, 1) if efficiency else None,
                            }
                        )
                    continue

                # Main sleep record
                record = {
                    'sleep_time': sleep_timestamp,
                    'wake_time': wake_timestamp,
                    'performance': performance,
                    'efficiency': efficiency,
                    'duration_min': asleep_duration,
                    'in_bed_min': in_bed_duration,
                    'light_min': light_duration,
                    'deep_min': deep_duration,
                    'rem_min': rem_duration,
                    'awake_min': awake_duration,
                    'sleep_need': sleep_need,
                    'sleep_debt': sleep_debt,
                    'consistency': consistency,
                    'respiratory_rate': respiratory_rate,
                }
                sleep_records.append(record)

                # Aggregate for patterns
                if performance and performance > 0:
                    total_performance += performance
                    valid_records += 1
                if efficiency and efficiency > 0:
                    total_efficiency += efficiency
                total_duration += asleep_duration
                total_deep += deep_duration
                total_rem += rem_duration

                # Track sleep/wake times for pattern analysis
                if sleep_timestamp:
                    sleep_times.append(sleep_timestamp.hour + sleep_timestamp.minute / 60)
                if wake_timestamp:
                    wake_times.append(wake_timestamp.hour + wake_timestamp.minute / 60)

            except Exception as e:
                logger.warning(f"Error parsing sleep row: {e}")
                continue

        logger.info(f"Parsed {len(sleep_records)} Whoop sleep records, {nap_count} naps")

        # Yield individual sleep records
        for record in sleep_records:
            duration_hours = record['duration_min'] / 60 if record['duration_min'] else 0

            # Determine sleep quality descriptor
            if record['performance'] and record['performance'] >= 85:
                quality = "excellent"
                strength = 0.85
            elif record['performance'] and record['performance'] >= 70:
                quality = "good"
                strength = 0.75
            elif record['performance'] and record['performance'] >= 50:
                quality = "fair"
                strength = 0.6
            else:
                quality = "poor"
                strength = 0.5

            subject = f"Sleep ({duration_hours:.1f}h, {quality})"

            yield ParsedPreference(
                subject=subject,
                preference_type="Like" if record['performance'] and record['performance'] >= 50 else "Neutral",
                category="wellness",
                strength=strength,
                observed_at=record['sleep_time'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Small",
                extra={
                    "type": "sleep",
                    "duration_hours": round(duration_hours, 1),
                    "performance": round(record['performance'], 1) if record['performance'] else None,
                    "efficiency": round(record['efficiency'], 1) if record['efficiency'] else None,
                    "deep_min": round(record['deep_min'], 0),
                    "rem_min": round(record['rem_min'], 0),
                    "light_min": round(record['light_min'], 0),
                    "awake_min": round(record['awake_min'], 0),
                    "consistency": round(record['consistency'], 1) if record['consistency'] else None,
                    "sleep_debt_min": round(record['sleep_debt'], 0) if record['sleep_debt'] else None,
                }
            )

        # Yield aggregate sleep pattern preferences
        if valid_records > 0:
            avg_performance = total_performance / valid_records
            avg_duration_hours = (total_duration / len(sleep_records)) / 60 if sleep_records else 0
            avg_deep_pct = (total_deep / total_duration * 100) if total_duration > 0 else 0
            avg_rem_pct = (total_rem / total_duration * 100) if total_duration > 0 else 0

            # Sleep tracking preference
            yield ParsedPreference(
                subject="Sleep tracking and optimization",
                preference_type="Like",
                category="wellness",
                strength=0.35,  # V2: Pattern
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "sleep_tracking_habit",
                    "total_nights_tracked": len(sleep_records),
                    "avg_performance": round(avg_performance, 1),
                    "avg_duration_hours": round(avg_duration_hours, 1),
                    "avg_deep_sleep_pct": round(avg_deep_pct, 1),
                    "avg_rem_sleep_pct": round(avg_rem_pct, 1),
                }
            )

            # Sleep schedule pattern
            if sleep_times and wake_times:
                avg_sleep_hour = sum(sleep_times) / len(sleep_times)
                avg_wake_hour = sum(wake_times) / len(wake_times)

                # Handle late night (past midnight) sleep times
                if avg_sleep_hour < 6:  # Probably past midnight
                    avg_sleep_hour += 24

                if avg_wake_hour < 12:
                    schedule = "early riser" if avg_wake_hour < 7 else "morning person"
                else:
                    schedule = "late riser"

                if avg_sleep_hour > 24:  # Past midnight
                    bedtime = "night owl"
                elif avg_sleep_hour > 23:
                    bedtime = "late sleeper"
                else:
                    bedtime = "early sleeper"

                yield ParsedPreference(
                    subject=f"Sleep schedule: {bedtime}, {schedule}",
                    preference_type="Like",
                    category="wellness",
                    strength=0.28,  # V2
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Medium",
                    extra={
                        "type": "sleep_schedule",
                        "avg_bedtime_hour": round(avg_sleep_hour % 24, 1),
                        "avg_wake_hour": round(avg_wake_hour, 1),
                    }
                )

            # Napping habit
            if nap_count >= 10:
                yield ParsedPreference(
                    subject="Regular napping habit",
                    preference_type="Like",
                    category="wellness",
                    strength=0.22,  # V2
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "nap_habit",
                        "nap_count": nap_count,
                    }
                )

    # =========================================================================
    # PHYSIOLOGICAL CYCLES PARSING
    # =========================================================================

    async def _parse_physiological_cycles(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Whoop physiological cycles (daily recovery/strain data).

        Yields:
        - Individual daily recovery records
        - Recovery pattern preferences
        - HRV and vitals trends
        """
        reader = csv.DictReader(io.StringIO(content))
        cycles = []

        # Aggregate metrics
        recovery_scores = []
        hrv_values = []
        rhr_values = []
        strain_values = []

        for row in reader:
            try:
                cycle_start = row.get('Cycle start time', '').strip()
                recovery = self._parse_float(row.get('Recovery score %', ''))
                rhr = self._parse_float(row.get('Resting heart rate (bpm)', ''))
                hrv = self._parse_float(row.get('Heart rate variability (ms)', ''))
                skin_temp = self._parse_float(row.get('Skin temp (celsius)', ''))
                blood_oxygen = self._parse_float(row.get('Blood oxygen %', ''))
                day_strain = self._parse_float(row.get('Day Strain', ''))
                calories = self._parse_float(row.get('Energy burned (cal)', ''))

                timestamp = self._parse_timestamp(cycle_start)

                cycle = {
                    'timestamp': timestamp,
                    'recovery': recovery,
                    'rhr': rhr,
                    'hrv': hrv,
                    'skin_temp': skin_temp,
                    'blood_oxygen': blood_oxygen,
                    'day_strain': day_strain,
                    'calories': calories,
                }
                cycles.append(cycle)

                # Aggregate for patterns
                if recovery and recovery > 0:
                    recovery_scores.append(recovery)
                if hrv and hrv > 0:
                    hrv_values.append(hrv)
                if rhr and rhr > 0:
                    rhr_values.append(rhr)
                if day_strain and day_strain > 0:
                    strain_values.append(day_strain)

            except Exception as e:
                logger.warning(f"Error parsing physiological cycle row: {e}")
                continue

        logger.info(f"Parsed {len(cycles)} Whoop physiological cycles")

        # Yield individual daily recovery records
        for cycle in cycles:
            if not cycle['recovery'] or cycle['recovery'] <= 0:
                continue

            # Recovery level descriptor
            if cycle['recovery'] >= 67:
                level = "green (optimal)"
                strength = 0.8
            elif cycle['recovery'] >= 34:
                level = "yellow (adequate)"
                strength = 0.65
            else:
                level = "red (low)"
                strength = 0.5

            subject = f"Daily recovery: {int(cycle['recovery'])}% ({level.split()[0]})"

            yield ParsedPreference(
                subject=subject,
                preference_type="Like" if cycle['recovery'] >= 50 else "Neutral",
                category="wellness",
                strength=strength,
                observed_at=cycle['timestamp'],
                source=self.source_name,
                compartment_level=default_compartment,
                size="Micro",
                extra={
                    "type": "daily_recovery",
                    "recovery_pct": round(cycle['recovery'], 1),
                    "hrv_ms": round(cycle['hrv'], 0) if cycle['hrv'] else None,
                    "rhr_bpm": round(cycle['rhr'], 0) if cycle['rhr'] else None,
                    "day_strain": round(cycle['day_strain'], 1) if cycle['day_strain'] else None,
                    "calories": round(cycle['calories'], 0) if cycle['calories'] else None,
                    "blood_oxygen_pct": round(cycle['blood_oxygen'], 1) if cycle['blood_oxygen'] else None,
                }
            )

        # Yield aggregate physiological patterns
        if recovery_scores:
            avg_recovery = sum(recovery_scores) / len(recovery_scores)
            green_days = sum(1 for r in recovery_scores if r >= 67)
            yellow_days = sum(1 for r in recovery_scores if 34 <= r < 67)
            red_days = sum(1 for r in recovery_scores if r < 34)

            yield ParsedPreference(
                subject=f"Recovery tracking ({len(recovery_scores)} days)",
                preference_type="Like",
                category="wellness",
                strength=0.32,  # V2: Strong pattern
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "recovery_pattern",
                    "total_days": len(recovery_scores),
                    "avg_recovery": round(avg_recovery, 1),
                    "green_days": green_days,
                    "yellow_days": yellow_days,
                    "red_days": red_days,
                    "green_pct": round(green_days / len(recovery_scores) * 100, 1),
                }
            )

        if hrv_values:
            avg_hrv = sum(hrv_values) / len(hrv_values)
            # HRV is generally better when higher
            if avg_hrv >= 50:
                hrv_level = "high (excellent)"
                strength = 0.85
            elif avg_hrv >= 30:
                hrv_level = "moderate"
                strength = 0.7
            else:
                hrv_level = "low"
                strength = 0.55

            yield ParsedPreference(
                subject=f"Heart rate variability: {hrv_level}",
                preference_type="Like",
                category="wellness",
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "hrv_pattern",
                    "avg_hrv_ms": round(avg_hrv, 0),
                    "min_hrv": round(min(hrv_values), 0),
                    "max_hrv": round(max(hrv_values), 0),
                }
            )

        if rhr_values:
            avg_rhr = sum(rhr_values) / len(rhr_values)
            # Lower RHR generally indicates better fitness
            if avg_rhr < 55:
                rhr_level = "athletic"
                strength = 0.85
            elif avg_rhr < 65:
                rhr_level = "good"
                strength = 0.75
            elif avg_rhr < 75:
                rhr_level = "average"
                strength = 0.65
            else:
                rhr_level = "elevated"
                strength = 0.55

            yield ParsedPreference(
                subject=f"Resting heart rate: {rhr_level} ({int(avg_rhr)} bpm)",
                preference_type="Like",
                category="wellness",
                strength=strength,
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "rhr_pattern",
                    "avg_rhr_bpm": round(avg_rhr, 0),
                    "min_rhr": round(min(rhr_values), 0),
                    "max_rhr": round(max(rhr_values), 0),
                }
            )

        if strain_values:
            avg_strain = sum(strain_values) / len(strain_values)
            high_strain_days = sum(1 for s in strain_values if s >= 14)

            yield ParsedPreference(
                subject=f"Daily strain tracking",
                preference_type="Like",
                category="fitness",
                strength=0.30,  # V2
                source=self.source_name,
                compartment_level=default_compartment,
                size="Medium",
                extra={
                    "type": "strain_pattern",
                    "avg_daily_strain": round(avg_strain, 1),
                    "high_strain_days": high_strain_days,
                    "max_strain": round(max(strain_values), 1),
                }
            )

    # =========================================================================
    # JOURNAL ENTRIES PARSING
    # =========================================================================

    async def _parse_journal_entries(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse Whoop journal entries (daily behavior tracking).

        Yields:
        - Behavioral preferences based on tracked habits
        - Individual notable entries (medications, vaccinations, etc.)
        """
        reader = csv.DictReader(io.StringIO(content))

        # Track question responses
        question_stats: Dict[str, Dict[str, Any]] = defaultdict(lambda: {
            'yes_count': 0,
            'no_count': 0,
            'dates': [],
        })

        for row in reader:
            try:
                question = row.get('Question text', '').strip()
                answered_yes = row.get('Answered yes', '').lower() == 'true'
                cycle_start = row.get('Cycle start time', '').strip()
                notes = row.get('Notes', '').strip()

                if not question or question == 'Question text':
                    continue

                timestamp = self._parse_timestamp(cycle_start)

                if answered_yes:
                    question_stats[question]['yes_count'] += 1
                    question_stats[question]['dates'].append(timestamp)
                else:
                    question_stats[question]['no_count'] += 1

            except Exception as e:
                logger.warning(f"Error parsing journal entry row: {e}")
                continue

        logger.info(f"Parsed journal entries for {len(question_stats)} tracked behaviors")

        # Generate preferences for each tracked behavior
        for question, stats in question_stats.items():
            yes_count = stats['yes_count']
            total = yes_count + stats['no_count']

            if total == 0:
                continue

            yes_rate = yes_count / total

            # Map questions to preference subjects
            behavior_map = {
                'Consumed caffeine?': ('Caffeine consumption', 'nutrition'),
                'Consumed meat?': ('Meat consumption', 'nutrition'),
                'Consumed dairy?': ('Dairy consumption', 'nutrition'),
                'Worked late?': ('Working late', 'work'),
                'Took vitamin D?': ('Vitamin D supplementation', 'wellness'),
                'Took fish oil?': ('Fish oil supplementation', 'wellness'),
                'Took a magnesium supplement?': ('Magnesium supplementation', 'wellness'),
                'Took AD(H)D medication?': ('ADHD medication', 'health'),
                'Took anti-anxiety medication?': ('Anti-anxiety medication', 'health'),
                'Received massage therapy?': ('Massage therapy', 'wellness'),
                'Felt recovered?': ('Feeling recovered', 'wellness'),
            }

            # Get mapped subject or clean the question
            if question in behavior_map:
                subject, category = behavior_map[question]
            else:
                # Clean up question to make it a subject
                subject = question.replace('?', '').strip()
                if subject.startswith('Consumed '):
                    subject = subject.replace('Consumed ', '') + ' consumption'
                    category = 'nutrition'
                elif subject.startswith('Took '):
                    subject = subject.replace('Took ', '')
                    category = 'wellness'
                elif 'vaccination' in subject.lower() or 'vaccine' in subject.lower():
                    category = 'health'
                else:
                    category = 'lifestyle'

            # Determine preference strength based on frequency
            if yes_rate >= 0.8:
                frequency = "regular"
                strength = 0.85
                pref_type = "Like"
            elif yes_rate >= 0.5:
                frequency = "frequent"
                strength = 0.7
                pref_type = "Like"
            elif yes_rate >= 0.2:
                frequency = "occasional"
                strength = 0.55
                pref_type = "Neutral"
            else:
                frequency = "rare"
                strength = 0.4
                pref_type = "Neutral"

            # Only create preference if there's meaningful data
            if yes_count >= 2 or (yes_count >= 1 and 'vaccination' in question.lower()):
                yield ParsedPreference(
                    subject=f"{subject} ({frequency})" if yes_count >= 3 else subject,
                    preference_type=pref_type,
                    category=category,
                    strength=strength,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra={
                        "type": "tracked_behavior",
                        "question": question,
                        "yes_count": yes_count,
                        "total_tracked": total,
                        "frequency_pct": round(yes_rate * 100, 1),
                    }
                )

    # =========================================================================
    # UTILITY METHODS
    # =========================================================================

    def _parse_float(self, value: str) -> Optional[float]:
        """Safely parse float from string."""
        if not value or value.strip() == '':
            return None
        try:
            return float(value)
        except (ValueError, TypeError):
            return None

    def _parse_timestamp(self, value: str) -> Optional[datetime]:
        """Parse Whoop timestamp formats."""
        if not value or value.strip() == '':
            return None

        formats = [
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M:%SZ",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%d",
        ]

        for fmt in formats:
            try:
                return datetime.strptime(value.strip(), fmt)
            except ValueError:
                continue

        return None
