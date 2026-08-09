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


# v1018-D014b. Sub-headings (`### `) that live INSIDE a `## ` section.
#
# Only two variants declare any; every other conversation shape is flat.
# These were previously known ONLY to the prompt template files, which is
# how they came to be dropped: the chunk-merge pass loads
# `02b_merge_chunks` rather than the variant template, so nothing told the
# model to keep them -- and the expected-heading check is `##`-only, so
# nothing noticed they were gone. 29 of 129 conversation summaries on the
# founder box carry `### Participants` and `### Thread` with no
# `### Narrative` at all: the prose the section exists for is simply
# absent, and the surrounding metadata reads as raw scaffolding.
#
# Measured, and it tracks CHUNKING rather than sparse input, which is the
# opposite of D014a's failure mode:
#
#   1 msg   83 ok /  2 missing    2% fail
#   2 msg   10 ok / 10 missing   50% fail
#   3 msg    1 ok / 10 missing   91% fail
#   4+ msgs  6 ok /  7 missing   54% fail
EXPECTED_SUBHEADINGS_BY_PROMPT: dict[str, list[str]] = {
    "02_enrich_email_thread": ["Participants", "Thread", "Narrative"],
    "02_enrich_work_one-on-one": ["Participants", "Location", "Narrative"],
}


def expected_subheadings_for(prompt_name: str) -> list[str]:
    """Return the expected `### ` sub-heading list for a prompt name.

    Unknown or flat variants return [] -- unlike `expected_headings_for`,
    there is NO fallback to another variant's list. Asserting
    work_one-on-one's sub-sections against a family conversation would
    manufacture failures for sections that variant never declares.
    """
    return list(EXPECTED_SUBHEADINGS_BY_PROMPT.get(prompt_name, []))


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


_PLACEHOLDER_TOKEN = re.compile(r"\{[a-z][a-z0-9_]*\}")


def strip_placeholder_tokens(text: str) -> tuple[str, list[str]]:
    """Remove prompt-template placeholder tokens the model copied verbatim.

    v1018-D014c. The enrichment prompts are INSTRUCTIONS; the real values
    arrive in `prompt_body` below a `---` separator (see the ten
    `load_prompt` call sites in processor.py, all of which do
    `template + "\n\n---\n\n" + prompt_body`). The `{token}` forms inside
    a template are ILLUSTRATIVE -- they show the model the shape of the
    output it should produce. `prompts.render()` exists but has zero
    callers; nothing substitutes them and nothing is meant to.

    The defect is that the model sometimes copies an illustrative token
    into its answer instead of substituting the value it can see below the
    rule, so a customer's wiki page ends up carrying a literal
    `{user_email}`. It is intermittent for exactly that reason -- a
    plumbing bug would fire every time.

    STRIPS rather than retries, deliberately. A retry costs a model call,
    and v1018-D031 established that those run to 900s each and that the
    step's total budget is the scarce resource. Dropping a token is
    deterministic, free, and a strict improvement on shipping it.

    Lowercase-initial only: `{user_email}` and `{conversation_id}` are
    template tokens, while prose legitimately contains `{...}` in code
    samples and JSON, and those overwhelmingly start with a quote, a
    digit, an uppercase letter or a brace. Narrow beats clever here --
    a missed token is a cosmetic defect, a false positive silently edits
    the customer's content.

    Returns the cleaned text and the sorted unique tokens removed, so the
    caller can log WHICH ones fired rather than just that something did.
    """
    found = sorted(set(_PLACEHOLDER_TOKEN.findall(text)))
    if not found:
        return text, []
    cleaned = _PLACEHOLDER_TOKEN.sub("", text)
    # Collapse the double spaces and orphaned separators a removal leaves
    # behind, so the sentence still reads.
    cleaned = re.sub(r"[ \t]{2,}", " ", cleaned)
    cleaned = re.sub(r"[ \t]+([,.;:])", r"\1", cleaned)
    cleaned = re.sub(r"\(\s*\)", "", cleaned)
    return cleaned, found


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


def _extract_sub_headings(text: str) -> list[str]:
    """Return every `### Heading` line in `text`, skipping fenced code.

    Mirrors `_extract_top_level_headings`. The `(?!#)` guard keeps `####`
    and deeper out, so a model that over-nests does not satisfy the
    contract by accident.
    """
    headings: list[str] = []
    in_fence = False
    fence_re = re.compile(r"^```")
    heading_re = re.compile(r"^###\s+(?!#)(.+?)\s*$")
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


def validate_subheadings(text: str, expected: list[str]) -> HeadingValidation:
    """Validate that every expected `### Heading` appears in `text`.

    Extras are NOT reported for sub-headings. A cleaned transcript
    legitimately contains one `###` per speaker turn, so every real
    document has dozens of them and an extras list would be noise.
    """
    if not expected:
        return HeadingValidation(ok=True, missing=[], extras=[], found=[])
    found = _extract_sub_headings(text)
    found_lower = {h.lower() for h in found}
    missing = [h for h in expected if h.lower() not in found_lower]
    return HeadingValidation(
        ok=not missing, missing=missing, extras=[], found=found,
    )


def build_section_contract(prompt_name: str) -> str:
    """The section contract, as one string, for ANY pass over a document.

    Single source of truth so the chunk-merge pass cannot drift from the
    per-chunk pass -- that drift IS v1018-D014b. Callers append this to
    whatever body they are building.
    """
    lines = [
        "--- SECTION STRUCTURE REMINDER ---",
        "You MUST use EXACTLY these section headings in this order. Do NOT",
        "invent your own headings. Do NOT skip sections. If a section has no",
        'content, write the heading followed by "_Nothing to report._"',
        "",
    ]
    lines += [f"## {h}" for h in expected_headings_for(prompt_name)]
    subs = expected_subheadings_for(prompt_name)
    if subs:
        lines += [
            "",
            "Inside `## " + expected_headings_for(prompt_name)[0] + "`, keep these",
            "sub-sections, in this order, each with its own content:",
            "",
        ]
        lines += [f"### {h}" for h in subs]
        lines += [
            "",
            "`### " + subs[-1] + "` carries the prose. Metadata sub-sections",
            "without it are not a summary.",
        ]
    return "\n".join(lines)


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
