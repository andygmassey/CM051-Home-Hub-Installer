"""The CONTEXT.md swap in probes/owner_knowledge_score.sh must be crash-safe and
must never touch a real owner's file.

Everything runs the REAL probe locally (OSTLER_BOX_HOST unset = this machine, the
probe contract) against a temp HOME and the loopback fake gateway from
test_owner_score.py. Run: python3 -I scripts/owner_score/test_context_swap.py
"""
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_owner_score as t  # noqa: E402

PROBE = os.path.join(HERE, "..", "box_walk_probes", "probes", "owner_knowledge_score.sh")
SEED_PERSON = "Ben Doe"          # the walk's synthetic known person (invented)
SYNTHETIC_CTX = "# Personal Context\n- %s works at Acme Corp\n" % SEED_PERSON
REAL_CTX = "# Personal Context\n- Someone Real works at Somewhere Real\n"
GOLD = {q["question"]: q["gold"] for q in t.ALL}


class Box:
    def __init__(self, ctx, declare_synthetic=False, table=None):
        self.home = tempfile.mkdtemp()
        self.ws = self.home + "/.zeroclaw/workspace"
        os.makedirs(self.ws)
        os.makedirs(self.home + "/.ostler/secrets")
        open(self.home + "/.ostler/secrets/zeroclaw_admin_token", "w").write("tok123")
        self.ctx_path = self.ws + "/CONTEXT.md"
        if ctx is not None:
            open(self.ctx_path, "w").write(ctx)
        if declare_synthetic:
            os.makedirs(self.home + "/.ostler/state")
            open(self.home + "/.ostler/state/synthetic-box", "w").write("")
        self.gw = t.FakeGateway("tok123", GOLD if table is None else table)
        self.gw.start()

    def env(self, **kw):
        e = dict(os.environ, HOME=self.home, OSTLER_PROBE_GATEWAY="http://127.0.0.1:%d" % self.gw.port,
                 OSTLER_OWNER_SCORE_LIMIT="8", OSTLER_GATE_KNOWN_PERSON=SEED_PERSON)
        e.pop("OSTLER_BOX_HOST", None)
        e.update(kw)
        return e

    def popen(self, **kw):
        return subprocess.Popen(["bash", PROBE], env=self.env(**kw), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, start_new_session=True)

    def run(self, **kw):
        r = subprocess.run(["bash", PROBE], env=self.env(**kw), capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout

    def ctx(self):
        return open(self.ctx_path).read() if os.path.exists(self.ctx_path) else None

    def leftovers(self):
        return sorted(f for f in os.listdir(self.ws) if f != "CONTEXT.md")

    def close(self):
        self.gw.srv.close()


class RealOwnerIsNeverTouched(unittest.TestCase):
    def test_non_synthetic_context_is_refused_and_untouched(self):
        b = Box(REAL_CTX)
        self.addCleanup(b.close)
        rc, out = b.run()
        self.assertEqual(rc, 78, out)
        self.assertIn("CANNOT-RUN", out)
        self.assertIn("not the synthetic seed", out)
        self.assertEqual(b.ctx(), REAL_CTX)
        self.assertEqual(b.leftovers(), [])
        self.assertEqual(b.gw.asked, [], "nothing may be asked of a real owner's assistant")

    def test_no_context_at_all_is_refused_too(self):
        b = Box(None)
        self.addCleanup(b.close)
        rc, out = b.run()
        self.assertEqual(rc, 78, out)
        self.assertIsNone(b.ctx())

    def test_seed_person_in_context_allows_the_swap_and_restores_exactly(self):
        b = Box(SYNTHETIC_CTX)
        self.addCleanup(b.close)
        rc, out = b.run()
        self.assertEqual(rc, 0, out)
        self.assertIn("VERDICT: PASS", out)
        self.assertEqual(b.ctx(), SYNTHETIC_CTX)
        self.assertEqual(b.leftovers(), [])

    def test_declared_synthetic_box_allows_the_swap(self):
        b = Box(REAL_CTX, declare_synthetic=True)
        self.addCleanup(b.close)
        rc, out = b.run()
        self.assertEqual(rc, 0, out)
        self.assertEqual(b.ctx(), REAL_CTX)


class CrashSafe(unittest.TestCase):
    def _kill_mid_run(self, b, sig):
        p = b.popen()
        fired = threading.Event()

        def on_ask(_q):
            if not fired.is_set():
                fired.set()
                os.killpg(p.pid, sig)   # the probe and everything it started
        b.gw.on_ask = on_ask
        p.communicate(timeout=60)
        self.assertTrue(fired.is_set(), "the gateway was never asked, so nothing was killed mid-run")
        time.sleep(0.5)

    def test_sigterm_mid_run_restores_the_original(self):
        b = Box(SYNTHETIC_CTX)
        self.addCleanup(b.close)
        self._kill_mid_run(b, signal.SIGTERM)
        self.assertEqual(b.ctx(), SYNTHETIC_CTX)
        self.assertEqual(b.leftovers(), [])

    def test_sigint_mid_run_restores_the_original(self):
        b = Box(SYNTHETIC_CTX)
        self.addCleanup(b.close)
        self._kill_mid_run(b, signal.SIGINT)
        self.assertEqual(b.ctx(), SYNTHETIC_CTX)
        self.assertEqual(b.leftovers(), [])

    def test_kill_9_mid_run_then_the_next_run_restores_the_original_first(self):
        b = Box(SYNTHETIC_CTX)
        self.addCleanup(b.close)
        self._kill_mid_run(b, signal.SIGKILL)
        # SIGKILL cannot be trapped: the persona is still in place and a backup exists.
        self.assertIn("Synthetic owner: Jane Smith", b.ctx())
        self.assertIn("CONTEXT.md.owner-score-backup", b.leftovers())
        # The next run must restore the original BEFORE it does anything else.
        b.gw.on_ask = None
        seen = []
        b.gw.on_ask = lambda q: seen.append(open(b.ctx_path).read())
        rc, out = b.run()
        self.assertEqual(rc, 0, out)
        self.assertIn("RECOVERED", out)
        self.assertEqual(b.ctx(), SYNTHETIC_CTX, "the original was lost")
        self.assertEqual(b.leftovers(), [])
        self.assertTrue(all("Synthetic owner: Jane Smith" in s for s in seen), "persona was live during the questions")

    def test_a_leftover_backup_is_never_clobbered_by_a_new_backup(self):
        # crash-state: persona installed, original only in the backup. A second
        # crash must not overwrite the only copy of the original with the persona.
        b = Box(SYNTHETIC_CTX)
        self.addCleanup(b.close)
        self._kill_mid_run(b, signal.SIGKILL)
        self._kill_mid_run(b, signal.SIGKILL)
        rc, out = b.run()
        self.assertEqual(rc, 0, out)
        self.assertEqual(b.ctx(), SYNTHETIC_CTX)


class AdvisoryInTheRealProbe(unittest.TestCase):
    def test_below_target_is_advisory_and_exits_zero_with_the_real_scope_row(self):
        b = Box(SYNTHETIC_CTX, table={})
        self.addCleanup(b.close)
        rc, out = b.run()
        self.assertEqual(rc, 0, out)
        self.assertIn("VERDICT: ADVISORY", out)
        self.assertNotIn("VERDICT: FAIL", out)

    def test_below_target_is_a_fail_once_the_row_is_blocking(self):
        b = Box(SYNTHETIC_CTX, table={})
        self.addCleanup(b.close)
        scope = os.path.join(b.home, "scope.tsv")
        open(scope, "w").write("owner_knowledge_score\tblocking\tCM051\tx\n")
        rc, out = b.run(OSTLER_PROMOTE_SCOPE_FILE=scope)
        self.assertEqual(rc, 1, out)
        self.assertIn("VERDICT: FAIL", out)


if __name__ == "__main__":
    unittest.main(verbosity=1)
