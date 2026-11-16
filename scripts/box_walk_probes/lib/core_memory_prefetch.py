"""core_memory_holds_no_prefetch_block: no core_ memory may carry the daemon's graph-prefetch block (#2436).

WHAT IT GUARDS. The daemon appends a lookup block to the user turn before the model answers
("[Looked up in the user's own data before answering (...)", ostler-assistant runtime agent.rs,
with_prefetched_context). It can carry L3 lookups. It is context for ONE answer, never something the
customer said, so it must never be consolidated into a core_ memory attributed to the user.
ostler-assistant #644 strips it inside consolidation itself (crates/zeroclaw-memory/src/prefetch.rs,
called from consolidation.rs consolidate_turn_with_trust). This is the post-walk box check of the result.

HOW. GET /api/memory?category=core on the daemon gateway (admin bearer, read from the install's token
file, never printed). Every core entry's content is matched, case-insensitively, against the block's
opening words and the cron block's opening words. Nothing is written to the box.

VERDICTS.
  FAIL        any core entry carries a marker (its KEY is printed, never its content)
  CANNOT-RUN  the token or the API could not be read, the reply has the wrong shape, or the daemon holds
              ZERO core entries (nothing was consolidated, so nothing was examined: a zero denominator is
              not a pass)
  PASS        N >= 1 core entries examined, 0 carry a marker

NOT INSTRUMENTED: daily_ and conversation entries are counted (printed as INFO) but do not decide the
verdict; the row's gate names core_ only. The command that would show a daily leak is the same request
with category=daily.

  box            drive on the box, print ONE json capture (keys and counts only, no memory content)
  judge FILE     judge a capture: exit 0 PASS, 1 FAIL, 78 CANNOT-RUN
  --self-test    canned captures; exits 0 only if every case lands on its expected verdict

Python 3.9, stdlib only.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
GATEWAY = os.environ.get("OSTLER_PROBE_GATEWAY", "http://127.0.0.1:8000").rstrip("/")
TOKEN_PATH = os.path.expanduser(
    os.environ.get("OSTLER_PROBE_TOKEN_PATH", "~/.ostler/secrets/zeroclaw_admin_token"))

# Opening words of the two blocks, lower-cased. Matching the opening only (not the close) catches a block
# the consolidator paraphrased the tail of, and a truncated one.
MARKERS = (
    "[looked up in the user's own data",
    "looked up in the user's own data before answering",
    "[the daemon has already acted on this request (cron_remove",
)


def has_marker(text):
    t = str(text or "").lower().replace("’", "'")
    return any(m in t for m in MARKERS)


def is_core(entry):
    key = str(entry.get("key") or "")
    cat = entry.get("category")
    cat = cat if isinstance(cat, str) else json.dumps(cat)
    return key.startswith("core_") or cat.strip('"').lower() == "core"


def _get(path, tok):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(GATEWAY + path, headers={"Authorization": "Bearer " + tok})
    return json.load(opener.open(req, timeout=20))


def _knob(name, default):
    raw = os.environ.get(name, "")
    try:
        v = int(raw) if raw.strip() else default
    except ValueError:
        v = default
    return v if v >= 0 else default


# CONSOLIDATION IS ASYNCHRONOUS (v1.0.124 and v1.0.125: 0 core entries on a box doing first-run work, the read
# taken once). The core read is now POLLED until at least one core entry exists or the budget runs out. The budget
# ends the wait and nothing else: a zero after it is still CANNOT-RUN, with the waited time printed, never PASS.
WAIT_S = _knob("OSTLER_CORE_MEMORY_WAIT_S", 300)
POLL_S = max(1, _knob("OSTLER_CORE_MEMORY_POLL_S", 15))


def _read(cat, tok):
    """(entries, None) or (None, reason)."""
    try:
        d = _get("/api/memory?category=" + cat, tok)
    except urllib.error.HTTPError as exc:
        return None, "GET /api/memory?category=%s answered HTTP %d" % (cat, exc.code)
    except Exception as exc:  # noqa: BLE001
        return None, "GET /api/memory?category=%s failed: %s" % (cat, type(exc).__name__)
    entries = d.get("entries") if isinstance(d, dict) else None
    if not isinstance(entries, list):
        return None, "GET /api/memory?category=%s returned no entries list (%s)" % (cat, type(d).__name__)
    return entries, None


def _summary(entries):
    return {
        "n": len(entries),
        "n_core_shaped": sum(1 for e in entries if isinstance(e, dict) and is_core(e)),
        "marker_keys": [str(e.get("key", "")) for e in entries if isinstance(e, dict) and has_marker(e.get("content"))],
    }


def box(wait_s=None, poll_s=None, clock=time.monotonic, sleep=time.sleep):
    wait_s = WAIT_S if wait_s is None else wait_s
    poll_s = POLL_S if poll_s is None else poll_s
    cap = {"gateway": GATEWAY, "core_wait_budget_s": wait_s}
    try:
        tok = open(TOKEN_PATH, encoding="utf-8").read().strip()
    except Exception as exc:  # noqa: BLE001 -- the reason is the output
        cap["cannot"] = "admin token unreadable at %s: %s" % (TOKEN_PATH, type(exc).__name__)
        return cap
    if not tok:
        cap["cannot"] = "admin token file is empty"
        return cap
    t0, polls = clock(), 0
    while True:
        entries, why = _read("core", tok)
        polls += 1
        if why:
            cap["cannot"] = why
            return cap
        waited = int(round(clock() - t0))
        if entries or waited + poll_s > wait_s:
            break
        sleep(poll_s)
    cap["core"] = _summary(entries)
    cap["core_waited_s"], cap["core_polls"] = waited, polls
    entries, why = _read("daily", tok)
    if why:
        cap["cannot"] = why
        return cap
    cap["daily"] = _summary(entries)
    return cap


def judge(cap):
    """Returns (rc, lines)."""
    if not isinstance(cap, dict):
        return EX_CANNOT, ["CANNOT the capture is not a json object"]
    if cap.get("cannot"):
        return EX_CANNOT, ["CANNOT " + str(cap["cannot"])]
    core = cap.get("core")
    if not isinstance(core, dict) or not isinstance(core.get("n"), int):
        return EX_CANNOT, ["CANNOT the capture has no core reading"]
    lines = []
    daily = cap.get("daily") or {}
    lines.append("INFO daily entries=%s carrying the marker=%d (not graded)"
                 % (daily.get("n", "?"), len(daily.get("marker_keys") or [])))
    if core["n"] > 0 and core.get("n_core_shaped") != core["n"]:
        # The category filter was ignored and some other category came back: what was examined is not
        # what the verdict would claim.
        return EX_CANNOT, lines + ["CANNOT category=core returned %d entries but only %s are core-shaped"
                                   % (core["n"], core.get("n_core_shaped"))]
    leaks = core.get("marker_keys") or []
    if leaks:
        return EX_FAIL, lines + ["FAIL core entries carrying the prefetch block: %d of %d (keys: %s)"
                                 % (len(leaks), core["n"], ", ".join(leaks[:10]))]
    if core["n"] == 0:
        waited = ""
        if isinstance(cap.get("core_waited_s"), int):
            waited = " (polled %s times over %ds of a %ss budget, OSTLER_CORE_MEMORY_WAIT_S)" % (
                cap.get("core_polls", "?"), cap["core_waited_s"], cap.get("core_wait_budget_s", "?"))
        return EX_CANNOT, lines + ["CANNOT the daemon holds 0 core entries%s: nothing was consolidated, nothing examined" % waited]
    return EX_PASS, lines + ["OK core_entries=%d prefetch_block_leaks=0" % core["n"]]


SELF_TEST_CASES = (
    ("clean core", {"core": {"n": 3, "n_core_shaped": 3, "marker_keys": []}, "daily": {"n": 1, "marker_keys": []}}, EX_PASS),
    ("one core entry carries the block", {"core": {"n": 3, "n_core_shaped": 3, "marker_keys": ["core_x"]}}, EX_FAIL),
    ("zero core entries is not a pass", {"core": {"n": 0, "n_core_shaped": 0, "marker_keys": []}}, EX_CANNOT),
    ("token unreadable", {"cannot": "admin token unreadable"}, EX_CANNOT),
    ("category filter ignored", {"core": {"n": 4, "n_core_shaped": 1, "marker_keys": []}}, EX_CANNOT),
    ("no core reading", {"daily": {"n": 2, "marker_keys": []}}, EX_CANNOT),
)

MARKER_CASES = (
    ("live block", "User moved.\n\n[Looked up in the user's own data before answering (pwg_people x):", True),
    ("paraphrased tail, upper-case", "LOOKED UP IN THE USER'S OWN DATA BEFORE ANSWERING", True),
    ("curly apostrophe", "[Looked up in the user’s own data before answering (", True),
    ("cron block", "[The daemon has ALREADY acted on this request (cron_remove abc", True),
    ("an ordinary fact", "User lives in a new flat and looked up train times.", False),
)


def self_test():
    bad = 0
    for name, cap, want in SELF_TEST_CASES:
        got, _ = judge(cap)
        ok = got == want
        bad += 0 if ok else 1
        print("  %s judge: %s (want %d got %d)" % ("ok  " if ok else "FAIL", name, want, got))
    for name, text, want in MARKER_CASES:
        got = has_marker(text)
        ok = got == want
        bad += 0 if ok else 1
        print("  %s marker: %s (want %s got %s)" % ("ok  " if ok else "FAIL", name, want, got))
    # The live box() reader runs the SAME predicate over a canned API reply.
    entries = [{"key": "core_a", "category": "core", "content": "User has a cat."},
               {"key": "core_b", "category": "core",
                "content": "User said: [Looked up in the user's own data before answering (pwg_people {}):"}]
    keys = [e["key"] for e in entries if has_marker(e["content"])]
    ok = keys == ["core_b"] and all(is_core(e) for e in entries)
    bad += 0 if ok else 1
    print("  %s reader: canned API reply flags exactly the leaking key" % ("ok  " if ok else "FAIL"))
    # The poll, driven through the REAL box() with a stubbed reader and clock: core entries that arrive on the
    # third read inside the budget are judged (PASS); a box that stays at zero is CANNOT-RUN once the budget is spent,
    # with the wait printed, and never PASS.
    for name, arrive_on, budget, want, want_polls in (
            ("core entries arrive on poll 3, inside the budget", 3, 60, EX_PASS, 3),
            ("core stays at zero: budget spent, CANNOT-RUN not PASS", 0, 60, EX_CANNOT, 5),
            ("budget 0: one read, no wait", 0, 0, EX_CANNOT, 1)):
        got, polls = _poll_case(arrive_on, budget)
        ok = got[0] == want and polls == want_polls and (want != EX_CANNOT or "polled %d times" % polls in got[1][-1])
        bad += 0 if ok else 1
        print("  %s poll: %s (want %d/%d polls, got %d/%d)" % ("ok  " if ok else "FAIL", name, want, want_polls, got[0], polls))
    return bad


def _poll_case(arrive_on, budget):
    global _read, TOKEN_PATH
    now, reads = [0.0], [0]
    real_read, real_tok = _read, TOKEN_PATH

    def fake_read(cat, tok):
        if cat == "daily":
            return [], None
        reads[0] += 1
        if arrive_on and reads[0] >= arrive_on:
            return [{"key": "core_a", "category": "core", "content": "User has a cat."}], None
        return [], None

    import tempfile
    fd, path = tempfile.mkstemp()
    os.write(fd, b"synthetic"); os.close(fd)
    try:
        _read, TOKEN_PATH = fake_read, path
        cap = box(wait_s=budget, poll_s=15, clock=lambda: now[0],
                  sleep=lambda s: now.__setitem__(0, now[0] + s))
    finally:
        _read, TOKEN_PATH = real_read, real_tok
        os.unlink(path)
    return judge(cap), reads[0]


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return EX_PASS if self_test() == 0 else EX_FAIL
    if len(argv) >= 2 and argv[1] == "box":
        print(json.dumps(box()))
        return EX_PASS
    if len(argv) >= 3 and argv[1] == "judge":
        try:
            cap = json.load(open(argv[2], encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            print("CANNOT capture unreadable: " + type(exc).__name__)
            return EX_CANNOT
        rc, lines = judge(cap)
        print("\n".join(lines))
        return rc
    print(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
