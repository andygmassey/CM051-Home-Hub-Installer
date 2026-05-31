"""Enrichment service CLI for batch processing.

Usage:
    # Enrich books, limit to 100 items
    python -m src.cli enrich --category book --limit 100

    # Enrich all categories
    python -m src.cli enrich --all --limit 1000

    # Dry run (preview what would be enriched)
    python -m src.cli enrich --category music --dry-run

    # Show enrichment statistics
    python -m src.cli stats
"""

import asyncio
import logging
import sys
from datetime import datetime
from typing import List, Optional

import click
import httpx

from .config import settings
from .enricher import EnrichmentService, EnrichmentStats

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)]
)
logger = logging.getLogger(__name__)

# Suppress noisy HTTP client logs (httpx, httpcore)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)


# Valid categories for enrichment
VALID_CATEGORIES = [
    # Core media
    "book", "movie", "video", "music", "tv", "tv_show", "podcast", "artist", "track",
    # URLs/bookmarks
    "bookmark", "website", "page",
    # Brands/topics
    "brand", "interest", "topic", "search_interest",
    # Places
    "place", "venue", "restaurant",
    # Events
    "event", "ticket", "concert",
]


def validate_category(ctx, param, value):
    """Validate category parameter."""
    if value is None:
        return None
    value = value.lower()
    if value not in VALID_CATEGORIES:
        raise click.BadParameter(
            f"Invalid category '{value}'. Valid categories: {', '.join(VALID_CATEGORIES)}"
        )
    return value


async def query_preferences_for_dry_run(
    user_id: str,
    category: Optional[str],
    limit: int,
    skip_enriched: bool,
) -> List[dict]:
    """Query Qdrant for preferences (for dry run display)."""
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            must_conditions = [{"key": "user_id", "match": {"value": user_id}}]

            if category:
                must_conditions.append({
                    "key": "category",
                    "match": {"value": category}
                })

            body = {
                "limit": limit,
                "offset": 0,
                "with_payload": True,
                "with_vector": False,
                "filter": {"must": must_conditions},
            }

            response = await client.post(
                f"{settings.qdrant_url}/collections/{settings.qdrant_collection}/points/scroll",
                json=body
            )

            if response.status_code == 200:
                data = response.json()
                return [
                    {
                        "id": str(point.get("id")),
                        **point.get("payload", {})
                    }
                    for point in data.get("result", {}).get("points", [])
                ]
            else:
                logger.error(f"Qdrant query failed: {response.status_code}")
                return []

    except Exception as e:
        logger.error(f"Error querying Qdrant: {e}")
        return []


async def check_if_enriched(preference_id: str) -> bool:
    """Check if a preference is already enriched in Oxigraph."""
    sparql = f"""
    ASK WHERE {{
        <urn:pwg:preference:{preference_id}> <http://pwg.local/ontology#enrichedAt> ?date .
    }}
    """

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(
                f"{settings.oxigraph_url}/query",
                content=sparql,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json"
                }
            )

            if response.status_code == 200:
                result = response.json()
                return result.get("boolean", False)

    except Exception:
        pass

    return False


async def get_enrichment_stats_from_db() -> dict:
    """Get enrichment statistics from Oxigraph."""
    stats = {
        "total_enriched": 0,
        "by_source": {},
        "by_confidence": {"high": 0, "medium": 0, "low": 0},
        "by_category": {},
        "recent_enrichments": [],
    }

    # Query for total enriched count
    count_query = """
    PREFIX pwg: <http://pwg.local/ontology#>
    SELECT (COUNT(DISTINCT ?pref) as ?count)
    WHERE {
        ?pref pwg:enrichedAt ?date .
    }
    """

    # Query for by-source breakdown
    source_query = """
    PREFIX pwg: <http://pwg.local/ontology#>
    SELECT ?source (COUNT(?pref) as ?count)
    WHERE {
        ?pref pwg:enrichmentSource ?source .
    }
    GROUP BY ?source
    """

    # Query for confidence distribution
    confidence_query = """
    PREFIX pwg: <http://pwg.local/ontology#>
    SELECT ?confidence
    WHERE {
        ?pref pwg:enrichmentConfidence ?confidence .
    }
    """

    # Query for recent enrichments
    recent_query = """
    PREFIX pwg: <http://pwg.local/ontology#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    SELECT ?pref ?date ?source ?confidence
    WHERE {
        ?pref pwg:enrichedAt ?date ;
              pwg:enrichmentSource ?source ;
              pwg:enrichmentConfidence ?confidence .
    }
    ORDER BY DESC(?date)
    LIMIT 10
    """

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            # Get total count
            response = await client.post(
                f"{settings.oxigraph_url}/query",
                content=count_query,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json"
                }
            )
            if response.status_code == 200:
                data = response.json()
                bindings = data.get("results", {}).get("bindings", [])
                if bindings:
                    stats["total_enriched"] = int(bindings[0]["count"]["value"])

            # Get by-source breakdown
            response = await client.post(
                f"{settings.oxigraph_url}/query",
                content=source_query,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json"
                }
            )
            if response.status_code == 200:
                data = response.json()
                for binding in data.get("results", {}).get("bindings", []):
                    source = binding["source"]["value"]
                    count = int(binding["count"]["value"])
                    stats["by_source"][source] = count

            # Get confidence distribution
            response = await client.post(
                f"{settings.oxigraph_url}/query",
                content=confidence_query,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json"
                }
            )
            if response.status_code == 200:
                data = response.json()
                for binding in data.get("results", {}).get("bindings", []):
                    conf = float(binding["confidence"]["value"])
                    if conf >= 0.8:
                        stats["by_confidence"]["high"] += 1
                    elif conf >= 0.5:
                        stats["by_confidence"]["medium"] += 1
                    else:
                        stats["by_confidence"]["low"] += 1

            # Get recent enrichments
            response = await client.post(
                f"{settings.oxigraph_url}/query",
                content=recent_query,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json"
                }
            )
            if response.status_code == 200:
                data = response.json()
                for binding in data.get("results", {}).get("bindings", []):
                    stats["recent_enrichments"].append({
                        "id": binding["pref"]["value"].split(":")[-1],
                        "date": binding["date"]["value"],
                        "source": binding["source"]["value"],
                        "confidence": float(binding["confidence"]["value"]),
                    })

    except Exception as e:
        logger.error(f"Error querying Oxigraph stats: {e}")

    return stats


async def get_unenriched_counts(user_id: str) -> dict:
    """Get counts of unenriched preferences by category."""
    counts = {}

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            for category in ["book", "movie", "music", "podcast", "tv"]:
                body = {
                    "limit": 1,  # We just want the total count
                    "offset": 0,
                    "with_payload": False,
                    "with_vector": False,
                    "filter": {
                        "must": [
                            {"key": "user_id", "match": {"value": user_id}},
                            {"key": "category", "match": {"value": category}},
                        ]
                    },
                }

                response = await client.post(
                    f"{settings.qdrant_url}/collections/{settings.qdrant_collection}/points/scroll",
                    json=body
                )

                if response.status_code == 200:
                    # Note: Qdrant scroll doesn't return total count easily
                    # We'll estimate by fetching more
                    body["limit"] = 10000
                    response = await client.post(
                        f"{settings.qdrant_url}/collections/{settings.qdrant_collection}/points/scroll",
                        json=body
                    )
                    if response.status_code == 200:
                        data = response.json()
                        points = data.get("result", {}).get("points", [])
                        counts[category] = len(points)

    except Exception as e:
        logger.error(f"Error getting unenriched counts: {e}")

    return counts


def print_progress(processed: int, total: int, stats: EnrichmentStats):
    """Print progress bar to stderr."""
    if total == 0:
        return

    pct = min(100, int(processed / total * 100))
    bar_len = 40
    filled = int(bar_len * processed / total)
    bar = "=" * filled + "-" * (bar_len - filled)

    status = (
        f"[{bar}] {pct}% | "
        f"Processed: {stats.total_processed} | "
        f"Enriched: {stats.successful} | "
        f"Skipped: {stats.skipped_already_enriched} | "
        f"Failed: {stats.failed}"
    )

    # Use carriage return to overwrite the line
    click.echo(f"\r{status}", nl=False, err=True)


@click.group()
@click.version_option(version="0.1.0", prog_name="PWG Enrichment CLI")
def cli():
    """PWG Enrichment Service CLI.

    Batch enrichment of preferences with external metadata from
    Open Library (books), TMDB (movies/TV), and MusicBrainz (music).
    """
    pass


@cli.command()
@click.option(
    "--category", "-c",
    callback=validate_category,
    help=f"Category to enrich. Valid: {', '.join(VALID_CATEGORIES)}"
)
@click.option(
    "--all", "all_categories",
    is_flag=True,
    help="Enrich all supported categories"
)
@click.option(
    "--limit", "-l",
    default=1000,
    type=int,
    help="Maximum items to process (default: 1000)"
)
@click.option(
    "--user-id", "-u",
    default="andy",
    help="User ID to filter by (default: andy)"
)
@click.option(
    "--skip-enriched/--no-skip-enriched",
    default=True,
    help="Skip already-enriched items (default: true)"
)
@click.option(
    "--dry-run", "-n",
    is_flag=True,
    help="Show what would be enriched without calling APIs"
)
@click.option(
    "--batch-size", "-b",
    default=50,
    type=int,
    help="Batch size for processing (default: 50)"
)
@click.option(
    "--verbose", "-v",
    is_flag=True,
    help="Enable verbose output"
)
def enrich(
    category: Optional[str],
    all_categories: bool,
    limit: int,
    user_id: str,
    skip_enriched: bool,
    dry_run: bool,
    batch_size: int,
    verbose: bool,
):
    """Enrich preferences with external metadata.

    Examples:

        # Enrich books (limit 100)
        python -m src.cli enrich --category book --limit 100

        # Enrich all categories
        python -m src.cli enrich --all --limit 500

        # Preview what would be enriched (dry run)
        python -m src.cli enrich --category music --dry-run

        # Verbose output with custom batch size
        python -m src.cli enrich -c movie -l 200 -b 25 -v
    """
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    if not category and not all_categories:
        raise click.UsageError(
            "You must specify --category or --all"
        )

    if category and all_categories:
        raise click.UsageError(
            "Cannot use both --category and --all"
        )

    # Determine categories to process
    if all_categories:
        categories_to_process = ["book", "movie", "music"]  # Core categories with clients
    else:
        categories_to_process = [category]

    click.echo("PWG Enrichment CLI", err=True)
    click.echo("=" * 50, err=True)
    click.echo(f"User ID:      {user_id}", err=True)
    click.echo(f"Categories:   {', '.join(categories_to_process)}", err=True)
    click.echo(f"Limit:        {limit}", err=True)
    click.echo(f"Skip enriched: {skip_enriched}", err=True)
    click.echo(f"Dry run:      {dry_run}", err=True)
    click.echo(f"Batch size:   {batch_size}", err=True)
    click.echo("=" * 50, err=True)

    if dry_run:
        asyncio.run(_dry_run(
            user_id=user_id,
            categories=categories_to_process,
            limit=limit,
            skip_enriched=skip_enriched,
        ))
    else:
        asyncio.run(_run_enrichment(
            user_id=user_id,
            categories=categories_to_process,
            limit=limit,
            batch_size=batch_size,
            verbose=verbose,
        ))


async def _dry_run(
    user_id: str,
    categories: List[str],
    limit: int,
    skip_enriched: bool,
):
    """Execute dry run - show what would be enriched."""
    click.echo("\n[DRY RUN] Previewing preferences to enrich:\n", err=True)

    total_would_enrich = 0
    total_already_enriched = 0
    total_no_client = 0

    # Category to client mapping
    category_clients = {
        "book": "openlibrary",
        "movie": "tmdb",
        "tv": "tmdb",
        "music": "musicbrainz",
        "artist": "musicbrainz",
        "track": "musicbrainz",
        "podcast": None,
    }

    for cat in categories:
        click.echo(f"\n--- Category: {cat} ---", err=True)

        prefs = await query_preferences_for_dry_run(
            user_id=user_id,
            category=cat,
            limit=limit,
            skip_enriched=skip_enriched,
        )

        if not prefs:
            click.echo(f"  No preferences found for category '{cat}'", err=True)
            continue

        client = category_clients.get(cat)
        if client is None:
            click.echo(f"  [SKIP] No client available for category '{cat}'", err=True)
            total_no_client += len(prefs)
            continue

        click.echo(f"  Client: {client}", err=True)
        click.echo(f"  Found {len(prefs)} preferences", err=True)
        click.echo("", err=True)

        would_enrich = 0
        already_enriched = 0

        # Show sample of preferences
        for i, pref in enumerate(prefs[:20]):  # Show max 20
            pref_id = pref.get("id", "")
            subject = pref.get("subject", "Unknown")
            source = pref.get("source", "Unknown")

            # Check if already enriched
            if skip_enriched:
                is_enriched = await check_if_enriched(pref_id)
                if is_enriched:
                    already_enriched += 1
                    if i < 5:  # Only show first 5 skipped
                        click.echo(f"    [SKIP] {subject[:60]:<60} (already enriched)", err=True)
                    continue

            would_enrich += 1
            if would_enrich <= 15:  # Show first 15 would-enrich
                click.echo(f"    [WOULD ENRICH] {subject[:50]:<50} (source: {source})", err=True)

        if len(prefs) > 20:
            click.echo(f"    ... and {len(prefs) - 20} more", err=True)

        click.echo("", err=True)
        click.echo(f"  Summary for {cat}:", err=True)
        click.echo(f"    Would enrich:     {would_enrich}", err=True)
        click.echo(f"    Already enriched: {already_enriched}", err=True)

        total_would_enrich += would_enrich
        total_already_enriched += already_enriched

    click.echo("\n" + "=" * 50, err=True)
    click.echo("DRY RUN SUMMARY", err=True)
    click.echo("=" * 50, err=True)
    click.echo(f"Total would enrich:     {total_would_enrich}", err=True)
    click.echo(f"Total already enriched: {total_already_enriched}", err=True)
    click.echo(f"Total no client:        {total_no_client}", err=True)
    click.echo("", err=True)

    if total_would_enrich > 0:
        # Estimate time based on rate limits
        # Most restrictive: MusicBrainz at 1 req/sec
        estimated_seconds = total_would_enrich  # 1 req/sec worst case
        hours = estimated_seconds // 3600
        minutes = (estimated_seconds % 3600) // 60
        click.echo(f"Estimated time: ~{hours}h {minutes}m (at 1 req/sec worst case)", err=True)
        click.echo("", err=True)
        click.echo("Run without --dry-run to execute enrichment.", err=True)


async def _run_enrichment(
    user_id: str,
    categories: List[str],
    limit: int,
    batch_size: int,
    verbose: bool,
):
    """Execute actual enrichment."""
    click.echo("\nStarting enrichment...\n", err=True)

    service = EnrichmentService()
    start_time = datetime.utcnow()

    try:
        if len(categories) == 1:
            # Single category
            stats = await service.enrich_all(
                user_id=user_id,
                category=categories[0],
                limit=limit,
                batch_size=batch_size,
                progress_callback=lambda p, t, s: print_progress(p, t, s),
            )
        else:
            # Multiple categories
            stats = await service.enrich_categories(
                categories=categories,
                user_id=user_id,
                limit_per_category=limit // len(categories),
            )

        click.echo("\n\n", err=True)  # Clear progress line
        click.echo("=" * 50, err=True)
        click.echo("ENRICHMENT COMPLETE", err=True)
        click.echo("=" * 50, err=True)
        click.echo(stats.summary(), err=True)

        # Show client stats if verbose
        if verbose:
            click.echo("\n--- Client Statistics ---", err=True)
            client_stats = service.get_client_stats()
            for client_name, client_info in client_stats.items():
                click.echo(f"\n{client_name}:", err=True)
                for key, value in client_info.items():
                    click.echo(f"  {key}: {value}", err=True)

        # Show errors if any
        if stats.errors:
            click.echo(f"\n--- Errors ({len(stats.errors)}) ---", err=True)
            for error in stats.errors[:10]:
                click.echo(f"  {error}", err=True)
            if len(stats.errors) > 10:
                click.echo(f"  ... and {len(stats.errors) - 10} more errors", err=True)

        duration = (datetime.utcnow() - start_time).total_seconds()
        click.echo(f"\nTotal duration: {duration:.1f}s", err=True)

        # Return exit code based on success
        if stats.failed > stats.successful:
            raise SystemExit(1)

    finally:
        await service.close()


@cli.command()
@click.option(
    "--user-id", "-u",
    default="andy",
    help="User ID to show stats for (default: andy)"
)
@click.option(
    "--json", "as_json",
    is_flag=True,
    help="Output as JSON"
)
def stats(user_id: str, as_json: bool):
    """Show enrichment statistics.

    Displays:
    - Total enriched preferences
    - Breakdown by source (Open Library, TMDB, MusicBrainz)
    - Confidence distribution
    - Unenriched counts by category

    Examples:

        # Show stats
        python -m src.cli stats

        # Output as JSON
        python -m src.cli stats --json
    """
    asyncio.run(_show_stats(user_id, as_json))


async def _show_stats(user_id: str, as_json: bool):
    """Display enrichment statistics."""
    click.echo("Fetching enrichment statistics...\n", err=True)

    # Get stats from Oxigraph
    db_stats = await get_enrichment_stats_from_db()

    # Get unenriched counts from Qdrant
    unenriched = await get_unenriched_counts(user_id)

    if as_json:
        import json
        output = {
            "enriched": db_stats,
            "unenriched": unenriched,
            "user_id": user_id,
        }
        click.echo(json.dumps(output, indent=2, default=str))
        return

    click.echo("=" * 50)
    click.echo("PWG ENRICHMENT STATISTICS")
    click.echo("=" * 50)
    click.echo(f"\nUser: {user_id}\n")

    # Enriched stats
    click.echo("--- Already Enriched ---")
    click.echo(f"Total enriched: {db_stats['total_enriched']}")
    click.echo("")

    if db_stats["by_source"]:
        click.echo("By source:")
        for source, count in db_stats["by_source"].items():
            click.echo(f"  {source}: {count}")
        click.echo("")

    if any(db_stats["by_confidence"].values()):
        click.echo("By confidence:")
        click.echo(f"  High (>=0.8):    {db_stats['by_confidence']['high']}")
        click.echo(f"  Medium (0.5-0.8): {db_stats['by_confidence']['medium']}")
        click.echo(f"  Low (<0.5):      {db_stats['by_confidence']['low']}")
        click.echo("")

    # Unenriched stats
    click.echo("--- Pending Enrichment ---")
    if unenriched:
        total_pending = sum(unenriched.values())
        click.echo(f"Total unenriched: {total_pending}")
        click.echo("")
        click.echo("By category:")
        for cat, count in sorted(unenriched.items(), key=lambda x: -x[1]):
            client = {"book": "openlibrary", "movie": "tmdb", "music": "musicbrainz", "tv": "tmdb"}.get(cat, "none")
            click.echo(f"  {cat}: {count} (client: {client})")
    else:
        click.echo("No unenriched preferences found")

    click.echo("")

    # Recent enrichments
    if db_stats["recent_enrichments"]:
        click.echo("--- Recent Enrichments ---")
        for item in db_stats["recent_enrichments"][:5]:
            conf_str = f"{item['confidence']:.2f}"
            date_str = item['date'][:19].replace('T', ' ')
            click.echo(f"  {date_str} | {item['source']:<15} | conf: {conf_str}")

    click.echo("\n" + "=" * 50)


@cli.command()
def test_connections():
    """Test connections to Qdrant and Oxigraph.

    Verifies that both databases are reachable and properly configured.
    """
    asyncio.run(_test_connections())


async def _test_connections():
    """Test database connections."""
    click.echo("Testing connections...\n")

    # Test Qdrant
    click.echo(f"Qdrant URL: {settings.qdrant_url}")
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(f"{settings.qdrant_url}/collections")
            if response.status_code == 200:
                collections = response.json().get("result", {}).get("collections", [])
                click.echo(f"  [OK] Qdrant connected ({len(collections)} collections)")

                # Check for pwg_preferences collection
                has_pwg = any(c.get("name") == settings.qdrant_collection for c in collections)
                if has_pwg:
                    click.echo(f"  [OK] Collection '{settings.qdrant_collection}' exists")
                else:
                    click.echo(f"  [WARN] Collection '{settings.qdrant_collection}' not found")
            else:
                click.echo(f"  [FAIL] Qdrant returned status {response.status_code}")
    except Exception as e:
        click.echo(f"  [FAIL] Qdrant connection error: {e}")

    click.echo("")

    # Test Oxigraph
    click.echo(f"Oxigraph URL: {settings.oxigraph_url}")
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            # Try a simple ASK query
            response = await client.post(
                f"{settings.oxigraph_url}/query",
                content="ASK WHERE { ?s ?p ?o } LIMIT 1",
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json"
                }
            )
            if response.status_code == 200:
                click.echo("  [OK] Oxigraph connected (SPARQL endpoint working)")
            else:
                click.echo(f"  [FAIL] Oxigraph returned status {response.status_code}")
    except Exception as e:
        click.echo(f"  [FAIL] Oxigraph connection error: {e}")

    click.echo("")

    # Test API keys
    click.echo("API Keys:")
    if settings.tmdb_api_key:
        click.echo(f"  TMDB_API_KEY: configured ({settings.tmdb_api_key[:8]}...)")
    else:
        click.echo("  TMDB_API_KEY: NOT SET (movies/TV enrichment will fail)")

    click.echo("")


@cli.command()
@click.option(
    "--verbose", "-v",
    is_flag=True,
    help="Enable verbose output"
)
def normalize(verbose: bool):
    """Normalize all topics to Wikidata Q-IDs.

    This is a second-pass enrichment that takes existing topic strings
    from enriched preferences and maps them to canonical Wikidata entities,
    enabling cross-platform topic correlation.

    Examples:

        # Run Wikidata normalization
        python -m src.cli normalize

        # With verbose output
        python -m src.cli normalize -v
    """
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    asyncio.run(_run_normalization(verbose))


async def _run_normalization(verbose: bool):
    """Execute Wikidata topic normalization."""
    click.echo("PWG Wikidata Normalization", err=True)
    click.echo("=" * 50, err=True)
    click.echo("Normalizing all enriched topics to Wikidata Q-IDs...\n", err=True)

    service = EnrichmentService()
    start_time = datetime.utcnow()

    def progress_callback(processed: int, total: int):
        if total == 0:
            return
        pct = min(100, int(processed / total * 100))
        bar_len = 40
        filled = int(bar_len * processed / total)
        bar = "=" * filled + "-" * (bar_len - filled)
        status = f"\r[{bar}] {pct}% | {processed}/{total} topics"
        click.echo(status, nl=False, err=True)

    try:
        stats = await service.normalize_topics_with_wikidata(
            progress_callback=progress_callback,
        )

        click.echo("\n\n", err=True)
        click.echo("=" * 50, err=True)
        click.echo("NORMALIZATION COMPLETE", err=True)
        click.echo("=" * 50, err=True)
        click.echo(f"Total topics:     {stats['total_topics']}", err=True)
        click.echo(f"Normalized:       {stats['normalized']}", err=True)
        click.echo(f"Failed:           {stats['failed']}", err=True)
        click.echo(f"Already done:     {stats['already_normalized']}", err=True)

        if verbose and stats['topics']:
            click.echo("\n--- Sample Normalizations ---", err=True)
            sample = list(stats['topics'].items())[:20]
            for topic, qid in sample:
                click.echo(f"  '{topic}' -> {qid}", err=True)
            if len(stats['topics']) > 20:
                click.echo(f"  ... and {len(stats['topics']) - 20} more", err=True)

        duration = (datetime.utcnow() - start_time).total_seconds()
        click.echo(f"\nTotal duration: {duration:.1f}s", err=True)

    finally:
        await service.close()


@cli.command()
@click.option(
    "--user-id", "-u",
    default="andy",
    help="User ID to filter by (default: andy)"
)
@click.option(
    "--min-strength", "-s",
    default=0.5,
    type=float,
    help="Minimum strength threshold 0-1 (default: 0.5)"
)
@click.option(
    "--music-limit", default=5000, type=int, help="Limit for music items"
)
@click.option(
    "--video-limit", default=3000, type=int, help="Limit for video/movie/tv items"
)
@click.option(
    "--book-limit", default=500, type=int, help="Limit for book items"
)
@click.option(
    "--podcast-limit", default=200, type=int, help="Limit for podcast items"
)
@click.option(
    "--priority/--no-priority",
    default=True,
    help="Process high-strength items first (default: true)"
)
@click.option(
    "--verbose", "-v",
    is_flag=True,
    help="Enable verbose output"
)
def parallel(
    user_id: str,
    min_strength: float,
    music_limit: int,
    video_limit: int,
    book_limit: int,
    podcast_limit: int,
    priority: bool,
    verbose: bool,
):
    """Run PARALLEL enrichment across all categories simultaneously.

    Since each category uses a different external API (MusicBrainz, TMDB,
    OpenLibrary, Podcast Index), we can run them all at the same time!

    This is MUCH faster than sequential processing.

    Examples:

        # Run parallel enrichment with defaults
        python -m src.cli parallel

        # High-value items only (strength >= 0.7)
        python -m src.cli parallel --min-strength 0.7

        # Custom limits per category
        python -m src.cli parallel --music-limit 10000 --video-limit 5000

        # Skip priority ordering (random order)
        python -m src.cli parallel --no-priority
    """
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    asyncio.run(_run_parallel(
        user_id=user_id,
        min_strength=min_strength,
        music_limit=music_limit,
        video_limit=video_limit,
        book_limit=book_limit,
        podcast_limit=podcast_limit,
        priority=priority,
        verbose=verbose,
    ))


async def _run_parallel(
    user_id: str,
    min_strength: float,
    music_limit: int,
    video_limit: int,
    book_limit: int,
    podcast_limit: int,
    priority: bool,
    verbose: bool,
):
    """Execute parallel enrichment."""
    click.echo("╔══════════════════════════════════════════════════════════════╗", err=True)
    click.echo("║         🚀 PARALLEL ENRICHMENT ENGINE 🚀                     ║", err=True)
    click.echo("╠══════════════════════════════════════════════════════════════╣", err=True)
    click.echo(f"║  User: {user_id:<15}  Min Strength: {min_strength:<6}  Priority: {str(priority):<5} ║", err=True)
    click.echo("╠══════════════════════════════════════════════════════════════╣", err=True)
    click.echo(f"║  Music:    {music_limit:>6} items   │  Video/TV: {video_limit:>6} items       ║", err=True)
    click.echo(f"║  Books:    {book_limit:>6} items   │  Podcasts: {podcast_limit:>6} items       ║", err=True)
    click.echo("╚══════════════════════════════════════════════════════════════╝", err=True)
    click.echo("", err=True)

    # Build category configs
    category_configs = [
        {"category": "music", "limit": music_limit, "min_strength": min_strength, "priority_order": priority},
        {"category": "video", "limit": video_limit, "min_strength": min_strength, "priority_order": priority},
        {"category": "movie", "limit": video_limit, "min_strength": min_strength, "priority_order": priority},
        {"category": "tv_show", "limit": video_limit, "min_strength": min_strength, "priority_order": priority},
        {"category": "book", "limit": book_limit, "min_strength": min_strength, "priority_order": priority},
        {"category": "podcast", "limit": podcast_limit, "min_strength": min_strength, "priority_order": priority},
    ]

    service = EnrichmentService()
    start_time = datetime.utcnow()

    try:
        click.echo("Starting parallel enrichment... (this runs ALL categories at once!)\n", err=True)

        stats_by_category = await service.enrich_parallel(
            category_configs=category_configs,
            user_id=user_id,
        )

        # Summary
        click.echo("\n", err=True)
        click.echo("╔══════════════════════════════════════════════════════════════╗", err=True)
        click.echo("║                   PARALLEL ENRICHMENT COMPLETE               ║", err=True)
        click.echo("╠══════════════════════════════════════════════════════════════╣", err=True)

        total_processed = 0
        total_enriched = 0
        total_failed = 0

        for category, stats in sorted(stats_by_category.items()):
            total_processed += stats.total_processed
            total_enriched += stats.successful
            total_failed += stats.failed
            pct = (stats.successful / stats.total_processed * 100) if stats.total_processed > 0 else 0
            click.echo(
                f"║  {category:<12} │ Processed: {stats.total_processed:>5} │ "
                f"Enriched: {stats.successful:>5} │ {pct:>4.0f}%  ║",
                err=True
            )

        click.echo("╠══════════════════════════════════════════════════════════════╣", err=True)
        total_pct = (total_enriched / total_processed * 100) if total_processed > 0 else 0
        click.echo(
            f"║  {'TOTAL':<12} │ Processed: {total_processed:>5} │ "
            f"Enriched: {total_enriched:>5} │ {total_pct:>4.0f}%  ║",
            err=True
        )
        click.echo("╚══════════════════════════════════════════════════════════════╝", err=True)

        duration = (datetime.utcnow() - start_time).total_seconds()
        items_per_sec = total_processed / duration if duration > 0 else 0
        click.echo(f"\nTotal duration: {duration:.1f}s ({items_per_sec:.1f} items/sec)", err=True)

        if verbose:
            click.echo("\n--- By Source ---", err=True)
            combined_sources = {}
            for stats in stats_by_category.values():
                for source, count in stats.by_source.items():
                    combined_sources[source] = combined_sources.get(source, 0) + count
            for source, count in sorted(combined_sources.items(), key=lambda x: -x[1]):
                click.echo(f"  {source}: {count}", err=True)

    finally:
        await service.close()


def main():
    """Main entry point."""
    cli()


if __name__ == "__main__":
    main()
