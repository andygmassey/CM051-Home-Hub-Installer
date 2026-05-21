"""Per-variant heading validation for enrichment outputs.

Each enrichment prompt under `prompts/02_enrich_*.md` declares its own set
of expected `## Heading` sections - work_one-on-one has 8, work_meeting has
9, family has 6, service_minimal has 3, etc. The model occasionally drops
or renames a section. This module:

- Captures the expected heading list per prompt name (single source of
  truth, kept in lockstep with the prompt files).
- Validates an enrichment markdown output against that list.
- Builds a variant-aware system prompt so the model receives the right
  heading list rather than the work_one-on-one one for every conversation
  shape.

Used by `processor._step_enrich` to detect drift, retry once with stricter
language, and log honestly when the second attempt also misses.
"""
from __future__ import annotations

import re
from dataclasses import dataclass


# Source of truth for the expected `## ` headings per enrichment prompt.
# Order matches the prompt-file declaration so consumers can render or
# compare ordered if they want; validation here only checks presence.
EXPECTED_HEADINGS_BY_PROMPT: dict[str, list[str]] = {
    "02_enrich_family": [
        "Summary",
        "Topics covered",
        "Practicalities",
        "Moments to remember",
        "People and places mentioned",
        "Cleaned transcript",
    ],
    "02_enrich_public_audience": [
        "Summary",
        "Key themes the speaker(s) presented",
        "Notable quotes from the speaker(s)",
        "Points worth remembering",
        "People and orgs encountered",
        "Follow-ups",
        "Selected transcript (speaker content)",
    ],
    "02_enrich_public_presentation": [
        "Summary",
        "Key themes presented",
        "Key quotes",
        "Q&A highlights",
        "Delivery observations",
        "Post-event commitments",
        "Cleaned transcript",
    ],
    "02_enrich_service_minimal": [
        "Service record",
        "Action items",
        "Notes",
    ],
    "02_enrich_social_casual": [
        "Summary",
        "Topics covered",
        "Notable moments",
        "Commitments",
        "People and places mentioned",
        "Cleaned transcript",
    ],
    "02_enrich_work_group-convo": [
        "Summary",
        "Topics covered",
        "Decisions",
        "Action items",
        "Notable moments",
        "People and orgs mentioned",
        "Cleaned transcript",
    ],
    "02_enrich_work_meeting": [
        "Summary",
        "Key topics",
        "Decisions",
        "Action items",
        "Communication dynamics",
        "Key quotes",
        "Key insights",
        "Next steps",
        "Cleaned transcript",
    ],
    "02_enrich_work_one-on-one": [
        "Summary",
        "Key topics",
        "Decisions",
        "Action items",
        "Key quotes",
        "Key insights",
        "Next steps",
        "Cleaned transcript",
    ],
    "02_enrich_email_thread": [
        "Summary",
        "Key topics",
        "Decisions",
        "Action items",
        "Key quotes",
        "Key insights",
        "Next steps",
        "Cleaned thread",
    ],
}


def expected_headings_for(prompt_name: str) -> list[str]:
    """Return the expected `## ` heading list for a prompt name.

    Falls back to work_one-on-one's list (the safest superset for
    work-shaped conversations) if the prompt name is unknown. Callers
    can still log the mismatch separately.
    """
    return EXPECTED_HEADINGS_BY_PROMPT.get(
        prompt_name,
        EXPECTED_HEADINGS_BY_PROMPT["02_enrich_work_one-on-one"],
    )


@dataclass
class HeadingValidation:
    ok: bool
    missing: list[str]
    extras: list[str]
    found: list[str]


def validate_headings(text: str, expected: list[str]) -> HeadingValidation:
    """Validate that every expected `## Heading` appears in `text`.

    Matching is case-insensitive and tolerates trailing whitespace, but
    requires the heading to be the full line content after the `## `.
    Headings inside fenced code blocks are NOT counted (the model
    sometimes echoes the prompt-file's example headings).
    """
    found = _extract_top_level_headings(text)
    found_lower = {h.lower(): h for h in found}
    expected_lower = [h.lower() for h in expected]

    missing = [
        original
        for original, lower in zip(expected, expected_lower)
        if lower not in found_lower
    ]
    extras = [
        found_lower[lower]
        for lower in found_lower
        if lower not in expected_lower
    ]
    return HeadingValidation(
        ok=not missing,
        missing=missing,
        extras=extras,
        found=found,
    )


def _extract_top_level_headings(text: str) -> list[str]:
    """Return every `## Heading` line in `text`, skipping fenced code blocks.

    Headings inside ``` ... ``` are ignored because the prompt files
    show example sections inside code fences and we don't want the
    model echoing those to count as a real section.
    """
    headings: list[str] = []
    in_fence = False
    fence_re = re.compile(r"^```")
    heading_re = re.compile(r"^##\s+(?!#)(.+?)\s*$")
    for line in text.splitlines():
        if fence_re.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = heading_re.match(line)
        if m:
            headings.append(m.group(1).strip())
    return headings


def build_system_prompt(prompt_name: str) -> str:
    """Build the per-variant system prompt the LLM receives.

    Replaces the previous hardcoded prompt that asserted work_one-on-one's
    eight sections for every conversation shape. Family conversations
    don't have `## Decisions`; service-minimal has only three sections;
    work-meeting has nine. The LLM was being told the wrong list and
    sometimes invented sections to match.
    """
    expected = expected_headings_for(prompt_name)
    headings_block = "\n".join(f"## {h}" for h in expected)
    return (
        "You are a conversation analyst. You MUST structure your output "
        "using EXACTLY these markdown headings in this order:\n"
        f"{headings_block}\n\n"
        "Start with YAML frontmatter (---), then the first heading. "
        "No preamble, no introductory text. Use the heading names "
        "EXACTLY as shown - do not rename, reorder, or skip them. "
        "Do not invent additional `## ` headings; sub-sections under a "
        "heading should use `### ` or `#### `."
    )


def build_retry_system_prompt(prompt_name: str, missing: list[str]) -> str:
    """Build a stricter system prompt for the retry attempt.

    Names every missing section explicitly so the model can't ignore the
    requirement again. Used after an initial enrichment misses one or
    more required headings.
    """
    base = build_system_prompt(prompt_name)
    missing_block = "\n".join(f"  - ## {h}" for h in missing)
    return (
        f"{base}\n\n"
        "RETRY NOTICE: Your previous attempt missed the following "
        "required `## ` heading(s):\n"
        f"{missing_block}\n\n"
        "This attempt MUST include every section listed above. If a "
        "section has no content, write `_Nothing to report._` under "
        "the heading rather than omitting it."
    )
