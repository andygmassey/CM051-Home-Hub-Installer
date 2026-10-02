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

    NEVER DROPS A CALL (Andy's product rule, 2026-10-02: "I'd rather Bursar
    overcounted, than undercounted"). ``add(None, None)`` on its own folds in
    neither a token nor a call. But a caller that also passes
    ``estimated_input_tokens`` (a chars/4 estimate of the text it actually
    submitted) gets that estimate folded in instead of the call being
    silently dropped, erring toward overcounting rather than under. The
    bucket is marked estimated and its flushed row's session_id carries an
    "-est" suffix, so an estimated row stays distinguishable from a purely
    measured one even though no dedicated wire-format field exists for it
    yet.

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
        self._bucket_has_estimate = False
        atexit.register(self.flush)
        self._install_signal_flush()

    @staticmethod
    def _measured(value):
        """True for a real, positive, measured count. Excludes bools (bool
        is an int subclass), non-ints, and non-positive values."""
        return isinstance(value, int) and not isinstance(value, bool) and value > 0

    def add(self, input_tokens, output_tokens, *, estimated_input_tokens=None):
        """Fold one call's token counts into the open bucket. NEVER DROPS A
        CALL (Andy's product rule, 2026-10-02: "I'd rather Bursar
        overcounted, than undercounted").

        Pass ``None`` for a count the runtime did not report, same contract
        as :func:`record_usage`. When Ollama reported NOTHING measurable for
        input, and the caller supplies ``estimated_input_tokens`` (a chars/4
        estimate of the text actually submitted), that estimate is folded in
        instead of dropping the call -- erring toward overcounting, not
        undercounting. The bucket is marked estimated (its session_id gets
        an "-est" suffix on flush) so an estimated row stays distinguishable
        from a purely measured one, short of a wire-format change.

        A call with no measured count AND no estimate available still
        contributes nothing -- there is no number to write, estimated or
        otherwise.
        """
        import time

        has_input = self._measured(input_tokens)
        has_output = self._measured(output_tokens)
        used_estimate = False

        if not has_input and not has_output:
            if self._measured(estimated_input_tokens):
                input_tokens = estimated_input_tokens
                has_input = True
                used_estimate = True
            else:
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
            if used_estimate:
                self._bucket_has_estimate = True

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
        # "-est" suffix (Andy's product rule, 2026-10-02): no wire-format
        # field exists yet for "this row includes an estimate", so the
        # session_id is the honest, low-risk way to keep an estimated row
        # distinguishable without touching the pinned record_usage schema.
        # A reader that does not know this suffix still gets a correct,
        # slightly-higher-than-strictly-measured total -- the erring
        # direction Andy asked for -- it just cannot yet filter it out.
        session_id = self._session_id
        if self._bucket_has_estimate:
            session_id = session_id + "-est"
        try:
            record_usage(
                model=self._model,
                input_tokens=self._input_tokens,
                output_tokens=self._output_tokens,
                purpose=self._purpose,
                session_id=session_id,
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
            self._bucket_has_estimate = False
