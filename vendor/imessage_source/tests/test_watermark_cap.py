"""The watermark must never advance past a failed session.

If it does, the next tick's `session_max <= prev_watermark` check treats the
failed conversation as already processed and it is dropped for good -- the
.208 box-walk symptom: `sessions_failed: 1`, tick reported complete,
conversation never in the graph.
"""
import pathlib
import sys

# pipeline.py uses relative imports, so it must be imported as a package
# member -- put the package's PARENT on the path, not the package itself.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
from imessage_source.pipeline import cap_watermark  # noqa: E402


class TestNoFailures:
    def test_a_clean_run_advances_normally(self):
        assert cap_watermark(200, None) == 200

    def test_it_does_not_invent_progress(self):
        assert cap_watermark(-1, None) == -1


class TestAFailureHoldsTheLine:
    def test_the_watermark_stops_below_the_failure(self):
        assert cap_watermark(200, 100) == 99

    def test_the_bug_that_shipped(self):
        """THE regression. A later SUCCESS used to erase the claw-back:

            session A rowid 100 FAILS -> max_rowid = 99
            session B rowid 200 OK    -> max_rowid = max(99, 200) = 200

        and 100 was never retried. The cap is applied once, at the end, so a
        failure anywhere holds the line for everything after it.
        """
        max_rowid_after_later_success = 200
        assert cap_watermark(max_rowid_after_later_success, 100) == 99, (
            "a later success re-advanced the watermark past a failed session"
        )

    def test_the_earliest_failure_wins(self):
        """Two failures: the watermark must stop below the FIRST, or the
        earlier one is skipped while the later one retries."""
        assert cap_watermark(500, 100) == 99

    def test_a_failure_on_the_first_session_blocks_all_progress(self):
        assert cap_watermark(300, 1) == 0

    def test_it_never_advances_a_fresh_chat_on_failure(self):
        """prev_watermark -1 on a brand-new chat whose first session fails."""
        assert cap_watermark(50, 10) == 9


class TestPositiveControl:
    def test_the_function_discriminates(self):
        """Same max_rowid, different failure state, different answer -- proves
        it is not simply returning its input."""
        assert cap_watermark(200, None) != cap_watermark(200, 100)
