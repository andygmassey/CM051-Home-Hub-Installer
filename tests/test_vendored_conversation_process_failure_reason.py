"""CM051 walk #5, item "conversations": a processor crash's failure_reason
must keep the TAIL of the subprocess's stderr, not the head.

Extracts the REAL _conversation_process_background function body from the
copy that actually ships (vendor/cm041/assistant_api/ical-server.py) via the
same technique as tests/test_conversation_process_metadata_conversation_id.sh
and tests/test_pip_stage_outside_bundle.sh ("drive the real helper, not a
copy"), then executes it with _invoke_pwg_convo stubbed -- avoiding the full
module's heavy ostler_security/qdrant/httpx import chain, which a source-grep
test would dodge but an import-the-whole-module test cannot.

Root cause (measured on a cold v1.0.107 install, walk #5): a crashing
pwg-convo subprocess writes its INFO-level progress logging FIRST and any
traceback/exception message LAST. The pre-fix code recorded
result.stderr[:500] -- the first 500 characters -- so on any stderr stream
longer than that (every one of the 4 measured "processor"-failed
conversations), the recorded "reason" was guaranteed to be ordinary logging
with the real error cut off before it ever printed.

All data here is synthetic (Rule 0): no real personal data.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import tempfile
import threading
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = REPO_ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py"


def _extract_function(name: str) -> str:
    """Pull `def name(...): ...` out of SERVER, from its def line to the
    next top-level def/class. Same technique as the sibling .sh test."""
    lines = SERVER.read_text(encoding="utf-8").splitlines(keepends=True)
    out: list[str] = []
    grabbing = False
    for line in lines:
        if line.startswith(f"def {name}("):
            grabbing = True
        elif grabbing and (line.startswith("def ") or line.startswith("class ")):
            break
        if grabbing:
            out.append(line)
    return "".join(out)


@pytest.fixture()
def background_fn():
    if not SERVER.is_file():
        pytest.skip(f"vendored ical-server.py missing: {SERVER}")
    src = _extract_function("_conversation_process_background")
    assert src, "could not locate _conversation_process_background() in vendored ical-server.py"

    ns: dict = {
        "json": json,
        "datetime": datetime,
        "subprocess": subprocess,
        "os": os,
        "threading": threading,
        "timedelta": timedelta,
        "timezone": timezone,
        "re": re,
        "Path": pathlib.Path,
        "CONVERSATION_RETRY_SIDECAR": "auto_retry.json",
        "__file__": str(SERVER),
    }
    # v1.0.107 #11: the failure path now calls _preserve_cm048_progress (keep
    # CM048's completed steps and error class instead of wiping them). Pull in
    # the REAL helpers it needs from the shipped file, same technique.
    for helper in ("_retry_code_stamp", "_read_retry_sidecar", "_write_retry_sidecar",
                   "_read_state_json", "_conversation_retry_error_class",
                   "_preserve_cm048_progress"):
        helper_src = _extract_function(helper)
        assert helper_src, f"could not locate {helper}() in vendored ical-server.py"
        exec(compile(helper_src, str(SERVER), "exec"), ns)  # noqa: S102
    exec(compile(src, str(SERVER), "exec"), ns)  # noqa: S102 -- extracting real shipped code, not arbitrary input
    return ns["_conversation_process_background"]


def _run(background_fn, tmp_path, fake_result, ns_patch=None):
    import types
    # Re-bind globals the extracted function closes over, the same way the
    # CM041 source test patches server.PROCESSING_DIR / server.subprocess.run.
    fn = background_fn
    fn.__globals__["PROCESSING_DIR"] = tmp_path
    fn.__globals__["_invoke_pwg_convo"] = lambda *a, **k: fake_result
    conv_id = "2026-10-03_walk5"
    fn(conv_id, "a transcript", {"date": "2026-10-03"})
    return json.loads((tmp_path / conv_id / "state.json").read_text())


def test_failure_reason_captures_the_tail_not_the_head(background_fn, tmp_path):
    noise = "INFO src.processor: doing routine work\n" * 20
    real_error = "RuntimeError: sqlcipher3 is not installed\n"
    fake_stderr = noise + real_error
    assert len(fake_stderr) > 500, "fixture must exceed the truncation budget or this test proves nothing"

    class _FakeResult:
        returncode = 1
        stdout = ""
        stderr = fake_stderr

    state = _run(background_fn, tmp_path, _FakeResult())
    assert state["failed_step"] == "processor"
    assert "RuntimeError: sqlcipher3 is not installed" in (state["failure_reason"] or ""), (
        "the real error must survive into failure_reason"
    )


def test_short_stderr_is_unaffected(background_fn, tmp_path):
    """CONTROL: a stderr shorter than the budget is recorded unchanged."""

    class _FakeResult:
        returncode = 1
        stdout = ""
        stderr = "ValueError: bad input\n"

    state = _run(background_fn, tmp_path, _FakeResult())
    assert state["failure_reason"] == "ValueError: bad input\n"


# ---------------------------------------------------------------------------
# CM051 walk #5, second finding: bounded retry on a transient "processor"
# failure.
#
# 4 of 18 cold-install conversations failed_step="processor" with identical
# metadata shape and no deterministic cause. Re-running the SAME saved input
# (alone, and concurrently in the same 4-at-once shape as the original
# dispatch) on the walk box succeeded every time -- the input is provably
# processable, so this is not "legitimately unprocessable" input and must
# not be marked skipped. All 4 were created in the SAME second (a
# cold-install backfill burst) and crashed during the FIRST or SECOND Ollama
# call, which is exactly the window in which a cold install is also still
# pulling/loading the Ollama model for the first time -- contention this
# process cannot see or wait out. There is no tick that re-dispatches a
# failed conversation (CM052's cli.py ~446-481 watermarks on a successful
# POST regardless of downstream pipeline failure), so without a retry HERE a
# transient cold-start failure is permanent.
# ---------------------------------------------------------------------------


def _run_sequence(background_fn, tmp_path, results, conv_id="2026-10-03_walk5retry"):
    """Like _run, but _invoke_pwg_convo returns/raises a DIFFERENT value on
    each successive call, in order -- for exercising the retry loop."""
    queue = list(results)
    calls = {"n": 0}

    def fake_invoke(*a, **k):
        calls["n"] += 1
        item = queue.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    fn = background_fn
    fn.__globals__["PROCESSING_DIR"] = tmp_path
    fn.__globals__["_invoke_pwg_convo"] = fake_invoke
    fn(conv_id, "a transcript", {"date": "2026-10-03"})
    state = json.loads((tmp_path / conv_id / "state.json").read_text())
    return state, calls["n"]


def test_transient_failure_retries_once_then_succeeds(background_fn, tmp_path):
    """RED before the fix: a single non-zero exit was recorded as a
    permanent failure with no second attempt."""

    class _FakeFailed:
        returncode = 1
        stdout = ""
        stderr = "RuntimeError: transient cold-start contention\n"

    class _FakeOk:
        returncode = 0
        stdout = "ok"
        stderr = ""

    with patch("time.sleep") as fake_sleep:
        state, call_count = _run_sequence(background_fn, tmp_path, [_FakeFailed(), _FakeOk()])

    assert call_count == 2, "a transient failure must be retried, not given up on after one attempt"
    assert state["current_step"] == "completed"
    assert state["failed_step"] is None
    assert state["retry_count"] == 1
    fake_sleep.assert_called_once()


def test_failure_persists_after_exhausting_retries(background_fn, tmp_path):
    """CONTROL: a failure that never clears is still reported failed after
    retrying, with the LAST attempt's reason (not the first), proving this
    adds bounded retry rather than masking a real defect."""

    class _FakeFailedFirst:
        returncode = 1
        stdout = ""
        stderr = "RuntimeError: FIRST_ATTEMPT_MARKER\n"

    class _FakeFailedSecond:
        returncode = 1
        stdout = ""
        stderr = "RuntimeError: SECOND_ATTEMPT_MARKER\n"

    with patch("time.sleep"):
        state, call_count = _run_sequence(
            background_fn, tmp_path, [_FakeFailedFirst(), _FakeFailedSecond()],
            conv_id="2026-10-03_walk5retryfail",
        )

    assert call_count == 2, "must stop after the bounded retry budget, not loop forever"
    assert state["failed_step"] == "processor"
    assert state["retry_count"] == 1
    assert "SECOND_ATTEMPT_MARKER" in (state["failure_reason"] or "")
    assert "FIRST_ATTEMPT_MARKER" not in (state["failure_reason"] or ""), (
        "the recorded reason must be the LAST attempt's, not the first"
    )


def test_file_not_found_is_not_retried(background_fn, tmp_path):
    """CONTROL: pwg-convo missing from PATH is deterministic (vendor-only
    branch -- CM041 source has no pwg-convo binary to go missing), so
    retrying it only doubles the wait for the same outcome."""
    with patch("time.sleep") as fake_sleep:
        state, call_count = _run_sequence(
            background_fn, tmp_path, [FileNotFoundError("no such file: pwg-convo")],
            conv_id="2026-10-03_walk5retryfnf",
        )

    assert call_count == 1, "a missing-binary failure must not be retried"
    fake_sleep.assert_not_called()
    assert state["failed_step"] == "processor"
    assert "not installed" in (state["failure_reason"] or "")
