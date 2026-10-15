"""Facts the pipeline KNOWS overwrite what the model WROTE.

Mini16, 2026-10-15: a one-speaker voice memo from the iPhone app came out
of enrichment as a two-person call. The frontmatter named the speaker
twice ("S1" and "S1 (new acquaintance, ex-S1)"), the summary said the
speaker "caught up with" themself, the location was "Remote - Voice call
(inferred from transcript structure)", ``enrichment_completed_at`` was a
date padded to midnight, ``enrichment_model`` named a 35B model on a
16 GB box that only had a 2B model installed, and ``conversation_id`` was
"N/A".

None of that was a reading error. The 02_enrich_* prompts show the model
an example frontmatter block and an example roster, and the model copied
them: the model label and ``(new acquaintance, ex-[company])`` are
literals in prompts/02_enrich_social_casual.md, and nothing told the
model the capture had one speaker. The writer then copied the model's
frontmatter verbatim to ~/Documents/Ostler/Conversations/<id>.md
(ingest._write_conversation_md).

So the rule here is the shape, not the instance: every frontmatter field
the pipeline itself knows is written by the pipeline, and a field nobody
measured is absent rather than invented.

- conversation_id, prompt_version, enrichment_model and
  enrichment_completed_at are stamped from the run that produced the text.
- location comes from the capture metadata or is absent.
- retention_tier comes from the same policy the Qdrant sink uses, or is
  absent; retention_score_inputs is absent (nothing computes it).
- a single-speaker spoken capture is a memo: one participant, shape
  "memo", no location subsection, no "person mentioned" that is only the
  speaker's own label.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Iterable

from .participants import normalise_participants
from .schemas import Classification

MEMO_SHAPE = "memo"
MEMO_PROMPT = "02_enrich_voice_memo"

# Diarisation labels a capture surface emits on its own, with no roster
# behind them: CM031 "S1", "Speaker 2", CM042 "Unknown" / "You".
_DIARISATION_LABEL = re.compile(
    r"^(?:s\d{1,2}|speaker\s*\d{1,2}|speaker|unknown|you|user|me)$", re.I
)

# One utterance header. Covers every shape a producer writes:
#   S1: text                      (CM031 iPhone / Watch)
#   **Alex** (01:02):             (spoken_source.renderer, CM042)
#   **Alex:** text                (markdown bold)
#   [00:01:02] Alex: text         (timestamped)
#   - Alex: text                  (bulleted)
_UTTERANCE = re.compile(
    r"^\s*(?:[-*]\s+)?"
    r"(?:\[?\d{1,2}:\d{2}(?::\d{2})?\]?\s+)?"
    r"(?:\*\*)?(?P<label>[A-Za-z][^\n:*()\[\]]{0,59}?)(?:\*\*)?"
    r"\s*(?:\(\d{1,2}:\d{2}(?::\d{2})?\))?\s*(?:\*\*)?:"
)


def _participant_names(metadata: dict) -> set[str]:
    names: set[str] = set()
    for p in normalise_participants(metadata.get("participants")):
        for key in ("display", "id", "name"):
            v = str(p.get(key) or "").strip().lower()
            if v:
                names.add(v)
    return names


def speaker_labels(transcript: str, metadata: dict | None = None) -> list[str]:
    """Distinct speaker labels heading an utterance, in first-seen order.

    Only a label that is a known participant or a diarisation label
    counts. A line such as ``Reminder: buy milk`` inside a memo is prose,
    not a second speaker, and must not turn a memo back into a call.
    """
    known = _participant_names(metadata or {})
    seen: list[str] = []
    lowered: set[str] = set()
    for line in (transcript or "").splitlines():
        m = _UTTERANCE.match(line)
        if not m:
            continue
        label = m.group("label").strip()
        key = label.lower()
        if key not in known and not _DIARISATION_LABEL.match(key):
            continue
        if key not in lowered:
            lowered.add(key)
            seen.append(label)
    return seen


def is_single_speaker_capture(transcript: str, metadata: dict) -> bool:
    """True when a SPOKEN capture has at most one speaker, by every
    measure the pipeline has: the roster and the transcript.

    Email and gateway chats are never memos: they are not spoken, and a
    gateway chat's other party is the assistant.
    """
    channel = str(metadata.get("channel") or "spoken").strip().lower()
    if channel != "spoken":
        return False
    if str(metadata.get("source") or "").strip().lower() == "gateway":
        return False
    if len(normalise_participants(metadata.get("participants"))) > 1:
        return False
    return len(speaker_labels(transcript, metadata)) <= 1


def as_memo(c: Classification) -> Classification:
    """The classification of a single-speaker capture, whatever the
    model guessed. Setting, stakes and sensitivity are kept (the model
    can read a memo's subject); shape is a fact we measured."""
    if c.shape == MEMO_SHAPE:
        return c
    c.reasoning = (
        f"single-speaker capture: shape set to {MEMO_SHAPE} by the pipeline "
        f"(model said {c.shape}). " + (c.reasoning or "")
    ).strip()
    c.shape = MEMO_SHAPE  # type: ignore[assignment]
    c.suggested_type_slug = f"{c.setting}_{MEMO_SHAPE}_{c.stakes}"
    return c


def utc_now_iso() -> str:
    """Wall-clock UTC to the second. Never a date padded to midnight."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


# ── frontmatter editing (text level: the model's YAML is not always YAML) ──


def _split_frontmatter(text: str) -> tuple[list[str] | None, str]:
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i], "\n".join(lines[i + 1:])
    return None, text


def _key_span(fm: list[str], key: str) -> tuple[int, int] | None:
    pat = re.compile(rf"^{re.escape(key)}\s*:")
    for i, line in enumerate(fm):
        if pat.match(line):
            j = i + 1
            while j < len(fm) and (fm[j].startswith((" ", "\t")) or fm[j].strip() == ""):
                j += 1
            return i, j
    return None


def _set(fm: list[str], key: str, block: list[str] | None) -> list[str]:
    """Replace top-level ``key`` (and its indented children) with
    ``block``; ``None`` removes it; a missing key is appended."""
    span = _key_span(fm, key)
    if span is None:
        return fm if block is None else fm + block
    i, j = span
    return fm[:i] + ([] if block is None else block) + fm[j:]


def _yaml_scalar(value: str) -> str:
    v = str(value)
    if v == "" or re.search(r"[:#\[\]{},&*!|>'\"%@`]|^\s|\s$", v):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return v


def stamp_frontmatter(
    text: str,
    *,
    conversation_id: str,
    prompt_version: str,
    model: str,
    completed_at: str,
    metadata: dict,
    classification: Classification,
    retention_tier: str | None,
    solo: bool,
) -> str:
    """Overwrite every frontmatter field the pipeline knows; drop the
    ones nobody measured. A reply with no frontmatter gets one."""
    fm, body = _split_frontmatter(text)
    if fm is None:
        fm, body = [], text
    fm = _set(fm, "conversation_id", [f"conversation_id: {_yaml_scalar(conversation_id)}"])
    fm = _set(fm, "prompt_version", [f"prompt_version: {_yaml_scalar(prompt_version)}"])
    fm = _set(fm, "enrichment_model", [f"enrichment_model: {_yaml_scalar(model)}"])
    fm = _set(fm, "enrichment_completed_at", [f"enrichment_completed_at: {completed_at}"])
    loc = str(metadata.get("location") or "").strip()
    fm = _set(fm, "location", [f"location: {_yaml_scalar(loc)}"] if loc else None)
    fm = _set(
        fm, "retention_tier",
        [f"retention_tier: {retention_tier}"] if retention_tier else None,
    )
    fm = _set(fm, "retention_score_inputs", None)
    if solo:
        fm = _set(fm, "classification", [
            "classification:",
            f"  setting: {_yaml_scalar(classification.setting)}",
            f"  shape: {MEMO_SHAPE}",
            f"  stakes: {_yaml_scalar(classification.stakes)}",
            f"  suggested_type_slug: {_yaml_scalar(classification.suggested_type_slug)}",
        ])
        fm = _set(fm, "participants", _solo_participants_block(metadata))
    return "---\n" + "\n".join(fm) + "\n---\n" + body.lstrip("\n")


def _solo_participants_block(metadata: dict) -> list[str]:
    people = normalise_participants(metadata.get("participants"))
    if not people:
        return ["participants: []"]
    p = people[0]
    name = str(p.get("display") or p.get("name") or p.get("id") or "").strip()
    if not name:
        return ["participants: []"]
    role = str(p.get("role") or "speaker").strip() or "speaker"
    return [
        "participants:",
        f"  - name: {_yaml_scalar(name)}",
        f"    role: {_yaml_scalar(role)}",
    ]


_HEADING = re.compile(r"^#{2,3}\s+(.*?)\s*$")


def scrub_solo_body(text: str, labels: Iterable[str], metadata: dict) -> str:
    """Body edits for a single-speaker capture.

    - a ``### Location`` subsection is removed unless the capture carried
      a location (the model infers "Remote - voice call" from the shape);
    - under a ``People ... mentioned`` heading, a bullet that is only the
      speaker's own label (with or without a copied role tag) is removed:
      the speaker is not someone they mentioned.
    """
    own = {lab.strip().lower() for lab in labels if lab.strip()}
    own |= _participant_names(metadata)
    keep_location = bool(str(metadata.get("location") or "").strip())
    out: list[str] = []
    section = ""
    sub = ""
    for line in text.split("\n"):
        m = _HEADING.match(line)
        if m:
            level = len(line) - len(line.lstrip("#"))
            title = m.group(1).strip().lower()
            if level == 2:
                section, sub = title, ""
            else:
                sub = title
            if sub == "location" and not keep_location:
                continue
            out.append(line)
            continue
        if sub == "location" and not keep_location:
            continue
        if section.startswith("people") and "mentioned" in section:
            b = re.match(r"^\s*[-*]\s+(.*)$", line)
            if b:
                name = re.sub(r"\s*\([^)]*\)\s*$", "", b.group(1)).strip(" *_`")
                if name.lower() in own:
                    continue
        out.append(line)
    return "\n".join(out)
