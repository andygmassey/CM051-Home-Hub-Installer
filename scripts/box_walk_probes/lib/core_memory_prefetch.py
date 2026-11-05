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


def box():
    cap = {"gateway": GATEWAY}
    try:
        tok = open(TOKEN_PATH, encoding="utf-8").read().strip()
    except Exception as exc:  # noqa: BLE001 -- the reason is the output
        cap["cannot"] = "admin token unreadable at %s: %s" % (TOKEN_PATH, type(exc).__name__)
        return cap
    if not tok:
        cap["cannot"] = "admin token file is empty"
        return cap
    for cat in ("core", "daily"):
        try:
            d = _get("/api/memory?category=" + cat, tok)
        except urllib.error.HTTPError as exc:
            cap["cannot"] = "GET /api/memory?category=%s answered HTTP %d" % (cat, exc.code)
            return cap
        except Exception as exc:  # noqa: BLE001
            cap["cannot"] = "GET /api/memory?category=%s failed: %s" % (cat, type(exc).__name__)
            return cap
        entries = d.get("entries") if isinstance(d, dict) else None
        if not isinstance(entries, list):
            cap["cannot"] = "GET /api/memory?category=%s returned no entries list (%s)" % (cat, type(d).__name__)
            return cap
        cap[cat] = {
            "n": len(entries),
            "n_core_shaped": sum(1 for e in entries if isinstance(e, dict) and is_core(e)),
            "marker_keys": [str(e.get("key", "")) for e in entries if isinstance(e, dict) and has_marker(e.get("content"))],
        }
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
        return EX_CANNOT, lines + ["CANNOT the daemon holds 0 core entries: nothing was consolidated, nothing examined"]
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
    return bad


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
