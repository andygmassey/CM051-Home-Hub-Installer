"""rc=124 is a timeout, and the Doctor counted it as a failed conversation.

BOARD ROW 967. ``_dispatch_failure_count`` matched its tokens as RAW
SUBSTRINGS, so ``"rc=1" in line`` was true of every return code from 10 to 19,
from 100 to 199, and of 124 in particular. 124 is the conventional timeout exit
code and the one a 90-second watchdog produces, so the first time the
conversation processor is KILLED rather than failing, the owner was told a
dispatch failed.

rc=124 is not an invented example. ``diagnostic_rules`` itself carries it as the
worked example of the log format these rules read.

WHY AN INFLATED COUNT IS THE SAME HARM AS A DEFLATED ONE. The rule exists
because Doctor once said "Everything looks healthy" while the bundle error log
carried a fresh failure. The number it produces is shown to the owner as how
many conversations were READ and could not be PROCESSED. Too high makes the
page as unusable as too low, and the second time a product reports a wrong
state is the time it stops being trusted.

THE PROOF THE ROW ASKED FOR, verbatim: a tail containing rc=1, rc=10 and rc=124
must report 1 and not 3, with a control proving the genuine rc=1 is still
counted. Both are below, and the control is what stops "always return 0"
passing the first assertion.

🗿 AND THE MATCH IS DELIBERATELY NOT WIDENED to rc=<non-zero>. sessions_failed
is a separate token with its own meaning and the two are different shapes on
purpose. The change is one of intent: rc=1 counts only when the 1 is the whole
number.
"""
from __future__ import annotations

# VENDORED copy of HR015 doctor/agent test at ea223d3 (#975), pointed at vendor/doctor/agent
# (the vendored file-set excludes test_*.py, so the test cannot travel with the graft).
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "vendor" / "doctor" / "agent"))

import pytest

import diagnostic_rules as D

# One real line per shape, in the format the log actually uses. The rc=124 line
# is the worked example from diagnostic_rules' own docstring.
GENUINE = "2026-09-18 08:00:01 tick failed rc=1 sessions=3"
TIMEOUT = "2026-09-18 08:00:02 browsing status=error rc=124 sent=0,skipped=0"
TEN = "2026-09-18 08:00:03 tick failed rc=10 sessions=1"
SESSIONS = "2026-09-18 08:00:04 sessions_failed=2 after retry"
CLEAN = "2026-09-18 08:00:05 tick ok rc=0 sent=4,skipped=0"


@pytest.fixture()
def err_log(tmp_path, monkeypatch):
    """Point the counter at a fixture log without touching HOME."""
    logs = tmp_path / "logs"
    logs.mkdir()
    monkeypatch.setenv("OSTLER_LOGS_DIR", str(logs))
    path = logs / "imessage-bundle.err"

    def write(*lines: str):
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    # CONTROL ON THE FIXTURE ITSELF, taken before any assertion depends on it:
    # if the override did not take, every count below would be a confident zero
    # about a file the counter never opened.
    write(GENUINE)
    assert D._imessage_bundle_err_path() == path, (
        "OSTLER_LOGS_DIR did not steer the counter; every count in this file "
        "would be about a path nobody wrote"
    )
    assert D._dispatch_failure_count() == 1, (
        "the counter cannot see the fixture at all, so its zeros mean nothing"
    )
    return write


# ── the defect ───────────────────────────────────────────────────────────────


def test_the_row_967_proof_one_not_three(err_log):
    err_log(GENUINE, TEN, TIMEOUT)
    assert D._dispatch_failure_count() == 1, (
        "rc=10 and rc=124 are not rc=1. Counting them tells the owner two "
        "conversations were dropped that were not"
    )


def test_a_timeout_alone_is_not_a_failure(err_log):
    err_log(TIMEOUT)
    assert D._dispatch_failure_count() == 0


def test_the_whole_1xx_range_is_not_rc_1(err_log):
    err_log(*[f"tick failed rc={n} sessions=1" for n in (10, 12, 19, 100, 124, 199)])
    assert D._dispatch_failure_count() == 0


# ── the controls, without which the assertions above are satisfied by zero ───


def test_control_the_genuine_failure_is_still_counted(err_log):
    err_log(GENUINE)
    assert D._dispatch_failure_count() == 1, (
        "MUST be non-zero. Every assertion above is an equality with a small "
        "number, and 'always return 0' satisfies three of them"
    )


def test_control_the_other_token_is_untouched(err_log):
    err_log(SESSIONS)
    assert D._dispatch_failure_count() == 1, (
        "sessions_failed is a separate token with its own meaning; anchoring "
        "the numeric one must not narrow it"
    )


def test_control_the_two_tokens_still_add_up(err_log):
    err_log(GENUINE, SESSIONS, TIMEOUT, TEN, CLEAN)
    assert D._dispatch_failure_count() == 2, (
        "two real failures among five lines: the counter must neither collapse "
        "them nor pick up the three that are not failures"
    )


def test_control_rc_1_at_end_of_line_still_counts(err_log):
    # The negative lookahead must not require a following character. A line
    # ending in rc=1 is the shape a truncated tail leaves behind.
    err_log("tick failed rc=1")
    assert D._dispatch_failure_count() == 1


def test_a_clean_log_is_zero(err_log):
    err_log(CLEAN)
    assert D._dispatch_failure_count() == 0


# ── the customer-facing sentence, which is the point of the count ────────────


def test_the_owner_is_not_told_a_timeout_dropped_a_conversation(err_log):
    err_log(TIMEOUT, TEN)
    findings = D.check_conversation_dispatch_failures(object())
    assert findings == [], (
        "a timeout and an rc=10 produced a customer-facing warning that named "
        "conversations as lost"
    )


def test_control_a_genuine_failure_still_reaches_the_owner(err_log):
    # MUST be non-zero: without it the assertion above passes for a rule that
    # has been switched off entirely.
    err_log(GENUINE)
    findings = D.check_conversation_dispatch_failures(object())
    assert findings, "the rule stopped reporting real failures"
    blob = " ".join(f["title"] + " " + f["detail"] for f in findings)
    assert "1 " in blob or " one " in blob.lower(), blob
