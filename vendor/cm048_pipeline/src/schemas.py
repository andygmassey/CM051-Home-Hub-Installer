"""Pydantic-free schemas (dataclass-based) for CM048 pipeline outputs.

Avoids a pydantic dependency for leaner deployment. Uses stdlib
dataclasses + explicit from_json/to_json helpers.

Each schema corresponds to one pipeline step's output.

# Free-form metadata.json fields (not formal dataclasses)

The metadata.json files written into ``~/.pwg/processing/{conv_id}/``
are accessed as plain dicts throughout the pipeline (see
``processor.py`` and ``cli.py``). The shape is documented here rather
than codified as a dataclass, to keep the metadata loader unchanged
across spoken / email / IM / SMS conversations.

- ``conversation_id: str`` - required. Used as the per-conversation
  state directory name.
- ``date: str`` - ISO date.
- ``source: str`` - free-form (``zoom_call``, ``mbox_inbox``,
  ``imap_personal``, ``in_person``, ``apple_watch``, etc.).
- ``location: str | None`` - optional.
- ``user_hint: str | None`` - optional free-text hint to the
  classifier.
- ``capture_source: str`` - one of the literals enforced in
  ``SpeakerLabelFeedback.capture_source``.
- ``participants: list[dict]`` - each entry has at least ``id``,
  ``display``, and ``role`` (``"user" | "other"``). Email channel
  conversations also carry ``email: str`` per participant for
  unambiguous resolution against the people graph (CM041).
- ``channel: str = "spoken"`` - added 2026-04-28 (Phase 3 prep).
  Discriminator: ``"spoken" | "email" | "im" | "sms" | "manual"``.
  Default ``"spoken"`` so existing fixtures keep working untouched.
  Email-channel conversations also carry an ``email_thread``
  sidecar:
  ```
  {
      "thread_id": "<root-message-id>",
      "subject": "Re: ...",
      "message_count": 7,
      "first_message_at": "2026-03-04T...",
      "last_message_at": "2026-04-22T...",
      "message_ids": ["<a@x>", "<b@x>", ...],
      "in_reply_to_chain": ["<a@x>", "<b@x>", ...]
  }
  ```
"""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Literal


# ── Step 1: Classification ───────────────────────────────────────────

# ``correspondence`` is the email-channel setting (added 2026-04-28).
# Routes to ``02_enrich_email_thread`` via
# ``prompts.enrichment_prompt_name_for``. Cleaner than reusing ``work``
# and overloading ``shape`` to mean "thread vs. message" for email.
Setting = Literal["work", "social", "family", "public", "service", "correspondence"]
Shape = Literal["meeting", "one-on-one", "group-convo", "presentation", "casual"]
Stakes = Literal["high", "medium", "low"]
SensitivityLevel = Literal["normal", "personal", "sensitive", "highly-sensitive"]
ProcessingDepth = Literal["full", "minimal", "none"]


@dataclass
class Sensitivity:
    level: SensitivityLevel = "normal"
    categories: list[str] = field(default_factory=list)
    reasoning: str = ""


@dataclass
class Classification:
    setting: Setting
    shape: Shape
    stakes: Stakes
    confidence: float
    reasoning: str
    sensitivity: Sensitivity
    review_before_ingest: bool = False
    processing_depth: ProcessingDepth = "full"
    hints_used: str = "none"
    suggested_type_slug: str = ""

    @classmethod
    def from_dict(cls, data: dict) -> "Classification":
        sens = data.get("sensitivity") or {}
        return cls(
            setting=data["setting"],
            shape=data["shape"],
            stakes=data["stakes"],
            confidence=float(data.get("confidence", 0.0)),
            reasoning=data.get("reasoning", ""),
            sensitivity=Sensitivity(
                level=sens.get("level", "normal"),
                categories=list(sens.get("categories") or []),
                reasoning=sens.get("reasoning", ""),
            ),
            review_before_ingest=bool(data.get("review_before_ingest", False)),
            processing_depth=data.get("processing_depth", "full"),
            hints_used=data.get("hints_used", "none"),
            suggested_type_slug=data.get(
                "suggested_type_slug",
                f"{data['setting']}_{data['shape']}_{data['stakes']}",
            ),
        )

    def to_dict(self) -> dict:
        return {
            "setting": self.setting,
            "shape": self.shape,
            "stakes": self.stakes,
            "confidence": self.confidence,
            "reasoning": self.reasoning,
            "sensitivity": {
                "level": self.sensitivity.level,
                "categories": self.sensitivity.categories,
                "reasoning": self.sensitivity.reasoning,
            },
            "review_before_ingest": self.review_before_ingest,
            "processing_depth": self.processing_depth,
            "hints_used": self.hints_used,
            "suggested_type_slug": self.suggested_type_slug,
        }


# ── Step 2: Enrichment ───────────────────────────────────────────────
# Enrichment output is markdown (per the 02_enrich_* prompts). We wrap
# it alongside a parsed frontmatter dict and extracted sidecars.


@dataclass
class ReminderCandidate:
    action: str
    owner: str
    deadline: str | None = None
    priority: str | None = None
    source_conversation_id: str | None = None

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class EnrichmentOutput:
    markdown: str  # full markdown with YAML frontmatter
    frontmatter: dict
    reminders_candidates: list[ReminderCandidate] = field(default_factory=list)
    prompt_version: str = ""

    def to_dict(self) -> dict:
        return {
            "markdown": self.markdown,
            "frontmatter": self.frontmatter,
            "reminders_candidates": [r.to_dict() for r in self.reminders_candidates],
            "prompt_version": self.prompt_version,
        }


# ── Step 3: Relationship signal ──────────────────────────────────────


@dataclass
class RelationshipSignal:
    """Matches 03_relationship_signal.md schema. Persisted to
    Oxigraph as pwg:RelationshipSignal triples."""

    target_participant: str
    target_display_name: str
    observed_in: str  # conversation_id
    observed_at: str  # ISO8601

    warmth: dict  # {score, confidence, evidence}
    reciprocity: dict
    energy: dict
    power_dynamic: dict
    topics_of_interest_to_other: list[dict]
    communication_style_observed: dict
    notable_moments: list[str]
    trust_and_rapport: dict
    relationship_category_hint: str
    overall_confidence: float
    flags: dict

    @classmethod
    def from_dict(cls, data: dict) -> "RelationshipSignal":
        return cls(**data)

    def to_dict(self) -> dict:
        return asdict(self)


# ── Step 4: Coach observation ────────────────────────────────────────


@dataclass
class CoachObservation:
    """Matches 04_coaching.md schema. Persisted to SQLite
    observations.db."""

    observation_id: str
    conversation_id: str
    observed_at: str
    conversation_type: str
    tone: Literal["direct", "supportive"]

    what_went_well: list[dict]
    what_to_work_on: list[dict]
    tip: dict
    tags: list[str]
    overall_severity: int
    confidence: float
    flags: dict

    skipped: bool = False
    skip_reason: str | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "CoachObservation":
        if data.get("skipped"):
            return cls(
                observation_id=data.get("observation_id") or "",
                conversation_id=data.get("conversation_id") or "",
                observed_at=data.get("observed_at") or "",
                conversation_type=data.get("conversation_type") or "",
                tone=data.get("tone") or "supportive",
                what_went_well=[],
                what_to_work_on=[],
                tip={},
                tags=[],
                overall_severity=0,
                confidence=0.0,
                flags={},
                skipped=True,
                skip_reason=data.get("skip_reason") or "",
            )
        return cls(
            observation_id=data["observation_id"],
            conversation_id=data["conversation_id"],
            observed_at=data["observed_at"],
            conversation_type=data["conversation_type"],
            tone=data["tone"],
            what_went_well=list(data.get("what_went_well") or []),
            what_to_work_on=list(data.get("what_to_work_on") or []),
            tip=dict(data.get("tip") or {}),
            tags=list(data.get("tags") or []),
            overall_severity=int(data.get("overall_severity", 1)),
            confidence=float(data.get("confidence", 0.0)),
            flags=dict(data.get("flags") or {}),
        )

    def to_dict(self) -> dict:
        return asdict(self)


# ── Step 5: Fact extraction ──────────────────────────────────────────


FactType = Literal[
    "fact", "preference", "decision", "plan", "event", "relationship",
    "belief", "milestone",
]
Domain = Literal[
    "food", "entertainment", "tech", "family", "work", "health",
    "travel", "finance", "social", "general", "politics", "creative",
    "education",
]
PrivacyLevel = Literal["L0", "L1", "L2"]


@dataclass
class ExtractedFact:
    """Matches 05_fact_extraction.md schema. CM040-compatible.

    The ``candidate`` flag is the Foundry-pattern guard: newly extracted
    facts start as candidates (True) and only flip to False when a
    second, independent source corroborates the same claim. See
    ``candidates.py`` for the promotion logic.

    Migration semantics: loading a fact dict that predates the candidate
    field treats it as already-promoted (``candidate=False``). Facts
    extracted after this change always carry the field explicitly.
    """

    text: str
    type: FactType
    subject: str  # user | other:{slug} | person:{slug} | org:{slug} | household:{id}
    domain: Domain
    confidence: Literal["stated", "inferred"]
    privacy_level: PrivacyLevel
    signal_strength: Literal["strong", "medium", "weak"]
    temporal: bool = False
    expires_at: str | None = None
    evidence: str = ""
    candidate: bool = True
    # Channel the fact was extracted from. Mirrors metadata.channel and
    # rides through to downstream redaction (the wiki's L0 demo mode +
    # obsidian export both need to know whether a fact came from an
    # email body, where the other participant did not consent to LLM
    # processing of their words). Free-form to match metadata.channel
    # rather than a closed Literal so a new channel added to the
    # adapter does not require a schema migration here. Missing on
    # legacy facts; default None so older sinks keep round-tripping.
    source_channel: str | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "ExtractedFact":
        return cls(
            text=data["text"],
            type=data["type"],
            subject=data.get("subject", "user"),
            domain=data["domain"],
            confidence=data.get("confidence", "stated"),
            privacy_level=data.get("privacy_level", "L1"),
            signal_strength=data.get("signal_strength", "medium"),
            temporal=bool(data.get("temporal", False)),
            expires_at=data.get("expires_at"),
            evidence=data.get("evidence", ""),
            # Missing key means the fact was written before the Foundry
            # pattern existed — treat those as already-promoted, per the
            # migration semantics documented in the class docstring.
            candidate=bool(data.get("candidate", False)),
            source_channel=data.get("source_channel"),
        )

    def to_dict(self) -> dict:
        d = asdict(self)
        if not d["expires_at"]:
            d.pop("expires_at")
        # Drop source_channel when absent so legacy fact files still
        # round-trip byte-identically and the JSON stays uncluttered
        # for spoken conversations (the common case).
        if d.get("source_channel") is None:
            d.pop("source_channel", None)
        return d


# ── Step 6: Speaker-label feedback ───────────────────────────────────


@dataclass
class SpeakerLabel:
    raw_label: str
    inferred_person_id: str
    inferred_display_name: str
    confidence: float
    evidence: str = ""
    voice_fingerprint_ref: str | None = None
    apply_mode: Literal["auto", "suggest", "review_required"] = "suggest"

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class SpeakerLabelFeedback:
    """Matches docs/speaker_label_feedback.schema.json."""

    feedback_id: str
    conversation_id: str
    produced_at: str
    capture_source: Literal["cm031_ios", "cm031_watch", "cm031_wearable", "cm042_mac"]
    labels: list[SpeakerLabel]
    unresolved_labels: list[dict] = field(default_factory=list)
    conversation_sensitivity_level: SensitivityLevel = "normal"

    def to_dict(self) -> dict:
        return {
            "feedback_id": self.feedback_id,
            "conversation_id": self.conversation_id,
            "produced_at": self.produced_at,
            "capture_source": self.capture_source,
            "labels": [l.to_dict() for l in self.labels],
            "unresolved_labels": self.unresolved_labels,
            "conversation_sensitivity_level": self.conversation_sensitivity_level,
        }


# ── Pipeline-wide types ──────────────────────────────────────────────


PipelineStep = Literal[
    "00_raw",
    "01_classify",
    "02_enrich",
    "03_relationship_signal",
    "04_coaching",
    "05_fact_extraction",
    "06_speaker_feedback",
    "07_sinks_written",
    "08_linked",
    "09_bundle",
]

PIPELINE_STEP_ORDER: tuple[PipelineStep, ...] = (
    "00_raw",
    "01_classify",
    "02_enrich",
    "03_relationship_signal",
    "04_coaching",
    "05_fact_extraction",
    "06_speaker_feedback",
    "07_sinks_written",
    "08_linked",
    "09_bundle",
)


@dataclass
class PipelineState:
    """Tracks progress through the pipeline for a single conversation.
    Persisted as state.json in the per-conversation directory."""

    conversation_id: str
    created_at: str
    last_updated_at: str
    current_step: PipelineStep
    completed_steps: list[PipelineStep]
    failed_step: PipelineStep | None = None
    failure_reason: str | None = None
    retry_count: int = 0
    # Parked after MAX_JOB_ATTEMPTS failed dispatches (processor.py
    # runaway fix, 2026-07-07). A dead-lettered conversation is refused
    # by `process()` and acknowledged (exit 0) so upstream feeds stop
    # resubmitting it; `pwg-convo retry` revives it explicitly.
    dead_lettered: bool = False
    prompt_versions: dict[str, str] = field(default_factory=dict)
    sink_idempotency_keys: dict[str, str] = field(default_factory=dict)

    @classmethod
    def new(cls, conversation_id: str) -> "PipelineState":
        now = datetime.now(timezone.utc).isoformat()
        return cls(
            conversation_id=conversation_id,
            created_at=now,
            last_updated_at=now,
            current_step="00_raw",
            completed_steps=[],
        )

    def advance(self, step: PipelineStep) -> None:
        if step not in self.completed_steps:
            self.completed_steps.append(step)
        self.current_step = step
        self.failed_step = None
        self.failure_reason = None
        self.last_updated_at = datetime.now(timezone.utc).isoformat()

    def fail(self, step: PipelineStep, reason: str) -> None:
        self.failed_step = step
        self.failure_reason = reason
        self.retry_count += 1
        self.last_updated_at = datetime.now(timezone.utc).isoformat()

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "PipelineState":
        return cls(**data)


# ── JSON helpers ─────────────────────────────────────────────────────


def write_json(path: "Path", obj: dict) -> None:
    from pathlib import Path as _P  # noqa
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2, ensure_ascii=False)


def read_json(path: "Path") -> dict:
    with open(path) as fh:
        return json.load(fh)
