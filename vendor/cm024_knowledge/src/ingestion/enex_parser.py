"""
ENEX Parser - Parse Evernote export files.

Handles large ENEX files (2GB+) using iterative XML parsing.
Extracts note metadata and content, converting ENML to plain text.

Usage:
    parser = ENEXParser()
    for note in parser.parse("My Notes.enex"):
        print(note.title)
"""

import html
import logging
import re
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterator, List, Optional, Union
from xml.etree import ElementTree as ET

logger = logging.getLogger(__name__)


@dataclass
class ParsedNote:
    """Represents a parsed Evernote note."""

    title: str
    content: str  # Plain text content (ENML stripped)
    content_html: str  # Original HTML/ENML for preservation
    created: Optional[datetime] = None
    updated: Optional[datetime] = None
    tags: List[str] = field(default_factory=list)
    author: Optional[str] = None
    source_url: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    evernote_guid: Optional[str] = None

    # Attachments info (not the actual binary data)
    attachment_count: int = 0
    attachment_names: List[str] = field(default_factory=list)

    # Quality/importance score (0.0-1.0) for RAG retrieval boosting
    importance_score: float = 0.0

    @property
    def word_count(self) -> int:
        """Approximate word count of plain text content."""
        return len(self.content.split())


class ENEXParser:
    """
    Stream parser for Evernote ENEX export files.

    Uses iterative XML parsing to handle large files without loading
    the entire file into memory.
    """

    # Evernote timestamp format: YYYYMMDDTHHmmssZ
    TIMESTAMP_FORMAT = "%Y%m%dT%H%M%SZ"

    # Tags to strip from ENML content
    STRIP_TAGS = {
        'en-note', 'en-media', 'en-crypt', 'en-todo',
        'span', 'div', 'font', 'style'
    }

    # HTML entities that need decoding
    HTML_ENTITIES = {
        '&nbsp;': ' ',
        '&lt;': '<',
        '&gt;': '>',
        '&amp;': '&',
        '&quot;': '"',
        '&apos;': "'",
    }

    def __init__(self, extract_attachments: bool = False):
        """
        Initialize the ENEX parser.

        Args:
            extract_attachments: Whether to extract attachment info (slower)
        """
        self.extract_attachments = extract_attachments
        self._stats = {
            'total_notes': 0,
            'parsed_notes': 0,
            'error_notes': 0,
            'skipped_notes': 0,
        }

    def parse(self, file_path: Union[str, Path]) -> Iterator[ParsedNote]:
        """
        Parse an ENEX file and yield notes.

        Args:
            file_path: Path to .enex file

        Yields:
            ParsedNote objects
        """
        file_path = Path(file_path)
        if not file_path.exists():
            raise FileNotFoundError(f"ENEX file not found: {file_path}")

        logger.info(f"Parsing ENEX file: {file_path} ({file_path.stat().st_size / 1024 / 1024:.1f} MB)")

        # Use iterparse for memory efficiency
        context = ET.iterparse(str(file_path), events=('end',))

        for event, elem in context:
            if elem.tag == 'note':
                self._stats['total_notes'] += 1

                try:
                    note = self._parse_note(elem)
                    if note:
                        self._stats['parsed_notes'] += 1
                        yield note
                    else:
                        self._stats['skipped_notes'] += 1

                except Exception as e:
                    self._stats['error_notes'] += 1
                    logger.warning(f"Error parsing note #{self._stats['total_notes']}: {e}")

                # Clear element to free memory
                elem.clear()

        logger.info(
            f"Parsing complete: {self._stats['parsed_notes']} notes parsed, "
            f"{self._stats['error_notes']} errors, {self._stats['skipped_notes']} skipped"
        )

    def _parse_note(self, elem: ET.Element) -> Optional[ParsedNote]:
        """Parse a single <note> element."""

        # Required: title
        title_elem = elem.find('title')
        if title_elem is None or not title_elem.text:
            logger.debug("Skipping note without title")
            return None

        title = title_elem.text.strip()

        # Content (ENML format)
        content_elem = elem.find('content')
        content_html = ""
        content_text = ""

        if content_elem is not None and content_elem.text:
            content_html = content_elem.text
            content_text = self._enml_to_text(content_html)

        # Skip empty notes
        if not content_text.strip():
            logger.debug(f"Skipping empty note: {title}")
            return None

        # Timestamps
        created = self._parse_timestamp(elem.findtext('created'))
        updated = self._parse_timestamp(elem.findtext('updated'))

        # Tags (can be multiple)
        tags = [tag.text for tag in elem.findall('tag') if tag.text]

        # Note attributes
        attrs = elem.find('note-attributes')
        author = None
        source_url = None
        latitude = None
        longitude = None

        if attrs is not None:
            author = attrs.findtext('author')
            source_url = attrs.findtext('source-url')

            lat_text = attrs.findtext('latitude')
            lon_text = attrs.findtext('longitude')
            if lat_text:
                try:
                    latitude = float(lat_text)
                except ValueError:
                    pass
            if lon_text:
                try:
                    longitude = float(lon_text)
                except ValueError:
                    pass

        # Attachments
        attachment_count = 0
        attachment_names = []

        if self.extract_attachments:
            for resource in elem.findall('resource'):
                attachment_count += 1
                res_attrs = resource.find('resource-attributes')
                if res_attrs is not None:
                    filename = res_attrs.findtext('file-name')
                    if filename:
                        attachment_names.append(filename)

        return ParsedNote(
            title=title,
            content=content_text,
            content_html=content_html,
            created=created,
            updated=updated,
            tags=tags,
            author=author,
            source_url=source_url,
            latitude=latitude,
            longitude=longitude,
            attachment_count=attachment_count,
            attachment_names=attachment_names,
        )

    def _parse_timestamp(self, ts_str: Optional[str]) -> Optional[datetime]:
        """Parse Evernote timestamp format (YYYYMMDDTHHmmssZ)."""
        if not ts_str:
            return None

        try:
            return datetime.strptime(ts_str, self.TIMESTAMP_FORMAT)
        except ValueError:
            logger.debug(f"Could not parse timestamp: {ts_str}")
            return None

    def _enml_to_text(self, enml: str) -> str:
        """
        Convert ENML/HTML content to plain text.

        Strips HTML tags, decodes entities, and normalizes whitespace.
        """
        if not enml:
            return ""

        # Extract content from CDATA if present
        cdata_match = re.search(r'<!\[CDATA\[(.*?)\]\]>', enml, re.DOTALL)
        if cdata_match:
            enml = cdata_match.group(1)

        # Remove XML declaration and DOCTYPE
        enml = re.sub(r'<\?xml[^>]*\?>', '', enml)
        enml = re.sub(r'<!DOCTYPE[^>]*>', '', enml)

        # Remove style blocks (including Evernote's display:none style divs)
        enml = re.sub(r'<style[^>]*>.*?</style>', '', enml, flags=re.DOTALL | re.IGNORECASE)
        enml = re.sub(r'<div[^>]*style="[^"]*display:\s*none[^"]*"[^>]*>.*?</div>', '', enml, flags=re.DOTALL | re.IGNORECASE)

        # Convert common block elements to newlines
        enml = re.sub(r'<br\s*/?>', '\n', enml, flags=re.IGNORECASE)
        enml = re.sub(r'</?(p|div|h[1-6]|li|tr)[^>]*>', '\n', enml, flags=re.IGNORECASE)

        # Convert list items
        enml = re.sub(r'<li[^>]*>', '\n- ', enml, flags=re.IGNORECASE)

        # Remove en-media tags (attachments) but note their presence
        enml = re.sub(r'<en-media[^>]*/?>', '[attachment]', enml, flags=re.IGNORECASE)

        # Remove en-todo (checkboxes)
        enml = re.sub(r'<en-todo[^>]*/>', '[ ] ', enml, flags=re.IGNORECASE)
        enml = re.sub(r'<en-todo[^>]*checked="true"[^>]*/>', '[x] ', enml, flags=re.IGNORECASE)

        # Remove all remaining HTML tags
        enml = re.sub(r'<[^>]+>', '', enml)

        # Decode HTML entities
        text = html.unescape(enml)

        # Normalize whitespace
        text = re.sub(r'\n\s*\n', '\n\n', text)  # Collapse multiple blank lines
        text = re.sub(r'[ \t]+', ' ', text)  # Collapse multiple spaces
        text = re.sub(r'\n ', '\n', text)  # Remove leading spaces on lines

        return text.strip()

    @property
    def stats(self) -> dict:
        """Get parsing statistics."""
        return self._stats.copy()

    def reset_stats(self):
        """Reset parsing statistics."""
        self._stats = {
            'total_notes': 0,
            'parsed_notes': 0,
            'error_notes': 0,
            'skipped_notes': 0,
        }


def count_notes(file_path: Union[str, Path]) -> int:
    """
    Quickly count notes in an ENEX file without full parsing.

    Args:
        file_path: Path to .enex file

    Returns:
        Number of <note> elements
    """
    file_path = Path(file_path)
    count = 0

    context = ET.iterparse(str(file_path), events=('end',))
    for event, elem in context:
        if elem.tag == 'note':
            count += 1
            elem.clear()

    return count


def sample_notes(file_path: Union[str, Path], n: int = 5) -> List[ParsedNote]:
    """
    Parse first N notes from an ENEX file.

    Args:
        file_path: Path to .enex file
        n: Number of notes to parse

    Returns:
        List of ParsedNote objects
    """
    parser = ENEXParser(extract_attachments=True)
    notes = []

    for note in parser.parse(file_path):
        notes.append(note)
        if len(notes) >= n:
            break

    return notes


if __name__ == "__main__":
    # Quick test
    import sys

    if len(sys.argv) < 2:
        print("Usage: python -m src.ingestion.enex_parser <file.enex> [--count]")
        sys.exit(1)

    file_path = sys.argv[1]

    if "--count" in sys.argv:
        count = count_notes(file_path)
        print(f"Notes in {file_path}: {count}")
    else:
        # Parse first 5 notes
        notes = sample_notes(file_path, 5)
        for i, note in enumerate(notes, 1):
            print(f"\n{'='*60}")
            print(f"Note {i}: {note.title}")
            print(f"Created: {note.created}")
            print(f"Tags: {note.tags}")
            print(f"Words: {note.word_count}")
            print(f"Content preview: {note.content[:200]}...")
