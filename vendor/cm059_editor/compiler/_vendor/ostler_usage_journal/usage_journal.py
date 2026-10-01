"""Vendored copy of the shared Ostler usage-journal writer contract.

The Hub daemon shows the customer a monthly breakdown of the work their
machine did, split by *purpose*: ingesting, enriching, answering, noticing.
That panel is built from one append-only file:

    <workspace_dir>/state/costs.jsonl

One JSON object per line. Short-lived Python processes outside the daemon
(like this scout) cannot reach the daemon's in-process accounting, so the
contract between them is this file.

**The hard rule: MEASURED, NEVER ESTIMATED.** If the runtime does not hand
you a token count, write no record. Do not estimate from character length,
do not divide by four, do not carry forward the last figure. This number is
shown to a paying customer beside a price comparison. A missing record is a
gap somebody can close; a guessed record is a fact that cannot be
distinguished from a real one once it is in the file.

Real counts come only from Ollama's ``prompt_eval_count`` / ``eval_count``,
on ``/api/embed``, ``/api/generate`` and ``/api/chat``.

Invariants enforced here:
 * An unknown purpose is a **programming error** and raises ``ValueError``.
   A downstream Rust reader REJECTS an unknown purpose string rather than
   coercing it, so a typo would make the whole line unparseable and
   silently shrink the customer's totals.
 * An I/O failure is an **environment problem** and is swallowed with a
   ``logger.warning``. Usage accounting must never abort the work it
   measures.

No PII is written: model name, token counts, timestamp and a run label.
``session_id`` identifies the RUN, never the person.
"""
from __future__ import annotations

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


PURPOSES = frozenset({
    "ingesting",      # reading a source in for the first time
    "enriching",      # turning raw material into facts, summaries, pages
    "answering",      # work done because a person asked
    "noticing",       # work the assistant chose to do unprompted
    "unattributed",   # the serde default; the producer genuinely does not know
})


def _expand(raw: str) -> Path:
    """Expand a leading ``~`` the way the daemon's ``expand_tilde_path`` does."""
    return Path(os.path.expanduser(raw.strip()))


def _default_config_dir() -> Path:
    """``$HOME/.ostler``, matching the daemon's ``default_config_dir()``."""
    home = os.environ.get("HOME", "").strip()
    if home:
        return Path(home) / ".ostler"
    return Path.home() / ".ostler"


def _config_dir_from_marker(default_config_dir: Path) -> Optional[Path]:
    """Read ``active_workspace.toml``, mirroring ``load_persisted_workspace_dirs``."""
    marker = default_config_dir / "active_workspace.toml"
    try:
        contents = marker.read_text(encoding="utf-8")
    except OSError:
        return None

    raw = ""
    for line in contents.splitlines():
        line = line.strip()
        if not line.startswith("config_dir"):
            continue
        _, _, value = line.partition("=")
        raw = value.strip().strip('"').strip("'").strip()
        break

    if not raw:
        return None

    parsed = _expand(raw)
    return parsed if parsed.is_absolute() else default_config_dir / parsed


def _workspace_for(workspace_env: Path) -> Path:
    """Port of ``resolve_config_dir_for_workspace``, workspace half."""
    if (workspace_env / "config.toml").exists():
        return workspace_env / "workspace"

    legacy = workspace_env.parent / ".zeroclaw"
    if (legacy / "config.toml").exists():
        return workspace_env
    if workspace_env.name == "workspace":
        return workspace_env

    return workspace_env / "workspace"


def resolve_journal_path() -> Path:
    """Resolve ``<workspace_dir>/state/costs.jsonl`` the way the daemon does.

    Precedence:
      1. ``ZEROCLAW_CONFIG_DIR``            -> ``<dir>/workspace``
      2. ``OSTLER_WORKSPACE`` / ``ZEROCLAW_WORKSPACE`` -> :func:`_workspace_for`
      3. ``~/.ostler/active_workspace.toml`` marker -> ``<config_dir>/workspace``
      4. default                            -> ``~/.ostler/workspace``

    Resolved PER CALL, never at import.
    """
    config_dir_env = os.environ.get("ZEROCLAW_CONFIG_DIR", "").strip()
    if config_dir_env:
        return _expand(config_dir_env) / "workspace" / "state" / "costs.jsonl"

    workspace_env = (
        os.environ.get("OSTLER_WORKSPACE", "").strip()
        or os.environ.get("ZEROCLAW_WORKSPACE", "").strip()
    )
    if workspace_env:
        return _workspace_for(_expand(workspace_env)) / "state" / "costs.jsonl"

    default_config_dir = _default_config_dir()
    from_marker = _config_dir_from_marker(default_config_dir)
    if from_marker is not None:
        return from_marker / "workspace" / "state" / "costs.jsonl"

    return default_config_dir / "workspace" / "state" / "costs.jsonl"


def record_usage(
    model: str,
    input_tokens: Optional[int],
    output_tokens: Optional[int],
    purpose: str,
    session_id: str,
    *,
    journal_path: Optional[Path] = None,
) -> bool:
    """Append one MEASURED local-model usage record. Returns True if written.

    Pass ``None`` for a count the runtime did not report -- it is treated as
    zero for the total but does NOT on its own suppress the record. When
    BOTH are absent or zero there is nothing measured and no record is
    written.

    Raises ``ValueError`` on an unknown purpose. Never raises on I/O.
    """
    if purpose not in PURPOSES:
        raise ValueError(
            f"unknown purpose {purpose!r}; must be one of {sorted(PURPOSES)}. "
            "A downstream reader rejects an unknown purpose and the whole "
            "record is lost."
        )

    prompt = int(input_tokens or 0)
    completion = int(output_tokens or 0)
    if prompt <= 0 and completion <= 0:
        return False

    record = {
        "id": str(uuid.uuid4()),
        "session_id": session_id,
        "usage": {
            "model": model,
            "input_tokens": prompt,
            "output_tokens": completion,
            "total_tokens": prompt + completion,
            "cost_usd": 0.0,
            "timestamp": datetime.now(timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "purpose": purpose,
        },
    }

    path = journal_path or resolve_journal_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(record, separators=(",", ":")) + "\n"
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line)
        return True
    except OSError as exc:
        logger.warning(
            "usage journal write failed (%s): %s", type(exc).__name__, exc
        )
        return False


def tokens_from_ollama(response: dict) -> tuple[Optional[int], Optional[int]]:
    """Extract MEASURED token counts from an Ollama JSON response.

    Returns ``(prompt_eval_count, eval_count)``, either of which may be
    ``None`` when the endpoint did not report it. A non-integer value is
    treated as absent rather than coerced.
    """
    if not isinstance(response, dict):
        return (None, None)

    def _count(key: str) -> Optional[int]:
        value = response.get(key)
        if isinstance(value, bool) or not isinstance(value, int):
            return None
        return value if value > 0 else None

    return (_count("prompt_eval_count"), _count("eval_count"))
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
