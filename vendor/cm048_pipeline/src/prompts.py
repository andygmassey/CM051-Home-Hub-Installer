"""Prompt template loader for CM048.

Loads prompt markdown files from the `prompts/` directory, substitutes
{placeholders} with runtime values, and returns the rendered prompt
string ready to send to Ollama.

Placeholders use single-brace format ({name}) to match the markdown
files' existing style. Missing placeholders are left as-is (rather
than raising) so prompt authors can review the rendered output and
see which substitutions didn't happen.
"""
from __future__ import annotations

import re
from pathlib import Path


PROMPTS_DIR = Path(__file__).parent.parent / "prompts"


def load_prompt(name: str) -> str:
    """Load a prompt's raw markdown contents. No substitution."""
    path = PROMPTS_DIR / f"{name}.md"
    if not path.exists():
        raise FileNotFoundError(f"Prompt not found: {path}")
    return path.read_text()


def load_conventions() -> str:
    """Load the shared conventions that prefix every prompt."""
    return load_prompt("_conventions")


def render(template: str, **substitutions: str) -> str:
    """Substitute {placeholder} tokens with provided values.

    Leaves unknown placeholders intact for debugging. Does NOT touch
    `{` inside code fences — callers should pre-escape if needed.
    """
    def replace(match: re.Match) -> str:
        key = match.group(1)
        if key in substitutions:
            return str(substitutions[key])
        return match.group(0)

    # Only substitute simple `{word}` — not JSON-shaped `{...}`
    return re.sub(r"\{([a-zA-Z_][a-zA-Z0-9_]*)\}", replace, template)


def enrichment_prompt_name_for(type_slug: str) -> str:
    """Map a classifier suggested_type_slug to its enrichment prompt name.

    E.g.:
      work_one-on-one_medium -> 02_enrich_work_one-on-one
      social_one-on-one_low  -> 02_enrich_social_casual
      public_presentation_high -> 02_enrich_public_presentation
      public_meeting_low -> 02_enrich_public_audience
      service_one-on-one_low -> 02_enrich_service_minimal
    """
    parts = type_slug.split("_")
    if len(parts) < 3:
        # Malformed — fall back
        return "02_enrich_work_one-on-one"
    setting, shape, _stakes = parts[0], parts[1], parts[2]

    if setting == "service":
        return "02_enrich_service_minimal"
    if setting == "family":
        return "02_enrich_family"
    if setting == "public" and shape == "presentation":
        return "02_enrich_public_presentation"
    if setting == "public":  # audience (any shape other than presentation)
        return "02_enrich_public_audience"
    if setting == "work" and shape == "meeting":
        return "02_enrich_work_meeting"
    if setting == "work" and shape == "group-convo":
        return "02_enrich_work_group-convo"
    if setting == "work":  # one-on-one (any remaining)
        return "02_enrich_work_one-on-one"
    if setting == "social":
        return "02_enrich_social_casual"
    if setting == "correspondence":
        # Email-channel conversations route to the async-aware variant
        # regardless of shape. Email threads do not have meaningful
        # meeting/one-on-one/group-convo structure in the same way
        # spoken conversations do, so a single enrichment template
        # covers the channel.
        return "02_enrich_email_thread"
    # Fallback
    return "02_enrich_work_one-on-one"
