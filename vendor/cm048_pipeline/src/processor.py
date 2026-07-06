"""CM048 orchestration  –  runs a transcript through the full pipeline.

Per `CLAUDE.md` bulletproof processing:
- Raw transcript written to state dir FIRST, before any LLM call
- Each step's output persisted as its own JSON file before advancing
- state.json tracks progress; resumable from any failed step
- Sink writes are idempotent (ingest.py's concern; this module just
  dispatches)
- Auto-retry once on LLM step failure; second failure persists and
  stops

Entry point: `process(conversation_id, transcript, metadata, settings,
 resume_from_step=None) -> PipelineState`

CLI wrapper in cli.py.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import time
import uuid
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from . import prompts
from . import enrichment_validation
from . import bundle_extractor as _bundle_extractor
from . import channel_adapter as _channel_adapter
from . import conversation_writer as _conversation_writer
from . import outstanding_todos as _outstanding_todos
from . import privacy as _privacy
from .chunker import chunk_transcript, describe as describe_chunks
from .ollama_client import OllamaClient
from .schemas import (
    Classification,
    CoachObservation,
    EnrichmentOutput,
    ExtractedFact,
    PIPELINE_STEP_ORDER,
    PipelineState,
    PipelineStep,
    ReminderCandidate,
    RelationshipSignal,
    Sensitivity,
    SpeakerLabel,
    SpeakerLabelFeedback,
    read_json,
    write_json,
)
from .settings import Settings, ensure_directories


logger = logging.getLogger(__name__)


# ── Job-level bounds (2026-07-07 runaway fix) ───────────────────────
#
# A stuck 02_enrich on one email transcript held the box's single
# Ollama inference slot for 4 days 17 hours, turning every user chat
# turn into a 50-237 s queue wait. Three complementary bounds stop the
# class of failure:
#   1. The chunker guarantees forward progress and caps chunk count
#      (chunker.py).
#   2. Each `process()` invocation carries a wall-clock budget; a job
#      that exceeds it fails permanently instead of grinding on.
#   3. A job whose dispatches keep failing is DEAD-LETTERED after
#      MAX_JOB_ATTEMPTS: `process()` refuses to run it again and exits
#      as acknowledged, so upstream feeds (email/iMessage/WhatsApp
#      ticks) advance their watermark and stop resubmitting it. An
#      operator can revive it explicitly with `pwg-convo retry`.

# Whole-job dispatch bound. `PipelineState.retry_count` increments once
# per failed dispatch (in `PipelineState.fail`), so this bounds how many
# times upstream resubmission can re-run a failing conversation.
MAX_JOB_ATTEMPTS = 3

# Wall-clock budget for ONE `process()` invocation, seconds.
# Override with CM048_JOB_BUDGET_SECONDS; 0 disables the budget.
DEFAULT_JOB_BUDGET_SECONDS = 1800.0


class JobBudgetExceededError(Exception):
    """The job exceeded its wall-clock budget. Permanent: never retried
    within the same dispatch; counts one failed dispatch towards the
    dead-letter bound."""


# Monotonic deadline for the in-flight job. pwg-convo processes one
# conversation per CLI invocation on one thread, so a module-level
# deadline is safe; `process()` resets it on entry.
_JOB_DEADLINE: float | None = None


def _job_budget_seconds() -> float:
    raw = os.getenv("CM048_JOB_BUDGET_SECONDS", "")
    try:
        return float(raw) if raw else DEFAULT_JOB_BUDGET_SECONDS
    except ValueError:
        logger.warning(
            "Invalid CM048_JOB_BUDGET_SECONDS=%r; using default %.0fs",
            raw, DEFAULT_JOB_BUDGET_SECONDS,
        )
        return DEFAULT_JOB_BUDGET_SECONDS


def _start_job_deadline() -> None:
    global _JOB_DEADLINE
    budget = _job_budget_seconds()
    _JOB_DEADLINE = (time.monotonic() + budget) if budget > 0 else None


def _check_job_deadline(where: str) -> None:
    """Raise JobBudgetExceededError if the job's wall-clock budget is spent.

    Called before each step attempt and before each enrichment chunk
    call, so a slow or contended Ollama can never keep one background
    job on the shared slot indefinitely.
    """
    if _JOB_DEADLINE is not None and time.monotonic() > _JOB_DEADLINE:
        raise JobBudgetExceededError(
            f"job wall-clock budget ({_job_budget_seconds():.0f}s) exceeded "
            f"at {where}; failing this dispatch (permanent, will be "
            "dead-lettered after "
            f"{MAX_JOB_ATTEMPTS} failed dispatches)"
        )


# ── Public entry point ──────────────────────────────────────────────


def process(
    conversation_id: str,
    transcript: str,
    metadata: dict,
    settings: Settings,
    *,
    resume_from_step: PipelineStep | None = None,
    dry_run: bool = False,
    ingest_sinks: bool = True,
) -> PipelineState:
    """Run a conversation through the pipeline.

    Args:
        conversation_id: stable identifier (YYYY-MM-DD_slug style)
        transcript: full transcript text (markdown with speaker labels OK)
        metadata: dict with at least `date`, `source`, `participants`,
            `location`, `user_hint` (optional), `capture_source` (optional)
        settings: loaded Settings
        resume_from_step: if set, skip any step earlier than this
        dry_run: if True, do not call LLMs or write sinks  –  just
            advance state and log
        ingest_sinks: if False, skip sink writes (for tests)

    Returns the final PipelineState.
    """
    ensure_directories(settings)
    state_dir = settings.processing_state_dir / conversation_id
    state_dir.mkdir(parents=True, exist_ok=True)

    # Step 00  –  write raw transcript (always, idempotent)
    _write_raw(state_dir, conversation_id, transcript, metadata)

    # Load or create state
    state = _load_or_new_state(state_dir, conversation_id)

    # Dead-letter gate: a conversation whose dispatches have failed
    # MAX_JOB_ATTEMPTS times is parked, not looped. Returning without
    # running (and exiting 0 at the CLI, see cmd_process) tells the
    # upstream feed to advance its watermark and stop resubmitting.
    # An explicit `pwg-convo retry` (resume_from_step set) revives it.
    if resume_from_step is None:
        if state.dead_lettered:
            logger.error(
                "%s is dead-lettered (%d failed dispatches); refusing to "
                "reprocess. Revive with `pwg-convo retry %s`.",
                conversation_id, state.retry_count, conversation_id,
            )
            return state
        if state.retry_count >= MAX_JOB_ATTEMPTS:
            state.dead_lettered = True
            state.failure_reason = (
                f"DEAD-LETTERED after {state.retry_count} failed dispatches "
                f"(bound {MAX_JOB_ATTEMPTS}). Last failure: "
                f"{state.failure_reason or 'unknown'}"
            )
            _save_state(state_dir, state)
            logger.error(
                "%s dead-lettered after %d failed dispatches; parking. "
                "Revive with `pwg-convo retry %s`.",
                conversation_id, state.retry_count, conversation_id,
            )
            return state
    elif state.dead_lettered:
        # Operator-explicit retry revives a parked conversation.
        logger.info("Reviving dead-lettered %s via explicit retry.", conversation_id)
        state.dead_lettered = False

    _start_job_deadline()
    state.advance("00_raw")
    _save_state(state_dir, state)

    client = OllamaClient(base_url=settings.ollama_url)

    # Step 01  –  classify
    if _should_run("01_classify", state.completed_steps, resume_from_step):
        _run_step(
            state_dir,
            state,
            "01_classify",
            lambda: _step_classify(client, transcript, metadata, settings, dry_run),
        )

    classification = _load_classification(state_dir)
    if classification is None:
        logger.error("No classification available; aborting.")
        return state

    if classification.processing_depth == "none":
        logger.info("processing_depth=none  –  pipeline stops here.")
        return state

    # Resolve privacy level once and reuse for the rest of the
    # pipeline. The L3 contract (CM052 wire 2026-05-08, mirrored
    # by the four-artefact human-conversation spec 2026-05-09):
    # gist sinks (Qdrant + Oxigraph + cross-conversation linking)
    # are SKIPPED for L3 conversations; the episodic four-artefact
    # bundle (step 09) ALWAYS lands so the user can browse it and
    # PWG MCP get_conversation can fetch with explicit opt-in.
    resolved_privacy_level = _privacy.infer(
        channel=metadata.get("channel") or "spoken",
        classification=classification,
        metadata=metadata,
    )
    logger.info(
        "Resolved privacy_level=%s for %s",
        resolved_privacy_level,
        conversation_id,
    )

    # Step 02  –  enrich
    if _should_run("02_enrich", state.completed_steps, resume_from_step):
        _run_step(
            state_dir,
            state,
            "02_enrich",
            lambda: _step_enrich(
                client, transcript, metadata, classification, settings, dry_run
            ),
        )

    # Step 03  –  relationship signal (conditional)
    if _should_run(
        "03_relationship_signal", state.completed_steps, resume_from_step
    ) and _should_run_relationship(classification):
        _run_step(
            state_dir,
            state,
            "03_relationship_signal",
            lambda: _step_relationship(
                client, state_dir, metadata, classification, settings, dry_run
            ),
        )

    # Step 04  –  coaching (conditional)
    if _should_run(
        "04_coaching", state.completed_steps, resume_from_step
    ) and _should_run_coach(classification):
        _run_step(
            state_dir,
            state,
            "04_coaching",
            lambda: _step_coach(
                client, state_dir, metadata, classification, settings, dry_run
            ),
        )

    # Step 05  –  fact extraction
    if _should_run(
        "05_fact_extraction", state.completed_steps, resume_from_step
    ) and classification.processing_depth == "full":
        _run_step(
            state_dir,
            state,
            "05_fact_extraction",
            lambda: _step_facts(
                client, state_dir, metadata, classification, settings, dry_run
            ),
        )

    # Step 06  –  speaker feedback: infer who each "Speaker N" is from
    # the transcript text + the people graph, so the device can bind the
    # name to its LOCAL voiceprint via the opaque voice_fingerprint_ref.
    # TEXT-ONLY: no embedding ever crosses the wire (DESIGN §4).
    if _should_run("06_speaker_feedback", state.completed_steps, resume_from_step):
        _run_step(
            state_dir,
            state,
            "06_speaker_feedback",
            lambda: _step_speaker_feedback(
                client,
                state_dir,
                conversation_id,
                metadata,
                classification,
                settings,
                dry_run,
            ),
        )

    # Step 07  –  write sinks (gist arm: qdrant + oxigraph + coach
    # + speaker_feedback + legacy single MD). Skipped entirely for
    # L3 conversations -- the gist arm short-circuit mirrors
    # CM052 wire's L3 pattern. The episodic arm (step 09 bundle
    # writer) still runs so the user can browse the conversation.
    if (
        ingest_sinks
        and resolved_privacy_level != "L3"
        and _should_run("07_sinks_written", state.completed_steps, resume_from_step)
    ):
        _run_step(
            state_dir,
            state,
            "07_sinks_written",
            lambda: _step_ingest(
                state_dir, conversation_id, classification, settings, dry_run
            ),
        )
    elif resolved_privacy_level == "L3":
        logger.info(
            "L3 short-circuit: skipping step 07 (gist sinks) for %s",
            conversation_id,
        )

    # Step 08  –  cross-conversation linking (post-ingest, needs
    # Qdrant populated). Skipped for L3 alongside step 07 -- there
    # is nothing in Qdrant to link against if the gist arm didn't
    # run.
    if (
        ingest_sinks
        and resolved_privacy_level != "L3"
        and _should_run("08_linked", state.completed_steps, resume_from_step)
    ):
        _run_step(
            state_dir,
            state,
            "08_linked",
            lambda: _step_link(
                state_dir, conversation_id, settings, dry_run
            ),
        )

    # Step 09  –  four-artefact episodic bundle (HR015 2026-05-09).
    # Always runs for human conversations regardless of privacy
    # level; the writer's L3 short-circuit prevents any
    # caller-supplied gist callback firing, so this step is safe
    # at every level. The wiki renderer + PWG MCP read this
    # bundle.
    if _should_run("09_bundle", state.completed_steps, resume_from_step):
        _run_step(
            state_dir,
            state,
            "09_bundle",
            lambda: _step_bundle(
                client,
                state_dir,
                metadata,
                classification,
                settings,
                resolved_privacy_level,
                ingest_sinks=ingest_sinks,
                dry_run=dry_run,
            ),
        )

    logger.info(
        "Pipeline complete for %s. Steps: %s",
        conversation_id,
        state.completed_steps,
    )
    return state


# ── State helpers ────────────────────────────────────────────────────


def _load_or_new_state(state_dir: Path, conversation_id: str) -> PipelineState:
    path = state_dir / "state.json"
    if path.exists():
        return PipelineState.from_dict(read_json(path))
    return PipelineState.new(conversation_id)


def _save_state(state_dir: Path, state: PipelineState) -> None:
    write_json(state_dir / "state.json", state.to_dict())


def _should_run(
    step: PipelineStep,
    completed: list[PipelineStep],
    resume_from: PipelineStep | None,
) -> bool:
    if step in completed:
        return False
    if resume_from is None:
        return True
    # Run if step >= resume_from in canonical order.
    return PIPELINE_STEP_ORDER.index(step) >= PIPELINE_STEP_ORDER.index(resume_from)


def _should_run_relationship(c: Classification) -> bool:
    if c.processing_depth != "full":
        return False
    if c.setting in ("public", "service"):
        return False
    if c.sensitivity.level == "highly-sensitive":
        return False
    return True


def _should_run_coach(c: Classification) -> bool:
    if c.processing_depth != "full":
        return False
    if c.setting in ("family", "service"):
        return False
    if c.sensitivity.level in ("sensitive", "highly-sensitive"):
        return False
    if c.setting == "social" and not (c.shape == "one-on-one" and c.stakes == "high"):
        return False
    if c.setting == "public" and c.shape != "presentation":
        return False
    return True


MAX_RETRIES = 3
BASE_DELAY_SECONDS = 30


def _is_retryable(exc: Exception) -> bool:
    """Classify whether an exception is worth retrying.

    Retryable: timeouts, 503 (service unavailable), 429 (rate limit),
    connection errors  –  transient infrastructure issues.

    Permanent: 400 (bad request / malformed input), 404, 422,
    JSON parse failures, value errors  –  retrying won't help.
    """
    import httpx

    if isinstance(exc, JobBudgetExceededError):
        # The job's wall-clock budget is spent; another attempt inside
        # this dispatch would just spend more of the shared Ollama slot.
        return False
    if isinstance(exc, (TimeoutError, ConnectionError, OSError)):
        return True
    if isinstance(exc, httpx.TimeoutException):
        return True
    if isinstance(exc, (ValueError, TypeError)):
        # Malformed or oversize input (incl. chunker.TranscriptTooLargeError,
        # a ValueError)  –  permanent, retrying cannot fix the input.
        return False
    if isinstance(exc, httpx.HTTPStatusError):
        return exc.response.status_code in (429, 500, 502, 503, 504)
    if isinstance(exc, RuntimeError):
        msg = str(exc).lower()
        # "no valid JSON" from classifier  –  permanent, won't improve on retry
        if "no valid json" in msg:
            return False
        # Generic runtime errors  –  assume retryable
        return True
    # Unknown exception types  –  retry once, might be transient
    return True


def _run_step(
    state_dir: Path,
    state: PipelineState,
    step: PipelineStep,
    fn,
) -> None:
    """Invoke a step function with exponential backoff retry.

    Retries up to MAX_RETRIES times for transient errors (timeouts,
    503s, connection failures). Fails immediately on permanent errors
    (400s, parse failures, value errors).

    Backoff: 30s, 60s, 120s (base * 2^attempt).
    """
    import time
    import traceback

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            # Inside the try so a spent budget is classified + persisted
            # like any other failure (permanent; no further attempts).
            _check_job_deadline(f"step {step} attempt {attempt}")
            fn()
            state.advance(step)
            _save_state(state_dir, state)
            return
        except Exception as exc:
            is_last = attempt == MAX_RETRIES
            retryable = _is_retryable(exc)

            logger.warning(
                "Step %s failed (attempt %d/%d, %s): %s",
                step,
                attempt,
                MAX_RETRIES,
                "retryable" if retryable else "PERMANENT",
                exc,
            )

            if not retryable or is_last:
                reason = (
                    f"{'PERMANENT' if not retryable else 'EXHAUSTED'}: "
                    f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}"
                )
                state.fail(step, reason)
                _save_state(state_dir, state)
                raise RuntimeError(
                    f"Step {step} failed "
                    f"({'permanent error' if not retryable else f'after {MAX_RETRIES} retries'}). "
                    f"See state.json."
                ) from exc

            delay = BASE_DELAY_SECONDS * (2 ** (attempt - 1))
            logger.info("Retrying step %s in %ds...", step, delay)
            time.sleep(delay)


# ── Step 00: raw transcript ─────────────────────────────────────────


def _write_raw(
    state_dir: Path,
    conversation_id: str,
    transcript: str,
    metadata: dict,
) -> None:
    raw_path = state_dir / "00_raw_transcript.md"
    if not raw_path.exists():
        raw_path.write_text(transcript)
    meta_path = state_dir / "00_metadata.json"
    if not meta_path.exists():
        write_json(meta_path, metadata)


# ── Step 01: classify ───────────────────────────────────────────────


def _step_classify(
    client: OllamaClient,
    transcript: str,
    metadata: dict,
    settings: Settings,
    dry_run: bool,
) -> None:
    state_dir = settings.processing_state_dir / metadata["conversation_id"]
    out_path = state_dir / "01_classification.json"
    if out_path.exists():
        return  # idempotent

    # metadata.channel selects the classifier prompt. Email-channel
    # conversations have no overlapping speech, message-level
    # boundaries, and async time gaps the spoken classifier doesn't
    # know to look for. Defaults to "spoken" so existing fixtures
    # route to the original prompt unchanged.
    classify_prompt_name = (
        "01_classify_email"
        if metadata.get("channel") == "email"
        else "01_classify"
    )
    template = prompts.load_prompt(classify_prompt_name)
    conventions = prompts.load_conventions()

    prompt_body = _build_classifier_input(
        transcript,
        metadata,
        conventions,
        settings,
    )
    full_prompt = template + "\n\n---\n\n" + prompt_body

    if dry_run:
        # Channel-aware stub so the smoke pipeline exercises the same
        # routing path (enrichment_prompt_name_for, etc.) the live
        # pipeline would. Spoken conversations stub as the historical
        # default; email conversations stub to correspondence so
        # downstream picks 02_enrich_email_thread.
        if metadata.get("channel") == "email":
            stub = {
                "setting": "correspondence",
                "shape": "one-on-one",
                "stakes": "medium",
                "confidence": 0.9,
                "reasoning": "dry-run stub (email channel)",
                "sensitivity": {"level": "normal", "categories": [], "reasoning": ""},
                "review_before_ingest": False,
                "processing_depth": "full",
                "hints_used": "none",
                "suggested_type_slug": "correspondence_one-on-one_medium",
            }
        else:
            stub = {
                "setting": "work",
                "shape": "one-on-one",
                "stakes": "medium",
                "confidence": 0.9,
                "reasoning": "dry-run stub",
                "sensitivity": {"level": "normal", "categories": [], "reasoning": ""},
                "review_before_ingest": False,
                "processing_depth": "full",
                "hints_used": "none",
                "suggested_type_slug": "work_one-on-one_medium",
            }
        write_json(out_path, stub)
        return

    result = client.generate_json(
        settings.ollama_classify_model,
        full_prompt,
        expect="object",
        priority="medium",
    )
    if result.parsed_json is None:
        raise RuntimeError("Classifier returned no valid JSON")

    c = Classification.from_dict(result.parsed_json)
    write_json(out_path, c.to_dict())
    (state_dir / "01_classification_raw.txt").write_text(result.raw_response)


def _build_classifier_input(
    transcript: str,
    metadata: dict,
    conventions: str,
    settings: Settings,
) -> str:
    participants = metadata.get("participants") or []
    participant_str = ", ".join(
        f"{p.get('display', p.get('id', '?'))}" for p in participants
    )
    return f"""
--- METADATA ---
Date: {metadata.get("date", "?")}
Source: {metadata.get("source", "?")}
Location: {metadata.get("location", "?")}
Participants: {participant_str}
User hint: {metadata.get("user_hint") or "none"}
User locale: {settings.locale}

--- TRANSCRIPT (first 3000 chars) ---
{transcript[:3000]}
"""


# ── Step 02: enrich ──────────────────────────────────────────────────


def _step_enrich(
    client: OllamaClient,
    transcript: str,
    metadata: dict,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
) -> None:
    state_dir = settings.processing_state_dir / metadata["conversation_id"]
    out_path = state_dir / "02_enrichment.md"
    sidecar_path = state_dir / "02_enrichment_sidecar.json"
    if out_path.exists():
        return

    prompt_name = prompts.enrichment_prompt_name_for(
        classification.suggested_type_slug
    )
    template = prompts.load_prompt(prompt_name)
    conventions = prompts.load_conventions()

    chunks = chunk_transcript(transcript)
    logger.info(
        "Enriching %s with prompt=%s, %s",
        metadata["conversation_id"],
        prompt_name,
        describe_chunks(chunks),
    )

    # Variant-aware system prompt. Previously hardcoded the
    # work_one-on-one section list for every conversation shape, which
    # made the model invent or rename sections to satisfy headings that
    # didn't apply (e.g. Decisions in a family chat). Now each variant
    # is told the right list.
    enrichment_system = enrichment_validation.build_system_prompt(prompt_name)
    expected_headings = enrichment_validation.expected_headings_for(prompt_name)

    if len(chunks) == 1:
        prompt_body = _build_enrichment_input(
            chunks[0].content,
            metadata,
            classification,
            conventions,
            settings,
        )
        full_prompt = template + "\n\n---\n\n" + prompt_body

        if dry_run:
            out_path.write_text("# DRY RUN  –  enrichment stub\n")
            write_json(sidecar_path, {"reminders_candidates": []})
            return

        result = client.generate(
            settings.ollama_enrich_model,
            full_prompt,
            system=enrichment_system,
            priority="medium",
            timeout=900.0,
        )
        rendered, retry_attempted, validation = _validate_and_maybe_retry(
            client=client,
            initial_text=result.raw_response,
            full_prompt=full_prompt,
            prompt_name=prompt_name,
            expected_headings=expected_headings,
            settings=settings,
        )
        out_path.write_text(rendered)
        # Pre-meeting brief input: walk the enrichment's Action items
        # table and emit a per-participant outstanding_todos.json
        # sidecar. Best-effort: if the LLM didn't produce a parseable
        # table this is a no-op. Wired here (not in step 07) because
        # the sidecar reads the just-written enrichment markdown and
        # because the ingest step's L3 short-circuit skips Oxigraph
        # for L3 conversations -- writing the sidecar regardless of
        # privacy level keeps it available for tooling that runs
        # outside the SPARQL surface (e.g. debug review of the
        # rejected gist arm).
        try:
            _todos = _outstanding_todos.extract_outstanding_todos(
                rendered, metadata
            )
            _outstanding_todos.write_sidecar(state_dir, _todos)
        except Exception as exc:  # pragma: no cover - defensive
            logger.warning(
                "outstanding_todos extraction failed for %s: %s",
                metadata.get("conversation_id"),
                exc,
            )
        write_json(
            sidecar_path,
            {
                "reminders_candidates": [],  # populated by post-parse (Phase C)
                "prompt_version": f"{prompt_name}@1.0",
                "chunks": 1,
                "heading_validation": {
                    "ok": validation.ok,
                    "missing": validation.missing,
                    "extras": validation.extras,
                    "found": validation.found,
                    "retried": retry_attempted,
                },
            },
        )
    else:
        # Multi-chunk: run enrichment per chunk, then merge into one
        # coherent document using the merge prompt.
        per_chunk_outputs = []
        for chunk in chunks:
            # Each chunk is one LLM call on the shared slot; stop the
            # moment the job's wall-clock budget is spent (2026-07
            # runaway fix  –  a background job must never hold the slot
            # indefinitely).
            _check_job_deadline(
                f"02_enrich chunk {chunk.index + 1}/{chunk.total}"
            )
            prompt_body = _build_enrichment_input(
                chunk.content,
                {**metadata, "chunk_note": f"chunk {chunk.index+1} of {chunk.total}"},
                classification,
                conventions,
                settings,
            )
            full_prompt = template + "\n\n---\n\n" + prompt_body
            if dry_run:
                per_chunk_outputs.append(
                    f"# DRY RUN chunk {chunk.index+1}/{chunk.total}\n"
                )
                continue
            result = client.generate(
                settings.ollama_enrich_model,
                full_prompt,
                system=enrichment_system,
                priority="medium",
                timeout=900.0,
            )
            per_chunk_outputs.append(result.raw_response)

        if dry_run:
            out_path.write_text("\n\n---\n\n".join(per_chunk_outputs))
            write_json(
                sidecar_path,
                {
                    "reminders_candidates": [],
                    "prompt_version": f"{prompt_name}+merge@1.0",
                    "chunks": len(chunks),
                },
            )
            return

        # Merge pass: combine per-chunk outputs into one document.
        merged = _merge_chunk_outputs(
            client, per_chunk_outputs, metadata, classification,
            conventions, settings, prompt_name=prompt_name,
        )
        # Validate the merged output too. Multi-chunk runs go through the
        # merge prompt which is a separate model call; the merged result
        # is what hits disk so it needs the same heading guarantees.
        rendered, retry_attempted, validation = _validate_and_maybe_retry(
            client=client,
            initial_text=merged,
            full_prompt=_build_merge_prompt_for_retry(
                per_chunk_outputs, metadata, classification,
                conventions, settings,
            ),
            prompt_name=prompt_name,
            expected_headings=expected_headings,
            settings=settings,
        )
        out_path.write_text(rendered)
        # See note above (single-chunk branch) for the rationale on
        # extracting outstanding_todos here rather than during ingest.
        try:
            _todos = _outstanding_todos.extract_outstanding_todos(
                rendered, metadata
            )
            _outstanding_todos.write_sidecar(state_dir, _todos)
        except Exception as exc:  # pragma: no cover - defensive
            logger.warning(
                "outstanding_todos extraction failed for %s: %s",
                metadata.get("conversation_id"),
                exc,
            )

        write_json(
            sidecar_path,
            {
                "reminders_candidates": [],
                "prompt_version": f"{prompt_name}+merge@1.0",
                "chunks": len(chunks),
                "heading_validation": {
                    "ok": validation.ok,
                    "missing": validation.missing,
                    "extras": validation.extras,
                    "found": validation.found,
                    "retried": retry_attempted,
                },
            },
        )


def _validate_and_maybe_retry(
    *,
    client: OllamaClient,
    initial_text: str,
    full_prompt: str,
    prompt_name: str,
    expected_headings: list[str],
    settings,
) -> tuple[str, bool, "enrichment_validation.HeadingValidation"]:
    """Validate enrichment output; retry once if a required heading is missing.

    Returns (final_text, retry_attempted, final_validation). If the first
    call produced all expected headings, returns immediately. Otherwise
    retries with a stricter system prompt that names the missing
    sections explicitly. If the retry also misses, the second result
    is still written - downstream consumers will see whatever the model
    produced and the sidecar records the gap.
    """
    validation = enrichment_validation.validate_headings(
        initial_text, expected_headings,
    )
    if validation.ok:
        if validation.extras:
            logger.info(
                "Enrichment headings ok for %s; extras (informational): %s",
                prompt_name, validation.extras,
            )
        return initial_text, False, validation

    logger.warning(
        "Enrichment for %s missing required headings: %s. Retrying with "
        "stricter system prompt.",
        prompt_name, validation.missing,
    )
    retry_system = enrichment_validation.build_retry_system_prompt(
        prompt_name, validation.missing,
    )
    retry_result = client.generate(
        settings.ollama_enrich_model,
        full_prompt,
        system=retry_system,
        priority="medium",
        timeout=900.0,
    )
    retry_validation = enrichment_validation.validate_headings(
        retry_result.raw_response, expected_headings,
    )
    if not retry_validation.ok:
        logger.warning(
            "Enrichment retry for %s STILL missing headings: %s. "
            "Persisting the second attempt anyway; sidecar records the gap.",
            prompt_name, retry_validation.missing,
        )
    else:
        logger.info(
            "Enrichment retry for %s succeeded; all required headings present.",
            prompt_name,
        )
    return retry_result.raw_response, True, retry_validation


def _build_merge_prompt_for_retry(
    chunk_outputs: list[str],
    metadata: dict,
    classification: "Classification",
    conventions: str,
    settings,
) -> str:
    """Re-build the merge prompt body so the retry path can re-send it.

    Mirrors the body construction inside _merge_chunk_outputs without
    the outer client.generate() call, so a retry can supply a stricter
    system prompt against the same input.
    """
    merge_template = prompts.load_prompt("02b_merge_chunks")
    chunks_body = ""
    for i, output in enumerate(chunk_outputs):
        chunks_body += f"\n--- CHUNK {i+1} OF {len(chunk_outputs)} ---\n{output}\n"
    participants = metadata.get("participants") or []
    participant_str = ", ".join(
        f"{p.get('display', p.get('id', '?'))}" for p in participants
    )
    other_name = next(
        (p.get("display", p.get("id", "other"))
         for p in participants if p.get("role") != "user"),
        "other",
    )
    merge_body = f"""
--- MERGE TASK ---
Merging {len(chunk_outputs)} enrichment outputs from a long conversation.

--- CLASSIFICATION ---
{json.dumps(classification.to_dict(), indent=2)}

--- METADATA ---
Date: {metadata.get("date", "?")}
Source: {metadata.get("source", "?")}
Location: {metadata.get("location", "?")}
Participants: {participant_str}
User name: {settings.user_display_name}
Other name: {other_name}
Locale: {settings.locale}

--- CONVENTIONS ---
{conventions}

{chunks_body}
"""
    return merge_template + "\n\n---\n\n" + merge_body


def _merge_chunk_outputs(
    client: OllamaClient,
    chunk_outputs: list[str],
    metadata: dict,
    classification: Classification,
    conventions: str,
    settings: Settings,
    prompt_name: str = "02_enrich_work_one-on-one",
) -> str:
    """Merge per-chunk enrichment outputs into a single coherent document
    using the 02b_merge_chunks prompt. The merged document must satisfy
    the same per-variant heading list as a single-chunk run; the system
    prompt here is variant-aware to match.
    """
    merge_template = prompts.load_prompt("02b_merge_chunks")

    # Build the merge input with all chunk outputs
    chunks_body = ""
    for i, output in enumerate(chunk_outputs):
        chunks_body += f"\n--- CHUNK {i+1} OF {len(chunk_outputs)} ---\n{output}\n"

    participants = metadata.get("participants") or []
    participant_str = ", ".join(
        f"{p.get('display', p.get('id', '?'))}" for p in participants
    )
    other_name = next(
        (p.get("display", p.get("id", "other"))
         for p in participants if p.get("role") != "user"),
        "other",
    )

    merge_body = f"""
--- MERGE TASK ---
You are merging {len(chunk_outputs)} enrichment outputs from a
conversation that was too long to process in a single pass. The chunks
overlap by approximately 2 speaker turns. Produce a single unified
document.

--- CLASSIFICATION ---
{json.dumps(classification.to_dict(), indent=2)}

--- METADATA ---
Date: {metadata.get("date", "?")}
Source: {metadata.get("source", "?")}
Location: {metadata.get("location", "?")}
Participants: {participant_str}
User name: {settings.user_display_name}
Other name: {other_name}
Locale: {settings.locale}

--- CONVENTIONS ---
{conventions}

{chunks_body}
"""
    merge_system = (
        "You are merging multiple enrichment outputs into one coherent "
        "document. Deduplicate topics, action items, and overlapping "
        "transcript. " + enrichment_validation.build_system_prompt(prompt_name)
    )
    full_prompt = merge_template + "\n\n---\n\n" + merge_body
    result = client.generate(
        settings.ollama_enrich_model,
        full_prompt,
        system=merge_system,
        priority="medium",
        timeout=900.0,
    )
    return result.raw_response


def _build_speaker_mapping(metadata: dict) -> str:
    """Build a speaker-to-participant mapping string for prompts.

    Transcripts from iOS use "Speaker 1", "Speaker 2" labels. This
    produces a mapping hint so the model can attribute facts to named
    participants instead of generic "Speaker N" references.
    """
    participants = metadata.get("participants") or []
    if not participants:
        return ""
    lines = ["speaker_mapping:"]
    for i, p in enumerate(participants, 1):
        display = p.get("display", p.get("id", f"Speaker {i}"))
        role = p.get("role", "other")
        slug = p.get("id", f"speaker_{i}")
        role_label = "(user)" if role == "user" else f"(other:{slug})"
        lines.append(f"  Speaker {i} = {display} {role_label}")
    lines.append(
        "Use participant names (not 'Speaker 1') in the subject field. "
        f"The user is '{participants[0].get('display', 'the user')}'."
    )
    return "\n".join(lines) + "\n"


def _fix_speaker_subjects(facts: list[dict], metadata: dict) -> list[dict]:
    """Post-process facts to replace generic speaker labels with actual
    participant IDs from metadata.

    Local models tend to use "other:speaker", "other:speaker_1",
    "other:speaker_2" etc. even when given an explicit speaker mapping.
    This maps those back to the actual participant slugs.
    """
    participants = metadata.get("participants") or []
    others = [p for p in participants if p.get("role") != "user"]
    user_id = next(
        (p.get("id") for p in participants if p.get("role") == "user"),
        "user",
    )

    # Build mapping of generic labels → real IDs
    label_map: dict[str, str] = {}
    for i, p in enumerate(others):
        pid = p.get("id", f"other_{i+1}")
        display = p.get("display", "").lower()
        # Map various generic labels the model might produce
        label_map[f"other:speaker_{i+1}"] = f"other:{pid}"
        label_map[f"other:speaker{i+1}"] = f"other:{pid}"
        label_map[f"person:speaker_{i+1}"] = f"person:{pid}"
    # If only one non-user participant, also map bare "other:speaker"
    if len(others) == 1:
        pid = others[0].get("id", "other")
        label_map["other:speaker"] = f"other:{pid}"
        label_map["other:the_speaker"] = f"other:{pid}"
        label_map["person:speaker"] = f"person:{pid}"

    if not label_map:
        return facts

    fixed = 0
    for fact in facts:
        subj = fact.get("subject", "")
        if subj in label_map:
            fact["subject"] = label_map[subj]
            fixed += 1

    if fixed:
        logger.info("Fixed %d speaker-label subjects in %d facts", fixed, len(facts))
    return facts


def _build_enrichment_input(
    transcript_chunk: str,
    metadata: dict,
    c: Classification,
    conventions: str,
    settings: Settings,
) -> str:
    classification_json = json.dumps(c.to_dict(), indent=2)
    participants = metadata.get("participants") or []
    participant_str = ", ".join(
        f"{p.get('display', p.get('id', '?'))}" for p in participants
    )
    other_name = next(
        (
            p.get("display", p.get("id", "other"))
            for p in participants
            if p.get("role") != "user"
        ),
        "other",
    )
    user_name = settings.user_display_name
    chunk_note = metadata.get("chunk_note")

    body = f"""
--- CLASSIFICATION ---
{classification_json}

--- METADATA ---
Date: {metadata.get("date", "?")}
Source: {metadata.get("source", "?")}
Location: {metadata.get("location", "?")}
Participants: {participant_str}
User name: {user_name}
Other name: {other_name}
User hint: {metadata.get("user_hint") or "none"}
Locale: {settings.locale}
Redaction policy: financial={settings.redaction.financial} medical={settings.redaction.medical} legal={settings.redaction.legal} contact_info={settings.redaction.contact_info}
"""
    if chunk_note:
        body += f"Note: {chunk_note}\n"
    body += f"""
--- CONVENTIONS ---
{conventions}

--- SECTION STRUCTURE REMINDER ---
You MUST use EXACTLY these section headings in this order. Do NOT
invent your own headings. Do NOT skip sections. If a section has no
content, write the heading followed by "_Nothing to report._"

## Summary
## Key topics
## Decisions
## Action items
## Key quotes
## Key insights
## Next steps
## Cleaned transcript

Start your response with the YAML frontmatter block (---), then
## Summary. No preamble.

--- TRANSCRIPT ---
{transcript_chunk}
"""
    return body


# ── Step 03: relationship signal (per non-user participant) ─────────


def _step_relationship(
    client: OllamaClient,
    state_dir: Path,
    metadata: dict,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
) -> None:
    out_dir = state_dir / "03_relationship_signals"
    out_dir.mkdir(exist_ok=True)

    participants = metadata.get("participants") or []
    others = [p for p in participants if p.get("role") != "user"]
    if not others:
        logger.info("No non-user participants; skipping relationship signal.")
        return

    enrichment_md = (state_dir / "02_enrichment.md").read_text()
    template = prompts.load_prompt("03_relationship_signal")

    for other in others:
        slug = other.get("id", "other")
        display = other.get("display", slug)
        signal_path = out_dir / f"{slug}.json"
        if signal_path.exists():
            continue
        if dry_run:
            stub = {
                "target_participant": slug,
                "target_display_name": display,
                "observed_in": metadata["conversation_id"],
                "observed_at": datetime.now(timezone.utc).isoformat(),
                "warmth": {"score": "warm", "confidence": 0.8, "evidence": "dry-run"},
                "reciprocity": {"user_talk_share": 0.5, "other_talk_share": 0.5, "balance": "roughly_balanced", "confidence": 0.5, "evidence": "dry-run"},
                "energy": {"level": "medium", "valence": "neutral", "confidence": 0.5, "evidence": "dry-run"},
                "power_dynamic": {"shape": "peer", "notes": "", "confidence": 0.5},
                "topics_of_interest_to_other": [],
                "communication_style_observed": {"style_tags": [], "notes": ""},
                "notable_moments": [],
                "trust_and_rapport": {"signal": "stable_medium", "confidence": 0.5, "notes": "dry-run"},
                "relationship_category_hint": other.get("category") or "unknown",
                "overall_confidence": 0.5,
                "flags": {
                    "reclassify_relationship_needed": False,
                    "signal_too_weak_to_publish": False,
                    "sensitive_content_present": False,
                },
            }
            write_json(signal_path, stub)
            continue

        prompt_body = f"""
--- CLASSIFICATION ---
{json.dumps(classification.to_dict(), indent=2)}

--- METADATA ---
conversation_id: {metadata["conversation_id"]}
target_participant: {slug}
target_display_name: {display}
target_role_hint: {other.get("role") or "other"}
prior_relationship_label: {other.get("category") or "unknown"}

--- ENRICHED CONTENT ---
{enrichment_md}
"""
        full_prompt = template + "\n\n---\n\n" + prompt_body
        result = client.generate_json(
            settings.ollama_relationship_model,
            full_prompt,
            expect="object",
            priority="medium",
            timeout=600.0,
        )
        if result.parsed_json is None:
            logger.warning(
                "Relationship signal for %s failed to parse; skipping.", slug
            )
            continue
        write_json(signal_path, result.parsed_json)


# ── Step 04: coaching ────────────────────────────────────────────────


def _step_coach(
    client: OllamaClient,
    state_dir: Path,
    metadata: dict,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
) -> None:
    out_path = state_dir / "04_coaching.json"
    if out_path.exists():
        return

    enrichment_md = (state_dir / "02_enrichment.md").read_text()
    template = prompts.load_prompt("04_coaching")
    tone = settings.coaching_tone
    if tone == "configurable":
        tone = "supportive"  # sensible default when no per-invocation answer

    if dry_run:
        stub = {
            "observation_id": str(uuid.uuid4()),
            "conversation_id": metadata["conversation_id"],
            "observed_at": datetime.now(timezone.utc).isoformat(),
            "conversation_type": classification.suggested_type_slug,
            "tone": tone,
            "what_went_well": [],
            "what_to_work_on": [],
            "tip": {"text": "dry-run", "attachable_to_reminder": False},
            "tags": [],
            "overall_severity": 1,
            "confidence": 0.5,
            "flags": {
                "cross_conversation_pattern": False,
                "recommend_surfacing_to_user_soon": False,
                "sensitive_to_state_aloud": False,
            },
        }
        write_json(out_path, stub)
        return

    prompt_body = f"""
--- CLASSIFICATION ---
{json.dumps(classification.to_dict(), indent=2)}

--- METADATA ---
conversation_id: {metadata["conversation_id"]}
coaching_tone: {tone}
user_name: {settings.user_display_name}

--- ENRICHED CONTENT ---
{enrichment_md}
"""
    full_prompt = template + "\n\n---\n\n" + prompt_body
    result = client.generate_json(
        settings.ollama_coach_model,
        full_prompt,
        expect="object",
        priority="medium",
        timeout=600.0,
    )
    if result.parsed_json is None:
        logger.warning("Coach observation failed to parse; skipping.")
        return
    # Ensure observation_id
    if not result.parsed_json.get("observation_id"):
        result.parsed_json["observation_id"] = str(uuid.uuid4())
    write_json(out_path, result.parsed_json)


# ── Step 05: fact extraction ────────────────────────────────────────


def _step_facts(
    client: OllamaClient,
    state_dir: Path,
    metadata: dict,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
) -> None:
    out_path = state_dir / "05_facts.json"
    if out_path.exists():
        return

    # Use raw transcript for fact extraction  –  the enrichment summary
    # lacks the specific dialogue turns and speaker attributions the
    # model needs to produce evidenced facts.
    raw_transcript = (state_dir / "00_raw_transcript.md").read_text()
    template = prompts.load_prompt("05_fact_extraction")

    if dry_run:
        write_json(out_path, [])
        return

    # Build speaker label mapping so the model connects "Speaker 1"
    # in the transcript to actual participant names from metadata
    speaker_mapping = _build_speaker_mapping(metadata)

    prompt_body = f"""
--- CLASSIFICATION ---
{json.dumps(classification.to_dict(), indent=2)}

--- METADATA ---
conversation_id: {metadata["conversation_id"]}
participants: {json.dumps(metadata.get("participants") or [])}
{speaker_mapping}
--- TRANSCRIPT ---
{raw_transcript}
"""
    # Ask for an object wrapper {"facts": [...]} rather than a bare array.
    # The 35b MoE model handles object output reliably but gets confused
    # by bare array requests, sometimes returning essays about why it
    # can't comply.
    fact_schema_hint = (
        '{"facts": [{"text": "Sam works at ContactCo-F as a developer", '
        '"type": "fact", "subject": "other:alex_chen", '
        '"domain": "work", "confidence": "stated", '
        '"privacy_level": "L0", "signal_strength": "strong", '
        '"temporal": false, "evidence": "Sam said: I work at ContactCo-F"}]}'
    )
    full_prompt = template + "\n\n---\n\n" + prompt_body
    result = client.generate_json(
        settings.ollama_fact_model,
        full_prompt,
        expect="object",
        schema_hint=fact_schema_hint,
        priority="medium",
        timeout=600.0,
    )
    # Extract the facts array from the wrapper object
    if isinstance(result.parsed_json, dict):
        facts = result.parsed_json.get("facts", [])
        # If model returned a single fact without wrapper, wrap it
        if not facts and "text" in result.parsed_json:
            facts = [result.parsed_json]
    elif isinstance(result.parsed_json, list):
        facts = result.parsed_json
    else:
        facts = []

    # Post-process: fix speaker label attribution. Local models often
    # output "other:speaker" or "other:speaker_1" despite the mapping
    # hint. Map these back to actual participant IDs from metadata.
    facts = _fix_speaker_subjects(facts, metadata)

    # Stamp every freshly-extracted fact as a candidate. The 08_linked
    # step promotes facts to candidate=False when a second independent
    # source corroborates them. The LLM doesn't emit this field (the
    # prompt doesn't ask for it), so we default it here.
    for fact in facts:
        fact.setdefault("candidate", True)

    write_json(out_path, facts)


# ── Step 06: speaker feedback (v1 stub) ──────────────────────────────


def _step_speaker_feedback(
    client: OllamaClient,
    state_dir: Path,
    conversation_id: str,
    metadata: dict,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
) -> None:
    """Infer the real person behind each unresolved "Speaker N" label.

    TEXT-ONLY round-route (DESIGN_capture_ingest_and_speaker_identity §4):
    the Hub LLM reads the transcript plus a candidate list from the people
    graph and suggests a name for each generic speaker label. The device
    later binds the confirmed name to its LOCAL voiceprint, keyed by the
    opaque ``voice_fingerprint_ref`` the capture surface attached. The
    voice embedding NEVER crosses the wire; only the opaque ref is echoed.

    Writes ``06_speaker_feedback.json`` matching
    ``docs/speaker_label_feedback.schema.json``. Resolved speakers go in
    ``labels`` with an ``apply_mode`` derived from confidence; speakers the
    model could not name go in ``unresolved_labels`` (still carrying their
    ``voice_fingerprint_ref`` so the device can prompt the user to label).
    """
    out_path = state_dir / "06_speaker_feedback.json"
    if out_path.exists():
        return

    capture_source = metadata.get("capture_source", "cm042_mac")
    # Map of "Speaker N" -> voice_fingerprint_ref attached by the device.
    ref_by_label = _speaker_fingerprint_refs(metadata)

    def _empty() -> SpeakerLabelFeedback:
        return SpeakerLabelFeedback(
            feedback_id=str(uuid.uuid4()),
            conversation_id=conversation_id,
            produced_at=datetime.now(timezone.utc).isoformat(),
            capture_source=capture_source,
            labels=[],
            unresolved_labels=[],
            conversation_sensitivity_level=classification.sensitivity.level,
        )

    # Nothing to infer for a dry run, or when there are no generic speaker
    # labels in the transcript at all.
    raw_path = state_dir / "00_raw_transcript.md"
    if dry_run or not raw_path.exists():
        write_json(out_path, _empty().to_dict())
        return

    raw_transcript = raw_path.read_text()
    speaker_labels = _unresolved_speaker_labels(raw_transcript, ref_by_label)
    if not speaker_labels:
        write_json(out_path, _empty().to_dict())
        return

    candidates = _load_candidate_people(metadata, settings)
    template = prompts.load_prompt("06_speaker_inference")

    prompt_body = f"""
--- SPEAKER LABELS TO RESOLVE ---
{json.dumps(speaker_labels)}

--- CANDIDATE PEOPLE (known contacts; slug = inferred_person_id) ---
{json.dumps(candidates, indent=2)}

--- TRANSCRIPT ---
{raw_transcript}
"""
    schema_hint = (
        '{"labels": [{"raw_label": "Speaker 2", '
        '"inferred_person_id": "danny_kwan", '
        '"inferred_display_name": "Danny Kwan", "confidence": 0.92, '
        '"evidence": "addressed as Danny at turn 4"}], '
        '"unresolved_labels": [{"raw_label": "Speaker 3", '
        '"sample_turns": ["Speaker 3: I will send the deck."]}]}'
    )
    full_prompt = template + "\n\n---\n\n" + prompt_body

    try:
        result = client.generate_json(
            settings.ollama_fact_model,
            full_prompt,
            expect="object",
            schema_hint=schema_hint,
            priority="medium",
            timeout=600.0,
        )
        parsed = result.parsed_json if isinstance(result.parsed_json, dict) else {}
    except Exception as exc:  # inference must never wedge the pipeline
        logger.warning("speaker inference LLM call failed: %s", exc)
        parsed = {}

    feedback = _build_speaker_feedback(
        conversation_id=conversation_id,
        capture_source=capture_source,
        sensitivity_level=classification.sensitivity.level,
        parsed=parsed,
        speaker_labels=speaker_labels,
        ref_by_label=ref_by_label,
    )
    write_json(out_path, feedback.to_dict())


# Confidence at/above which a label may be auto-applied without prompting.
_SPEAKER_AUTO_APPLY_THRESHOLD = 0.9
# Confidence below which a label needs explicit user review before applying.
_SPEAKER_REVIEW_THRESHOLD = 0.7


def _speaker_fingerprint_refs(metadata: dict) -> dict[str, str | None]:
    """Map each "Speaker N" label to the opaque voice_fingerprint_ref the
    capture device attached. Returns {} when the device sent none.

    The device may carry refs either on participants (role-keyed) or on a
    dedicated ``speaker_fingerprints`` map ("Speaker 1" -> ref). We accept
    both shapes; the embedding itself is never present, only the ref.
    """
    refs: dict[str, str | None] = {}
    explicit = metadata.get("speaker_fingerprints")
    if isinstance(explicit, dict):
        for label, ref in explicit.items():
            refs[str(label)] = ref if isinstance(ref, str) else None
    participants = metadata.get("participants") or []
    for i, p in enumerate(participants, 1):
        if not isinstance(p, dict):
            continue
        ref = p.get("voice_fingerprint_ref")
        if ref:
            refs.setdefault(f"Speaker {i}", ref)
    return refs


def _unresolved_speaker_labels(
    transcript: str, ref_by_label: dict[str, str | None]
) -> list[dict]:
    """Find every distinct "Speaker N" label appearing as a turn prefix.

    Returns a list of {raw_label, voice_fingerprint_ref, sample_turns}
    in first-appearance order. Only generic labels are returned -- a turn
    already prefixed with a real name is considered resolved.
    """
    import re

    pattern = re.compile(r"^\s*(Speaker\s+\d+)\s*:\s*(.*)$")
    order: list[str] = []
    samples: dict[str, list[str]] = {}
    for line in transcript.splitlines():
        m = pattern.match(line)
        if not m:
            continue
        label = m.group(1).strip()
        # Normalise internal whitespace ("Speaker  2" -> "Speaker 2").
        label = re.sub(r"\s+", " ", label)
        if label not in samples:
            order.append(label)
            samples[label] = []
        if len(samples[label]) < 3 and m.group(2).strip():
            samples[label].append(f"{label}: {m.group(2).strip()}")
    return [
        {
            "raw_label": label,
            "voice_fingerprint_ref": ref_by_label.get(label),
            "sample_turns": samples[label],
        }
        for label in order
    ]


def _load_candidate_people(metadata: dict, settings: Settings) -> list[dict]:
    """Assemble candidate {id, display} contacts for the inference prompt.

    Sources, deduped by slug:
    1. non-user participants already named in the request metadata, and
    2. up to 200 known ``pwg:Person`` display names from the people graph.

    Degrades to whatever it can reach -- a graph outage yields the
    metadata-only list rather than failing the step.
    """
    candidates: dict[str, str] = {}
    for p in metadata.get("participants") or []:
        if not isinstance(p, dict) or p.get("role") == "user":
            continue
        slug = p.get("id")
        display = p.get("display") or p.get("id")
        if slug and display:
            candidates[str(slug)] = str(display)

    for row in _query_graph_people(settings):
        slug = row.get("slug")
        display = row.get("display")
        if slug and display:
            candidates.setdefault(slug, display)

    return [{"id": s, "display": d} for s, d in candidates.items()]


def _query_graph_people(settings: Settings) -> list[dict]:
    """Best-effort SPARQL fetch of known people (slug + display name).

    Person nodes are typed ``pwg:Person`` in the ``https://pwg.dev/
    ontology#`` namespace (see last_contact_updater). Returns [] on any
    failure -- candidate enrichment is optional, never load-bearing.
    """
    import httpx

    sparql = """
PREFIX pwg: <https://pwg.dev/ontology#>
SELECT DISTINCT ?slug ?display WHERE {
  ?person a pwg:Person ;
          pwg:displayName ?display .
  OPTIONAL { ?person pwg:slug ?slug . }
}
LIMIT 200
"""
    try:
        with httpx.Client(
            timeout=15.0, transport=httpx.HTTPTransport(proxy=None)
        ) as hc:
            resp = hc.post(
                f"{settings.oxigraph_url}/query",
                content=sparql,
                headers={
                    "Content-Type": "application/sparql-query",
                    "Accept": "application/sparql-results+json",
                },
            )
            resp.raise_for_status()
            data = resp.json()
    except Exception as exc:
        logger.info("speaker candidate people query unavailable: %s", exc)
        return []

    out: list[dict] = []
    for binding in data.get("results", {}).get("bindings", []):
        display = binding.get("display", {}).get("value", "")
        slug = binding.get("slug", {}).get("value", "")
        if not display:
            continue
        if not slug:
            slug = _slugify(display)
        out.append({"slug": slug, "display": display})
    return out


def _slugify(name: str) -> str:
    import re

    s = name.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "_", s)
    return s.strip("_") or "unknown"


def _build_speaker_feedback(
    *,
    conversation_id: str,
    capture_source: str,
    sensitivity_level: str,
    parsed: dict,
    speaker_labels: list[dict],
    ref_by_label: dict[str, str | None],
) -> SpeakerLabelFeedback:
    """Turn the raw LLM JSON into a validated SpeakerLabelFeedback.

    - Only labels whose raw_label was actually in the transcript survive.
    - Each resolved label is re-stamped with the device's
      voice_fingerprint_ref (the device is authoritative for the ref; the
      model must not influence it).
    - apply_mode is derived from confidence so the consumer knows whether
      to auto-apply, suggest, or force review.
    - Every transcript speaker not resolved (and >= the floor) lands in
      unresolved_labels, carrying its ref + sample turns.
    """
    valid_raw = {s["raw_label"] for s in speaker_labels}
    samples_by_label = {s["raw_label"]: s.get("sample_turns", []) for s in speaker_labels}

    labels: list[SpeakerLabel] = []
    resolved_raw: set[str] = set()
    for item in parsed.get("labels", []) or []:
        if not isinstance(item, dict):
            continue
        raw_label = str(item.get("raw_label", "")).strip()
        person_id = str(item.get("inferred_person_id", "")).strip()
        if raw_label not in valid_raw or not person_id:
            continue
        try:
            confidence = float(item.get("confidence", 0.0))
        except (TypeError, ValueError):
            confidence = 0.0
        confidence = max(0.0, min(1.0, confidence))
        display = str(item.get("inferred_display_name", "")).strip() or person_id
        if confidence >= _SPEAKER_AUTO_APPLY_THRESHOLD:
            apply_mode: str = "auto"
        elif confidence >= _SPEAKER_REVIEW_THRESHOLD:
            apply_mode = "suggest"
        else:
            apply_mode = "review_required"
        labels.append(
            SpeakerLabel(
                raw_label=raw_label,
                inferred_person_id=person_id,
                inferred_display_name=display,
                confidence=confidence,
                evidence=str(item.get("evidence", "")).strip(),
                # Device-authoritative ref; ignore anything the model emitted.
                voice_fingerprint_ref=ref_by_label.get(raw_label),
                apply_mode=apply_mode,  # type: ignore[arg-type]
            )
        )
        resolved_raw.add(raw_label)

    unresolved: list[dict] = []
    for raw_label in valid_raw - resolved_raw:
        unresolved.append(
            {
                "raw_label": raw_label,
                "voice_fingerprint_ref": ref_by_label.get(raw_label),
                "sample_turns": samples_by_label.get(raw_label, [])[:3],
            }
        )

    return SpeakerLabelFeedback(
        feedback_id=str(uuid.uuid4()),
        conversation_id=conversation_id,
        produced_at=datetime.now(timezone.utc).isoformat(),
        capture_source=capture_source,
        labels=labels,
        unresolved_labels=unresolved,
        conversation_sensitivity_level=sensitivity_level,
    )


# ── Step 07: ingest sinks ────────────────────────────────────────────


def _step_ingest(
    state_dir: Path,
    conversation_id: str,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
) -> None:
    """Step 07: write every artefact to its destination sink.

    L3 privacy short-circuit (L3 privacy contract): an L3 classification
    writes the on-disk markdown artefact but does NOT call the gist
    sinks (Qdrant / Oxigraph / coach DB / speaker feedback). Mirrors
    conversation_writer Path B and CM052 wire.post() behaviour,
    applied here as defence-in-depth on the legacy Path A.

    Resolution order for privacy_level: classification.privacy_level
    if present, else metadata['privacy_level'] persisted to state_dir,
    else "L1" (the prior default; NOT L3, to avoid silently
    suppressing legacy artefacts that genuinely should be ingested).
    """
    from . import ingest

    privacy_level = _resolve_privacy_level(state_dir, classification)
    if privacy_level == "L3":
        logger.info(
            "L3 short-circuit: skipping gist sinks for %s "
            "(markdown stays on disk)",
            conversation_id,
        )
        ingest._write_conversation_md(
            state_dir, conversation_id, settings, dry_run
        )
        return

    ingest.write_all(
        state_dir=state_dir,
        conversation_id=conversation_id,
        classification=classification,
        settings=settings,
        dry_run=dry_run,
    )


def _resolve_privacy_level(
    state_dir: Path,
    classification: Classification,
) -> str:
    """Return the conversation's effective privacy level.

    Priority:
      1. classification.privacy_level (if the schema has been extended
         to carry it).
      2. metadata['privacy_level'] from state_dir/00_metadata.json.
      3. "L1" (the historical default; chosen to avoid surprising
         existing pipelines that never set the field).
    """
    valid = ("L0", "L1", "L2", "L3")
    explicit = getattr(classification, "privacy_level", None)
    if isinstance(explicit, str) and explicit.upper() in valid:
        return explicit.upper()
    metadata_path = state_dir / "00_metadata.json"
    if metadata_path.exists():
        try:
            metadata = json.loads(metadata_path.read_text())
        except (OSError, json.JSONDecodeError):
            metadata = {}
        raw = metadata.get("privacy_level")
        if isinstance(raw, str) and raw.upper() in valid:
            return raw.upper()
    return "L1"


# ── Step 08: cross-conversation linking ────────────────────────────


def _step_link(
    state_dir: Path,
    conversation_id: str,
    settings: Settings,
    dry_run: bool,
) -> None:
    """Find related conversations via Qdrant similarity search and
    update the enrichment frontmatter + emit Oxigraph triples."""
    from .linker import (
        extract_summary_for_linking,
        find_related,
        update_frontmatter,
        write_link_triples,
    )

    out_path = state_dir / "08_links.json"
    if out_path.exists():
        return

    enrichment_path = state_dir / "02_enrichment.md"
    summary_text = extract_summary_for_linking(enrichment_path)
    if not summary_text:
        logger.info("No summary text for linking; skipping.")
        write_json(out_path, {"related_ids": [], "scores": {}})
        return

    link_result = find_related(
        conversation_id=conversation_id,
        summary_text=summary_text,
        settings=settings,
        dry_run=dry_run,
    )

    # Write triples to Oxigraph
    triples = write_link_triples(link_result, settings, dry_run=dry_run)

    # Update enrichment frontmatter with related IDs
    if link_result.related_ids and not dry_run:
        update_frontmatter(enrichment_path, link_result.related_ids)

    # Foundry candidate promotion: check this conversation's candidate
    # facts against the corpus for corroborating evidence, flipping
    # pairs to non-candidate when a second independent source supports
    # the same claim. Runs here because all sinks are written by now  – 
    # the fact triples exist in Oxigraph and Qdrant for SPARQL/search
    # to find them.
    from .candidates import promote_corroborated
    candidate_stats = promote_corroborated(
        conversation_id=conversation_id,
        state_dir=state_dir,
        settings=settings,
        dry_run=dry_run,
    )

    # Persist link results
    write_json(out_path, {
        "related_ids": link_result.related_ids,
        "scores": link_result.scores,
        "oxigraph_triples_emitted": triples,
        "candidate_promotion": candidate_stats,
    })
    logger.info(
        "Linked %s to %d related conversations; candidates %s",
        conversation_id,
        len(link_result.related_ids),
        candidate_stats,
    )


# ── Step 09: four-artefact bundle (HR015 2026-05-09) ────────────────


def _step_bundle(
    client: OllamaClient,
    state_dir: Path,
    metadata: dict,
    classification: Classification,
    settings: Settings,
    privacy_level: str,
    *,
    ingest_sinks: bool,
    dry_run: bool,
) -> None:
    """Produce the four-artefact bundle for a human conversation.

    Two sub-steps fold into one pipeline step for resumability:

    1. Bundle extraction LLM call -- summary + topics + todos.
       Output cached at ``09_bundle.json`` so a partial-pipeline
       restart doesn't re-run the model.
    2. Channel-adapter dispatch + write_conversation -- builds
       the ``ConversationBundle`` and writes the three markdown
       artefacts atomically under
       ``~/Documents/Ostler/Conversations/<YYYY-MM-DD>/<slug>-<short-id>/``.

    The writer's gist callback is intentionally NOT supplied: the
    gist arm is step 07 (already run, or skipped for L3); step 09
    only does the episodic side. Mirrors CM052 wire 2026-05-08
    pattern where ``stage_episodic`` is independent of
    ``post()``'s CM048 POST.

    Honours ``ingest_sinks=False`` for tests / dry-runs by
    skipping the on-disk write while still producing
    ``09_bundle.json`` -- so the smoke test can assert the LLM
    call shape without polluting the customer's filesystem.
    """
    bundle_json_path = state_dir / "09_bundle.json"
    transcript_path = state_dir / "00_raw_transcript.md"
    enrichment_path = state_dir / "02_enrichment.md"

    if not transcript_path.exists():
        logger.warning(
            "No raw transcript at %s; skipping bundle step", transcript_path
        )
        return

    transcript = transcript_path.read_text(encoding="utf-8")
    enrichment_md = (
        enrichment_path.read_text(encoding="utf-8")
        if enrichment_path.exists()
        else ""
    )

    # ── Sub-step A: extraction (LLM call, cached on disk) ──────────
    if bundle_json_path.exists():
        extraction = _bundle_extractor.BundleExtraction.from_dict(
            read_json(bundle_json_path)
        )
    elif dry_run:
        # Dry-run stub matches the shape the live extractor would
        # produce so downstream code paths exercise unchanged. The
        # smoke test relies on this surfacing 09_bundle.json.
        extraction = _bundle_extractor.BundleExtraction(
            overall_summary="[dry-run] stub overall summary.",
            topics=[
                {
                    "name": "Dry-Run Topic",
                    "points": ["Stub point one.", "Stub point two."],
                }
            ],
            todos=[],
        )
        write_json(bundle_json_path, extraction.to_dict())
    else:
        extraction = _bundle_extractor.extract(
            client,
            transcript=transcript,
            enrichment_md=enrichment_md,
            channel=str(metadata.get("channel") or "spoken"),
            model=settings.ollama_enrich_model,
            locale=settings.locale,
            timeout=600.0,
        )
        write_json(bundle_json_path, extraction.to_dict())

    # ── Sub-step B: bundle assembly + atomic write ─────────────────
    if not ingest_sinks:
        logger.info(
            "ingest_sinks=False; skipping disk bundle write for %s",
            metadata.get("conversation_id"),
        )
        return

    try:
        bundle = _channel_adapter.make_bundle(
            metadata=metadata,
            classification=classification,
            extraction=extraction,
            transcript=transcript,
            privacy_level=privacy_level,
        )
    except NotImplementedError as exc:
        # Per-source PR sequence (CM042 -> CM040 -> CM046 -> CM047).
        # When a channel hasn't yet had its adapter PR merged, the
        # bundle write is skipped without raising -- the gist arm
        # already ran (or was correctly skipped for L3) so the
        # conversation isn't lost; the adapter PR backfills the
        # episodic artefacts next time the conversation is re-run.
        logger.warning(
            "Bundle adapter not implemented for channel=%r (%s). "
            "Re-run after the per-source PR lands to backfill the "
            "episodic bundle.",
            metadata.get("channel"),
            exc,
        )
        return

    output = _conversation_writer.write_conversation(
        bundle,
        root=settings.output_conversations_dir,
        gist_post_fn=None,
    )
    logger.info(
        "Bundle written for %s at %s (privacy=%s, gist=%s)",
        bundle.conversation_id,
        output.folder,
        output.privacy_level,
        output.gist_status,
    )

    # #311: refresh per-person lastContact<Channel> recency signal.
    # Post-CM047 retirement, CM048 owns the WhatsApp lastContactWhatsApp
    # write the wiki person-page recency row / CM041 stale-contacts /
    # CM031 badge consume. update_last_contact_for_bundle is a no-op for
    # channels without a recency predicate, for L3 bundles, and on a
    # SPARQL hiccup -- the conversation is already written, this is a
    # secondary index and must never fail the ingest.
    from .last_contact_updater import update_last_contact_for_bundle
    try:
        update_last_contact_for_bundle(
            bundle, oxigraph_url=settings.oxigraph_url
        )
    except Exception as exc:  # pragma: no cover - defensive
        logger.warning(
            "lastContact update failed for %s: %s",
            bundle.conversation_id, type(exc).__name__,
        )


# ── Helpers ──────────────────────────────────────────────────────────


def _load_classification(state_dir: Path) -> Classification | None:
    path = state_dir / "01_classification.json"
    if not path.exists():
        return None
    return Classification.from_dict(read_json(path))
