"""
Markdown Writer - Convert parsed notes to Obsidian-compatible markdown.

Creates markdown files with YAML frontmatter for metadata.
Supports deduplication and incremental updates.

Usage:
    writer = MarkdownWriter("./data/obsidian-vault/evernote")
    writer.write(parsed_note)
"""

import logging
import re
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Union

import yaml

from .enex_parser import ParsedNote

logger = logging.getLogger(__name__)


class MarkdownWriter:
    """
    Write parsed notes to Obsidian-compatible markdown files.

    Creates files with YAML frontmatter containing metadata and
    clean markdown content.
    """

    def __init__(
        self,
        output_dir: Union[str, Path],
        create_subdirs: bool = True,
        overwrite: bool = False,
    ):
        """
        Initialize the markdown writer.

        Args:
            output_dir: Directory to write markdown files
            create_subdirs: Create year/month subdirectories
            overwrite: Overwrite existing files (default: skip)
        """
        self.output_dir = Path(output_dir)
        self.create_subdirs = create_subdirs
        self.overwrite = overwrite

        self._stats = {
            'written': 0,
            'skipped': 0,
            'errors': 0,
        }

        # Ensure output directory exists
        self.output_dir.mkdir(parents=True, exist_ok=True)

    def write(
        self,
        note: ParsedNote,
        compartment_level: int = 2,
        importance_score: float = 0.0,
    ) -> Optional[Path]:
        """
        Write a single note to markdown file.

        Args:
            note: ParsedNote object to write
            compartment_level: Privacy level (0-4), default 2 (personal)
            importance_score: RAG importance score (0.0-1.0), default 0.0

        Returns:
            Path to written file, or None if skipped/error
        """
        try:
            # Generate filename and path
            file_path = self._get_file_path(note)

            # Check if exists
            if file_path.exists() and not self.overwrite:
                logger.debug(f"Skipping existing file: {file_path}")
                self._stats['skipped'] += 1
                return None

            # Create directory if needed
            file_path.parent.mkdir(parents=True, exist_ok=True)

            # Generate markdown content
            content = self._generate_markdown(note, compartment_level, importance_score)

            # Write file
            file_path.write_text(content, encoding='utf-8')

            self._stats['written'] += 1
            logger.debug(f"Written: {file_path}")

            return file_path

        except Exception as e:
            logger.error(f"Error writing note '{note.title}': {e}")
            self._stats['errors'] += 1
            return None

    def write_batch(
        self,
        notes: List[ParsedNote],
        compartment_level: int = 2,
    ) -> List[Path]:
        """
        Write multiple notes.

        Args:
            notes: List of ParsedNote objects
            compartment_level: Default privacy level

        Returns:
            List of paths to written files
        """
        written_paths = []

        for note in notes:
            path = self.write(note, compartment_level)
            if path:
                written_paths.append(path)

        logger.info(
            f"Batch complete: {len(written_paths)} written, "
            f"{self._stats['skipped']} skipped, {self._stats['errors']} errors"
        )

        return written_paths

    def _get_file_path(self, note: ParsedNote) -> Path:
        """Generate file path for a note."""

        # Sanitize title for filename
        filename = self._sanitize_filename(note.title)

        # Limit filename length (filesystem limits)
        if len(filename) > 200:
            filename = filename[:200]

        # Add .md extension
        filename = f"{filename}.md"

        # Create subdirectory structure by date
        if self.create_subdirs and note.created:
            year = note.created.strftime("%Y")
            month = note.created.strftime("%m")
            return self.output_dir / year / month / filename
        else:
            return self.output_dir / filename

    def _sanitize_filename(self, title: str) -> str:
        """
        Convert title to safe filename.

        - Remove/replace invalid characters
        - Normalize unicode
        - Handle edge cases
        """
        if not title:
            return "untitled"

        # Normalize unicode
        filename = unicodedata.normalize('NFKD', title)

        # Replace problematic characters
        filename = re.sub(r'[<>:"/\\|?*]', '-', filename)
        filename = re.sub(r'[\x00-\x1f\x7f]', '', filename)  # Control chars

        # Replace multiple spaces/dashes with single
        filename = re.sub(r'[-\s]+', '-', filename)

        # Remove leading/trailing dashes and spaces
        filename = filename.strip('- ')

        # Avoid reserved names on Windows
        reserved = {'CON', 'PRN', 'AUX', 'NUL',
                    'COM1', 'COM2', 'COM3', 'COM4',
                    'LPT1', 'LPT2', 'LPT3', 'LPT4'}
        if filename.upper() in reserved:
            filename = f"_{filename}"

        return filename if filename else "untitled"

    def _generate_markdown(
        self,
        note: ParsedNote,
        compartment_level: int,
        importance_score: float = 0.0,
    ) -> str:
        """Generate markdown content with YAML frontmatter."""

        # Build frontmatter
        frontmatter = {
            'title': note.title,
            'source': 'evernote',
            'compartment_level': compartment_level,
            'importance_score': round(importance_score, 3),
        }

        if note.created:
            frontmatter['created'] = note.created.isoformat()
        if note.updated:
            frontmatter['updated'] = note.updated.isoformat()
        if note.tags:
            frontmatter['tags'] = note.tags
        if note.author:
            frontmatter['author'] = note.author
        if note.source_url:
            frontmatter['source_url'] = note.source_url
        if note.evernote_guid:
            frontmatter['evernote_guid'] = note.evernote_guid
        if note.latitude and note.longitude:
            frontmatter['location'] = {
                'latitude': note.latitude,
                'longitude': note.longitude,
            }

        # Process content
        content = self._process_content(note.content)

        # Build final markdown
        yaml_str = yaml.dump(
            frontmatter,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,
        )

        return f"---\n{yaml_str}---\n\n{content}"

    def _process_content(self, content: str) -> str:
        """
        Process plain text content for markdown.

        - Convert obvious formatting
        - Clean up whitespace
        - Handle special cases
        """
        if not content:
            return ""

        # Already mostly clean from ENEX parser
        # Add any additional processing here

        # Ensure consistent line endings
        content = content.replace('\r\n', '\n').replace('\r', '\n')

        # Remove excessive blank lines (more than 2)
        content = re.sub(r'\n{4,}', '\n\n\n', content)

        return content.strip()

    @property
    def stats(self) -> dict:
        """Get writing statistics."""
        return self._stats.copy()

    def reset_stats(self):
        """Reset statistics."""
        self._stats = {
            'written': 0,
            'skipped': 0,
            'errors': 0,
        }


def convert_enex_to_markdown(
    enex_path: Union[str, Path],
    output_dir: Union[str, Path],
    limit: Optional[int] = None,
    compartment_level: int = 2,
    overwrite: bool = False,
) -> dict:
    """
    Convert an ENEX file to markdown files.

    Convenience function combining ENEXParser and MarkdownWriter.

    Args:
        enex_path: Path to .enex file
        output_dir: Directory for markdown output
        limit: Maximum notes to process (None = all)
        compartment_level: Default privacy level
        overwrite: Overwrite existing files

    Returns:
        Statistics dict with counts
    """
    from .enex_parser import ENEXParser

    parser = ENEXParser()
    writer = MarkdownWriter(output_dir, overwrite=overwrite)

    count = 0
    for note in parser.parse(enex_path):
        writer.write(note, compartment_level)
        count += 1

        if limit and count >= limit:
            logger.info(f"Reached limit of {limit} notes")
            break

    return {
        'parsed': parser.stats,
        'written': writer.stats,
    }


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 3:
        print("Usage: python -m src.ingestion.markdown_writer <input.enex> <output_dir> [--limit N]")
        sys.exit(1)

    enex_path = sys.argv[1]
    output_dir = sys.argv[2]
    limit = None

    if "--limit" in sys.argv:
        idx = sys.argv.index("--limit")
        if idx + 1 < len(sys.argv):
            limit = int(sys.argv[idx + 1])

    logging.basicConfig(level=logging.INFO)

    print(f"Converting {enex_path} -> {output_dir}")
    if limit:
        print(f"Limit: {limit} notes")

    stats = convert_enex_to_markdown(enex_path, output_dir, limit=limit)

    print(f"\nResults:")
    print(f"  Parsed: {stats['parsed']['parsed_notes']}")
    print(f"  Written: {stats['written']['written']}")
    print(f"  Skipped: {stats['written']['skipped']}")
    print(f"  Errors: {stats['written']['errors']}")
