"""Transcript chunking for CM048.

When a transcript exceeds the enrichment model's context window, it
must be split. CM048 uses a speaker-turn-preserving chunker with a
2-sentence overlap between consecutive chunks so the model has
continuity context at chunk boundaries.

Rough budget for `qwen3.5:35b-a3b`: ~32K token context window. Our
full prompt envelope (conventions + classifier output + metadata +
prompt body) is roughly 3K tokens; we can afford ~25K tokens of
transcript per chunk, which at ~4 chars/token is ~100K chars. We
default `max_chars_per_chunk = 80000` to stay safe.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterator


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
    max_chars_per_chunk: int = 80_000,
    overlap_sentences: int = 2,
) -> list[Chunk]:
    """Split transcript into chunks, preserving speaker turn boundaries.

    If the transcript fits in one chunk, returns a single Chunk.
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
        # Find the furthest turn boundary we can include without exceeding max_chars
        end = _advance_to_boundary(
            cursor,
            cursor + max_chars_per_chunk,
            turn_boundaries,
        )
        if end <= cursor:
            # No turn boundary within range — hard-split at max_chars
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

        # Overlap: back up `overlap_sentences` sentences for context continuity.
        # Guard: must always advance at least 1 char past previous cursor to
        # prevent infinite looping when overlap walks back below cursor.
        overlap_start = _back_up_sentences(transcript, end, overlap_sentences)
        cursor = max(overlap_start, cursor + 1)

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
