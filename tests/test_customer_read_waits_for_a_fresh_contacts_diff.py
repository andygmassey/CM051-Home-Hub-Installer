#!/usr/bin/env python3
"""no_person_holds_two_contact_cards must not call a STALE contacts/diff report a miss.

The Hub serves a cached /api/v1/contacts/diff report (ical-server.py
_contacts_diff_cached) that can predate the walk seed, so a seeded duplicate
pair is absent from it and the probe read that as UNREVIEWED (false FAIL).
Now: wait (bounded) for as_of > seed time and refreshing false; on expiry the
verdict is CANNOT-RUN with as_of in the detail, never FAIL and never PASS.

Runs the REAL judge (DECLARED[13]) and the REAL wait loop with a stubbed fetch
and a fake clock. Synthetic data only. Exit 0 all pass, 1 any fail.
"""
import copy
import datetime as dt
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib"))
import customer_read as cr  # noqa: E402

SEED = 1_800_000_000.0


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).isoformat(timespec="seconds")


def verdict13(extra, reviewed):
    f = copy.deepcopy(cr._good())
    f["people_rows"] += ["Jane Doe\n+44 7700 900008", "John Doe\n+44 7700 900008"]
    f["duplicate_review_phones"] = reviewed
    f.update(extra)
    out = [r for r in cr.judge(f) if r[0] == cr.DECLARED[13]]
    assert len(out) == 1, out
    return out[0]


class Clock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


def wait(responses, seed_ts=SEED, bound=720, poll=15):
    c = Clock()
    seq = list(responses)
    calls = []

    def fetch():
        calls.append(c.t)
        return seq.pop(0) if len(seq) > 1 else seq[0]

    diff, stale = cr.wait_for_fresh_diff(fetch, seed_ts, bound, poll, sleep=c.sleep, clock=c.now)
    return diff, stale, calls


STALE = {"as_of": iso(SEED - 300), "refreshing": False, "items": []}
FRESH = {"as_of": iso(SEED + 60), "refreshing": False, "items": []}

CASES = []


def case(label):
    def deco(fn):
        CASES.append((label, fn))
        return fn
    return deco


@case("judge: stale report + missing card -> CANNOT-RUN (main says FAIL)")
def _():
    v = verdict13({"duplicate_review_stale": "stale report after 720s", "duplicate_review_as_of": iso(SEED - 300),
                   "duplicate_review_refreshing": False, "duplicate_review_seed_ts": SEED}, [])
    return v[1] is None and iso(SEED - 300) in v[2] and "refreshing=False" in v[2], v


@case("judge: fresh report + missing card -> still FAIL (control: a real miss is caught)")
def _():
    v = verdict13({"duplicate_review_as_of": iso(SEED + 60), "duplicate_review_refreshing": False,
                   "duplicate_review_seed_ts": SEED}, [])
    return v[1] is False and iso(SEED + 60) in v[2], v


@case("judge: fresh report + card -> PASS, as_of and refreshing recorded")
def _():
    v = verdict13({"duplicate_review_as_of": iso(SEED + 60), "duplicate_review_refreshing": False,
                   "duplicate_review_seed_ts": SEED}, ["447700900008"])
    return v[1] is True and "refreshing=False" in v[2], v


@case("wait: stale for the whole bound -> stale reason, as_of kept, polled repeatedly")
def _():
    diff, stale, calls = wait([STALE])
    return bool(stale) and "not later than the seed" in stale and diff["as_of"] == STALE["as_of"] and len(calls) > 10, (stale, len(calls))


@case("wait: stale, then a post-seed report arrives -> settled, no stale")
def _():
    diff, stale, calls = wait([STALE, STALE, FRESH])
    return stale is None and diff is FRESH and len(calls) == 3, (stale, len(calls))


@case("wait: post-seed as_of but refreshing=true never clears -> stale")
def _():
    busy = dict(FRESH, refreshing=True)
    diff, stale, _ = wait([busy])
    return bool(stale) and "refreshing" in stale, stale


@case("wait: refreshing=true then false -> settled")
def _():
    diff, stale, _ = wait([dict(FRESH, refreshing=True), FRESH])
    return stale is None, stale


@case("wait: still 'preparing' for the whole bound -> stale")
def _():
    diff, stale, _ = wait([{"preparing": True, "items": [], "degraded": True}])
    return bool(stale) and "preparing" in stale, stale


@case("wait: as_of missing or unparseable with a seed time -> stale, never trusted")
def _():
    r1 = wait([{"refreshing": False, "items": []}], bound=60)[1]
    r2 = wait([{"as_of": "garbage", "refreshing": False, "items": []}], bound=60)[1]
    return bool(r1) and bool(r2), (r1, r2)


@case("wait: no seed time recorded -> only refreshing is required (settled on first read)")
def _():
    diff, stale, calls = wait([STALE], seed_ts=None)
    return stale is None and len(calls) == 1, (stale, len(calls))


@case("wait: as_of equal to the seed second is not 'later' -> stale")
def _():
    return bool(wait([dict(STALE, as_of=iso(SEED))], bound=60)[1]), None


def _seed_block():
    """The probe's own seed-time block, cut out of the real shell file."""
    src = open(os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes",
                            "hub_screens_customer_read.sh")).read()
    if '    seed_unreadable=""' not in src:  # the pre-fix two-line block, so its behaviour is what fails
        a = src.index('    box_run "cat')
        b = src.index("\n", src.index("[ -s", a)) + 1
        return src[a:b]
    a = src.index('    seed_unreadable=""')
    b = src.index("    esac\n", a) + len("    esac\n")
    # plus the probe's own argument assembly for the collector
    c = src.index('    [ "${seed_rc}" -eq 0 ]', b)
    d = src.index("--seed-ts-unreadable", c)
    d = src.index("\n", d) + 1
    return src[a:b] + src[c:d]


def probe_seed(mode, content=None):
    """Run the real block with a box_run that executes the REAL remote command
    locally against a temp HOME. mode: absent | file | dir (read error) | ssh (255)."""
    with tempfile.TemporaryDirectory() as home:
        seed = os.path.join(home, ".walk-contact-cards-seed-ts")
        if mode == "file":
            open(seed, "w").write(content)
        elif mode == "dir":
            os.mkdir(seed)
        script = (
            'seedf="$OUT/seed_ts.txt"\n'
            'probe_note() { echo "NOTE: $*"; }\n'
            'box_run() { if [ "$MODE" = ssh ]; then return 255; fi; HOME="$FAKEHOME" bash -c "$1" 2>/dev/null; }\n'
            + _seed_block()
            + 'echo "RC=${seed_rc} UNREADABLE=${seed_unreadable}"\necho "ARGS=$*"\n')
        script = "set --\n" + script
        r = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True,
                           env={"PATH": os.environ["PATH"], "OUT": home, "MODE": mode, "FAKEHOME": home})
        return r.stdout


@case("probe: seed file ABSENT keeps the 'refreshing only' note, not unreadable")
def _():
    o = probe_seed("absent")
    return "refreshing only" in o and "UNREADABLE=\n" in o and "RC=4" in o, o


@case("probe: ssh/box failure -> 'seed ts unreadable' (main: collapsed into 'no seed ts')")
def _():
    o = probe_seed("ssh")
    return ("seed ts unreadable" in o and "CANNOT-RUN" in o and "refreshing only" not in o
            and "ARGS=--seed-ts-unreadable seed ts unreadable" in o and "--seed-ts-file" not in o), o


@case("probe: file present but read error -> 'seed ts unreadable'")
def _():
    o = probe_seed("dir")
    return "seed ts unreadable" in o and "refreshing only" not in o, o


@case("probe: readable file -> rc 0, no note, no unreadable")
def _():
    o = probe_seed("file", "1800000000\n")
    return "RC=0 UNREADABLE=\n" in o and "NOTE" not in o and "ARGS=--seed-ts-file " in o, o


@case("py: read_seed_ts_file good file -> (ts, None)")
def _():
    with tempfile.NamedTemporaryFile("w", suffix=".ts") as t:
        t.write("1800000000\n")
        t.flush()
        return cr.read_seed_ts_file(t.name) == (1800000000.0, None), None


@case("py: unparseable / empty / implausible seed file -> problem 'seed ts unparseable: ...', never silent None")
def _():
    outs = []
    for body in ("garbage\n", "", "nan", "-5", "0"):
        with tempfile.NamedTemporaryFile("w", suffix=".ts") as t:
            t.write(body)
            t.flush()
            outs.append(cr.read_seed_ts_file(t.name))
    return all(ts is None and p and p.startswith("seed ts unparseable: ") for ts, p in outs), outs


@case("py: seed file missing on disk -> 'seed ts unreadable'")
def _():
    ts, p = cr.read_seed_ts_file("/nonexistent/seed.ts")
    return ts is None and p.startswith("seed ts unreadable"), (ts, p)


@case("judge: seed problem + duplicate -> CANNOT-RUN naming the problem, even if a card exists")
def _():
    v = verdict13({"duplicate_review_seed_problem": "seed ts unparseable: 'garbage' is not a number",
                   "duplicate_review_as_of": iso(SEED + 60), "duplicate_review_refreshing": False}, ["447700900008"])
    return v[1] is None and "seed ts unparseable" in v[2], v


@case("judge: seed problem + missing card -> CANNOT-RUN, not FAIL")
def _():
    v = verdict13({"duplicate_review_seed_problem": "seed ts unreadable (box command rc=255)",
                   "duplicate_review_as_of": iso(SEED + 60), "duplicate_review_refreshing": False}, [])
    return v[1] is None and "seed ts unreadable" in v[2], v


@case("end to end: CLI main() with an unparseable --seed-ts-file reaches collect with the problem")
def _():
    seen = {}
    real = cr.collect
    cr.collect = lambda *a, **k: (seen.update(k), (_ for _ in ()).throw(RuntimeError("stop")))[1]
    try:
        with tempfile.TemporaryDirectory() as d:
            for n, body in (("tok", "t"), ("seed", "garbage")):
                open(os.path.join(d, n), "w").write(body)
            argv = ["collect", "--base", "http://x", "--token-file", os.path.join(d, "tok"),
                    "--out", d, "--seed-ts-file", os.path.join(d, "seed")]
            try:
                cr.main(argv)
            except RuntimeError:
                pass
            seen1 = dict(seen)
            argv2 = ["collect", "--base", "http://x", "--token-file", os.path.join(d, "tok"),
                     "--out", d, "--seed-ts-unreadable", "seed ts unreadable (box command rc=255)"]
            try:
                cr.main(argv2)
            except RuntimeError:
                pass
    finally:
        cr.collect = real
    return ("unparseable" in (seen1.get("seed_problem") or "") and seen1.get("seed_ts") is None
            and "unreadable" in (seen.get("seed_problem") or "")), (seen1, seen)


@case("wiring (static; collect needs a browser): seed time flows seed -> probe -> main -> collect -> wait")
def _():
    root = os.path.dirname(HERE)
    rd = lambda *p: open(os.path.join(root, *p)).read()
    cr_src = rd("scripts", "box_walk_probes", "lib", "customer_read.py")
    got = (".walk-contact-cards-seed-ts" in rd("scripts", "box_walk_probes", "lib", "contact_cards_seed.sh"),
           ".walk-contact-cards-seed-ts" in rd("scripts", "box_walk_probes", "probes", "hub_screens_customer_read.sh")
           and "--seed-ts-file" in rd("scripts", "box_walk_probes", "probes", "hub_screens_customer_read.sh"),
           'a.get("--seed-ts-file")' in cr_src and "seed_ts=seed_ts" in cr_src,
           "wait_for_fresh_diff(_fetch, seed_ts)" in cr_src,
           "--seed-ts-unreadable" in rd("scripts", "box_walk_probes", "probes", "hub_screens_customer_read.sh")
           and 'a.get("--seed-ts-unreadable")' in cr_src)
    return all(got), got


def main():
    bad = 0
    for label, fn in CASES:
        try:
            ok, got = fn()
        except Exception as exc:  # a missing function on main is a FAIL, not a crash
            ok, got = False, "{}: {}".format(type(exc).__name__, exc)
        bad += not ok
        print("%s  %s%s" % ("ok  " if ok else "FAIL", label, "" if ok else "  (got %r)" % (got,)))
    print("%d case(s), %d failed" % (len(CASES), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
