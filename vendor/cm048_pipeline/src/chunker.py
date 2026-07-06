"""Transcript chunking for CM048.

When a transcript exceeds the enrichment model's context window, it
must be split. CM048 uses a speaker-turn-preserving chunker with a
2-sentence overlap between consecutive chunks so the model has
continuity context at chunk boundaries.

Rough budget for `qwen3.5:35b-a3b`: ~32K token context window. Our
full prompt envelope (conventions + classifier output + metadata +
prompt body) is roughly 3K tokens; we can afford ~25K tokens of
transcript per chunk. Prose runs ~4 chars/token but machine-generated
content (URLs, tables, tracking links in email digests) and chat text
heavy with emoji/CJK/links can run as low as ~2.3 chars/token
(measured: a 65,571-char WhatsApp chunk prefilled as 27,863 tokens).
The chunk size must leave decode room inside the window too -- the
enrichment call generates until done, and a 28k-token prompt left only
~4k tokens of decode before the context filled (observed truncated=1).
We default `max_chars_per_chunk = 48000` (~21k tokens worst case +
3k envelope, leaving ~9k decode headroom).

Runaway guards (2026-07-07): a machine-generated transcript with no
sentence punctuation used to make the overlap back-up return offset 0,
so the cursor advanced ONE character per chunk and a 119 KB email
became ~39,000 overlapping 39k-token LLM calls (4.7 days of a pegged
Ollama slot before it was killed). The overlap is now bounded in
characters, forward progress is guaranteed per chunk, and the total
chunk count is hard-capped.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterator

# Hard ceiling on chunks per transcript. A transcript needing more than
# this many LLM calls is not a conversation worth enriching wholesale;
# the processor fails it permanently (dead-letter path) rather than
# occupying the shared Ollama slot for hours.
MAX_CHUNKS = 24

# The overlap exists to give the model continuity at a boundary, not to
# re-read the previous chunk. Bounding it in characters guarantees the
# cursor advances by at least (chunk size - overlap) each iteration no
# matter what the sentence scan returns.
MAX_OVERLAP_CHARS = 1_000

# Default chunk size in characters (see module docstring for the sums).
DEFAULT_MAX_CHARS_PER_CHUNK = 48_000


class TranscriptTooLargeError(ValueError):
    """Transcript would need more than MAX_CHUNKS chunks.

    Deliberately permanent: retrying cannot shrink the input, so the
    processor must fail (and eventually dead-letter) the job instead of
    looping.
    """


@dataclass
class Chunk:
    index: int
    total: int
    content: str
    char_start: int
    char_end: int


_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")
_SPEAKER_LINE = re.compile(r"^\s*(?:\*\*)?\[?[A-Z][^:\n]{0,40}\]?(?:\*\*)?\s*:\s", re.MULTILINE)


def chunk_transcript(
    transcript: str,
    *,
    max_chars_per_chunk: int = DEFAULT_MAX_CHARS_PER_CHUNK,
    overlap_sentences: int = 2,
    max_chunks: int = MAX_CHUNKS,
) -> list[Chunk]:
    """Split transcript into chunks, preserving speaker turn boundaries.

    If the transcript fits in one chunk, returns a single Chunk.

    Raises TranscriptTooLargeError if the transcript would need more
    than ``max_chunks`` chunks (permanent failure; see module note).
    """
    transcript = transcript.strip()
    if len(transcript) <= max_chars_per_chunk:
        return [
            Chunk(
                index=0,
                total=1,
                content=transcript,
                char_start=0,
                char_end=len(transcript),
            )
        ]

    turn_boundaries = _find_turn_boundaries(transcript)
    chunks: list[Chunk] = []
    idx = 0
    cursor = 0
    n_boundaries = len(turn_boundaries)

    while cursor < len(transcript):
        if idx >= max_chunks:
            raise TranscriptTooLargeError(
                f"transcript of {len(transcript):,} chars needs more than "
                f"{max_chunks} chunks of {max_chars_per_chunk:,} chars; "
                "refusing to enrich (permanent, will not retry)"
            )
        # Find the furthest turn boundary we can include without exceeding max_chars
        end = _advance_to_boundary(
            cursor,
            cursor + max_chars_per_chunk,
            turn_boundaries,
        )
        # A boundary too close to the cursor (or none at all) degrades to
        # a hard split at max_chars: a degenerate boundary layout must not
        # produce sliver chunks, because each chunk is one LLM call.
        if end - cursor < max_chars_per_chunk // 4:
            end = min(cursor + max_chars_per_chunk, len(transcript))

        content = transcript[cursor:end]
        chunks.append(
            Chunk(
                index=idx,
                total=-1,  # patched below once we know total
                content=content,
                char_start=cursor,
                char_end=end,
            )
        )
        idx += 1
        if end >= len(transcript):
            break

        # Overlap: back up `overlap_sentences` sentences for context
        # continuity, but never more than MAX_OVERLAP_CHARS. The sentence
        # scan returns 0 on punctuation-free machine-generated text; left
        # unbounded that made the cursor advance one char per chunk (the
        # 2026-07 runaway). Forward progress per chunk is now at least
        # (end - cursor) - MAX_OVERLAP_CHARS.
        overlap_start = _back_up_sentences(transcript, end, overlap_sentences)
        cursor = max(overlap_start, end - MAX_OVERLAP_CHARS, cursor + 1)

    # Patch totals
    total = len(chunks)
    chunks = [
        Chunk(
            index=c.index,
            total=total,
            content=c.content,
            char_start=c.char_start,
            char_end=c.char_end,
        )
        for c in chunks
    ]
    return chunks


def _find_turn_boundaries(transcript: str) -> list[int]:
    """Return character offsets of the start of each speaker turn."""
    return [m.start() for m in _SPEAKER_LINE.finditer(transcript)]


def _advance_to_boundary(
    start: int, limit: int, boundaries: list[int]
) -> int:
    """Return the largest boundary <= limit, or limit if none found in range."""
    best = start
    for b in boundaries:
        if start < b <= limit:
            best = b
    return best


def _back_up_sentences(transcript: str, from_offset: int, n: int) -> int:
    """Return the offset `n` sentences back from from_offset."""
    # Scan backwards for sentence-end marks
    sentence_ends = list(_SENTENCE_END.finditer(transcript[:from_offset]))
    if len(sentence_ends) <= n:
        return 0
    return sentence_ends[-n].end()


def describe(chunks: list[Chunk]) -> str:
    """Human-readable summary for logs."""
    if len(chunks) == 1:
        return f"1 chunk ({len(chunks[0].content):,} chars)"
    sizes = [len(c.content) for c in chunks]
    return (
        f"{len(chunks)} chunks (sizes: "
        + ", ".join(f"{s:,}" for s in sizes)
        + " chars)"
    )
