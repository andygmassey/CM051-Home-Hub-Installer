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
import pathlib
import subprocess
import tempfile
from datetime import datetime

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
    }
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
