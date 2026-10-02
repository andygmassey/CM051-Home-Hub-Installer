"""RollingUsageRecorder: a volume-reducing wrapper around ``record_usage``.

Deliberately a SEPARATE file from ``usage_journal.py``, which carries a
"DO NOT EDIT" banner and is meant to stay byte-identical to its canonical
source (HR015 ``ostler_fda/usage_journal.py``). This file only ever
*imports* from that module; it never duplicates or modifies its body.

Same implementation as the sibling copies in andygmassey/evernote-knowledge
(``ostler_knowledge/_vendor/ostler_usage_journal/``) and
andygmassey/CM059-Ostler-Editor (``compiler/_vendor/ostler_usage_journal/``),
kept in sync by hand across the three (CM051 #2472 review, 2026-10-02).
"""
from .usage_journal import record_usage

import logging

logger = logging.getLogger(__name__)


class RollingUsageRecorder:
    """Accumulates MEASURED token counts across many short Ollama calls and
    flushes ONE summed journal row per time window, instead of one row per
    call.

    WHY THIS EXISTS (CM051 #2472 review). A bulk ingest run can make
    thousands of Ollama calls a minute. Writing one journal row per call
    grows the journal, and the Bursar's "what your Mac did" panel
    (``tracker.rs::local_work_for_month``) does a FULL LINEAR RESCAN of the
    whole journal on every call, with no cache and no rotation.

    MEASURED 2026-10-02: one journal row is ~263 bytes. At the walk-measured
    rate of ~14,000 Ollama calls/hour from the high-frequency producers
    (cm019 preference ingest; cm024_knowledge embed), per-call writing
    projects to ~339,000 rows/day (~89 MB/day, ~2.7 GB/month). A 60-second
    rollup cuts that by roughly two orders of magnitude while keeping token
    totals exact (real sums, never estimates).

    AN UNMEASURED CALL CONTRIBUTES NOTHING, THE SAME RULE AS ``record_usage``
    ITSELF. ``add(None, None)`` folds in neither a token nor a call -- it is
    not "folded in as zero". A bucket must never be able to look measured
    (a call counted) while carrying no real tokens.

    One instance per (model, purpose) combination in a process. Flushes
    when ``window_seconds`` have elapsed since the bucket opened (checked
    on each ``add()`` call), on process exit via ``atexit``, AND on SIGTERM
    (atexit handlers do not run when a process is killed by a signal). The
    SIGTERM handler CHAINS to whatever handler was already installed.
    Never raises: usage accounting must not be able to break the work it
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
        is an int subclass), non-ints, and non-positive values."""
        return isinstance(value, int) and not isinstance(value, bool) and value > 0

    def add(self, input_tokens, output_tokens):
        """Fold one call's MEASURED token counts into the open bucket.

        Pass ``None`` for a count the runtime did not report, same contract
        as :func:`record_usage`. A call where NEITHER count is measured
        contributes nothing: it does not open a bucket, does not add a
        call, and does not touch the token sums.
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
        """Best-effort: flush on SIGTERM too. Chains to any handler already
        installed rather than replacing it."""
        import os
        import signal

        try:
            previous = signal.getsignal(signal.SIGTERM)
        except (ValueError, OSError):
            return

        def _handler(signum, frame):
            self.flush()
            if callable(previous):
                previous(signum, frame)
            elif previous == signal.SIG_DFL:
                signal.signal(signal.SIGTERM, signal.SIG_DFL)
                os.kill(os.getpid(), signal.SIGTERM)

        try:
            signal.signal(signal.SIGTERM, _handler)
        except (ValueError, OSError):
            return

    def _flush_locked(self):
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
