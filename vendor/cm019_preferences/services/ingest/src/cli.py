"""Ingestion service CLI for batch processing.

Usage:
    # Ingest email preferences from CM021 (dry run)
    python -m services.ingest.src.cli ingest-email /path/to/preferences.jsonl -u andy --dry-run

    # Ingest email preferences for real
    python -m services.ingest.src.cli ingest-email /path/to/preferences.jsonl -u andy

    # Ingest a directory of files
    python -m services.ingest.src.cli ingest-dir /path/to/archives -u andy

    # Show statistics about an email preferences file
    python -m services.ingest.src.cli stats /path/to/preferences.jsonl
"""

import asyncio
import json
import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

import click

from .pipeline import IngestPipeline
from .parsers.email import EmailParser, get_file_stats, validate_file

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)]
)
logger = logging.getLogger(__name__)


@click.group()
@click.version_option(version="0.1.0", prog_name="PWG Ingest CLI")
def cli():
    """PWG Ingestion Service CLI.

    Batch ingestion of preferences from various sources including
    email preferences from CM021 Email Intelligence.
    """
    pass


@cli.command('ingest-email')
@click.argument('file_path', type=click.Path(exists=True))
@click.option('--user-id', '-u', required=True, help='User ID for these preferences')
@click.option('--dry-run', is_flag=True, help='Validate and show stats without storing')
@click.option('--batch-size', default=100, help='Commit batch size (default 100)')
@click.option('--verbose', '-v', is_flag=True, help='Show detailed progress')
@click.option('--min-strength', default=0.0, type=float, help='Minimum strength threshold (0-1)')
@click.option('--compartment', default=2, type=int, help='Default compartment level (0-6)')
@click.option('--reinforce', '-r', is_flag=True, help='Enable cross-source reinforcement (strengthen existing preferences)')
def ingest_email(
    file_path: str,
    user_id: str,
    dry_run: bool,
    batch_size: int,
    verbose: bool,
    min_strength: float,
    compartment: int,
    reinforce: bool
):
    """
    Ingest email preferences from CM021 Email Intelligence.

    FILE_PATH should be a JSONL file with one preference per line,
    produced by CM021's PWG formatter.

    Examples:
        # Dry run - validate and show stats
        python -m services.ingest.src.cli ingest-email ./preferences.jsonl -u andy --dry-run

        # Real ingestion
        python -m services.ingest.src.cli ingest-email ./preferences.jsonl -u andy

        # With cross-source reinforcement (email Nike strengthens social Nike)
        python -m services.ingest.src.cli ingest-email ./preferences.jsonl -u andy --reinforce

        # With options
        python -m services.ingest.src.cli ingest-email ./preferences.jsonl -u andy --min-strength 0.3 -v
    """
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    click.echo(f"\n{'='*60}", err=True)
    click.echo(f"CM021 Email Preference Ingestion", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"File: {file_path}", err=True)
    click.echo(f"User: {user_id}", err=True)
    click.echo(f"Mode: {'DRY RUN' if dry_run else 'LIVE'}", err=True)
    click.echo(f"Min Strength: {min_strength}", err=True)
    click.echo(f"Compartment: {compartment}", err=True)
    click.echo(f"Cross-Source Reinforce: {reinforce}", err=True)
    click.echo(f"{'='*60}\n", err=True)

    # Get file statistics
    click.echo("Analyzing file...", err=True)
    try:
        stats = get_file_stats(file_path)
    except Exception as e:
        click.echo(f"Error reading file: {e}", err=True)
        raise SystemExit(1)

    click.echo(f"\nFile Statistics:", err=True)
    click.echo(f"  Total lines: {stats['total']:,}", err=True)
    click.echo(f"  Valid records: {stats['valid']:,}", err=True)
    click.echo(f"  Parse errors: {stats['errors']:,}", err=True)

    click.echo(f"\nBy Category:", err=True)
    for cat, count in sorted(stats['by_category'].items(), key=lambda x: -x[1]):
        click.echo(f"  {cat}: {count:,}", err=True)

    click.echo(f"\nBy Source:", err=True)
    for src, count in sorted(stats['by_source'].items(), key=lambda x: -x[1]):
        click.echo(f"  {src}: {count:,}", err=True)

    click.echo(f"\nBy Preference Type:", err=True)
    for ptype, count in sorted(stats['by_preference_type'].items(), key=lambda x: -x[1]):
        click.echo(f"  {ptype}: {count:,}", err=True)

    click.echo(f"\nDate Range:", err=True)
    click.echo(f"  Earliest: {stats['date_range']['earliest']}", err=True)
    click.echo(f"  Latest: {stats['date_range']['latest']}", err=True)

    if dry_run:
        # Validate a sample
        click.echo(f"\n{'='*60}", err=True)
        click.echo("Validation (first 100 records):", err=True)
        click.echo(f"{'='*60}", err=True)

        report = validate_file(file_path, sample_size=100)
        click.echo(f"  Valid: {report['valid_count']}", err=True)
        click.echo(f"  Errors: {report['error_count']}", err=True)

        if report['issues']:
            click.echo(f"\nIssues found:", err=True)
            for issue in report['issues'][:10]:
                click.echo(f"  - {issue}", err=True)
            if len(report['issues']) > 10:
                click.echo(f"  ... and {len(report['issues']) - 10} more issues", err=True)

        if report['sample_records']:
            click.echo(f"\nSample record:", err=True)
            click.echo(json.dumps(report['sample_records'][0], indent=2, default=str), err=True)

        click.echo(f"\n[DRY RUN COMPLETE] No data was stored.", err=True)
        return

    # Live ingestion
    click.echo(f"\n{'='*60}", err=True)
    click.echo("Starting ingestion...", err=True)
    click.echo(f"{'='*60}", err=True)

    asyncio.run(_run_ingestion(
        file_path=file_path,
        user_id=user_id,
        batch_size=batch_size,
        verbose=verbose,
        min_strength=min_strength,
        compartment=compartment,
        reinforce=reinforce,
    ))


async def _run_ingestion(
    file_path: str,
    user_id: str,
    batch_size: int,
    verbose: bool,
    min_strength: float,
    compartment: int,
    reinforce: bool = False,
):
    """Execute actual ingestion."""
    pipeline = IngestPipeline()

    try:
        # Initialize pipeline (connects to Oxigraph and Qdrant)
        if not await pipeline.initialize():
            click.echo("Failed to initialize pipeline. Check that Oxigraph and Qdrant are running.", err=True)
            raise SystemExit(1)

        # Use aggregation mode when reinforcement is enabled
        # This ensures proper frequency tracking and cross-source reinforcement
        if reinforce:
            result = await pipeline.ingest_file_with_aggregation(
                file_path=Path(file_path),
                user_id=user_id,
                compartment_level=compartment,
                incremental=True,  # Warm from DB and merge
            )
        else:
            result = await pipeline.ingest_file(
                file_path=Path(file_path),
                user_id=user_id,
                compartment_level=compartment,
                batch_size=batch_size,
            )

        click.echo(f"\n{'='*60}", err=True)
        click.echo("INGESTION COMPLETE", err=True)
        click.echo(f"{'='*60}", err=True)
        click.echo(f"  Preferences created: {result['preferences_created']:,}", err=True)
        click.echo(f"  Preferences filtered: {result['preferences_filtered']:,}", err=True)
        click.echo(f"  Date-excluded: {result['preferences_date_excluded']:,}", err=True)
        click.echo(f"  RDF triples inserted: {result['triples_inserted']:,}", err=True)
        click.echo(f"  Vectors inserted: {result['vectors_inserted']:,}", err=True)
        click.echo(f"  Duration: {result['duration_seconds']:.2f}s", err=True)

        # Show reinforcement stats if enabled
        if reinforce:
            click.echo(f"\nIncremental/Cross-Source Stats:", err=True)
            click.echo(f"  Existing preferences loaded: {result.get('warmed_from_db', 0):,}", err=True)
            filter_stats = pipeline.filter.get_stats()
            click.echo(f"  Cross-source matches: {filter_stats.get('cross_source_reinforced', 0):,}", err=True)
            if result.get('frequency_stats'):
                click.echo(f"  Frequency distribution: {result['frequency_stats']}", err=True)

        if result['errors']:
            click.echo(f"\nErrors ({len(result['errors'])}):", err=True)
            for error in result['errors'][:10]:
                click.echo(f"  - {error}", err=True)
            if len(result['errors']) > 10:
                click.echo(f"  ... and {len(result['errors']) - 10} more errors", err=True)

        click.echo(f"\nNext step: Run enrichment", err=True)
        click.echo(f"  python -m services.enrich.src.cli enrich --user-id {user_id}", err=True)

    except Exception as e:
        click.echo(f"Ingestion failed: {e}", err=True)
        raise SystemExit(1)


@cli.command('ingest-dir')
@click.argument('dir_path', type=click.Path(exists=True))
@click.option('--user-id', '-u', required=True, help='User ID for these preferences')
@click.option('--recursive/--no-recursive', default=True, help='Process subdirectories')
@click.option('--aggregate-frequency/--no-aggregate-frequency', default=True,
              help='Aggregate frequency across files')
@click.option('--compartment', default=2, type=int, help='Default compartment level (0-6)')
@click.option('--verbose', '-v', is_flag=True, help='Show detailed progress')
@click.option('--incremental', is_flag=True, help='Merge with existing preferences instead of replacing (top-up mode)')
def ingest_dir(
    dir_path: str,
    user_id: str,
    recursive: bool,
    aggregate_frequency: bool,
    compartment: int,
    verbose: bool,
    incremental: bool
):
    """
    Ingest all supported files in a directory.

    Automatically detects file types and uses appropriate parsers.

    Use --incremental for "top-up" ingestion that merges new data with
    existing preferences (frequencies combined, cross-source reinforcement).

    Examples:
        python -m services.ingest.src.cli ingest-dir /path/to/archives -u andy
        python -m services.ingest.src.cli ingest-dir /path/to/archives -u andy --no-recursive

        # Incremental mode - merge with existing preferences
        python -m services.ingest.src.cli ingest-dir /path/to/new_data -u andy --incremental
    """
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    click.echo(f"\n{'='*60}", err=True)
    click.echo(f"Directory Ingestion", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"Directory: {dir_path}", err=True)
    click.echo(f"User: {user_id}", err=True)
    click.echo(f"Recursive: {recursive}", err=True)
    click.echo(f"Aggregate Frequency: {aggregate_frequency}", err=True)
    click.echo(f"Incremental Mode: {incremental}", err=True)
    click.echo(f"{'='*60}\n", err=True)

    asyncio.run(_run_dir_ingestion(
        dir_path=dir_path,
        user_id=user_id,
        recursive=recursive,
        aggregate_frequency=aggregate_frequency,
        compartment=compartment,
        incremental=incremental,
    ))


async def _run_dir_ingestion(
    dir_path: str,
    user_id: str,
    recursive: bool,
    aggregate_frequency: bool,
    compartment: int,
    incremental: bool = False,
):
    """Execute directory ingestion."""
    pipeline = IngestPipeline()

    try:
        if not await pipeline.initialize():
            click.echo("Failed to initialize pipeline. Check that Oxigraph and Qdrant are running.", err=True)
            raise SystemExit(1)

        result = await pipeline.ingest_directory(
            dir_path=Path(dir_path),
            user_id=user_id,
            compartment_level=compartment,
            recursive=recursive,
            aggregate_frequency=aggregate_frequency,
            incremental=incremental,
        )

        click.echo(f"\n{'='*60}", err=True)
        click.echo("DIRECTORY INGESTION COMPLETE", err=True)
        click.echo(f"{'='*60}", err=True)
        click.echo(f"  Files processed: {result.get('files_processed', 0):,}", err=True)
        click.echo(f"  Preferences created: {result.get('total_preferences', 0):,}", err=True)
        click.echo(f"  Preferences filtered: {result.get('total_filtered', 0):,}", err=True)
        click.echo(f"  RDF triples inserted: {result.get('total_triples', 0):,}", err=True)
        click.echo(f"  Vectors inserted: {result.get('total_vectors', 0):,}", err=True)

        # Show incremental mode stats
        if incremental and result.get('warmed_from_db', 0) > 0:
            click.echo(f"\nIncremental Mode:", err=True)
            click.echo(f"  Existing preferences loaded: {result.get('warmed_from_db', 0):,}", err=True)

    except Exception as e:
        click.echo(f"Ingestion failed: {e}", err=True)
        raise SystemExit(1)


@cli.command('stats')
@click.argument('file_path', type=click.Path(exists=True))
@click.option('--json', 'as_json', is_flag=True, help='Output as JSON')
def stats(file_path: str, as_json: bool):
    """
    Show statistics about an email preferences file.

    Examples:
        python -m services.ingest.src.cli stats /path/to/preferences.jsonl
        python -m services.ingest.src.cli stats /path/to/preferences.jsonl --json
    """
    try:
        file_stats = get_file_stats(file_path)
    except Exception as e:
        click.echo(f"Error reading file: {e}", err=True)
        raise SystemExit(1)

    if as_json:
        click.echo(json.dumps(file_stats, indent=2, default=str))
        return

    click.echo(f"\n{'='*60}")
    click.echo(f"Email Preferences File Statistics")
    click.echo(f"{'='*60}")
    click.echo(f"File: {file_path}")
    click.echo(f"\nOverview:")
    click.echo(f"  Total lines: {file_stats['total']:,}")
    click.echo(f"  Valid records: {file_stats['valid']:,}")
    click.echo(f"  Parse errors: {file_stats['errors']:,}")

    click.echo(f"\nBy Category:")
    for cat, count in sorted(file_stats['by_category'].items(), key=lambda x: -x[1]):
        click.echo(f"  {cat}: {count:,}")

    click.echo(f"\nBy Source:")
    for src, count in sorted(file_stats['by_source'].items(), key=lambda x: -x[1]):
        click.echo(f"  {src}: {count:,}")

    click.echo(f"\nBy Preference Type:")
    for ptype, count in sorted(file_stats['by_preference_type'].items(), key=lambda x: -x[1]):
        click.echo(f"  {ptype}: {count:,}")

    click.echo(f"\nDate Range:")
    click.echo(f"  Earliest: {file_stats['date_range']['earliest']}")
    click.echo(f"  Latest: {file_stats['date_range']['latest']}")
    click.echo("")


@cli.command('validate')
@click.argument('file_path', type=click.Path(exists=True))
@click.option('--sample-size', default=100, type=int, help='Number of records to validate')
def validate(file_path: str, sample_size: int):
    """
    Validate an email preferences file.

    Parses a sample of records and reports any issues found.

    Examples:
        python -m services.ingest.src.cli validate /path/to/preferences.jsonl
        python -m services.ingest.src.cli validate /path/to/preferences.jsonl --sample-size 500
    """
    click.echo(f"\n{'='*60}")
    click.echo(f"Validating Email Preferences File")
    click.echo(f"{'='*60}")
    click.echo(f"File: {file_path}")
    click.echo(f"Sample size: {sample_size}")
    click.echo("")

    try:
        report = validate_file(file_path, sample_size=sample_size)
    except Exception as e:
        click.echo(f"Error reading file: {e}", err=True)
        raise SystemExit(1)

    click.echo(f"Results:")
    click.echo(f"  Valid records: {report['valid_count']}")
    click.echo(f"  Error records: {report['error_count']}")

    if report['issues']:
        click.echo(f"\nIssues found ({len(report['issues'])}):")
        for issue in report['issues'][:20]:
            click.echo(f"  - {issue}")
        if len(report['issues']) > 20:
            click.echo(f"  ... and {len(report['issues']) - 20} more issues")
    else:
        click.echo(f"\nNo issues found!")

    if report['sample_records']:
        click.echo(f"\nSample records ({len(report['sample_records'])}):")
        for i, record in enumerate(report['sample_records'][:3], 1):
            click.echo(f"\n  Record {i}:")
            click.echo(f"    Subject: {record.get('subject', 'N/A')[:60]}")
            click.echo(f"    Category: {record.get('category', 'N/A')}")
            click.echo(f"    Source: {record.get('source', 'N/A')}")
            click.echo(f"    Strength: {record.get('strength', 'N/A')}")

    # Exit with error if validation failed
    if report['error_count'] > 0 or report['issues']:
        click.echo(f"\nValidation FAILED - {report['error_count']} errors, {len(report['issues'])} issues")
        raise SystemExit(1)
    else:
        click.echo(f"\nValidation PASSED")


def main():
    """Main entry point."""
    cli()


if __name__ == "__main__":
    main()
