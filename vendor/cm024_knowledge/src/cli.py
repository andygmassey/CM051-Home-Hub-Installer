"""
CM024 Evernote Knowledge CLI - Process Evernote exports into knowledge base.

Usage:
    # Convert ENEX to markdown (Phase 1)
    python -m src.cli convert data/evernote-export/*.enex --output data/obsidian-vault/evernote

    # Classify existing markdown files (Phase 2)
    python -m src.cli classify data/obsidian-vault/evernote --llm

    # Full pipeline (convert + classify)
    python -m src.cli process data/evernote-export/*.enex --output data/obsidian-vault/evernote
"""

import glob
import logging
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Tuple
from urllib.parse import urlparse

import click

from .ingestion.adapters import ADAPTERS
from .ingestion.enex_parser import ENEXParser, count_notes


# Env-var-driven default URLs so the same code runs without flags on
# the operator's machine (defaults) and against any non-default stack
# via env (OSTLER_OLLAMA_URL / OSTLER_QDRANT_URL). Single-machine
# localhost is the productised default per the launch architecture.
def _default_ollama_url() -> str:
    return os.environ.get("OSTLER_OLLAMA_URL", "http://localhost:11434")


def _default_qdrant_url() -> str:
    return os.environ.get("OSTLER_QDRANT_URL", "http://localhost:6333")


def _parse_qdrant_url(url: str) -> Tuple[str, int]:
    """Parse ``http(s)://host:port`` into ``(host, port)`` for the existing
    QdrantStore / QdrantClient APIs which want the split form. Sensible
    defaults if the URL omits a port: 443 for https, 6333 for everything
    else (Qdrant's HTTP API default).
    """
    parsed = urlparse(url)
    host = parsed.hostname or "localhost"
    if parsed.port is not None:
        port = parsed.port
    elif parsed.scheme == "https":
        port = 443
    else:
        port = 6333
    return host, port


def _default_qdrant_host() -> str:
    return _parse_qdrant_url(_default_qdrant_url())[0]


def _default_qdrant_port() -> int:
    return _parse_qdrant_url(_default_qdrant_url())[1]
from .ingestion.markdown_writer import MarkdownWriter
from .ingestion.classifier import PrivacyClassifier, ClassificationResult, COMPARTMENT_NAMES
from .ingestion.importance_scorer import ImportanceScorer
from .ingestion.chunker import SemanticChunker
from .ingestion.embedder import Embedder
from .ingestion.incremental import (
    IncrementalIngester, compute_content_hash,
    find_duplicates, remove_duplicates,
)
from .storage.qdrant_store import QdrantStore
from .storage.metadata_db import MetadataDB, NoteRecord, ChunkRecord

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)]
)
logger = logging.getLogger(__name__)


@click.group()
@click.version_option(version="0.1.0", prog_name="CM024 Evernote Knowledge CLI")
def cli():
    """CM024 Evernote Knowledge Backend CLI.

    Process Evernote exports into a searchable knowledge base.
    """
    pass


@cli.command('convert')
@click.argument('enex_files', nargs=-1, type=click.Path(exists=True))
@click.option('--output', '-o', required=True, type=click.Path(), help='Output directory for markdown files')
@click.option('--source', default='evernote', type=click.Choice(sorted(ADAPTERS.keys())), help='Knowledge-source adapter (default: evernote)')
@click.option('--limit', '-l', type=int, help='Maximum notes to process per file')
@click.option('--overwrite', is_flag=True, help='Overwrite existing files')
@click.option('--classify', '-c', is_flag=True, help='Also classify privacy levels')
@click.option('--llm', is_flag=True, help='Use LLM for ambiguous classifications (requires Ollama)')
@click.option('--verbose', '-v', is_flag=True, help='Verbose output')
def convert_cmd(
    enex_files: tuple,
    output: str,
    source: str,
    limit: Optional[int],
    overwrite: bool,
    classify: bool,
    llm: bool,
    verbose: bool,
):
    """
    Convert ENEX files to Obsidian markdown.

    Parses Evernote export files and creates markdown files with
    YAML frontmatter containing metadata.

    Examples:
        # Convert single file
        python -m src.cli convert data/export.enex -o data/vault

        # Convert multiple files with glob
        python -m src.cli convert "data/*.enex" -o data/vault

        # Convert with classification
        python -m src.cli convert data/*.enex -o data/vault --classify
    """
    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Expand globs
    all_files = []
    for pattern in enex_files:
        expanded = glob.glob(pattern)
        if expanded:
            all_files.extend(expanded)
        else:
            all_files.append(pattern)

    if not all_files:
        click.echo("No ENEX files found", err=True)
        raise SystemExit(1)

    click.echo(f"\n{'='*60}", err=True)
    click.echo("CM024 Knowledge Convert", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"Source adapter: {source}", err=True)
    click.echo(f"Files: {len(all_files)}", err=True)
    click.echo(f"Output: {output}", err=True)
    click.echo(f"Classify: {classify}", err=True)
    if classify:
        click.echo(f"LLM: {llm}", err=True)
    click.echo(f"{'='*60}\n", err=True)

    # Initialize components
    adapter_cls = ADAPTERS[source]
    adapter = adapter_cls()
    writer = MarkdownWriter(output, overwrite=overwrite)
    classifier = PrivacyClassifier(use_llm=llm) if classify else None
    importance_scorer = ImportanceScorer()

    total_parsed = 0
    total_written = 0
    total_skipped = 0
    total_errors = 0
    start_time = datetime.now()

    for file_path in all_files:
        file_path = Path(file_path)
        click.echo(f"\nProcessing: {file_path.name}", err=True)

        # Count notes first for progress (Evernote-specific fast count;
        # other adapters fall back to "?" until they implement equivalents).
        total_in_file = 0
        if source == 'evernote':
            try:
                total_in_file = count_notes(file_path)
                click.echo(f"  Notes in file: {total_in_file:,}", err=True)
            except Exception as e:
                click.echo(f"  Error counting notes: {e}", err=True)

        file_count = 0
        file_written = 0

        for raw in adapter.discover(file_path):
            note = adapter.parse(raw)
            if note is None:
                continue
            file_count += 1
            total_parsed += 1

            # Classify if requested
            compartment_level = 2  # default
            if classifier:
                result = classifier.classify(note)
                compartment_level = result.level

            # Calculate importance score
            importance_result = importance_scorer.score(note)
            importance_score = importance_result.score

            # Write markdown
            path = writer.write(note, compartment_level, importance_score)
            if path:
                file_written += 1
                total_written += 1

            # Progress every 100 notes
            if file_count % 100 == 0:
                click.echo(f"  Processed: {file_count:,} / {total_in_file:,}", err=True)

            # Check limit
            if limit and file_count >= limit:
                click.echo(f"  Reached limit of {limit}", err=True)
                break

        click.echo(f"  Complete: {file_written:,} written from {file_count:,} notes", err=True)

    # Final stats
    duration = (datetime.now() - start_time).total_seconds()
    total_skipped = writer.stats['skipped']
    total_errors = writer.stats['errors']

    click.echo(f"\n{'='*60}", err=True)
    click.echo("CONVERSION COMPLETE", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"  Notes parsed: {total_parsed:,}", err=True)
    click.echo(f"  Files written: {total_written:,}", err=True)
    click.echo(f"  Skipped: {total_skipped:,}", err=True)
    click.echo(f"  Errors: {total_errors:,}", err=True)
    click.echo(f"  Duration: {duration:.1f}s", err=True)

    if classifier:
        click.echo(f"\nClassification stats:", err=True)
        for key, value in classifier.stats.items():
            click.echo(f"  {key}: {value:,}", err=True)

    click.echo(f"\nImportance scoring stats:", err=True)
    for key, value in importance_scorer.stats.items():
        click.echo(f"  {key}: {value:,}", err=True)


@cli.command('count')
@click.argument('enex_files', nargs=-1, type=click.Path(exists=True))
def count_cmd(enex_files: tuple):
    """
    Count notes in ENEX files without processing.

    Quick way to estimate processing time.

    Example:
        python -m src.cli count data/*.enex
    """
    total = 0

    for pattern in enex_files:
        for file_path in glob.glob(pattern) or [pattern]:
            file_path = Path(file_path)
            try:
                count = count_notes(file_path)
                size_mb = file_path.stat().st_size / 1024 / 1024
                click.echo(f"{file_path.name}: {count:,} notes ({size_mb:.1f} MB)")
                total += count
            except Exception as e:
                click.echo(f"{file_path.name}: Error - {e}", err=True)

    click.echo(f"\nTotal: {total:,} notes")


@cli.command('sample')
@click.argument('enex_file', type=click.Path(exists=True))
@click.option('--count', '-n', default=5, help='Number of notes to sample')
@click.option('--classify', '-c', is_flag=True, help='Also classify privacy levels')
def sample_cmd(enex_file: str, count: int, classify: bool):
    """
    Sample notes from an ENEX file.

    Shows note metadata and content preview.

    Example:
        python -m src.cli sample data/export.enex -n 10
    """
    from .ingestion.enex_parser import sample_notes

    notes = sample_notes(enex_file, count)
    classifier = PrivacyClassifier() if classify else None

    for i, note in enumerate(notes, 1):
        click.echo(f"\n{'='*60}")
        click.echo(f"Note {i}: {note.title}")
        click.echo(f"{'='*60}")
        click.echo(f"Created: {note.created}")
        click.echo(f"Updated: {note.updated}")
        click.echo(f"Tags: {note.tags}")
        click.echo(f"Author: {note.author}")
        click.echo(f"Words: {note.word_count}")
        click.echo(f"Attachments: {note.attachment_count}")

        if classifier:
            result = classifier.classify(note)
            click.echo(f"Privacy: L{result.level} ({COMPARTMENT_NAMES[result.level]}) - {result.reason}")

        click.echo(f"\nContent preview:")
        click.echo(note.content[:500] + "..." if len(note.content) > 500 else note.content)


@cli.command('stats')
@click.argument('markdown_dir', type=click.Path(exists=True))
def stats_cmd(markdown_dir: str):
    """
    Show statistics about processed markdown files.

    Example:
        python -m src.cli stats data/obsidian-vault/evernote
    """
    import yaml
    from collections import Counter

    markdown_dir = Path(markdown_dir)
    files = list(markdown_dir.rglob("*.md"))

    click.echo(f"\n{'='*60}")
    click.echo(f"Markdown Statistics: {markdown_dir}")
    click.echo(f"{'='*60}")
    click.echo(f"Total files: {len(files):,}")

    if not files:
        return

    # Analyze frontmatter
    levels = Counter()
    tags = Counter()
    years = Counter()
    errors = 0

    for file_path in files:
        try:
            content = file_path.read_text(encoding='utf-8')
            if content.startswith('---'):
                # Extract frontmatter
                end = content.find('---', 3)
                if end > 0:
                    frontmatter = yaml.safe_load(content[3:end])
                    if frontmatter:
                        level = frontmatter.get('compartment_level', 2)
                        levels[level] += 1

                        for tag in frontmatter.get('tags', []):
                            tags[tag] += 1

                        created = frontmatter.get('created', '')
                        if created:
                            year = str(created)[:4]
                            years[year] += 1
        except Exception:
            errors += 1

    click.echo(f"\nBy Compartment Level:")
    for level in sorted(levels.keys()):
        name = COMPARTMENT_NAMES.get(level, "unknown")
        click.echo(f"  L{level} ({name}): {levels[level]:,}")

    click.echo(f"\nBy Year:")
    for year in sorted(years.keys()):
        click.echo(f"  {year}: {years[year]:,}")

    click.echo(f"\nTop Tags:")
    for tag, count in tags.most_common(20):
        click.echo(f"  {tag}: {count:,}")

    if errors:
        click.echo(f"\nParse errors: {errors:,}")


@cli.command('process')
@click.argument('enex_files', nargs=-1, type=click.Path(exists=True))
@click.option('--output', '-o', required=True, type=click.Path(), help='Output directory')
@click.option('--source', default='evernote', type=click.Choice(sorted(ADAPTERS.keys())), help='Knowledge-source adapter (default: evernote)')
@click.option('--classify', '-c', is_flag=True, default=True, help='Classify privacy levels')
@click.option('--llm', is_flag=True, help='Use LLM for classification')
@click.option('--overwrite', is_flag=True, help='Overwrite existing files')
@click.option('--verbose', '-v', is_flag=True, help='Verbose output')
def process_cmd(
    enex_files: tuple,
    output: str,
    source: str,
    classify: bool,
    llm: bool,
    overwrite: bool,
    verbose: bool,
):
    """
    Full processing pipeline: parse, convert, classify.

    Combines all steps into one command.

    Example:
        python -m src.cli process "data/*.enex" -o data/vault --classify
    """
    # Delegate to convert with classification enabled
    ctx = click.get_current_context()
    ctx.invoke(
        convert_cmd,
        enex_files=enex_files,
        output=output,
        source=source,
        limit=None,
        overwrite=overwrite,
        classify=classify,
        llm=llm,
        verbose=verbose,
    )


@cli.command('embed')
@click.argument('vault_path', type=click.Path(exists=True))
@click.option('--db-path', '-d', default='./data/metadata.db', help='Metadata database path')
@click.option('--qdrant-host', default=_default_qdrant_host, help='Qdrant host (env: OSTLER_QDRANT_URL is parsed for host+port; default http://localhost:6333)')
@click.option('--qdrant-port', default=_default_qdrant_port, type=int, help='Qdrant port (env: OSTLER_QDRANT_URL is parsed for host+port)')
@click.option('--collection', default='evernote_knowledge', help='Qdrant collection name')
@click.option('--embedding-provider', default='ollama', type=click.Choice(['ollama', 'openai']), help='Embedding provider')
@click.option('--embedding-model', default='nomic-embed-text', help='Embedding model name (must match the collection vector dim; nomic-embed-text=768 is the Ostler Hub default)')
@click.option('--ollama-host', default=_default_ollama_url, help='Ollama server URL (env: OSTLER_OLLAMA_URL, default http://localhost:11434)')
@click.option('--batch-size', default=32, type=int, help='Batch size for embedding')
@click.option('--limit', '-l', type=int, help='Maximum notes to embed')
@click.option('--incremental', is_flag=True, help='Only process new/updated notes (skip existing)')
@click.option('--max-compartment-level', type=int, default=None, help='Privacy cap: skip notes whose compartment_level exceeds this (e.g. 2 keeps L3 out of the searchable collection). Default: embed all.')
@click.option('--verbose', '-v', is_flag=True, help='Verbose output')
def embed_cmd(
    vault_path: str,
    db_path: str,
    qdrant_host: str,
    qdrant_port: int,
    collection: str,
    embedding_provider: str,
    embedding_model: str,
    ollama_host: str,
    batch_size: int,
    limit: Optional[int],
    incremental: bool,
    max_compartment_level: Optional[int],
    verbose: bool,
):
    """
    Embed markdown notes and store in Qdrant.

    Reads markdown files from the vault, chunks them semantically,
    generates embeddings, and stores in Qdrant for search.

    Example:
        # Full embedding (replaces collection)
        python -m src.cli embed data/obsidian-vault/evernote

        # Incremental update (only new/updated notes)
        python -m src.cli embed data/vault --incremental

        python -m src.cli embed data/vault --embedding-model nomic-embed-text
    """
    import asyncio

    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    vault = Path(vault_path)

    click.echo(f"\n{'='*60}", err=True)
    click.echo("CM024 Evernote Knowledge - Embed", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"Vault: {vault}", err=True)
    click.echo(f"Database: {db_path}", err=True)
    click.echo(f"Qdrant: {qdrant_host}:{qdrant_port}/{collection}", err=True)
    click.echo(f"Embedding: {embedding_provider}/{embedding_model}", err=True)
    if embedding_provider == 'ollama':
        click.echo(f"Ollama: {ollama_host}", err=True)
    click.echo(f"Batch size: {batch_size}", err=True)
    if limit:
        click.echo(f"Limit: {limit}", err=True)
    click.echo(f"Incremental: {incremental}", err=True)
    click.echo(f"{'='*60}\n", err=True)

    asyncio.run(_run_embed(
        vault=vault,
        db_path=db_path,
        qdrant_host=qdrant_host,
        qdrant_port=qdrant_port,
        collection=collection,
        embedding_provider=embedding_provider,
        embedding_model=embedding_model,
        ollama_host=ollama_host,
        batch_size=batch_size,
        limit=limit,
        incremental=incremental,
        max_compartment_level=max_compartment_level,
        verbose=verbose,
    ))


def _note_passes_privacy_gate(compartment_level, max_compartment_level):
    """True if a note may be embedded into the searchable collection.

    ``max_compartment_level`` None means no cap (embed everything).
    Otherwise a note is gated out when its compartment level exceeds the
    cap -- e.g. cap=2 keeps L3 (compartment_level 3) notes out of Qdrant
    while still allowing them to exist as staged markdown. Pure + total so
    it is unit-testable without Qdrant/Ollama.
    """
    if max_compartment_level is None:
        return True
    try:
        level = int(compartment_level)
    except (TypeError, ValueError):
        # Unknown/garbled level: fail CLOSED (do not embed) so malformed
        # frontmatter cannot leak a private note into search.
        return False
    return level <= int(max_compartment_level)


async def _run_embed(
    vault: Path,
    db_path: str,
    qdrant_host: str,
    qdrant_port: int,
    collection: str,
    embedding_provider: str,
    embedding_model: str,
    ollama_host: str,
    batch_size: int,
    limit: Optional[int],
    incremental: bool,
    max_compartment_level: Optional[int] = None,
    verbose: bool = False,
):
    """Execute embedding pipeline."""
    import time
    import yaml
    from qdrant_client import QdrantClient

    start_time = time.time()

    # Initialize components
    click.echo("Initializing components...", err=True)

    db = MetadataDB(db_path)
    db.initialize()

    # Vector dim MUST follow the embedding model so a freshly-created
    # collection matches the vectors we upsert (nomic-embed-text=768,
    # the Ostler Hub default). If the collection already exists at a
    # different dim, Qdrant rejects the upsert with a dimension error
    # rather than silently dropping points, so a mismatch is loud, not
    # a silently-empty Knowledge section.
    vector_size = Embedder.MODEL_CONFIGS.get(embedding_model, {}).get("dimensions", 768)

    store = QdrantStore(
        host=qdrant_host,
        port=qdrant_port,
        collection=collection,
        vector_size=vector_size,
    )
    if not await store.initialize():
        click.echo("Failed to initialize Qdrant store. Is Qdrant running?", err=True)
        raise SystemExit(1)

    embedder = Embedder(
        provider=embedding_provider,
        model=embedding_model,
        ollama_host=ollama_host,
    )

    chunker = SemanticChunker()

    # Initialize incremental ingester if needed
    incremental_ingester = None
    if incremental:
        click.echo("Loading existing notes for incremental update...", err=True)
        qdrant_client = QdrantClient(host=qdrant_host, port=qdrant_port)
        incremental_ingester = IncrementalIngester(qdrant_client, collection)
        existing_count = await incremental_ingester.warm()
        click.echo(f"  Found {existing_count:,} existing notes", err=True)

    # Find markdown files
    click.echo("Finding markdown files...", err=True)
    md_files = list(vault.rglob("*.md"))
    if limit:
        md_files = md_files[:limit]
    click.echo(f"Found {len(md_files):,} markdown files", err=True)

    # Process files
    notes_processed = 0
    notes_skipped = 0
    chunks_created = 0
    vectors_inserted = 0
    errors = []

    for i, md_file in enumerate(md_files):
        try:
            content = md_file.read_text(encoding='utf-8')

            # Parse frontmatter
            metadata = {}
            if content.startswith('---'):
                parts = content.split('---', 2)
                if len(parts) >= 3:
                    try:
                        metadata = yaml.safe_load(parts[1]) or {}
                        content = parts[2].strip()
                    except yaml.YAMLError:
                        pass

            # Extract metadata
            note_id = metadata.get('evernote_guid') or md_file.stem
            title = metadata.get('title', md_file.stem)
            tags = metadata.get('tags', [])
            if isinstance(tags, str):
                tags = [tags]
            compartment_level = metadata.get('compartment_level', 2)
            created_str = metadata.get('created')
            updated_str = metadata.get('updated')
            created_at = None
            updated_at = None
            if created_str:
                try:
                    created_at = datetime.fromisoformat(str(created_str).replace('Z', '+00:00'))
                except (ValueError, TypeError):
                    pass
            if updated_str:
                try:
                    updated_at = datetime.fromisoformat(str(updated_str).replace('Z', '+00:00'))
                except (ValueError, TypeError):
                    pass

            # Privacy gate (Ostler): never embed notes above the compartment
            # cap into the searchable Qdrant collection. The wiki Knowledge
            # reader surfaces whatever is in Qdrant, so an L3 (compartment
            # level 3) note that reached the collection would leak. The Doctor
            # import passes max_compartment_level=2 so L3 notes are staged as
            # markdown but never become searchable. None = embed everything
            # (explicit operator `embed` use / backward compatible).
            if not _note_passes_privacy_gate(compartment_level, max_compartment_level):
                notes_skipped += 1
                continue

            # Incremental mode: check if note should be processed
            if incremental_ingester:
                if not incremental_ingester.should_process(note_id, updated_at or created_at, content):
                    notes_skipped += 1
                    continue
                # Delete existing chunks before re-inserting
                await incremental_ingester.delete_existing_chunks(note_id)

            # Chunk the content
            text_chunks = chunker.chunk(content)

            # Store note metadata
            note_record = NoteRecord(
                id=note_id,
                title=title,
                created_at=created_at,
                updated_at=None,
                compartment_level=compartment_level,
                tags=tags,
                source_url=None,
                word_count=len(content.split()),
                chunk_count=len(text_chunks),
                file_path=str(md_file),
                processed_at=datetime.now(),
            )
            db.insert_note(note_record)

            # Embed and store chunks
            for chunk_idx, chunk in enumerate(text_chunks):
                chunk_text = chunk.text if hasattr(chunk, 'text') else str(chunk)

                # Generate embedding
                embedding = await embedder.embed(chunk_text)
                if embedding is None:
                    errors.append(f"Failed to embed chunk {chunk_idx} of {md_file.name}")
                    continue

                # Store in Qdrant (include content_hash for incremental dedup)
                content_hash = compute_content_hash(content) if chunk_idx == 0 else None
                success = await store.upsert(
                    note_id=note_id,
                    chunk_index=chunk_idx,
                    vector=embedding,
                    content=chunk_text,
                    title=title,
                    tags=tags,
                    compartment_level=compartment_level,
                    created_at=created_at,
                )
                if success:
                    vectors_inserted += 1

                chunks_created += 1

            # Track inserted chunks for incremental stats
            if incremental_ingester:
                incremental_ingester.record_inserted_chunks(len(text_chunks))

            notes_processed += 1

            if (i + 1) % 100 == 0:
                click.echo(f"  Processed: {i + 1:,} / {len(md_files):,}", err=True)

        except Exception as e:
            errors.append(f"{md_file.name}: {e}")
            if verbose:
                logger.exception(f"Error processing {md_file}")

    duration = time.time() - start_time

    click.echo(f"\n{'='*60}", err=True)
    click.echo("EMBEDDING COMPLETE", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"  Notes processed: {notes_processed:,}", err=True)
    if incremental_ingester:
        click.echo(f"  Notes skipped: {notes_skipped:,}", err=True)
        click.echo(f"  Incremental stats: {incremental_ingester.get_stats_summary()}", err=True)
    click.echo(f"  Chunks created: {chunks_created:,}", err=True)
    click.echo(f"  Vectors inserted: {vectors_inserted:,}", err=True)
    click.echo(f"  Duration: {duration:.1f}s", err=True)

    if errors:
        click.echo(f"\nErrors ({len(errors)}):", err=True)
        for error in errors[:10]:
            click.echo(f"  - {error}", err=True)
        if len(errors) > 10:
            click.echo(f"  ... and {len(errors) - 10} more errors", err=True)


@cli.command('extract-email-knowledge')
@click.argument('email_source', type=click.Path(exists=True))
@click.option('--output', '-o', type=click.Path(), help='Output JSON file for extracted knowledge')
@click.option('--limit', '-l', type=int, help='Maximum emails to process')
@click.option('--min-messages', default=2, type=int, help='Minimum messages per thread')
@click.option('--ollama-host', default=_default_ollama_url, help='Ollama server URL (env: OSTLER_OLLAMA_URL, default http://localhost:11434)')
@click.option('--model', default='qwen2.5:14b-instruct', help='LLM model for summarization')
@click.option('--qdrant-host', default=_default_qdrant_host, help='Qdrant host (env: OSTLER_QDRANT_URL is parsed for host+port; default http://localhost:6333)')
@click.option('--qdrant-port', default=_default_qdrant_port, type=int, help='Qdrant port (env: OSTLER_QDRANT_URL is parsed for host+port)')
@click.option('--collection', default='email_knowledge', help='Qdrant collection name')
@click.option('--embedding-model', default='all-minilm', help='Embedding model')
@click.option('--skip-embed', is_flag=True, help='Skip embedding, only extract and save')
@click.option('--threads-only', is_flag=True, help='Only parse and group threads, skip LLM (no Ollama needed)')
@click.option('--verbose', '-v', is_flag=True, help='Verbose output')
def extract_email_knowledge_cmd(
    email_source: str,
    output: Optional[str],
    limit: Optional[int],
    min_messages: int,
    ollama_host: str,
    model: str,
    qdrant_host: str,
    qdrant_port: int,
    collection: str,
    embedding_model: str,
    skip_embed: bool,
    threads_only: bool,
    verbose: bool,
):
    """
    Extract knowledge from email correspondence.

    Supports multiple formats (auto-detected):
    - MBOX files (Gmail exports)
    - EML files in directory (iCloud Mail, standard format)
    - Zip files containing EML files

    Processes emails, groups into threads, and uses LLM to
    extract knowledge (topics, decisions, advice, events).

    Examples:
        # Gmail MBOX
        python -m src.cli extract-email-knowledge ~/mail.mbox -o knowledge.json

        # iCloud Mail (zip file)
        python -m src.cli extract-email-knowledge ~/Mailboxes.zip --limit 100

        # Directory of EML files
        python -m src.cli extract-email-knowledge ~/emails/ -o knowledge.json
    """
    import asyncio

    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Detect source type
    source_path = Path(email_source)
    if source_path.suffix.lower() == '.mbox':
        source_type = "MBOX (Gmail)"
    elif source_path.suffix.lower() == '.zip':
        source_type = "ZIP (EML files)"
    elif source_path.is_dir():
        source_type = "Directory (EML files)"
    else:
        source_type = "Unknown (trying MBOX)"

    click.echo(f"\n{'='*60}", err=True)
    click.echo("CM024 - Extract Email Knowledge", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"Source: {email_source}", err=True)
    click.echo(f"Type: {source_type}", err=True)
    click.echo(f"Min messages per thread: {min_messages}", err=True)
    if threads_only:
        click.echo(f"Mode: THREADS ONLY (no Ollama)", err=True)
    else:
        click.echo(f"Ollama: {ollama_host}", err=True)
        click.echo(f"Model: {model}", err=True)
        if not skip_embed:
            click.echo(f"Qdrant: {qdrant_host}:{qdrant_port}/{collection}", err=True)
    click.echo(f"{'='*60}\n", err=True)

    asyncio.run(_run_email_knowledge_extraction(
        email_source=email_source,
        output=output,
        limit=limit,
        min_messages=min_messages,
        ollama_host=ollama_host,
        model=model,
        qdrant_host=qdrant_host,
        qdrant_port=qdrant_port,
        collection=collection,
        embedding_model=embedding_model,
        skip_embed=skip_embed,
        threads_only=threads_only,
        verbose=verbose,
    ))


async def _run_email_knowledge_extraction(
    email_source: str,
    output: Optional[str],
    limit: Optional[int],
    min_messages: int,
    ollama_host: str,
    model: str,
    qdrant_host: str,
    qdrant_port: int,
    collection: str,
    embedding_model: str,
    skip_embed: bool,
    threads_only: bool,
    verbose: bool,
):
    """Execute email knowledge extraction pipeline."""
    import json
    import time

    from .knowledge import EmailProcessor, EmailSummarizer, ThreadKnowledge
    from .ingestion.embedder import Embedder
    from .storage.qdrant_store import QdrantStore

    start_time = time.time()

    # Phase 1: Process email source and extract correspondence threads
    click.echo("[1/4] Processing email source...", err=True)

    processor = EmailProcessor()

    def progress_cb(count: int):
        click.echo(f"  Processed {count:,} emails...", err=True)

    # Auto-detect format (MBOX, EML directory, or zip)
    threads = processor.process(
        email_source,
        limit=limit,
        min_thread_messages=min_messages,
        progress_callback=progress_cb,
    )

    click.echo(f"  Found {len(threads):,} correspondence threads", err=True)
    click.echo(f"  Stats: {processor.stats}", err=True)

    if not threads:
        click.echo("No threads found. Exiting.", err=True)
        return

    # threads_only mode: save raw threads and exit
    if threads_only:
        if output:
            click.echo(f"\n[2/2] Saving {len(threads):,} raw threads to {output}...", err=True)
            with open(output, 'w') as f:
                json.dump({
                    'mode': 'threads_only',
                    'source': email_source,
                    'stats': {
                        'total_read': processor.stats.total_read,
                        'correspondence_found': processor.stats.correspondence_found,
                        'threads_created': processor.stats.threads_created,
                    },
                    'threads': [t.to_dict() for t in threads]
                }, f, indent=2)
            click.echo(f"  Saved {len(threads):,} threads", err=True)
        else:
            click.echo("\n[2/2] No output file specified, skipping save", err=True)

        duration = time.time() - start_time
        click.echo(f"\n{'='*60}", err=True)
        click.echo("THREAD EXTRACTION COMPLETE (no LLM)", err=True)
        click.echo(f"{'='*60}", err=True)
        click.echo(f"  Emails processed: {processor.stats.total_read:,}", err=True)
        click.echo(f"  Correspondence found: {processor.stats.correspondence_found:,}", err=True)
        click.echo(f"  Threads saved: {len(threads):,}", err=True)
        click.echo(f"  Duration: {duration:.1f}s", err=True)
        click.echo(f"\nRun without --threads-only to summarize with LLM", err=True)
        return

    # Phase 2: Summarize threads with LLM
    click.echo(f"\n[2/4] Summarizing threads with {model}...", err=True)

    summarizer = EmailSummarizer(ollama_host=ollama_host, model=model)

    knowledge_items: list[ThreadKnowledge] = []

    for i, thread in enumerate(threads):
        try:
            knowledge = await summarizer.summarize_thread(thread)
            knowledge_items.append(knowledge)

            if (i + 1) % 10 == 0 or (i + 1) == len(threads):
                click.echo(f"  Summarized {i + 1:,} / {len(threads):,} threads", err=True)

        except Exception as e:
            logger.error(f"Failed to summarize thread {thread.thread_id}: {e}")
            if verbose:
                import traceback
                traceback.print_exc()

    click.echo(f"  Summarization stats: {summarizer.stats}", err=True)

    # Phase 3: Save to JSON (always do this)
    if output:
        click.echo(f"\n[3/4] Saving to {output}...", err=True)
        with open(output, 'w') as f:
            json.dump([k.to_dict() for k in knowledge_items], f, indent=2)
        click.echo(f"  Saved {len(knowledge_items):,} knowledge items", err=True)
    else:
        click.echo(f"\n[3/4] No output file specified, skipping save", err=True)

    # Phase 4: Embed and store in Qdrant
    if not skip_embed:
        click.echo(f"\n[4/4] Embedding and storing in Qdrant...", err=True)

        # Initialize embedder and store
        embedder = Embedder(
            provider='ollama',
            model=embedding_model,
            ollama_host=ollama_host,
        )

        store = QdrantStore(
            host=qdrant_host,
            port=qdrant_port,
            collection=collection,
            vector_size=384,  # all-minilm
        )

        if not await store.initialize():
            click.echo("Failed to initialize Qdrant. Is it running?", err=True)
            return

        vectors_stored = 0
        for i, knowledge in enumerate(knowledge_items):
            try:
                # Get text for embedding
                text = knowledge.get_text_for_embedding()
                if not text or len(text) < 10:
                    continue

                # Generate embedding
                embedding = await embedder.embed(text)
                if embedding is None:
                    continue

                # Store in Qdrant
                success = await store.upsert(
                    note_id=knowledge.thread_id,
                    chunk_index=0,  # One chunk per thread
                    vector=embedding,
                    content=text,
                    title=knowledge.subject,
                    tags=knowledge.topics[:5],  # Use topics as tags
                    compartment_level=knowledge.privacy_level,
                    created_at=knowledge.date_range_end,
                )

                if success:
                    vectors_stored += 1

            except Exception as e:
                logger.error(f"Failed to embed thread {knowledge.thread_id}: {e}")

            if (i + 1) % 50 == 0:
                click.echo(f"  Embedded {i + 1:,} / {len(knowledge_items):,}", err=True)

        click.echo(f"  Stored {vectors_stored:,} vectors in Qdrant", err=True)
    else:
        click.echo(f"\n[4/4] Skipping embedding (--skip-embed)", err=True)

    # Summary
    duration = time.time() - start_time
    click.echo(f"\n{'='*60}", err=True)
    click.echo("EXTRACTION COMPLETE", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"  Emails processed: {processor.stats.total_read:,}", err=True)
    click.echo(f"  Correspondence found: {processor.stats.correspondence_found:,}", err=True)
    click.echo(f"  Threads created: {len(threads):,}", err=True)
    click.echo(f"  Knowledge extracted: {len(knowledge_items):,}", err=True)
    click.echo(f"  Duration: {duration:.1f}s", err=True)


@cli.command('summarize-threads')
@click.argument('threads_json', type=click.Path(exists=True))
@click.option('-o', '--output', type=click.Path(), help='Output JSON file for knowledge')
@click.option('--provider', default='ollama', type=click.Choice(['ollama', 'gemini']), help='LLM provider')
@click.option('--ollama-host', default=_default_ollama_url, help='Ollama server URL (env: OSTLER_OLLAMA_URL, default http://localhost:11434)')
@click.option('--model', default='gemma2:2b', help='LLM model for summarization')
@click.option('--gemini-key', envvar='GEMINI_API_KEY', help='Gemini API key (or set GEMINI_API_KEY env var)')
@click.option('--verbose', '-v', is_flag=True, help='Verbose output')
def summarize_threads_cmd(
    threads_json: str,
    output: Optional[str],
    provider: str,
    ollama_host: str,
    model: str,
    gemini_key: Optional[str],
    verbose: bool,
):
    """
    Summarize pre-extracted email threads with LLM.

    Loads threads from JSON (created with --threads-only) and runs
    LLM summarization to extract knowledge.

    Examples:
        # Using Ollama (local)
        python -m src.cli summarize-threads output/icloud_threads.json -o output/icloud_knowledge.json

        # Using Gemini (fast, cheap API)
        python -m src.cli summarize-threads output/icloud_threads.json -o output/icloud_knowledge.json \\
            --provider gemini --model gemini-1.5-flash --gemini-key YOUR_KEY
    """
    import asyncio

    if provider == 'gemini' and not gemini_key:
        raise click.ClickException("--gemini-key required when using --provider gemini")

    if verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    asyncio.run(_run_summarize_threads(
        threads_json=threads_json,
        output=output,
        provider=provider,
        ollama_host=ollama_host,
        model=model,
        gemini_key=gemini_key,
        verbose=verbose,
    ))


async def _run_summarize_threads(
    threads_json: str,
    output: Optional[str],
    provider: str,
    ollama_host: str,
    model: str,
    gemini_key: Optional[str],
    verbose: bool,
):
    """Execute thread summarization."""
    import json
    import time

    from .knowledge import EmailSummarizer, ThreadKnowledge
    from .knowledge.thread_aggregator import EmailThread, EmailMessage

    start_time = time.time()

    # Load threads from JSON
    click.echo(f"\n{'='*60}", err=True)
    click.echo("CM024 - Summarize Email Threads", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"Input: {threads_json}", err=True)
    click.echo(f"Provider: {provider}", err=True)
    if provider == 'gemini':
        click.echo(f"Model: {model}", err=True)
    else:
        click.echo(f"Ollama: {ollama_host}", err=True)
        click.echo(f"Model: {model}", err=True)
    click.echo(f"{'='*60}\n", err=True)

    click.echo("[1/2] Loading threads from JSON...", err=True)

    with open(threads_json, 'r') as f:
        data = json.load(f)

    # Handle both formats: list of threads or dict with 'threads' key
    if isinstance(data, dict) and 'threads' in data:
        threads_data = data['threads']
        source = data.get('source', 'unknown')
        click.echo(f"  Source: {source}", err=True)
    else:
        threads_data = data

    # Reconstruct EmailThread objects
    threads = []
    for td in threads_data:
        thread = EmailThread(
            thread_id=td['thread_id'],
            subject=td['subject'],
            normalized_subject=td['normalized_subject'],
        )
        thread.participants = td.get('participants', [])
        thread.message_count = td.get('message_count', 0)
        thread.total_body_length = td.get('total_body_length', 0)

        # Parse dates
        if td.get('date_range_start'):
            from datetime import datetime
            try:
                thread.date_range_start = datetime.fromisoformat(td['date_range_start'])
            except:
                pass
        if td.get('date_range_end'):
            try:
                thread.date_range_end = datetime.fromisoformat(td['date_range_end'])
            except:
                pass

        # Reconstruct messages
        for md in td.get('messages', []):
            msg = EmailMessage(
                message_id=md['message_id'],
                from_address=md['from_address'],
                from_name=md.get('from_name'),
                to_addresses=md.get('to_addresses', []),
                cc_addresses=md.get('cc_addresses', []),
                subject=md['subject'],
                date=datetime.fromisoformat(md['date']) if md.get('date') else None,
                body=md.get('body_preview', ''),  # We only have preview in JSON
                is_sent=md.get('is_sent', False),
            )
            thread.messages.append(msg)

        threads.append(thread)

    click.echo(f"  Loaded {len(threads):,} threads", err=True)

    # Summarize with LLM
    click.echo(f"\n[2/2] Summarizing with {provider}/{model}...", err=True)

    summarizer = EmailSummarizer(
        ollama_host=ollama_host,
        model=model,
        provider=provider,
        gemini_api_key=gemini_key,
    )
    knowledge_items: list[ThreadKnowledge] = []

    for i, thread in enumerate(threads):
        try:
            knowledge = await summarizer.summarize_thread(thread)
            knowledge_items.append(knowledge)

            if (i + 1) % 10 == 0 or (i + 1) == len(threads):
                click.echo(f"  Summarized {i + 1:,} / {len(threads):,} threads", err=True)

        except Exception as e:
            logger.error(f"Failed to summarize thread {thread.thread_id}: {e}")
            if verbose:
                import traceback
                traceback.print_exc()

    click.echo(f"  Summarization stats: {summarizer.stats}", err=True)

    # Save to JSON
    if output:
        click.echo(f"\nSaving to {output}...", err=True)
        with open(output, 'w') as f:
            json.dump([k.to_dict() for k in knowledge_items], f, indent=2)
        click.echo(f"  Saved {len(knowledge_items):,} knowledge items", err=True)

    # Summary
    duration = time.time() - start_time
    click.echo(f"\n{'='*60}", err=True)
    click.echo("SUMMARIZATION COMPLETE", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"  Threads processed: {len(threads):,}", err=True)
    click.echo(f"  Knowledge extracted: {len(knowledge_items):,}", err=True)
    click.echo(f"  Duration: {duration:.1f}s", err=True)


@cli.command('find-duplicates')
@click.option('--qdrant-host', default=_default_qdrant_host, help='Qdrant host (env: OSTLER_QDRANT_URL is parsed for host+port; default http://localhost:6333)')
@click.option('--qdrant-port', default=_default_qdrant_port, type=int, help='Qdrant port (env: OSTLER_QDRANT_URL is parsed for host+port)')
@click.option('--collection', default='evernote_knowledge', help='Qdrant collection name')
@click.option('--verbose', '-v', is_flag=True, help='Show details for each duplicate group')
def find_duplicates_cmd(
    qdrant_host: str,
    qdrant_port: int,
    collection: str,
    verbose: bool,
):
    """
    Find duplicate notes in the Qdrant collection.

    Scans the collection and identifies notes with identical content
    (based on content hash). Reports duplicate groups.

    Example:
        python -m src.cli find-duplicates
        python -m src.cli find-duplicates --collection evernote_knowledge -v
    """
    import asyncio

    asyncio.run(_run_find_duplicates(
        qdrant_host=qdrant_host,
        qdrant_port=qdrant_port,
        collection=collection,
        verbose=verbose,
    ))


async def _run_find_duplicates(
    qdrant_host: str,
    qdrant_port: int,
    collection: str,
    verbose: bool,
):
    """Execute duplicate finding."""
    from qdrant_client import QdrantClient

    click.echo(f"\n{'='*60}", err=True)
    click.echo("CM024 - Find Duplicate Notes", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"Qdrant: {qdrant_host}:{qdrant_port}/{collection}", err=True)
    click.echo(f"{'='*60}\n", err=True)

    qdrant_client = QdrantClient(host=qdrant_host, port=qdrant_port)

    duplicates = await find_duplicates(qdrant_client, collection)

    if not duplicates:
        click.echo("No duplicates found!", err=True)
        return

    click.echo(f"\nFound {len(duplicates):,} duplicate groups:\n", err=True)

    total_duplicate_notes = 0
    for i, group in enumerate(duplicates, 1):
        total_duplicate_notes += group.count - 1  # Exclude primary

        if verbose:
            click.echo(f"\nGroup {i}: {group.count} copies", err=True)
            primary_idx = group.note_ids.index(group.get_primary())
            for j, (note_id, title, chunks) in enumerate(zip(
                group.note_ids, group.titles, group.chunk_counts
            )):
                marker = " [PRIMARY]" if j == primary_idx else ""
                click.echo(f"  - {title[:50]}... ({chunks} chunks){marker}", err=True)
        else:
            if i <= 10:
                click.echo(f"  {i}. {group.titles[0][:50]}... ({group.count} copies)", err=True)

    if not verbose and len(duplicates) > 10:
        click.echo(f"  ... and {len(duplicates) - 10} more groups", err=True)

    click.echo(f"\n{'='*60}", err=True)
    click.echo("SUMMARY", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"  Duplicate groups: {len(duplicates):,}", err=True)
    click.echo(f"  Notes that can be removed: {total_duplicate_notes:,}", err=True)
    click.echo(f"\nRun 'remove-duplicates' to clean up.", err=True)


@cli.command('remove-duplicates')
@click.option('--qdrant-host', default=_default_qdrant_host, help='Qdrant host (env: OSTLER_QDRANT_URL is parsed for host+port; default http://localhost:6333)')
@click.option('--qdrant-port', default=_default_qdrant_port, type=int, help='Qdrant port (env: OSTLER_QDRANT_URL is parsed for host+port)')
@click.option('--collection', default='evernote_knowledge', help='Qdrant collection name')
@click.option('--dry-run', is_flag=True, default=True, help='Only show what would be deleted (default)')
@click.option('--execute', is_flag=True, help='Actually delete duplicates')
@click.option('--verbose', '-v', is_flag=True, help='Show details for each deletion')
def remove_duplicates_cmd(
    qdrant_host: str,
    qdrant_port: int,
    collection: str,
    dry_run: bool,
    execute: bool,
    verbose: bool,
):
    """
    Remove duplicate notes from the Qdrant collection.

    Keeps the most complete version (most chunks) and removes duplicates.

    By default, runs in dry-run mode. Use --execute to actually delete.

    Example:
        # See what would be deleted
        python -m src.cli remove-duplicates

        # Actually delete duplicates
        python -m src.cli remove-duplicates --execute
    """
    import asyncio

    # execute flag overrides dry_run
    actual_dry_run = not execute

    asyncio.run(_run_remove_duplicates(
        qdrant_host=qdrant_host,
        qdrant_port=qdrant_port,
        collection=collection,
        dry_run=actual_dry_run,
        verbose=verbose,
    ))


async def _run_remove_duplicates(
    qdrant_host: str,
    qdrant_port: int,
    collection: str,
    dry_run: bool,
    verbose: bool,
):
    """Execute duplicate removal."""
    from qdrant_client import QdrantClient

    mode = "DRY RUN" if dry_run else "EXECUTING"

    click.echo(f"\n{'='*60}", err=True)
    click.echo(f"CM024 - Remove Duplicate Notes ({mode})", err=True)
    click.echo(f"{'='*60}", err=True)
    click.echo(f"Qdrant: {qdrant_host}:{qdrant_port}/{collection}", err=True)
    click.echo(f"{'='*60}\n", err=True)

    qdrant_client = QdrantClient(host=qdrant_host, port=qdrant_port)

    # Find duplicates first
    click.echo("Finding duplicates...", err=True)
    duplicates = await find_duplicates(qdrant_client, collection)

    if not duplicates:
        click.echo("No duplicates found!", err=True)
        return

    click.echo(f"Found {len(duplicates):,} duplicate groups", err=True)

    # Remove duplicates
    if verbose:
        # Set logging level to see individual deletions
        logging.getLogger('src.ingestion.incremental').setLevel(logging.INFO)

    removed = await remove_duplicates(
        qdrant_client,
        collection,
        duplicates,
        dry_run=dry_run,
    )

    click.echo(f"\n{'='*60}", err=True)
    action = "Would remove" if dry_run else "Removed"
    click.echo(f"{action} {removed:,} duplicate notes", err=True)

    if dry_run:
        click.echo("\nRun with --execute to actually delete.", err=True)


if __name__ == '__main__':
    cli()
