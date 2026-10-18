"""Vendored copy of the shared Ostler usage-journal writer contract.

This module exists so that code in this repo which calls Ollama's HTTP
API directly (embedding, classification, summarization) reports measured
token usage to the Hub's customer-facing cost panel, instead of silently
reporting nothing for that call.

Contract (matches sibling vendored copies elsewhere in the Ostler product
family -- keep in sync by hand, this package has no shared dependency on
the canonical source):

- ``tokens_from_ollama`` extracts measured (not estimated) token counts
  from an Ollama ``/api/embed`` or ``/api/generate`` JSON response.
- ``record_usage`` appends one JSON line to the cost journal, but only
  when there is a real measurement to write -- a guessed number would be
  worse than a gap, since this figure is shown to a paying customer next
  to a price comparison.
- ``resolve_journal_path`` mirrors the env-var precedence a downstream
  Rust daemon (ZeroClaw) uses to find the active workspace, resolved
  fresh on every call since the environment can change between calls.
"""
from __future__ import annotations

import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Tuple

logger = logging.getLogger(__name__)


# The only purpose labels a downstream Rust reader accepts. Anything else
# must fail loudly (ValueError) rather than being silently coerced, so a
# typo in a call site is caught at test time, not read as a missing field
# by the reader.
_VALID_PURPOSES = frozenset(
    {"ingesting", "enriching", "answering", "noticing", "unattributed"}
)


def _as_positive_int(value: object) -> Optional[int]:
    """Return ``value`` as a positive int, or None if it isn't measurable.

    Excludes bools (bool is an int subclass in Python), non-ints, and
    values <= 0 -- all of those mean "no measurement", not "zero usage".
    """
    if isinstance(value, bool):
        return None
    if not isinstance(value, int):
        return None
    if value <= 0:
        return None
    return value


def tokens_from_ollama(response: dict) -> Tuple[Optional[int], Optional[int]]:
    """Extract (input_tokens, output_tokens) from an Ollama response dict.

    Ollama's ``/api/generate`` response carries ``prompt_eval_count``
    (input) and ``eval_count`` (output). Its ``/api/embed`` response
    carries only ``prompt_eval_count`` -- embedding has no output tokens,
    so the second element is always None for that endpoint.

    Never estimates from text length: a missing or malformed key returns
    None for that side, it does not invent a number.
    """
    if not isinstance(response, dict):
        return None, None

    input_tokens = _as_positive_int(response.get("prompt_eval_count"))
    output_tokens = _as_positive_int(response.get("eval_count"))
    return input_tokens, output_tokens


def _read_config_dir_from_toml(path: Path) -> Optional[str]:
    """Pull a top-level ``config_dir = "..."`` value out of a tiny TOML file.

    Deliberately not a real TOML parser (tomllib is 3.11+ only and this
    package supports 3.10): ``active_workspace.toml`` is a single-key
    file written by the Hub installer, not general config.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None

    for line in text.splitlines():
        match = re.match(r'^\s*config_dir\s*=\s*"([^"]*)"\s*$', line)
        if match:
            return match.group(1)
    return None


def _home_dir() -> Path:
    """Home directory, honouring $HOME if set, else Path.home()."""
    home_env = os.environ.get("HOME")
    if home_env:
        return Path(home_env)
    return Path.home()


def resolve_journal_path() -> Path:
    """Resolve the costs.jsonl path, mirroring the ZeroClaw daemon's rules.

    Resolved fresh on every call (never cached at import time), since the
    environment this process sees can change between calls -- in
    particular in tests, which rely on this being re-evaluated per call.
    """
    config_dir_env = os.environ.get("ZEROCLAW_CONFIG_DIR")
    if config_dir_env:
        return Path(config_dir_env).expanduser() / "workspace" / "state" / "costs.jsonl"

    workspace_env = os.environ.get("OSTLER_WORKSPACE") or os.environ.get("ZEROCLAW_WORKSPACE")
    if workspace_env:
        workspace_dir = Path(workspace_env).expanduser()

        if (workspace_dir / "config.toml").exists():
            # This directory is actually a config dir in disguise.
            return workspace_dir / "workspace" / "state" / "costs.jsonl"

        if (workspace_dir.parent / ".zeroclaw" / "config.toml").exists():
            # The directory itself is the workspace.
            return workspace_dir / "state" / "costs.jsonl"

        if workspace_dir.name == "workspace":
            return workspace_dir / "state" / "costs.jsonl"

        return workspace_dir / "workspace" / "state" / "costs.jsonl"

    default_config_dir = _home_dir() / ".ostler"
    active_workspace_toml = default_config_dir / "active_workspace.toml"
    if active_workspace_toml.exists():
        config_dir_value = _read_config_dir_from_toml(active_workspace_toml)
        if config_dir_value:
            resolved = Path(config_dir_value).expanduser()
            if not resolved.is_absolute():
                resolved = default_config_dir / resolved
            return resolved / "workspace" / "state" / "costs.jsonl"

    return default_config_dir / "workspace" / "state" / "costs.jsonl"


def record_usage(
    model: str,
    input_tokens: Optional[int],
    output_tokens: Optional[int],
    purpose: str,
    session_id: str,
    *,
    journal_path: Optional[Path] = None,
    calls: int = 1,
) -> bool:
    """Append one usage record to the cost journal.

    Returns True if a record was written, False if there was nothing
    measurable to write (both token counts absent/zero) or the write
    failed. Never raises for an I/O failure -- a cost-accounting bug must
    never break the caller's actual work -- but DOES raise ValueError for
    an unknown ``purpose``, since that is a programming error a downstream
    reader would otherwise reject silently.
    """
    if purpose not in _VALID_PURPOSES:
        raise ValueError(
            f"invalid usage purpose {purpose!r}; must be one of "
            f"{sorted(_VALID_PURPOSES)}"
        )

    measured_input = _as_positive_int(input_tokens)
    measured_output = _as_positive_int(output_tokens)

    if measured_input is None and measured_output is None:
        # No real measurement. A guessed number would be worse than a
        # gap here, so write nothing rather than a zero.
        return False

    # The wire field is a plain integer (Rust's TokenUsage::input_tokens /
    # output_tokens are `u64`, not `Option<u64>`, and carry no
    # `#[serde(default)]`). Writing `null` here is not "unmeasured", it is
    # a record the Rust reader CANNOT PARSE AT ALL -- confirmed empirically
    # (2026-10-02): `serde_json::from_str` on a record with
    # `"output_tokens": null` returns "invalid type: null, expected u64",
    # which drops the WHOLE record (including its input_tokens) into
    # `unreadable_records`, not just the one field. An absent count
    # therefore means exactly 0 on the wire -- the "is this measured"
    # distinction lives in whether `record_usage` is called at all (it
    # returns False and writes nothing when there is nothing to report),
    # never in a null inside a written record.
    prompt = measured_input or 0
    completion = measured_output or 0
    total_tokens = prompt + completion

    record = {
        "id": str(uuid.uuid4()),
        "session_id": session_id,
        "usage": {
            "model": model,
            "input_tokens": prompt,
            "output_tokens": completion,
            "total_tokens": total_tokens,
            "cost_usd": 0.0,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "purpose": purpose,
            # #2603 follow-up (Archie review, 2026-10-02): how many real
            # calls this record represents. Default 1 is correct for every
            # per-call producer; RollingUsageRecorder passes its real total
            # so a rolled-up row is not silently undercounted downstream.
            "calls": max(1, int(calls)),
        },
    }

    path = journal_path if journal_path is not None else resolve_journal_path()

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
        return True
    except OSError as exc:
        logger.warning("failed to write usage journal record to %s: %s", path, exc)
        return False
class RollingUsageRecorder:
    """Accumulates MEASURED token counts across many short Ollama calls and
    flushes ONE summed journal row per time window, instead of one row per
    call.

    WHY THIS EXISTS (CM051 #2472 review). A bulk ingest/classify/embed run
    can make thousands of Ollama calls a minute. Writing one journal row per
    call grows the journal, and the Bursar's "what your Mac did" panel
    (``tracker.rs::local_work_for_month``) does a FULL LINEAR RESCAN of the
    whole journal on every call, with no cache and no rotation.

    MEASURED 2026-10-02: one journal row (this product's JSON shape) is
    ~263 bytes. At the walk-measured rate of ~14,000 Ollama calls/hour from
    the high-frequency producers (cm019 preference ingest; cm024_knowledge
    embed/classify/summarise), per-call writing projects to ~339,000
    rows/day (~89 MB/day, ~2.7 GB/month, ~10.2M lines/month). A Python-proxy
    linear scan (json.loads per line, same shape of work as the Rust
    reader) took 0.78s over 338,808 lines and an extrapolated ~22s over 10M
    lines -- and that full rescan runs on every Bursar panel open, growing
    worse every day since nothing truncates the journal.

    DECISION: a 60-second rollup bucket per (model, purpose) combination
    within a process. Worst case ~1,440 rows/day per producer (~380 KB/day),
    a >50x reduction, keeping a month's scan under roughly a second at the
    same per-line rate.

    KNOWN LIMITATION, documented rather than hidden: the downstream
    ``LocalWorkSummary.calls`` counter (oa ``tracker.rs::absorb``)
    increments once per JOURNAL LINE, not per real call, so a rolled-up row
    under-reports the call count by however many real calls it folded in.
    Token totals -- input_tokens/output_tokens/total_tokens -- remain
    EXACT: they are real sums, never estimates. The Bursar's own bars are
    keyed on tokens, not call count, so the customer-facing headline figure
    is unaffected, but the raw "calls" number in the journal is a floor,
    not a count, for a rolled-up producer. A proper fix needs a
    ``call_count`` field added to ``TokenUsage`` in
    ostler-ai/ostler-assistant so ``absorb()`` can add the real count
    instead of a flat 1 -- tracked as a follow-up, not implemented here.

    AN UNMEASURED CALL CONTRIBUTES NOTHING, THE SAME RULE AS ``record_usage``
    ITSELF. ``add(None, None)`` folds in neither a token nor a call -- it is
    not "folded in as zero". A bucket must never be able to look measured
    (a call counted) while carrying no real tokens: that is exactly the gap
    this product's whole contract exists to keep visible. A bucket that
    received only unmeasured calls flushes nothing at all.

    One instance per (model, purpose) combination in a process. Flushes
    when ``window_seconds`` have elapsed since the bucket opened (checked
    on each ``add()`` call -- no background thread, since callers are
    synchronous batch scripts), on process exit via ``atexit``, AND on
    SIGTERM (atexit handlers do not run when a process is killed by a
    signal, and a batch ingest is exactly the kind of process a supervisor
    or a cancelled Doctor import can SIGTERM mid-run). The SIGTERM handler
    CHAINS to whatever handler was already installed -- it flushes, then
    calls through -- so it never silently replaces a caller's own
    graceful-shutdown logic, and composes correctly when more than one
    recorder is alive in the same process. If signal handling is
    unavailable (not the main thread, or an unsupported platform), it is
    skipped rather than raised: a 60-second bucket lost to SIGTERM in that
    case is a known, accepted gap, not a crash. Never raises on the write
    path either: usage accounting must not be able to break the work it
    measures.
    """

    def __init__(
        self,
        model,
        purpose,
        session_id,
        *,
        window_seconds=60.0,
        journal_path=None,
    ):
        import atexit
        import threading

        self._model = model
        self._purpose = purpose
        self._session_id = session_id
        self._window_seconds = window_seconds
        self._journal_path = journal_path
        self._lock = threading.Lock()
        self._bucket_start = None
        self._input_tokens = 0
        self._output_tokens = 0
        self._calls = 0
        atexit.register(self.flush)
        self._install_signal_flush()

    @staticmethod
    def _measured(value):
        """True for a real, positive, measured count. Excludes bools (bool
        is an int subclass), non-ints, and non-positive values -- the same
        exclusions ``tokens_from_ollama`` applies, kept local here so this
        class stays self-contained and copy-paste-safe across the vendored
        copies of this module."""
        return isinstance(value, int) and not isinstance(value, bool) and value > 0

    def add(self, input_tokens, output_tokens):
        """Fold one call's MEASURED token counts into the open bucket.

        Pass ``None`` for a count the runtime did not report, same contract
        as :func:`record_usage`. A call where NEITHER count is measured
        contributes nothing: it does not open a bucket, does not add a
        call, and does not touch the token sums -- an absence stays an
        absence, never a silent zero folded into a total that then looks
        measured. Flushes and opens a fresh bucket first if the window has
        elapsed on a call that DOES carry a measurement.
        """
        import time

        has_input = self._measured(input_tokens)
        has_output = self._measured(output_tokens)
        if not has_input and not has_output:
            return

        with self._lock:
            now = time.monotonic()
            if (
                self._bucket_start is not None
                and now - self._bucket_start >= self._window_seconds
            ):
                self._flush_locked()

            if self._bucket_start is None:
                self._bucket_start = now

            if has_input:
                self._input_tokens += input_tokens
            if has_output:
                self._output_tokens += output_tokens
            self._calls += 1

    def flush(self):
        """Write the accumulated bucket as one journal row, if non-empty."""
        with self._lock:
            self._flush_locked()

    def _install_signal_flush(self):
        """Best-effort: flush on SIGTERM too.

        atexit handlers do not run when a process is killed by a signal,
        and a batch ingest/import is exactly the kind of process a
        supervisor (launchd, the Doctor's import runner) can SIGTERM
        mid-run, losing up to one open window of real measured work.

        Chains to whatever handler is already installed rather than
        replacing it, so this never silently overrides a caller's own
        graceful-shutdown logic, and composes correctly if more than one
        recorder is alive in the same process (each chains to the next,
        terminating at whatever handler -- or default -- was there first).
        """
        import os
        import signal

        try:
            previous = signal.getsignal(signal.SIGTERM)
        except (ValueError, OSError):
            # Not the main thread, or signals unavailable on this platform.
            # A bucket lost to SIGTERM in that case is a known, accepted
            # gap -- documented, not silently claimed as covered.
            return

        def _handler(signum, frame):
            self.flush()
            if callable(previous):
                previous(signum, frame)
            elif previous == signal.SIG_DFL:
                signal.signal(signal.SIGTERM, signal.SIG_DFL)
                os.kill(os.getpid(), signal.SIGTERM)
            # SIG_IGN: nothing further to do -- the process ignores SIGTERM,
            # same as it did before this recorder existed.

        try:
            signal.signal(signal.SIGTERM, _handler)
        except (ValueError, OSError):
            return

    def _flush_locked(self):
        # Caller already holds self._lock.
        if self._calls == 0:
            return
        try:
            record_usage(
                model=self._model,
                input_tokens=self._input_tokens,
                output_tokens=self._output_tokens,
                purpose=self._purpose,
                session_id=self._session_id,
                journal_path=self._journal_path,
                calls=self._calls,
            )
        except Exception:  # noqa: BLE001 - accounting must never raise
            logger.warning(
                "rolled-up usage journal write skipped (model=%s purpose=%s "
                "calls=%d)",
                self._model,
                self._purpose,
                self._calls,
                exc_info=True,
            )
        finally:
            self._bucket_start = None
            self._input_tokens = 0
            self._output_tokens = 0
            self._calls = 0
