"""VENDOR COPY (CM051 graft of CM048 #85, v1.0.107 walk #13), run against vendor/cm048_pipeline, the tree that ships.

The reminders_candidates sidecar must never reach the conversation body.

v1.0.107 walk #13: the enrich prompts ask the model for a
``reminders_candidates`` sidecar and nothing parsed it out of the reply, so
the key reached the customer's wiki (People/timeline) as an internal value.
The four shapes below are the four measured on the walk box (values
synthetic). Synthetic data only.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor" / "cm048_pipeline"))

from src.enrichment_validation import strip_reminders_sidecar

BARE = """## Action items
| Owner | Action |
|---|---|
| Sam Doe | Send the draft |

reminders_candidates:
  - action: "Send the draft"
    deadline: 2026-04-19
- None

## Key quotes
> fine by me
"""

BULLET = """## Commitments
* Owner: Sam Doe, book the room
* reminders_candidates:
    - action: "Book the room"

## Topics
"""

FENCED = """## Action items
_Nothing to report._

```yaml
reminders_candidates:
  - action: "Call the plumber"
```

## Key quotes
"""

INLINE = """## Commitments
* Owner: Sam Doe, what to do: skip a day [reminders_candidates: Sam Doe, skip a day]
* Owner: Alex Smith, bring the cake
"""


def _check(text, kept):
    out, n = strip_reminders_sidecar(text)
    assert n >= 1
    assert "reminders_candidates" not in out
    for k in kept:
        assert k in out, (k, out)
    return out


def test_bare_block_is_removed_and_the_table_and_next_section_survive():
    out = _check(BARE, ["| Sam Doe | Send the draft |", "## Key quotes", "> fine by me"])
    assert "deadline: 2026-04-19" not in out


def test_bullet_block_is_removed():
    out = _check(BULLET, ["* Owner: Sam Doe, book the room", "## Topics"])
    assert 'action: "Book the room"' not in out


def test_fenced_block_is_removed_with_its_fences():
    out = _check(FENCED, ["_Nothing to report._", "## Key quotes"])
    assert "```" not in out
    assert "Call the plumber" not in out


def test_inline_tail_is_removed_and_the_commitment_survives():
    out = _check(INLINE, ["* Owner: Sam Doe, what to do: skip a day", "bring the cake"])
    assert out.splitlines()[1].endswith("skip a day")


def test_control_prose_about_reminders_is_untouched():
    text = "## Action items\n* Set up Apple Reminders for the school run\n* remind Sam: candidates list due\n"
    out, n = strip_reminders_sidecar(text)
    assert n == 0 and out == text


def test_control_a_fenced_block_that_is_not_the_sidecar_survives():
    text = "## Key quotes\n```\nkeep: this\n```\n"
    out, n = strip_reminders_sidecar(text)
    assert n == 0 and out == text


def test_the_enrichment_file_written_to_disk_carries_no_sidecar(tmp_path, monkeypatch):
    """Through the real write path: _step_enrich writes 02_enrichment.md."""
    from types import SimpleNamespace

    from src import processor

    reply = BARE + "\n" + INLINE
    monkeypatch.setattr(processor, "_build_enrichment_input", lambda *a, **k: "input")
    monkeypatch.setattr(
        processor, "_validate_and_maybe_retry",
        lambda **k: (k["initial_text"], False, SimpleNamespace(missing=[], ok=True, extras=[], found=[])),
    )

    class _Client:
        def generate(self, *a, **k):
            return SimpleNamespace(raw_response=reply)

    settings = SimpleNamespace(processing_state_dir=tmp_path, ollama_enrich_model="m")
    (tmp_path / "conv-1").mkdir()
    processor._step_enrich(
        _Client(), "Sam: hello", {"conversation_id": "conv-1"},
        SimpleNamespace(suggested_type_slug="work_one-on-one"), settings, False,
    )
    written = (tmp_path / "conv-1" / "02_enrichment.md").read_text()
    assert "reminders_candidates" not in written
    assert "| Sam Doe | Send the draft |" in written
