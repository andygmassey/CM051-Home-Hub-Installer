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
import re
import threading
import time
import uuid
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from . import attribution
from . import capture_truth as _capture_truth
from . import language as _language
from . import prompts
from . import enrichment_validation
from . import bulk_classifier as _bulk_classifier
from . import bundle_extractor as _bundle_extractor
from . import channel_adapter as _channel_adapter
from . import handle_resolver as _handle_resolver
from . import conversation_writer as _conversation_writer
from . import outstanding_todos as _outstanding_todos
from . import privacy as _privacy
from .chunker import chunk_transcript, describe as describe_chunks
from .ollama_client import OllamaClient
from .participants import normalise_participants
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

    # v1.0.107 #11: the Hub's assistant API (CM041 ical-server) records a
    # dispatch failure in state.json as failed_step="processor", which is a
    # DISPATCHER label, not a pipeline step. ``retry`` / ``retry-all`` pass
    # failed_step straight in here, and _should_run then did
    # PIPELINE_STEP_ORDER.index("processor") -> ValueError, so the manual
    # retry crashed on exactly the conversations it exists for. A resume
    # point we do not recognise means "resume from whatever is not yet
    # completed", which is what resume_from_step=None already does.
    if resume_from_step is not None and resume_from_step not in PIPELINE_STEP_ORDER:
        logger.warning(
            "resume_from_step %r is not a pipeline step; resuming from the "
            "first incomplete step", resume_from_step,
        )
        resume_from_step = None

    # v1.0.107 #12: CM031's iPhone / Watch envelope sends participants as
    # a list of speaker-label STRINGS; every reader here expects dicts.
    # Normalise once on entry so 00_metadata.json (read back by the sink
    # writers) carries the dict shape too. Each reader also normalises,
    # so a direct caller that skips process() is covered as well.
    # In place, like the non_relational stamp below, so a caller holding
    # the dict sees the same metadata the pipeline ran on.
    if "participants" in metadata:
        metadata["participants"] = normalise_participants(
            metadata.get("participants")
        )

    # Update detection. A connector re-POSTs the SAME conversation_id when
    # the thread grows (a new reply, comment or message). Before this,
    # _write_raw kept the first transcript and every completed step was
    # skipped, so the update was answered "complete" and silently lost.
    # Now: a changed transcript or metadata supersedes the cached step
    # outputs and the pipeline re-runs; a byte-identical re-POST changes
    # nothing and makes no LLM call.
    content_changed = _supersede_if_changed(
        state_dir, conversation_id, transcript, metadata,
        cooldown_seconds=0 if dry_run else settings.reprocess_cooldown_seconds,
    )
    if content_changed:
        # The cached completed_steps are gone; a resume point from the
        # earlier version no longer means anything.
        resume_from_step = None

    # Step 00  –  write raw transcript (rewritten on an update)
    _write_raw(state_dir, conversation_id, transcript, metadata)
    _write_content_hash(state_dir, transcript, metadata)

    # Load or create state
    state = _load_or_new_state(state_dir, conversation_id)
    if not content_changed:
        _restore_completed_steps_reset_by_the_hub(state_dir, state)
    state.advance("00_raw")
    _save_state(state_dir, state)

    client = OllamaClient(base_url=settings.ollama_url)

    # Gist-only channel declared L3 by its producer: nothing CM048 makes for
    # it can land (no gist for L3, no bundle for a gist-only channel), so
    # stop BEFORE the first model call. See GIST_ONLY_CHANNELS.
    if _is_gist_only(metadata) and _privacy.normalise(
        metadata.get("privacy_level") or ""
    ) == "L3" and metadata.get("privacy_level") is not None:
        return _stop_gist_only_l3(
            state_dir, conversation_id, state, settings,
            ingest_sinks=ingest_sinks, dry_run=dry_run,
        )

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

    # Mini16 2026-10-15: a one-speaker iPhone voice memo was classified
    # social/one-on-one and enriched as a call with an invented second
    # person. The speaker count is a fact the pipeline measures, so it
    # overrides the model's shape and is persisted, so every later step
    # (and a resume) reads the same classification.
    #
    # A memo is ALWAYS kept. 01_classify.md used to tell the model to answer
    # processing_depth "none" for a solo voice memo, and "none" stops the
    # pipeline below: the memo was silently never written. Whether to skip
    # is decided here, in code, from what we measured: a capture with no
    # speech (capture_truth.has_speech) is skipped, a memo with speech is
    # kept.
    if _capture_truth.is_spoken(metadata) and not _capture_truth.has_speech(
        transcript, metadata
    ):
        # A spoken capture with no speech in it (silence markers, Whisper's
        # "Thank you." hallucination, a bare label) is never enriched,
        # whatever the model said: no summary, no facts, no bundle.
        if classification.processing_depth != "none":
            classification.processing_depth = "none"
            classification.reasoning = (
                "no speech: the pipeline found fewer than "
                f"{_capture_truth.MIN_SPEECH_WORDS} spoken words. "
                + (classification.reasoning or "")
            )
            write_json(state_dir / "01_classification.json", classification.to_dict())
        logger.info("No speech in %s; nothing to enrich.", conversation_id)
    elif _capture_truth.is_single_speaker_capture(transcript, metadata):
        changed = False
        if classification.shape != _capture_truth.MEMO_SHAPE:
            classification = _capture_truth.as_memo(classification)
            changed = True
        if classification.processing_depth == "none":  # has_speech held above
            classification.processing_depth = "full"
            classification.reasoning = (
                "memo kept: the model said processing_depth none. "
                + (classification.reasoning or "")
            )
            changed = True
        if changed:
            write_json(state_dir / "01_classification.json", classification.to_dict())
            logger.info(
                "Single-speaker capture %s: classified as %s, depth %s",
                conversation_id, classification.suggested_type_slug,
                classification.processing_depth,
            )

    if classification.processing_depth == "none":
        logger.info("processing_depth=none  –  pipeline stops here.")
        # An update reclassified as "do not process" must not keep the
        # earlier version's facts in the stores either.
        if ingest_sinks:
            _retract_previous_gist_if_pending(
                state_dir, conversation_id, settings, dry_run
            )
        _clear_update_marker_if_settled(state_dir, state)
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
    # Same rule when L3 came from the classifier (a sensitive AI chat):
    # the one classify call was needed to decide; nothing after it is.
    if _is_gist_only(metadata) and resolved_privacy_level == "L3":
        return _stop_gist_only_l3(
            state_dir, conversation_id, state, settings,
            ingest_sinks=ingest_sinks, dry_run=dry_run,
        )

    # Andy's #30 walk, SHAPE 1 (new facts): resolve a carded contact's raw
    # phone/email handle to their NAME so the extraction LLM writes "Jane
    # Doe agreed to..." not "+447700900123 agreed to...". The
    # extraction steps below read the `transcript` var, so resolving here still
    # reaches the fact text.
    #
    # PLACED AFTER the privacy level is resolved and SKIPPED for L3 (Archie #87
    # privacy review): an L3 conversation must produce ZERO store traffic, and
    # name resolution reads the People graph, so it must never run for L3. The
    # guard is test_pipeline_l3_conversation_lands_no_topics (oxigraph.requests
    # == []). Guarded: an unreachable graph leaves handles unresolved, never
    # blocks ingest.
    if resolved_privacy_level != "L3":
        try:
            transcript, metadata = _handle_resolver.resolve(transcript, metadata, settings)
        except Exception as exc:  # noqa: BLE001 -- must never block ingest
            logger.warning("handle resolution skipped for %s: %s", conversation_id, exc)

    # Non-relational gate (bulk / marketing / no-reply email).
    # CM046 feeds newsletters, shipping notifications and marketing
    # blasts through this pipeline as ``channel="email"`` conversations
    # that are structurally identical to genuine person-to-person mail.
    # Left ungated they fan a relationship signal, extracted facts and a
    # contact-recency bump onto every co-recipient's person page – a
    # "28car" digest ends up as an interaction on two real people who
    # never corresponded. Detect it here, UPSTREAM of the relationship-
    # graph steps, and keep it out of the graph while still letting the
    # message land as browseable content in the Conversations wing (the
    # bundle step stamps ``non_relational`` so CM044 can suppress the
    # person-page attachment). Only the email channel carries the
    # signals; every other channel returns a non-bulk verdict.
    bulk_verdict = _bulk_classifier.classify(metadata)
    if bulk_verdict.is_non_relational:
        logger.info(
            "Non-relational (bulk/marketing) conversation %s "
            "[%s]: %s – skipping relationship / coaching / fact "
            "fan-out and tagging bundle non_relational.",
            conversation_id,
            bulk_verdict.confidence,
            bulk_verdict.reason_text,
        )
        # Stamp the metadata so the bundle adapter records the verdict
        # in ``extra_metadata`` for the downstream (CM044) consumer.
        metadata["non_relational"] = True
        metadata["non_relational_reason"] = bulk_verdict.reason_text

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
    #  Skipped for non-relational bulk mail: a mailing-list / no-reply
    #  "conversation" has no relationship to signal about its recipients.
    if _should_run(
        "03_relationship_signal", state.completed_steps, resume_from_step
    ) and _should_run_relationship(classification) and not bulk_verdict.is_non_relational:
        _run_step(
            state_dir,
            state,
            "03_relationship_signal",
            lambda: _step_relationship(
                client, state_dir, metadata, classification, settings, dry_run
            ),
        )

    # Step 04  –  coaching (conditional)
    #  Skipped for non-relational bulk mail: there is no two-way
    #  conversation for the user to be coached on.
    if _should_run(
        "04_coaching", state.completed_steps, resume_from_step
    ) and _should_run_coach(classification) and not bulk_verdict.is_non_relational:
        _run_step(
            state_dir,
            state,
            "04_coaching",
            lambda: _step_coach(
                client, state_dir, metadata, classification, settings, dry_run
            ),
        )

    # Step 05  –  fact extraction
    #  Skipped for non-relational bulk mail: facts extracted from a
    #  marketing / transactional body fan onto ``other:<slug>`` subjects
    #  (co-recipients), polluting real people's pages with newsletter
    #  content. Genuine correspondence is unaffected.
    if _should_run(
        "05_fact_extraction", state.completed_steps, resume_from_step
    ) and classification.processing_depth == "full" and not bulk_verdict.is_non_relational:
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
        def _ingest_replacing_earlier_version() -> None:
            # An update REPLACES its earlier facts: retract first, then
            # the writers add the current version. Inside the step so a
            # failed retraction fails (and retries) step 07.
            _retract_previous_gist_if_pending(
                state_dir, conversation_id, settings, dry_run
            )
            _step_ingest(
                state_dir, conversation_id, classification, settings, dry_run
            )

        _run_step(
            state_dir,
            state,
            "07_sinks_written",
            _ingest_replacing_earlier_version,
        )
    elif resolved_privacy_level == "L3":
        logger.info(
            "L3 short-circuit: skipping step 07 (gist sinks) for %s",
            conversation_id,
        )
        # An update that turned the conversation L3 (the operator
        # labelled the chat private, say) must not leave the earlier
        # version's facts in the stores. This is the only store traffic
        # an L3 conversation makes, it is a DELETE, and it happens only
        # when an earlier non-L3 version was actually written. A first
        # L3 POST has no marker and makes no request at all.
        if ingest_sinks:
            try:
                _retract_previous_gist_if_pending(
                    state_dir, conversation_id, settings, dry_run
                )
            except Exception as exc:
                state.fail(
                    "07_sinks_written",
                    f"retraction of the earlier non-L3 version failed: "
                    f"{type(exc).__name__}: {exc}",
                )
                _save_state(state_dir, state)
                raise RuntimeError(
                    "Step 07_sinks_written failed (L3 update retraction). "
                    "See state.json."
                ) from exc

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

    # Read BEFORE the marker is cleared: the earlier version's bundle
    # location lives in it.
    stale_folders = _pending_stale_bundle_folders(state_dir, state)
    _clear_update_marker_if_settled(state_dir, state)
    _record_processed_state(state_dir, state)
    logger.info(
        "Pipeline complete for %s. Steps: %s",
        conversation_id,
        state.completed_steps,
    )
    # After completion is recorded, never before: the sweep is cleanup,
    # and nothing it does (or fails to do) may change the outcome.
    if ingest_sinks and stale_folders is not None:
        keep = _read_bundle_location(state_dir)
        if keep is not None:
            _sweep_stale_bundles_bounded(
                settings.output_conversations_dir,
                conversation_id,
                stale_folders,
                keep=keep,
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
    if c.shape == _capture_truth.MEMO_SHAPE:
        return False  # one speaker: there is no relationship to signal
    if c.setting in ("public", "service"):
        return False
    if c.sensitivity.level == "highly-sensitive":
        return False
    return True


def _should_run_coach(c: Classification) -> bool:
    if c.processing_depth != "full":
        return False
    if c.shape == _capture_truth.MEMO_SHAPE:
        return False  # one speaker: no exchange to coach
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

# --- v1018-D031: a total wall-clock allowance for the enrichment step ----
#
# Every LLM call in _step_enrich was already individually bounded at 900s.
# That is why no per-call timeout could fix this: nothing was ever stuck.
# The step simply has a very large BOUNDED worst case --
#
#   3-4 chunks x 900s + merge 900s + validation retry 900s   ~= 1h15m
#   x MAX_RETRIES (3), backoff 30s + 60s                     ~= 4h30m
#
# -- four and a half hours, by design, for one email. On the shipped box a
# single 236KB newsletter thread (2.8x the next largest document) sat in
# this step from 03:47 until it was killed, holding the shared ingest lock
# and stopping all four conversation feeds.
#
# So the ceiling belongs on the STEP, not on the call. Each call is given
# whatever remains of the document's allowance, so the total cannot exceed
# it however the chunks divide up.
#
# The deadline is module-level rather than threaded through
# _merge_chunk_outputs / _validate_and_maybe_retry because pwg-convo
# processes exactly ONE document per invocation (`pwg-convo process
# <transcript> <metadata>`), single-threaded -- so there is never a second
# concurrent budget in this process. Threading it through would mean
# changing three signatures in a vendored tree whose source repo is
# git-sick and whose divergence patch must be hand-crafted.
_ENRICH_BUDGET_DEFAULT_SECS = 1800
_ENRICH_CALL_CEILING_SECS = 900.0

_enrich_deadline: float | None = None


class EnrichmentBudgetExceeded(Exception):
    """The enrichment step used up its total wall-clock allowance."""


def _enrich_budget_secs():
    """Total allowance for one document, or None for unbounded.

    ``OSTLER_ENRICH_BUDGET_SECS=0`` restores the old behaviour. A
    malformed value falls back to the default rather than raising -- a
    typo in an env var must not be the thing that stops ingest.
    """
    raw = os.environ.get("OSTLER_ENRICH_BUDGET_SECS")
    if raw is None or not raw.strip():
        return float(_ENRICH_BUDGET_DEFAULT_SECS)
    try:
        secs = float(raw)
    except ValueError:
        return float(_ENRICH_BUDGET_DEFAULT_SECS)
    return None if secs <= 0 else secs


def _budget_timeout(ceiling: float = _ENRICH_CALL_CEILING_SECS) -> float:
    """Timeout for the next LLM call: whatever is left of the allowance.

    Raises EnrichmentBudgetExceeded rather than issuing a call that
    cannot finish inside the document's remaining time.
    """
    if _enrich_deadline is None:
        return ceiling
    remaining = _enrich_deadline - time.monotonic()
    if remaining <= 0:
        raise EnrichmentBudgetExceeded(
            f"enrichment budget exhausted before the next model call "
            f"(allowance {_enrich_budget_secs()}s; raise or disable it with "
            f"OSTLER_ENRICH_BUDGET_SECS)"
        )
    return min(ceiling, remaining)
# ------------------------------------------------------------------------
BASE_DELAY_SECONDS = 30


class SinkUnavailableError(RuntimeError):
    """A step failed because the model / gateway could not be REACHED (refused
    connection, DNS, 502/503/504), not because it rejected this document.
    ``pwg-convo process`` exits 75 (EX_TEMPFAIL) on it so a catch-up caller
    can tell an outage from a poisoned item."""


def _is_sink_unreachable(exc: BaseException) -> bool:
    import httpx

    if isinstance(exc, httpx.HTTPStatusError):
        return exc.response.status_code in (502, 503, 504)
    if isinstance(exc, httpx.TimeoutException):
        # Only a connect timeout: a read timeout is one slow document.
        return isinstance(exc, httpx.ConnectTimeout)
    if isinstance(exc, (httpx.ConnectError, ConnectionError)):
        return True
    return False


def _is_retryable(exc: Exception) -> bool:
    """Classify whether an exception is worth retrying.

    Retryable: timeouts, 503 (service unavailable), 429 (rate limit),
    connection errors  –  transient infrastructure issues.

    Permanent: 400 (bad request / malformed input), 404, 422,
    JSON parse failures, value errors  –  retrying won't help.
    """
    import httpx

    # v1018-D031. Retrying a budget exhaustion just spends the budget
    # again, and MAX_RETRIES would multiply the step ceiling by three --
    # which is precisely the arithmetic that made a 4h30m worst case
    # possible in the first place. Checked FIRST because the function
    # ends in `return True`: every unrecognised exception is retried.
    if isinstance(exc, EnrichmentBudgetExceeded):
        return False

    if isinstance(exc, (TimeoutError, ConnectionError, OSError)):
        return True
    if isinstance(exc, httpx.TimeoutException):
        return True
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
                if _is_sink_unreachable(exc):
                    raise SinkUnavailableError(
                        f"Step {step}: model or gateway unreachable "
                        f"({type(exc).__name__}). See state.json."
                    ) from exc
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
    """Persist the transcript + metadata before any LLM call.

    Written when absent, and REWRITTEN when the content differs (an
    update, already detected by ``_supersede_if_changed``). Every later
    step reads these files back (05 facts, 07 sinks, 09 bundle), so a
    write-once raw file is what made an update invisible downstream.
    Unchanged content is not rewritten, so the files keep their mtime.
    """
    raw_path = state_dir / "00_raw_transcript.md"
    if not raw_path.exists() or raw_path.read_text() != transcript:
        raw_path.write_text(transcript)
    meta_path = state_dir / "00_metadata.json"
    if not meta_path.exists() or _canonical_json(
        _hashed_metadata(read_json(meta_path))
    ) != _canonical_json(_hashed_metadata(metadata)):
        write_json(meta_path, metadata)


# ── Update detection ────────────────────────────────────────────────

CONTENT_HASH_FILE = "content_hash.json"
# Written when an update supersedes an earlier version; read by step 07
# (retract the earlier gist writes first) and step 09 (remove a bundle
# folder the update no longer writes to); removed once the re-run
# completes. No step-number prefix, so `cli reprocess --from-step` never
# archives it.
UPDATE_MARKER_FILE = "update_pending.json"
# Where step 09 wrote this version's bundle. Moved to _superseded/ by an
# update like any step output; its value is first copied into the update
# marker, so the re-run knows the exact folder to clean up without
# listing ~/Documents/Ostler/Conversations (an opendir there can block
# forever under launchd, see _remove_stale_bundle_folders).
BUNDLE_LOCATION_FILE = "bundle_location.json"
SUPERSEDED_DIR = "_superseded"
# Files that belong to the conversation, not to a step's cached output.
_KEEP_ON_SUPERSEDE = {
    "state.json",
    "00_raw_transcript.md",
    "00_metadata.json",
    CONTENT_HASH_FILE,
    UPDATE_MARKER_FILE,
    SUPERSEDED_DIR,
}


class UpdateDeferred(RuntimeError):
    """A changed re-POST arrived inside the reprocess cooldown window.

    Nothing was written: the stored version, its artefacts and its facts
    are untouched, so the caller must re-send later (the CLI exits 75,
    the HTTP endpoint answers 429). See Settings.reprocess_cooldown_seconds.
    """

    def __init__(self, conversation_id: str, retry_after_seconds: int) -> None:
        super().__init__(
            f"update to {conversation_id} deferred: the previous version was "
            f"accepted under the reprocess cooldown; retry in "
            f"{retry_after_seconds}s"
        )
        self.conversation_id = conversation_id
        self.retry_after_seconds = retry_after_seconds


def _canonical_json(obj: object) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


# Which metadata keys decide "this conversation changed" (CM048 #93).
#
# Hashing the WHOLE dict would make any volatile field a producer adds (a
# post timestamp, a run id, a retry counter) turn every unchanged re-POST
# into a full re-run: about six LLM calls per conversation per tick. So the
# change hash covers a DECLARED subset: the keys that reach an artefact, a
# prompt, or a privacy decision. Every key the shipped producers send was
# classified on 2026-10-19 (CM051 origin/main):
#   iMessage  vendor/imessage_source/threader.py:185-200
#   WhatsApp  vendor/whatsapp_source/renderer.py:215-245
#   Mail      vendor/email_source/threader.py:298-320
#   Mbox/import vendor/ostler_fda/universal_import.py:1509-1521
#   Spoken    vendor/spoken_source/renderer.py:215-243
#   iOS capture vendor/cm041/assistant_api/ical-server.py:2474-2476
#     (caller's dict passed through + conversation_id + channel default)
#   CM052 wire  src/cm052/wire.py:444-457 (CM052 repo; reaches CM048 via
#     the Hub API above). ``extra`` is the connector's free-form dict and
#     is NOT hashed: a connector's content belongs in the transcript.
# tests/test_update_reprocess.py pins that list: a producer key in neither
# set fails it, so a new key is a decision, not an accident. A key that
# arrives unclassified at run time is logged and left out of the hash
# (an extra no-op beats an unbounded re-run loop).
METADATA_HASH_KEYS: frozenset = frozenset({
    # identity and routing
    "conversation_id", "channel", "source", "source_app", "source_subtype",
    "provenance", "participant_kind",
    "source_session_id", "chat_identifier", "chat_jid", "service",
    # who and when (frontmatter, folder slug, speaker mapping)
    "participants", "date", "started_at", "ended_at",
    "is_group_chat", "chat_type", "group_subject",
    # privacy (L3 short-circuit, WhatsApp/email ladders)
    "privacy_level", "contact_label", "group_label",
    # content shaping (prompts, titles, language)
    "subject", "title", "email_thread", "shape", "context", "language",
    "tags", "location", "user_hint", "is_voice_note",
})
# Known keys deliberately NOT hashed: bookkeeping that does not change what
# is written, or values that move on every send.
METADATA_IGNORED_KEYS: frozenset = frozenset({
    "capture_source", "contact_source_tier", "diarization_method", "extra",
    "duration_seconds", "message_count",
    "posted_at", "received_at", "ingested_at", "generated_at",
    "extracted_at", "sent_at", "run_id", "request_id", "attempt",
    "retry_count", "non_relational", "non_relational_reason",
})


def _hashed_metadata(metadata: dict) -> dict:
    return {k: metadata[k] for k in metadata if k in METADATA_HASH_KEYS}


def content_fingerprint(transcript: str, metadata: dict) -> dict:
    """sha256 of the transcript and of the declared stable metadata subset."""
    return {
        "transcript_sha256": hashlib.sha256(transcript.encode("utf-8")).hexdigest(),
        "metadata_sha256": hashlib.sha256(
            _canonical_json(_hashed_metadata(metadata)).encode("utf-8")
        ).hexdigest(),
    }


def _log_unclassified_metadata_keys(conversation_id: str, metadata: dict) -> None:
    unknown = sorted(
        k for k in metadata
        if k not in METADATA_HASH_KEYS and k not in METADATA_IGNORED_KEYS
    )
    if unknown:
        logger.info(
            "metadata keys outside the change hash for %s (unclassified): %s",
            conversation_id, ", ".join(unknown),
        )


def _read_hash_record(state_dir: Path) -> dict:
    hash_path = state_dir / CONTENT_HASH_FILE
    if not hash_path.exists():
        return {}
    try:
        data = read_json(hash_path)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


# Cached step outputs written AFTER the raw file in a normal run. A raw file
# NEWER than any of them was rewritten after they were made: the Hub API
# writes the new raw text into the state dir before pwg-convo runs.
_CACHED_OUTPUTS = ("01_classification.json", "05_facts.json", "09_bundle.json")


def _raw_rewritten_after_processing(state_dir: Path) -> bool:
    raw = state_dir / "00_raw_transcript.md"
    if not raw.exists():
        return False
    raw_mtime = raw.stat().st_mtime
    return any(
        (state_dir / name).exists() and (state_dir / name).stat().st_mtime < raw_mtime
        for name in _CACHED_OUTPUTS
    )


def _legacy_gist_probably_written(state_dir: Path) -> bool:
    """A pre-content_hash state dir whose state.json the Hub reset: facts
    exist and the stored metadata is not L3, so step 07 wrote them. A
    retraction when nothing was written is a harmless no-op delete; an L3
    conversation never gets one."""
    if not (state_dir / "05_facts.json").exists():
        return False
    try:
        level = str(read_json(state_dir / "00_metadata.json").get("privacy_level") or "")
    except (OSError, ValueError, AttributeError):
        level = ""
    return level.strip().upper() != "L3"


def _record_processed_state(state_dir: Path, state: PipelineState) -> None:
    """Remember, in a file only CM048 writes, how far this version got."""
    if state.failed_step is not None:
        return
    record = _read_hash_record(state_dir)
    if not record:
        return
    record["completed_steps"] = list(state.completed_steps)
    if "07_sinks_written" in state.completed_steps:
        record["gist_written"] = True
    write_json(state_dir / CONTENT_HASH_FILE, record)


def _restore_completed_steps_reset_by_the_hub(
    state_dir: Path, state: PipelineState
) -> None:
    """Unchanged content after the Hub reset state.json: put back the steps
    this version already completed, so the re-POST is a true no-op (no
    re-embedding, no sink rewrite) on that path too."""
    if state.failed_step is not None:
        return
    recorded = _read_hash_record(state_dir).get("completed_steps") or []
    for step in recorded:
        if step in PIPELINE_STEP_ORDER and step not in state.completed_steps:
            state.completed_steps.append(step)


def _stored_fingerprint(state_dir: Path) -> dict | None:
    """The fingerprint of the version already processed, or None.

    Prefers content_hash.json; a state dir from before this change has
    none, so the stored raw files are hashed instead (same function, so
    an unchanged legacy conversation compares equal and stays a no-op).
    """
    hash_path = state_dir / CONTENT_HASH_FILE
    if hash_path.exists():
        try:
            data = read_json(hash_path)
            if data.get("transcript_sha256") and data.get("metadata_sha256"):
                return {
                    "transcript_sha256": data["transcript_sha256"],
                    "metadata_sha256": data["metadata_sha256"],
                }
        except (OSError, ValueError):
            logger.warning("Unreadable %s; re-deriving from raw files", hash_path)
    raw_path = state_dir / "00_raw_transcript.md"
    meta_path = state_dir / "00_metadata.json"
    if not raw_path.exists() or not meta_path.exists():
        return None
    if _raw_rewritten_after_processing(state_dir):
        # The stored raw is already the NEW text (the Hub wrote it), so
        # hashing it would compare the update with itself.
        return {"transcript_sha256": "rewritten-after-processing",
                "metadata_sha256": "rewritten-after-processing"}
    return content_fingerprint(raw_path.read_text(), read_json(meta_path))


def _write_content_hash(state_dir: Path, transcript: str, metadata: dict) -> None:
    """Record the accepted version's fingerprint and WHEN it was accepted.

    ``accepted_at`` is only stamped when the fingerprint changes, so an
    identical re-POST never restarts the cooldown window.
    """
    fp = content_fingerprint(transcript, metadata)
    hash_path = state_dir / CONTENT_HASH_FILE
    if hash_path.exists():
        try:
            if {k: read_json(hash_path).get(k) for k in fp} == fp:
                return
        except (OSError, ValueError):
            pass
    write_json(hash_path, {
        **fp,
        "accepted_at": datetime.now(timezone.utc).isoformat(),
    })


def _cooldown_remaining(state_dir: Path, cooldown_seconds: int) -> int:
    """Seconds left before an update may supersede the stored version.

    0 when the guard is off, when no accepted_at is recorded (a state dir
    from before the guard: never deferred, the update runs), or when the
    window has passed.
    """
    if cooldown_seconds <= 0:
        return 0
    hash_path = state_dir / CONTENT_HASH_FILE
    if not hash_path.exists():
        return 0
    try:
        accepted = datetime.fromisoformat(read_json(hash_path)["accepted_at"])
    except (OSError, ValueError, KeyError, TypeError):
        return 0
    elapsed = (datetime.now(timezone.utc) - accepted).total_seconds()
    return max(0, int(cooldown_seconds - elapsed + 0.999))


def _supersede_if_changed(
    state_dir: Path,
    conversation_id: str,
    transcript: str,
    metadata: dict,
    *,
    cooldown_seconds: int = 0,
) -> bool:
    """Detect an updated re-POST and clear the earlier version's caches.

    Raises ``UpdateDeferred`` (and changes nothing) when the update lands
    inside ``cooldown_seconds`` of the stored version's acceptance.

    Returns True when the incoming content differs from the version
    already processed. Then:

    - every cached step output moves to ``_superseded/`` (only the most
      recent superseded set is kept, so a thread that updates daily does
      not grow the state dir without bound);
    - state.json's completed_steps is cleared, so every step re-runs on
      the new transcript;
    - ``update_pending.json`` records whether the earlier version reached
      the gist sinks (step 07) and where its bundle was written, so the
      re-run can retract the old facts and replace the old artefacts.

    Returns False (and touches nothing) for a first POST and for a
    byte-identical re-POST.
    """
    _log_unclassified_metadata_keys(conversation_id, metadata)
    stored = _stored_fingerprint(state_dir)
    if stored is None:
        return False
    incoming = content_fingerprint(transcript, metadata)
    if stored == incoming:
        return False

    remaining = _cooldown_remaining(state_dir, cooldown_seconds)
    if remaining > 0:
        logger.info(
            "Update to %s deferred %ds (reprocess cooldown); nothing written",
            conversation_id, remaining,
        )
        raise UpdateDeferred(conversation_id, remaining)

    previous = _load_or_new_state(state_dir, conversation_id)
    marker_path = state_dir / UPDATE_MARKER_FILE
    earlier_marker: dict = {}
    if marker_path.exists():
        try:
            earlier_marker = read_json(marker_path)
        except (OSError, ValueError):
            earlier_marker = {}
    # A second update can arrive before the first one's re-run finished
    # its retraction (step 07 failed, say). The gist writes still in the
    # stores then belong to an even earlier version: keep that flag set.
    # state.json alone cannot answer this: the Hub API's background
    # processor (CM041 ical-server, the iOS + CM052 path) REWRITES state.json
    # with completed_steps=["00_raw"] before it runs pwg-convo, so on that
    # path "07 is not completed" even though the earlier version's facts
    # are in the stores. content_hash.json is written only by CM048 and
    # records it durably.
    hash_record = _read_hash_record(state_dir)
    gist_written = (
        "07_sinks_written" in previous.completed_steps
        or bool(earlier_marker.get("previous_gist_written"))
        or bool(hash_record.get("gist_written"))
        or "07_sinks_written" in (hash_record.get("completed_steps") or [])
        or (not hash_record and _legacy_gist_probably_written(state_dir))
    )

    # Every earlier bundle folder not yet cleaned up: one from an earlier
    # update whose re-run never reached the sweep, plus this version's.
    previous_bundle_folders = [
        str(f) for f in (earlier_marker.get("previous_bundle_folders") or [])
    ]
    location = _read_bundle_location(state_dir)
    if location is not None and str(location) not in previous_bundle_folders:
        previous_bundle_folders.append(str(location))

    import shutil

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    superseded_root = state_dir / SUPERSEDED_DIR
    if superseded_root.exists():
        shutil.rmtree(superseded_root)
    dest = superseded_root / stamp
    moved = []
    for f in sorted(state_dir.iterdir()):
        if f.name in _KEEP_ON_SUPERSEDE or ".archive" in f.name:
            continue
        dest.mkdir(parents=True, exist_ok=True)
        f.rename(dest / f.name)
        moved.append(f.name)

    write_json(marker_path, {
        "superseded_at": stamp,
        "previous": stored,
        "incoming": incoming,
        "transcript_changed": stored["transcript_sha256"] != incoming["transcript_sha256"],
        "metadata_changed": stored["metadata_sha256"] != incoming["metadata_sha256"],
        "previous_completed_steps": list(previous.completed_steps),
        "previous_gist_written": gist_written,
        "previous_bundle_folders": previous_bundle_folders,
    })

    fresh = PipelineState.new(conversation_id)
    fresh.created_at = previous.created_at
    _save_state(state_dir, fresh)

    logger.info(
        "Updated conversation %s (transcript_changed=%s, metadata_changed=%s): "
        "superseded %d cached outputs, re-running every step",
        conversation_id,
        stored["transcript_sha256"] != incoming["transcript_sha256"],
        stored["metadata_sha256"] != incoming["metadata_sha256"],
        len(moved),
    )
    return True


def _read_update_marker(state_dir: Path) -> dict | None:
    path = state_dir / UPDATE_MARKER_FILE
    if not path.exists():
        return None
    try:
        return read_json(path)
    except (OSError, ValueError):
        logger.warning("Unreadable %s; treating as no pending update", path)
        return None


def _clear_update_marker_if_settled(state_dir: Path, state: PipelineState) -> None:
    """Drop the update marker once the re-run has nothing left to do.

    Kept while a step failed (the retry still needs it) or while the
    earlier version's gist writes are not yet retracted.
    """
    marker = _read_update_marker(state_dir)
    if marker is None or state.failed_step is not None:
        return
    if marker.get("previous_gist_written"):
        return
    (state_dir / UPDATE_MARKER_FILE).unlink(missing_ok=True)


def _retract_previous_gist_if_pending(
    state_dir: Path,
    conversation_id: str,
    settings: Settings,
    dry_run: bool,
) -> None:
    """Delete the earlier version's facts before the update writes its own.

    Runs at most once per update: the marker flag is cleared only after
    the delete succeeded, so a failed retraction is retried with the
    step instead of being forgotten.
    """
    marker = _read_update_marker(state_dir)
    if not marker or not marker.get("previous_gist_written"):
        return
    if dry_run:
        logger.info("dry_run: would retract earlier gist writes for %s", conversation_id)
        return
    from . import gist_retraction

    gist_retraction.retract_conversation(conversation_id, settings)
    marker["previous_gist_written"] = False
    marker["gist_retracted_at"] = datetime.now(timezone.utc).isoformat()
    write_json(state_dir / UPDATE_MARKER_FILE, marker)


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
    participants = normalise_participants(metadata.get("participants"))
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

    # v1018-D031. Arm the document's total allowance. Disarmed in the
    # finally below so a later step never inherits a spent budget, and so
    # a _run_step retry starts from a full one rather than a stale
    # deadline in the past.
    global _enrich_deadline
    _budget = _enrich_budget_secs()
    _enrich_deadline = None if _budget is None else time.monotonic() + _budget
    if _budget is not None:
        logger.info(
            "Enrichment budget for %s: %.0fs total across all model calls.",
            metadata["conversation_id"],
            _budget,
        )
    # Gateway: the enrichment is an extraction step too. Its Action items
    # table becomes the outstanding_todos sidecar and its text seeds the
    # step 09 topics, so it reads the owner's turns only. The raw
    # transcript on disk (00_raw_transcript.md) is not touched.
    transcript = _extraction_transcript(transcript, metadata)
    try:
        _step_enrich_inner(
            client, transcript, metadata, classification, settings, dry_run,
            state_dir, out_path, sidecar_path,
        )
    finally:
        _enrich_deadline = None
    return


def _step_enrich_inner(
    client: OllamaClient,
    transcript: str,
    metadata: dict,
    classification: Classification,
    settings: Settings,
    dry_run: bool,
    state_dir,
    out_path,
    sidecar_path,
) -> None:

    solo = _capture_truth.is_single_speaker_capture(transcript, metadata)
    if solo:
        classification = _capture_truth.as_memo(classification)
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
            timeout=_budget_timeout(),
        )
        rendered, retry_attempted, validation = _validate_and_maybe_retry(
            client=client,
            initial_text=result.raw_response,
            full_prompt=full_prompt,
            prompt_name=prompt_name,
            expected_headings=expected_headings,
            settings=settings,
        )
        # Pipeline-known facts overwrite the model's copies (capture_truth).
        rendered = _stamp_capture_truth(
            rendered, transcript, metadata, classification, settings,
            prompt_version=f"{prompt_name}@1.0",
            model=getattr(result, "model", None) or settings.ollama_enrich_model,
            solo=solo,
        )
        rendered = enrichment_validation.sanitise_participants_section(
            rendered,
            normalise_participants(metadata.get("participants")),
            getattr(settings, "user_display_name", "") or "",
        )
        # v1018-D014c: last stop before the customer's wiki page. A
        # placeholder the model copied out of the prompt template must not
        # reach disk. Stripped, not retried -- see the helper's docstring.
        rendered, _dropped = enrichment_validation.strip_placeholder_tokens(rendered)
        if _dropped:
            logger.warning(
                "Dropped %d prompt-template placeholder(s) from %s output: %s",
                len(_dropped),
                metadata.get("conversation_id"),
                ", ".join(_dropped),
            )
        rendered, _sidecars = enrichment_validation.strip_reminders_sidecar(rendered)
        if _sidecars:
            logger.warning(
                "Dropped %d reminders_candidates sidecar(s) from %s enrichment body",
                _sidecars,
                metadata.get("conversation_id"),
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
                timeout=_budget_timeout(),
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
        # Pipeline-known facts overwrite the model's copies (capture_truth).
        rendered = _stamp_capture_truth(
            rendered, transcript, metadata, classification, settings,
            prompt_version=f"{prompt_name}+merge@1.0",
            model=settings.ollama_enrich_model,
            solo=solo,
        )
        rendered = enrichment_validation.sanitise_participants_section(
            rendered,
            normalise_participants(metadata.get("participants")),
            getattr(settings, "user_display_name", "") or "",
        )
        # v1018-D014c: last stop before the customer's wiki page. A
        # placeholder the model copied out of the prompt template must not
        # reach disk. Stripped, not retried -- see the helper's docstring.
        rendered, _dropped = enrichment_validation.strip_placeholder_tokens(rendered)
        if _dropped:
            logger.warning(
                "Dropped %d prompt-template placeholder(s) from %s output: %s",
                len(_dropped),
                metadata.get("conversation_id"),
                ", ".join(_dropped),
            )
        rendered, _sidecars = enrichment_validation.strip_reminders_sidecar(rendered)
        if _sidecars:
            logger.warning(
                "Dropped %d reminders_candidates sidecar(s) from %s enrichment body",
                _sidecars,
                metadata.get("conversation_id"),
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


def _retention_tier(classification: Classification) -> str | None:
    """The tier the Qdrant sink stamps, so the frontmatter cannot disagree
    with it. Absent (not guessed) when the sink module cannot load."""
    try:
        from .ingest import _retention_tier_for

        return _retention_tier_for(classification)
    except Exception as exc:  # ingest hard-requires ostler_security
        logger.warning("retention_tier left absent: %s", type(exc).__name__)
        return None


def _stamp_capture_truth(
    rendered: str,
    transcript: str,
    metadata: dict,
    classification: Classification,
    settings: Settings,
    *,
    prompt_version: str,
    model: str,
    solo: bool,
) -> str:
    """Last edit before 02_enrichment.md is written (and copied verbatim
    to ~/Documents/Ostler/Conversations/<id>.md). See capture_truth."""
    if solo:
        rendered = _capture_truth.scrub_solo_body(
            rendered, _capture_truth.speaker_labels(transcript, metadata), metadata,
            owner_name=getattr(settings, "user_display_name", "") or "",
        )
    return _capture_truth.stamp_frontmatter(
        rendered,
        conversation_id=str(metadata.get("conversation_id") or ""),
        prompt_version=prompt_version,
        model=str(model or ""),
        completed_at=_capture_truth.utc_now_iso(),
        metadata=metadata,
        classification=classification,
        retention_tier=_retention_tier(classification),
        solo=solo,
        owner_name=getattr(settings, "user_display_name", "") or "",
    )


def _validate_document(
    text: str, prompt_name: str, expected_headings: list[str],
):
    """Validate a document against BOTH heading levels.

    v1018-D014b. The `##` check alone passed a merged document whose
    `### Narrative` had been dropped -- the check was one level coarser
    than the defect, so the defect was invisible to it. A missing
    sub-section is reported as `### Name` so the retry prompt and the
    log say which level is wrong.
    """
    top = enrichment_validation.validate_headings(text, expected_headings)
    subs = enrichment_validation.validate_subheadings(
        text, enrichment_validation.expected_subheadings_for(prompt_name),
    )
    if subs.ok:
        return top
    return enrichment_validation.HeadingValidation(
        ok=False,
        missing=top.missing + [f"### {m}" for m in subs.missing],
        extras=top.extras,
        found=top.found + subs.found,
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
    validation = _validate_document(initial_text, prompt_name, expected_headings)
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
        timeout=_budget_timeout(),
    )
    retry_validation = _validate_document(
        retry_result.raw_response, prompt_name, expected_headings,
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
    participants = normalise_participants(metadata.get("participants"))
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

{_language_block(settings, metadata, chunks_body)}
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

    participants = normalise_participants(metadata.get("participants"))
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

{_language_block(settings, metadata, chunks_body)}
--- CONVENTIONS ---
{conventions}

{chunks_body}

{enrichment_validation.build_section_contract(prompt_name)}
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
        timeout=_budget_timeout(),
    )
    return result.raw_response


def _build_speaker_mapping(metadata: dict) -> str:
    """Build a speaker-to-participant mapping string for prompts.

    Transcripts from iOS use "Speaker 1", "Speaker 2" labels. This
    produces a mapping hint so the model can attribute facts to named
    participants instead of generic "Speaker N" references.
    """
    participants = normalise_participants(metadata.get("participants"))
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
    participants = normalise_participants(metadata.get("participants"))
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


def _language_block(settings, metadata: dict, text: str) -> str:
    """Output-language instruction (see src/language.py)."""
    return _language.language_instruction(
        _language.resolve_output_language(settings, metadata, text)
    )


def _build_enrichment_input(
    transcript_chunk: str,
    metadata: dict,
    c: Classification,
    conventions: str,
    settings: Settings,
) -> str:
    classification_json = json.dumps(c.to_dict(), indent=2)
    participants = normalise_participants(metadata.get("participants"))
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
    if c.shape == _capture_truth.MEMO_SHAPE:
        # Without this the line read "Other name: other", and the prompt's
        # roster example gave that "other" a role and a former employer.
        other_name = "none (one speaker; this is a memo, not a conversation)"
    user_name = settings.user_display_name
    chunk_note = metadata.get("chunk_note")
    # The reminder used to hard-code work_one-on-one's eight headings for
    # EVERY variant, contradicting the variant's own system prompt.
    _headings = enrichment_validation.expected_headings_for(
        prompts.enrichment_prompt_name_for(c.suggested_type_slug)
    )
    heading_lines = "\n".join(f"## {h}" for h in _headings)

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
    body += "\n" + _language_block(settings, metadata, transcript_chunk)
    body += f"""
--- CONVENTIONS ---
{conventions}

--- SECTION STRUCTURE REMINDER ---
You MUST use EXACTLY these section headings in this order. Do NOT
invent your own headings. Do NOT skip sections. If a section has no
content, write the heading followed by "_Nothing to report._"

{heading_lines}

Start your response with the YAML frontmatter block (---), then
## {_headings[0]}. No preamble.

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

    participants = normalise_participants(metadata.get("participants"))
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


# ── Gateway transcripts: extraction reads the OWNER's turns only ───
#
# CM051 v1.0.107 F&F blocker (Mini16 #27). A gateway conversation
# (metadata source "gateway", provenance source_kind "zeroclaw_gateway",
# conversation ids zg-*) is the owner chatting with their OWN assistant.
# Fact extraction read the whole transcript, so the assistant's replies,
# guesses and test-persona answers included, were extracted as facts with
# subject=user and the assistant then repeated them back as knowledge.
# Measured on the box: 66 gateway facts, 45 subject=user, 15 located only
# in Assistant turns, 0 of those in User turns.
#
# The turn structure is the producer's, not a guess at prose: CM052
# wire.render_transcript writes one "**<label>:** <content>" header per
# message, where <label> is CM052_USER_EMAIL for role=user,
# CM052_ASSISTANT_NAME (default "Assistant") for role=assistant, and
# role.capitalize() for anything else. A message's continuation lines
# carry no header. Only headers whose label is one of those speakers open
# a new turn, so a bold "**Note:**" inside an assistant reply cannot end
# the assistant turn and smuggle its text back in.

_TURN_HEADER = re.compile(r"^\*\*(?P<label>[^*\n]+?):\*\*(?=\s|$)")
_NON_OWNER_ROLE_LABELS = frozenset({"system", "tool"})


def _is_gateway_conversation(metadata: dict) -> bool:
    if str(metadata.get("source") or "").strip().lower() == "gateway":
        return True
    prov = metadata.get("provenance")
    if isinstance(prov, dict):
        if str(prov.get("source_kind") or "") == "zeroclaw_gateway":
            return True
        if str(prov.get("source_subtype") or "").strip().lower() == "gateway":
            return True
    return False


def _gateway_assistant_labels() -> set[str]:
    labels = {"assistant"}
    configured = (os.environ.get("CM052_ASSISTANT_NAME") or "").strip()
    if configured:
        labels.add(configured.lower())
    return labels


def _owner_turns_only(transcript: str) -> str:
    """Return ``transcript`` with every non-owner turn removed.

    Kept: any preamble before the first turn header (the frontmatter)
    and the owner's turns. Dropped: assistant turns and system/tool
    turns. The owner label is CM052_USER_EMAIL when it is set and heads a
    turn; otherwise the first header label that is not the assistant or a
    reserved role (the gateway opens a session on an owner message). With
    no owner label at all, no turns are kept: fail closed, extract nothing.
    """
    lines = transcript.splitlines(keepends=True)
    assistant = _gateway_assistant_labels()
    headers = [
        m.group("label").strip()
        for m in (_TURN_HEADER.match(line) for line in lines)
        if m
    ]
    owner = (os.environ.get("CM052_USER_EMAIL") or "").strip()
    if not owner or owner not in headers:
        owner = next(
            (
                h for h in headers
                if h.lower() not in assistant
                and h.lower() not in _NON_OWNER_ROLE_LABELS
            ),
            "",
        )
    speakers = assistant | _NON_OWNER_ROLE_LABELS
    if owner:
        speakers = speakers | {owner.lower()}

    kept: list[str] = []
    current: str | None = None  # None = preamble, before any turn
    dropped = 0
    for line in lines:
        m = _TURN_HEADER.match(line)
        if m and m.group("label").strip().lower() in speakers:
            current = m.group("label").strip()
            if current != owner:
                dropped += 1
        if current is None or (owner and current == owner):
            kept.append(line)
    logger.info(
        "gateway transcript: kept owner turns only, dropped %d non-owner turn(s)",
        dropped,
    )
    return "".join(kept)


def _extraction_transcript(transcript: str, metadata: dict) -> str:
    """The transcript an EXTRACTION step reads. Unchanged for every
    source except gateway, where only the owner's turns are kept."""
    if _is_gateway_conversation(metadata):
        return _owner_turns_only(transcript)
    return transcript


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
    # Gateway: the assistant's own turns are not evidence about the owner.
    raw_transcript = _extraction_transcript(raw_transcript, metadata)
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
participants: {json.dumps(normalise_participants(metadata.get("participants")))}
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
    # DMG #27: a first-person line written by ANOTHER participant ("my dad's
    # ...") is about them, not the owner. Move such facts onto the person
    # concerned, on evidence read from the transcript. See attribution.py.
    facts = attribution.reattribute(facts, raw_transcript, metadata)

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
        '"inferred_person_id": "john_smith", '
        '"inferred_display_name": "John Smith", "confidence": 0.92, '
        '"evidence": "addressed as John at turn 4"}], '
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
    participants = normalise_participants(metadata.get("participants"))
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
    for p in normalise_participants(metadata.get("participants")):
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

    Person nodes are typed ``pwg:Person`` in the ``https://schema.ostler.ai/
    ontology#`` namespace (see last_contact_updater). Returns [] on any
    failure -- candidate enrichment is optional, never load-bearing.
    """
    import httpx

    sparql = """
PREFIX pwg: <https://schema.ostler.ai/ontology#>
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
        # Summary, topics and todos come from ONE call on one input, so
        # for a gateway conversation all three read the owner's turns
        # only (see _extraction_transcript). The rendered transcript
        # artefact below still gets the full ``transcript``.
        extraction = _bundle_extractor.extract(
            client,
            transcript=_extraction_transcript(transcript, metadata),
            enrichment_md=enrichment_md,
            channel=str(metadata.get("channel") or "spoken"),
            model=settings.ollama_enrich_model,
            locale=settings.locale,
            output_language=_language.resolve_output_language(
                settings, metadata, transcript
            ),
            timeout=600.0,
        )
        write_json(bundle_json_path, extraction.to_dict())

    # ── Sub-step A2: topic bridge (graph) ──────────────────────────
    # The extraction's topics become pwg:ConversationTopic /
    # pwg:TopicMention nodes so the assistant's pwg_topics tool
    # (CM041 ical-server GET /api/v1/topics) has something to read.
    # Nothing wrote that class before, so the endpoint answered
    # {"topics": [], "count": 0} on every install.
    #
    # This runs HERE, not in step 07's _write_oxigraph, for two
    # reasons the writer's docstring covers in full: step 07 runs
    # BEFORE step 09, so 09_bundle.json does not exist yet at sink
    # time; and the reader queries the DEFAULT graph while
    # _write_oxigraph POSTs into the named graph urn:ostler:user/<id>.
    #
    # Placed ahead of sub-step B deliberately: a channel whose bundle
    # adapter has not landed yet still gets its topics into the graph.
    # Imported lazily, matching the last_contact_updater call below.
    if ingest_sinks:
        from . import topic_writer as _topic_writer

        _topic_writer.write_topics(
            conversation_id=str(metadata.get("conversation_id") or ""),
            topics=extraction.topics,
            settings=settings,
            privacy_level=privacy_level,
            metadata=metadata,
            dry_run=dry_run,
        )

    # ── Sub-step B: bundle assembly + atomic write ─────────────────
    if _is_gist_only(metadata):
        # Declared, not an unimplemented adapter: an AI conversation's
        # durable readable copy is CM052's own artefact under
        # ~/Documents/Ostler/AI Conversations/, so a CM048 bundle under
        # Conversations/ would put the same chat in two folders (and on two
        # wiki pages). The extraction above still feeds the topic bridge.
        logger.info(
            "channel=%r is gist-only: no Conversations/ bundle for %s",
            metadata.get("channel"), metadata.get("conversation_id"),
        )
        return

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
    # An update can move the bundle: the folder is <date>/<participants
    # slug>-<short id>, so a new participant joining the thread changes
    # the slug. Record where this version went, so the next update can
    # remove exactly this folder (process() does it, after completion).
    write_json(state_dir / BUNDLE_LOCATION_FILE, {"folder": str(output.folder)})

    # #311: refresh per-person lastContact<Channel> recency signal.
    # Post-CM047 retirement, CM048 owns the WhatsApp lastContactWhatsApp
    # write the wiki person-page recency row / CM041 stale-contacts /
    # CM031 badge consume. update_last_contact_for_bundle is a no-op for
    # channels without a recency predicate, for L3 bundles, and on a
    # SPARQL hiccup -- the conversation is already written, this is a
    # secondary index and must never fail the ingest.
    # A non-relational bulk message must not bump any participant's
    # contact-recency: a "last contacted on email" badge driven by a
    # marketing blast is exactly the false-interaction symptom this
    # change removes. The bundle carries the flag in extra_metadata.
    if bundle.extra_metadata.get("non_relational"):
        logger.info(
            "Non-relational bundle %s: skipping lastContact recency bump",
            bundle.conversation_id,
        )
        return

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


# Channels whose conversations get the GIST arm only (facts, summary point,
# topics) and never a Conversations/ bundle. "manual" is CM052's channel for
# AI conversations (chatgpt_export, claude_code_watcher, zeroclaw_sessions):
# their readable copy is CM052's episodic markdown, written by CM052 itself.
# Before this was declared, make_bundle raised NotImplementedError for
# "manual" and step 09 logged it as a missing adapter on every AI chat.
GIST_ONLY_CHANNELS: frozenset = frozenset({"manual"})


def _is_gist_only(metadata: dict) -> bool:
    return str(metadata.get("channel") or "").strip().lower() in GIST_ONLY_CHANNELS


def _stop_gist_only_l3(
    state_dir: Path,
    conversation_id: str,
    state: PipelineState,
    settings: Settings,
    *,
    ingest_sinks: bool,
    dry_run: bool,
) -> PipelineState:
    """L3 on a gist-only channel: no gist (L3) and no bundle (gist-only),
    so every later model call would produce nothing. Stop, after removing
    an earlier non-L3 version's gist if this is an update (a DELETE, the
    only store traffic, and only when that version was written)."""
    logger.info(
        "L3 on gist-only channel for %s: nothing to write, no model calls",
        conversation_id,
    )
    if ingest_sinks:
        try:
            _retract_previous_gist_if_pending(
                state_dir, conversation_id, settings, dry_run
            )
        except Exception as exc:
            state.fail(
                "07_sinks_written",
                f"retraction of the earlier non-L3 version failed: "
                f"{type(exc).__name__}: {exc}",
            )
            _save_state(state_dir, state)
            raise RuntimeError(
                "Step 07_sinks_written failed (L3 update retraction). "
                "See state.json."
            ) from exc
    _clear_update_marker_if_settled(state_dir, state)
    _record_processed_state(state_dir, state)
    return state


_BUNDLE_ARTEFACTS = ("summary.md", "transcript.md", "todos.md")


# The sweep is cleanup after a completed run, so it gets a hard bound.
_STALE_SWEEP_TIMEOUT_SECONDS = 10.0


def _read_bundle_location(state_dir: Path) -> Path | None:
    path = state_dir / BUNDLE_LOCATION_FILE
    if not path.exists():
        return None
    try:
        folder = read_json(path).get("folder")
    except (OSError, ValueError, AttributeError):
        logger.warning("Unreadable %s; no recorded bundle location", path)
        return None
    return Path(folder) if folder else None


def _pending_stale_bundle_folders(
    state_dir: Path, state: PipelineState
) -> list[str] | None:
    """The earlier version's recorded bundle folders, or None when this
    run is not an update whose bundle was just written."""
    if state.failed_step is not None or "09_bundle" not in state.completed_steps:
        return None
    marker = _read_update_marker(state_dir)
    if marker is None:
        return None
    folders = [str(f) for f in (marker.get("previous_bundle_folders") or [])]
    if not folders:
        logger.info(
            "Updated conversation %s: no recorded earlier bundle location; "
            "not sweeping (the conversations tree is never listed)",
            state.conversation_id,
        )
    return folders


def _sweep_stale_bundles_bounded(
    root: Path,
    conversation_id: str,
    folders: list[str],
    *,
    keep: Path,
) -> None:
    """Run the sweep on a daemon thread and wait at most
    ``_STALE_SWEEP_TIMEOUT_SECONDS``. A sweep stuck in the kernel is
    abandoned (logged), and being a daemon it cannot hold the process
    open at exit."""
    if not folders:
        return

    def sweep() -> None:
        try:
            _remove_stale_bundle_folders(root, conversation_id, folders, keep=keep)
        except Exception as exc:
            logger.warning(
                "Stale bundle sweep for %s failed: %s: %s",
                conversation_id, type(exc).__name__, exc,
            )

    t = threading.Thread(
        target=sweep, name=f"stale-bundle-sweep-{conversation_id}", daemon=True
    )
    t.start()
    t.join(_STALE_SWEEP_TIMEOUT_SECONDS)
    if t.is_alive():
        logger.warning(
            "Stale bundle sweep for %s still running after %.0fs; abandoned "
            "(the conversation is complete, the earlier folder may remain)",
            conversation_id, _STALE_SWEEP_TIMEOUT_SECONDS,
        )


_BUNDLE_ARTEFACTS = ("summary.md", "transcript.md", "todos.md")


def _remove_stale_bundle_folders(
    root: Path, conversation_id: str, folders: list[str], *, keep: Path
) -> list[Path]:
    """Remove this conversation's artefacts from the RECORDED earlier
    bundle folders, never from anywhere found by listing the tree.

    The tree is not listed because, under the Hub's launchd agent, an
    opendir on a folder carrying a com.apple.macl label blocks forever
    (measured on the v1.0.111 walk box: os_scandir -> __opendir2 ->
    open$NOCANCEL). A recorded folder is touched only when it sits under
    ``root`` and is not ``keep``; a file goes only when its frontmatter
    carries this conversation_id, so a different conversation sharing the
    8-hex suffix is never touched. The folder goes only if that leaves it
    empty.
    """
    removed: list[Path] = []
    if root is None:
        return removed
    root_abs = Path(root).absolute()
    keep_abs = Path(keep).absolute()
    id_line = f"conversation_id: {_conversation_writer._yaml_quote(conversation_id)}"
    for entry in folders:
        folder = Path(entry).absolute()
        if folder == keep_abs or root_abs not in folder.parents:
            continue
        if not folder.is_dir():
            continue
        for name in _BUNDLE_ARTEFACTS:
            f = folder / name
            if not f.exists():
                continue
            head = f.read_text(encoding="utf-8").splitlines()[:2]
            if len(head) == 2 and head[0] == "---" and head[1] == id_line:
                f.unlink()
                removed.append(f)
        try:
            folder.rmdir()  # only succeeds when empty
        except OSError:
            pass
    if removed:
        logger.info(
            "Updated conversation %s moved folder; removed %d stale artefact(s)",
            conversation_id, len(removed),
        )
    return removed


# ── Helpers ──────────────────────────────────────────────────────────


def _load_classification(state_dir: Path) -> Classification | None:
    path = state_dir / "01_classification.json"
    if not path.exists():
        return None
    return Classification.from_dict(read_json(path))
