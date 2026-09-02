"""
Semantic Chunker - Split notes into chunks for embedding.

Implements intelligent text splitting that respects document structure.
Chunks are sized for optimal embedding and retrieval.

Usage:
    chunker = SemanticChunker(max_tokens=512, overlap=50)
    chunks = chunker.chunk(text)
"""

import logging
import re
from dataclasses import dataclass
from typing import List, Optional

logger = logging.getLogger(__name__)


@dataclass
class Chunk:
    """Represents a text chunk."""

    text: str
    index: int  # Position in original document
    start_char: int  # Character offset
    end_char: int  # Character offset
    token_count: int

    @property
    def word_count(self) -> int:
        return len(self.text.split())


class SemanticChunker:
    """
    Intelligent text chunker that respects document structure.

    Splitting strategy:
    1. Try to split on section boundaries (headers, blank lines)
    2. Fall back to paragraph boundaries
    3. Fall back to sentence boundaries
    4. Last resort: character-based split

    Ensures chunks don't exceed max_tokens and have overlap for context.
    """

    # Patterns for splitting (in order of preference)
    HEADER_PATTERN = re.compile(r'^#+\s+.+$', re.MULTILINE)
    BLANK_LINE_PATTERN = re.compile(r'\n\s*\n')
    SENTENCE_PATTERN = re.compile(r'(?<=[.!?])\s+')

    def __init__(
        self,
        max_tokens: int = 512,
        min_tokens: int = 50,
        overlap_tokens: int = 50,
        tokenizer: str = "simple",  # or "tiktoken"
    ):
        """
        Initialize the chunker.

        Args:
            max_tokens: Maximum tokens per chunk
            min_tokens: Minimum tokens (avoid tiny chunks)
            overlap_tokens: Overlap between chunks for context
            tokenizer: Tokenizer to use ("simple" or "tiktoken")
        """
        self.max_tokens = max_tokens
        self.min_tokens = min_tokens
        self.overlap_tokens = overlap_tokens
        self.tokenizer = tokenizer

        # Token estimator
        self._tokens_per_word = 1.3  # Rough estimate

        # Stats
        self._stats = {
            'documents_chunked': 0,
            'total_chunks': 0,
            'avg_chunk_size': 0,
        }

    def chunk(self, text: str, title: str = "") -> List[Chunk]:
        """
        Split text into chunks.

        Args:
            text: Text to chunk
            title: Optional title to include in first chunk

        Returns:
            List of Chunk objects
        """
        if not text or not text.strip():
            return []

        self._stats['documents_chunked'] += 1

        # Prepend title if provided
        if title:
            text = f"# {title}\n\n{text}"

        # Estimate if we even need to chunk
        estimated_tokens = self._estimate_tokens(text)
        if estimated_tokens <= self.max_tokens:
            chunk = Chunk(
                text=text.strip(),
                index=0,
                start_char=0,
                end_char=len(text),
                token_count=estimated_tokens,
            )
            self._stats['total_chunks'] += 1
            return [chunk]

        # Split into initial segments
        segments = self._split_into_segments(text)

        # Merge small segments and split large ones
        chunks = self._create_chunks(segments)

        self._stats['total_chunks'] += len(chunks)

        return chunks

    def _estimate_tokens(self, text: str) -> int:
        """Estimate token count for text."""
        if self.tokenizer == "tiktoken":
            try:
                import tiktoken
                enc = tiktoken.get_encoding("cl100k_base")
                return len(enc.encode(text))
            except ImportError:
                pass

        # Simple estimation: words * factor
        words = len(text.split())
        return int(words * self._tokens_per_word)

    def _split_into_segments(self, text: str) -> List[str]:
        """Split text into logical segments."""
        segments = []

        # First try splitting on headers
        parts = self.HEADER_PATTERN.split(text)
        headers = self.HEADER_PATTERN.findall(text)

        if len(headers) > 1:
            # Re-attach headers to following content
            result = []
            for i, part in enumerate(parts):
                if part.strip():
                    if i > 0 and i - 1 < len(headers):
                        result.append(headers[i - 1] + "\n" + part)
                    else:
                        result.append(part)
            if result:
                segments = result

        if not segments:
            # Fall back to paragraph splitting
            segments = self.BLANK_LINE_PATTERN.split(text)

        # Filter empty segments
        segments = [s.strip() for s in segments if s.strip()]

        return segments

    def _create_chunks(self, segments: List[str]) -> List[Chunk]:
        """Create properly sized chunks from segments."""
        chunks = []
        current_text = ""
        current_start = 0
        char_offset = 0

        for segment in segments:
            segment_tokens = self._estimate_tokens(segment)

            # If segment alone exceeds max, split it further
            if segment_tokens > self.max_tokens:
                # Flush current chunk first
                if current_text:
                    chunks.append(self._make_chunk(
                        current_text,
                        len(chunks),
                        current_start,
                        char_offset,
                    ))
                    current_text = ""

                # Split large segment by sentences
                sub_chunks = self._split_large_segment(segment, char_offset)
                chunks.extend(sub_chunks)
                char_offset += len(segment)
                current_start = char_offset
                continue

            # Check if adding this segment exceeds max
            combined = current_text + "\n\n" + segment if current_text else segment
            combined_tokens = self._estimate_tokens(combined)

            if combined_tokens > self.max_tokens:
                # Save current chunk
                if current_text:
                    chunks.append(self._make_chunk(
                        current_text,
                        len(chunks),
                        current_start,
                        char_offset,
                    ))

                # Start new chunk, possibly with overlap
                overlap_text = self._get_overlap_text(current_text)
                current_text = overlap_text + segment if overlap_text else segment
                current_start = char_offset - len(overlap_text) if overlap_text else char_offset
            else:
                current_text = combined

            char_offset += len(segment) + 2  # +2 for paragraph break

        # Final chunk
        if current_text and self._estimate_tokens(current_text) >= self.min_tokens:
            chunks.append(self._make_chunk(
                current_text,
                len(chunks),
                current_start,
                char_offset,
            ))

        return chunks

    def _split_large_segment(self, text: str, offset: int) -> List[Chunk]:
        """Split a segment that's too large."""
        chunks = []

        # Split by sentences
        sentences = self.SENTENCE_PATTERN.split(text)
        current_text = ""
        current_start = offset

        for sentence in sentences:
            sentence = sentence.strip()
            if not sentence:
                continue

            combined = current_text + " " + sentence if current_text else sentence
            if self._estimate_tokens(combined) > self.max_tokens:
                if current_text:
                    chunks.append(self._make_chunk(
                        current_text,
                        len(chunks),
                        current_start,
                        offset + len(current_text),
                    ))
                    # Overlap
                    overlap = self._get_overlap_text(current_text)
                    current_text = overlap + sentence if overlap else sentence
                    current_start = offset
                else:
                    # Single sentence too long - force split
                    chunks.append(self._make_chunk(
                        sentence[:self.max_tokens * 4],  # Rough char limit
                        len(chunks),
                        current_start,
                        current_start + len(sentence),
                    ))
                    current_text = ""
            else:
                current_text = combined

        if current_text:
            chunks.append(self._make_chunk(
                current_text,
                len(chunks),
                current_start,
                offset + len(text),
            ))

        return chunks

    def _get_overlap_text(self, text: str) -> str:
        """Get overlap text from end of previous chunk."""
        if not text or self.overlap_tokens <= 0:
            return ""

        # Get last N words as overlap
        words = text.split()
        overlap_words = int(self.overlap_tokens / self._tokens_per_word)

        if len(words) > overlap_words:
            return " ".join(words[-overlap_words:]) + " "

        return ""

    def _make_chunk(
        self,
        text: str,
        index: int,
        start: int,
        end: int,
    ) -> Chunk:
        """Create a Chunk object."""
        return Chunk(
            text=text.strip(),
            index=index,
            start_char=start,
            end_char=end,
            token_count=self._estimate_tokens(text),
        )

    @property
    def stats(self) -> dict:
        """Get chunking statistics."""
        stats = self._stats.copy()
        if stats['total_chunks'] > 0:
            stats['avg_chunk_size'] = stats['total_chunks'] / max(stats['documents_chunked'], 1)
        return stats


def chunk_document(
    text: str,
    title: str = "",
    max_tokens: int = 512,
    overlap: int = 50,
) -> List[Chunk]:
    """
    Convenience function to chunk a single document.

    Args:
        text: Document text
        title: Optional title
        max_tokens: Maximum tokens per chunk
        overlap: Overlap tokens between chunks

    Returns:
        List of Chunk objects
    """
    chunker = SemanticChunker(max_tokens=max_tokens, overlap_tokens=overlap)
    return chunker.chunk(text, title)


if __name__ == "__main__":
    # Test the chunker
    import sys

    test_text = """
# Introduction

This is the introduction section. It contains some important context.

## Background

The background section provides historical information. This is a longer
paragraph that explains the context of the work. It might include multiple
sentences that together form a coherent thought.

## Methods

We used the following methods:
- Method A: Description of method A
- Method B: Description of method B
- Method C: Description of method C

### Sub-method Details

Each method has specific implementation details that are important to understand.

## Results

The results show that our approach was effective. We observed significant
improvements across all metrics. The data supports our hypothesis.

## Conclusion

In conclusion, this work demonstrates the value of our approach. Future work
should focus on expanding these findings.
"""

    print("Testing chunker with sample document...")
    print(f"Document length: {len(test_text)} chars")
    print()

    chunker = SemanticChunker(max_tokens=100, overlap_tokens=20)
    chunks = chunker.chunk(test_text, "Test Document")

    print(f"Generated {len(chunks)} chunks:")
    print()

    for chunk in chunks:
        print(f"Chunk {chunk.index}: {chunk.token_count} tokens, {chunk.word_count} words")
        print(f"  Preview: {chunk.text[:100]}...")
        print()
