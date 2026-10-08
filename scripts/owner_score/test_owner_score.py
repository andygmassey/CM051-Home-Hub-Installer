"""Self-tests that VALIDATE THE CHECK before anything is graded against it.

Run: python3 -I scripts/owner_score/test_owner_score.py   (stdlib unittest)

A check that has never been seen to score 0 on wrong answers, or 100 on right
ones, is not a check. These tests are the proof it can do both.
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import base64
import hashlib
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import grading            # noqa: E402
import owner_score as os_  # noqa: E402
import persona_digest     # noqa: E402

VIS = os_.load_questions(os.path.join(HERE, "questions_visible.jsonl"))
HELD = os_.load_questions(os.path.join(HERE, "questions_heldout.jsonl"))
ALL = VIS + HELD
GOLD = {q["id"]: q["gold"] for q in ALL}


def pct(answers, qs=ALL):
    return grading.score_set(qs, answers)[0] * 100


class Shape(unittest.TestCase):
    def test_split_is_60_visible_20_held_back(self):
        self.assertEqual((len(VIS), len(HELD)), (60, 20))

    def test_ids_unique_and_disjoint(self):
        ids = [q["id"] for q in ALL]
        self.assertEqual(len(ids), len(set(ids)))

    def test_every_category_has_ten_and_both_splits(self):
        for c in grading.CATEGORIES:
            self.assertEqual(sum(q["category"] == c for q in ALL), 10, c)
            self.assertTrue(any(q["category"] == c for q in HELD), c)
            self.assertTrue(any(q["category"] == c for q in VIS), c)

    def test_there_are_absent_questions_and_they_are_visible_only_or_both(self):
        self.assertGreaterEqual(sum(q["kind"] == "absent" for q in ALL), 8)

    def test_no_llm_judge_anywhere(self):
        src = open(os.path.join(HERE, "grading.py")).read().lower()
        for bad in ("ollama", "anthropic", "openai", "urllib", "socket"):
            self.assertNotIn(bad, src)


class KnownGoodScoresFull(unittest.TestCase):
    def test_gold_answers_score_100_per_question(self):
        bad = [(q["id"], grading.grade(q, GOLD[q["id"]])) for q in ALL if grading.grade(q, GOLD[q["id"]])[0] != 1.0]
        self.assertEqual(bad, [])

    def test_gold_is_100_percent(self):
        self.assertEqual(pct(GOLD), 100.0)


class WrongAnswersScoreNearZero(unittest.TestCase):
    def test_blank_is_zero(self):
        self.assertEqual(pct({q["id"]: "" for q in ALL}), 0.0)
        self.assertEqual(pct({}), 0.0)

    def test_global_shuffle_is_wrong_person(self):
        ids = [q["id"] for q in ALL]
        shuffled = {ids[i]: GOLD[ids[(i + 7) % len(ids)]] for i in range(len(ids))}
        self.assertLessEqual(pct(shuffled), 5.0)

    def test_within_category_rotation_is_wrong_person(self):
        out = {}
        for c in grading.CATEGORIES:
            ids = [q["id"] for q in ALL if q["category"] == c]
            for i, k in enumerate(ids):
                out[k] = GOLD[ids[(i + 1) % len(ids)]]
        self.assertLessEqual(pct(out), 10.0)

    def test_idk_everywhere_only_earns_the_absent_questions(self):
        n_abs = sum(q["kind"] == "absent" for q in ALL)
        got = pct({q["id"]: "I don't know." for q in ALL})
        self.assertLessEqual(got, 100.0 * n_abs / len(ALL) + 0.001)
        self.assertLessEqual(got, 12.5)

    def test_echoing_the_question_scores_zero_so_no_question_leaks_its_answer(self):
        self.assertLessEqual(pct({q["id"]: q["question"] for q in ALL}), 1.0)

    def test_shotgun_every_fact_pasted_scores_zero(self):
        blob = " ".join(GOLD.values())
        self.assertLessEqual(pct({q["id"]: blob for q in ALL}), 0.0)

    def test_fabricating_a_figure_on_an_absent_question_fails(self):
        q = next(q for q in ALL if q["id"] == "family-10")
        self.assertEqual(grading.grade(q, "I don't have it, but try 07700 900123.")[0], 0.0)
        self.assertEqual(grading.grade(q, "His number is 07700 900123.")[0], 0.0)
        self.assertEqual(grading.grade(q, "I don't have a phone number for Dominic.")[0], 1.0)

    def test_trap_zeroes_a_right_answer(self):
        q = {"id": "t", "category": "work", "question": "?", "kind": "fact",
             "require": [["fenwick"]], "none_of": ["contoso"]}
        self.assertEqual(grading.grade(q, "Fenwick, not Contoso.")[0], 0.0)
        self.assertEqual(grading.grade(q, "Fenwick.")[0], 1.0)

    def test_word_boundaries_and_case(self):
        q = {"id": "t", "category": "work", "question": "?", "kind": "fact", "require": [["14"]]}
        self.assertEqual(grading.grade(q, "There are 140 of them.")[0], 0.0)
        self.assertEqual(grading.grade(q, "A team of **14** people.")[0], 1.0)


class QuestionsAreAnswerableFromTheOwnerCheatSheet(unittest.TestCase):
    """The persona digest is the CONTEXT.md a test workspace would carry."""
    P = json.load(open(os.path.join(HERE, "persona.json")))
    DIGEST = grading.normalise(persona_digest.render(P))

    def test_every_required_fact_is_in_the_digest(self):
        missing = []
        for q in ALL:
            if q["kind"] != "fact":
                continue
            for g in q["require"]:
                if not any(grading._present(a, self.DIGEST) for a in g):
                    missing.append((q["id"], g[0]))
        self.assertEqual(missing, [])

    def test_absent_questions_really_are_absent(self):
        for needle in ("salary", "pension", "favourite film", "lunch", "canada", "phone", "address", "new job"):
            # the persona may mention Calgary/Dominic, but never these asks
            self.assertNotIn(needle, self.DIGEST, needle)

    def test_committed_digest_matches_persona(self):
        path = os.path.join(HERE, "CONTEXT.persona.md")
        self.assertEqual(open(path).read(), persona_digest.render(self.P))

    def test_digest_fits_the_daemon_cap(self):
        self.assertLess(len(persona_digest.render(self.P)), 20000)  # BOOTSTRAP_MAX_CHARS

    def test_no_real_contact_details(self):
        text = open(os.path.join(HERE, "persona.json")).read() + "".join(open(os.path.join(HERE, f)).read() for f in ("questions_visible.jsonl", "questions_heldout.jsonl"))
        self.assertIsNone(re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}", text))
        self.assertIsNone(re.search(r"\b0\d{9,10}\b|\+\d{8,}", text))


class ChecksumIsEnforced(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_committed_lock_matches_the_files(self):
        ok, combined, msg = os_.verify_checksum([os.path.join(HERE, f) for f in os_.CHECKED], os_.LOCK)
        self.assertTrue(ok, msg)

    def _copy_and_run(self, mutate):
        d = os.path.join(self.tmp, "o")
        shutil.copytree(HERE, d, ignore=shutil.ignore_patterns("__pycache__"))
        mutate(d)
        gold = os.path.join(self.tmp, "g.json")
        json.dump(GOLD, open(gold, "w"))
        return subprocess.run([sys.executable, "-I", os.path.join(d, "owner_score.py"), "--answers", gold],
                              capture_output=True, text=True)

    def test_untouched_copy_scores(self):
        r = self._copy_and_run(lambda d: None)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("SCORE  100.0%", r.stdout)

    def test_editing_a_question_is_refused(self):
        def m(d):
            p = os.path.join(d, "questions_visible.jsonl")
            open(p, "w").write(open(p).read().replace("Where do I work", "Where do I toil"))
        r = self._copy_and_run(m)
        self.assertEqual(r.returncode, 3)
        self.assertIn("CHECK CHANGED", r.stdout)
        self.assertNotIn("SCORE", r.stdout)

    def test_editing_a_grader_is_refused(self):
        def m(d):
            p = os.path.join(d, "grading.py")
            open(p, "a").write("\n# softer\n")
        self.assertEqual(self._copy_and_run(m).returncode, 3)

    def test_editing_the_runner_is_refused(self):
        def m(d):
            p = os.path.join(d, "owner_score.py")
            open(p, "a").write("\n# skip the hard questions\n")
        r = self._copy_and_run(m)
        self.assertEqual(r.returncode, 3)
        self.assertIn("owner_score.py", r.stdout)

    def test_runner_hash_is_printed_beside_the_check_hash(self):
        r = self._copy_and_run(lambda d: None)
        self.assertRegex(r.stdout, r"CHECK  runner owner_score.py sha256 [0-9a-f]{64}")

    def test_editing_the_heldout_file_is_refused(self):
        def m(d):
            p = os.path.join(d, "questions_heldout.jsonl")
            open(p, "a").write("\n")
        self.assertEqual(self._copy_and_run(m).returncode, 3)

    def test_custom_file_is_locked_on_first_use_then_verified(self):
        cq = os.path.join(self.tmp, "mine.jsonl")
        open(cq, "w").write(json.dumps({"id": "x-01", "category": "work", "question": "Where?", "kind": "fact",
                                        "require": [["acme"]], "gold": "Acme."}) + "\n")
        ans = os.path.join(self.tmp, "a.json")
        json.dump({"x-01": "Acme."}, open(ans, "w"))
        run = lambda: subprocess.run([sys.executable, "-I", os.path.join(HERE, "owner_score.py"), "--questions", cq, "--answers", ans],
                                     capture_output=True, text=True)
        r1 = run()
        self.assertEqual(r1.returncode, 0, r1.stdout)
        self.assertIn("FIRST USE", r1.stdout)
        self.assertTrue(os.path.exists(cq + ".lock"))
        self.assertEqual(run().returncode, 0)
        open(cq, "a").write("# loosened\n")
        r3 = run()
        self.assertEqual(r3.returncode, 3)


class HeldBackSetStaysHeldBack(unittest.TestCase):
    def _run(self, *args):
        gold = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump({k: "wrong" for k in GOLD}, gold)   # make every question a failure so worst-10 prints
        gold.close()
        self.addCleanup(os.unlink, gold.name)
        return subprocess.run([sys.executable, "-I", os.path.join(HERE, "owner_score.py"), "--answers", gold.name, *args],
                              capture_output=True, text=True).stdout

    def test_default_run_never_names_a_heldout_question(self):
        out = self._run()
        for q in HELD:
            self.assertNotIn(q["question"], out)
            self.assertNotIn(q["gold"], out)
            self.assertNotIn("[" + q["id"] + "]", out)

    def test_scoring_the_heldout_set_withholds_its_text(self):
        out = self._run("--set", "heldout")
        self.assertIn("text withheld", out)
        for q in HELD:
            self.assertNotIn(q["question"], out)
            self.assertNotIn(q["gold"], out)

    def test_no_verbatim_flag_prints_no_answer_text(self):
        out = self._run("--no-verbatim")
        self.assertNotIn("A: wrong", out)
        self.assertIn("text not shown", out)
        self.assertNotIn("held back", out)   # visible ids are not held-back ids


class FakeGateway(threading.Thread):
    """A loopback /ws/chat that enforces the bearer token like the real gateway
    (ostler-assistant crates/zeroclaw-gateway/src/ws.rs handle_ws_chat) and
    answers from a table, so the runner is exercised end to end."""
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(self, token, table):
        super().__init__(daemon=True)
        self.token, self.table, self.asked = token, table, []
        self.on_ask = None   # optional callback(question) fired when a question arrives
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(5)
        self.port = self.srv.getsockname()[1]

    @staticmethod
    def _send(c, obj):
        d = json.dumps(obj).encode()
        h = struct.pack("!BB", 0x81, len(d)) if len(d) < 126 else struct.pack("!BBH", 0x81, 126, len(d))
        c.sendall(h + d)

    def run(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            try:
                buf = b""
                while b"\r\n\r\n" not in buf:
                    buf += c.recv(4096)
                hdr = buf.decode(errors="replace")
                if ("Authorization: Bearer %s" % self.token) not in hdr:
                    c.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
                    c.close()
                    continue
                key = re.search(r"Sec-WebSocket-Key: (\S+)", hdr).group(1)
                acc = base64.b64encode(hashlib.sha1((key + self.GUID).encode()).digest()).decode()
                c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Accept: %s\r\nSec-WebSocket-Protocol: zeroclaw.v1\r\n\r\n" % acc).encode())
                self._send(c, {"type": "session_start", "session_id": "s"})
                b = c.recv(2)
                n = b[1] & 0x7F
                if n == 126:
                    n = struct.unpack("!H", c.recv(2))[0]
                mask = c.recv(4)
                data = b""
                while len(data) < n:
                    data += c.recv(n - len(data))
                q = json.loads(bytes(x ^ mask[i % 4] for i, x in enumerate(data)))["content"]
                self.asked.append(q)
                if self.on_ask:
                    self.on_ask(q)
                ans = self.table.get(q, "")
                self._send(c, {"type": "chunk", "content": "draft "})
                self._send(c, {"type": "chunk_reset"})
                self._send(c, {"type": "done", "full_response": ans})
            except Exception:
                pass
            finally:
                try:
                    c.close()
                except OSError:
                    pass


class RunsOverTheRealChatShape(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.tok = os.path.join(self.tmp, "tok")
        open(self.tok, "w").write("s3cret-test-token\n")

    def _gw(self, table):
        g = FakeGateway("s3cret-test-token", table)
        g.start()
        self.addCleanup(g.srv.close)
        return g

    def _run(self, g, *args, token_path=None):
        return subprocess.run([sys.executable, "-I", os.path.join(HERE, "owner_score.py"),
                               "--gateway", "http://127.0.0.1:%d" % g.port,
                               "--token-path", token_path or self.tok, "--timeout", "10", *args],
                              capture_output=True, text=True)

    def test_gold_over_the_wire_scores_100_and_uses_full_response_not_the_draft(self):
        g = self._gw({q["question"]: q["gold"] for q in VIS})
        r = self._run(g)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("SCORE  100.0%", r.stdout)
        self.assertEqual(len(g.asked), 60)

    def test_blank_gateway_scores_zero(self):
        g = self._gw({})
        r = self._run(g)
        self.assertIn("SCORE  0.0%", r.stdout)

    def test_enforce_below_target_exits_1(self):
        g = self._gw({})
        self.assertEqual(self._run(g, "--enforce", "--limit", "8").returncode, 1)
        self.assertEqual(self._run(g, "--limit", "8").returncode, 0)

    def test_wrong_token_is_cannot_run_not_a_zero(self):
        g = self._gw({})
        bad = os.path.join(self.tmp, "bad")
        open(bad, "w").write("nope")
        r = self._run(g, token_path=bad)
        self.assertEqual(r.returncode, 78)
        self.assertNotIn("SCORE", r.stdout)

    def test_missing_token_is_cannot_run(self):
        g = self._gw({})
        self.assertEqual(self._run(g, token_path=os.path.join(self.tmp, "none")).returncode, 78)

    def test_non_loopback_gateway_is_refused_so_nothing_can_leave_the_machine(self):
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "owner_score.py"),
                            "--gateway", "http://203.0.113.9:8000", "--token-path", self.tok],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("not loopback", r.stdout)

    def test_limit_samples_every_category(self):
        g = self._gw({})
        self._run(g, "--limit", "8")
        cats = {next(q for q in VIS if q["question"] == a)["category"] for a in g.asked}
        self.assertEqual(cats, set(grading.CATEGORIES))
        self.assertEqual(len(g.asked), 8)


if __name__ == "__main__":
    unittest.main(verbosity=1)
