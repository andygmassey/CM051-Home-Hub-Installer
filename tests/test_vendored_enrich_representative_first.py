#!/usr/bin/env python3
"""Representative-first enrichment, on the SHIPPED vendored tree.

Enriching one representative per rollup group (artist, album, series,
restaurant), biggest group first, is what multiplies Smart Preferences coverage:
on a measured walk box 402 of 117,730 points were enriched and the rollup
readers apply one item's genre to its whole group. Synthetic values only.

  arm 1  ordering: biggest group first, one representative per group, the
         strongest member, a tagged group is skipped, a track serving its
         artist's and its album's group is one lookup.
  arm 2  consent NO (every wrong spelling): zero urlopen calls with the real
         default gateway and the real gate; CONTROL: YES does reach urlopen.
  arm 3  resumable: killed after one chunk then re-run = one lookup per group
         in total; a finished corpus does no work; status file is counts only.
  arm 4  misses: a deterministic miss is ledgered and the next member tried;
         an errored chunk is not a verdict.
  arm 5  MUTANTS: ordering inverted, consent removed, covered-check removed
         each turn an arm red.
  arm 6  `enrich --all` as the agent runs it (answer only in config/.env) runs
         the representative pass BEFORE the tail; --no-representative-first
         skips it.

Exit: 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import tempfile
import types
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENRICH = REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
KEY = "OSTLER_CONSENT_ENRICHMENT_DECISION"
for var in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
    os.environ.pop(var, None)
os.environ.pop(KEY, None)

sys.path[:0] = [str(ENRICH), str(REPO / "vendor" / "cm019_preferences" / "services" / "common")]
try:
    from click.testing import CliRunner
    from src import cli as cli_module
    from src.derive.model import PREF_URN_PREFIX
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: vendored enrich tree does not import: {exc!r}")
    sys.exit(2)
try:
    from src.derive import representatives as R
except ImportError as exc:
    # The tree imports; the module is what is missing. A real failure, not a cannot-run.
    print(f"FAIL  the vendored tree has no derive/representatives.py: {exc!r}")
    sys.exit(1)

FAILS = []
TMP = Path(tempfile.mkdtemp(prefix="cm051-repfirst-"))
os.environ["OSTLER_DIR"] = str(TMP / "ostler")
(TMP / "ostler" / "config").mkdir(parents=True)
ENVFILE = TMP / "ostler" / "config" / ".env"


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{(' -- ' + detail) if detail and not ok else ''}")
    if not ok:
        FAILS.append(name)


def answer(value):
    if value is None:
        ENVFILE.unlink(missing_ok=True)
    else:
        ENVFILE.write_text(f"{KEY}={value}\n")


class Store:
    def __init__(self):
        self.points, self.tags, self.enriched = [], {}, set()

    def point(self, pid, cat, subject, strength=0.5, **extra):
        self.points.append({"id": pid, "payload": {
            "category": cat, "subject": subject, "source": "synthetic",
            "strength": strength, "observed_at": "2026-09-01T00:00:00Z", "extra": extra}})

    def scroll(self, categories, fields):
        return [p for p in self.points if not categories or p["payload"]["category"] in categories]

    def sparql(self, q):
        if "enrichedAt" in q and "hasGenre" not in q:
            return [{"p": {"value": PREF_URN_PREFIX + i}} for i in sorted(self.enriched)]
        pred = re.search(r"enrichment/ontology#(\w+)>", q).group(1)
        if "entityType" in q:
            return []
        return [{"s": {"value": PREF_URN_PREFIX + pid}, "label": {"value": lab},
                 "conf": {"value": "0.9"}} for pid, lab in self.tags.get(pred, [])]


class Stats:
    failed = 0


class Result:
    def __init__(self, pid):
        self.preference_id = pid


class Service:
    CATEGORY_CLIENTS = {"music": "musicbrainz", "tv_show": "wikidata_film", "food": "wikidata"}

    def __init__(self, store, miss=(), fail_after_chunks=None, error_ids=()):
        self.store, self.miss, self.lookups = store, set(miss), []
        self.fail_after_chunks, self.chunks, self.error_ids = fail_after_chunks, 0, set(error_ids)

    async def enrich_batch(self, prefs, stats):
        if self.fail_after_chunks is not None and self.chunks >= self.fail_after_chunks:
            raise RuntimeError("killed")
        self.chunks += 1
        out = []
        for p in prefs:
            self.lookups.append(p["id"])
            if p["id"] in self.error_ids:
                stats.failed += 1
            elif p["id"] not in self.miss:
                self.store.tags.setdefault("hasGenre", []).append((p["id"], "rock"))
                self.store.enriched.add(p["id"])
                out.append(Result(p["id"]))
        return out


def scenario():
    s = Store()
    for i in range(5):
        s.point(f"big{i}", "music", f"s{i}", strength=0.1 + i / 10, artist="Big Artist")
    for i in range(3):
        s.point(f"mid{i}", "music", f"t{i}", strength=0.5, artist="Mid Artist")
    for i in range(2):
        s.point(f"tv{i}", "tv_show", f"Some Series - ep {i}", strength=0.5)
    s.point("lone", "music", "x", artist="Lonely")
    for i in range(4):
        s.point(f"done{i}", "music", f"d{i}", artist="Done Artist")
    s.tags["hasGenre"] = [("done0", "jazz")]
    s.enriched.add("done0")
    return s


def plan_of(mod, s):
    rows = mod.rollup_rows(s)
    tagged = [set(r.tags._overlay_tags()) for r in rows]
    return mod.plan_representatives(s.scroll(None, []), rows, tagged, set(s.enriched), {}, set(),
                                    lambda c: c in Service.CATEGORY_CLIENTS)


def run(coro):
    return asyncio.run(coro)


yes = lambda: True  # noqa: E731

# ---------------------------------------------------------------- arm 1
ids = [r["id"] for r in plan_of(R, scenario()).reps]
check("arm1 biggest group first, its strongest member", ids[:1] == ["big4"], str(ids))
check("arm1 then the group of 3, then the series",
      len(ids) == 3 and ids[1].startswith("mid") and ids[2].startswith("tv"), str(ids))
check("arm1 a tagged group and a group of one are owed nothing",
      not any(i.startswith("done") or i == "lone" for i in ids))
two = Store()
for i in range(3):
    two.point(f"a{i}", "music", f"t{i}", strength=0.9 - i / 10, artist="Art", album="Alb")
check("arm1 a track in an artist group AND an album group is ONE lookup",
      [r["id"] for r in plan_of(R, two).reps] == ["a0"])

# ---------------------------------------------------------------- arm 2
real_urlopen = urllib.request.urlopen
calls = []


def boom(*a, **k):
    calls.append(a)
    raise OSError("blocked by test")


urllib.request.urlopen = boom
try:
    for value in ("declined", "", "Accepted", "garbage", None):
        answer(value)
        calls.clear()
        svc = Service(scenario())
        st = run(R.run_representative_pass(svc, state_dir=TMP / "state-no"))
        check(f"arm2 answer {value!r}: zero network calls, no lookup",
              calls == [] and svc.lookups == [] and st.state == "consent_declined",
              f"calls={len(calls)} lookups={svc.lookups} state={st.state}")
    answer("accepted")
    calls.clear()
    st = run(R.run_representative_pass(Service(scenario()), state_dir=TMP / "state-yes"))
    check("arm2 CONTROL: with a recorded yes the same call reaches urlopen",
          len(calls) > 0 and st.state == "stores_unreadable", f"calls={len(calls)} state={st.state}")
finally:
    urllib.request.urlopen = real_urlopen

# ---------------------------------------------------------------- arm 3
s = scenario()
svc = Service(s, fail_after_chunks=1)
sd = TMP / "state-resume"
r1 = run(R.run_representative_pass(svc, gateway=s, consent=yes, batch_size=1, state_dir=sd))
check("arm3 killed after one chunk: one lookup done", svc.lookups == ["big4"] and r1.reps_errored >= 1,
      str(svc.lookups))
svc.fail_after_chunks = None
run(R.run_representative_pass(svc, gateway=s, consent=yes, batch_size=1, state_dir=sd))
check("arm3 re-run finishes: exactly one lookup per group, none twice",
      len(svc.lookups) == len(set(svc.lookups)) == 3, str(svc.lookups))
n = len(svc.lookups)
run(R.run_representative_pass(svc, gateway=s, consent=yes, state_dir=sd))
check("arm3 a finished corpus does no work", len(svc.lookups) == n)
raw = (sd / R.STATUS_NAME).read_text()
leaks = [w for w in ("Big Artist", "Mid Artist", "Some Series", "big4") if w in raw]
check("arm3 status file is counts only and 0600",
      not leaks and oct((sd / R.STATUS_NAME).stat().st_mode & 0o777) == "0o600", str(leaks))

# ---------------------------------------------------------------- arm 4
s = scenario()
svc = Service(s, miss={"big4"})
sd = TMP / "state-miss"
run(R.run_representative_pass(svc, gateway=s, consent=yes, state_dir=sd))
big = [i for i in svc.lookups if i.startswith("big")]
check("arm4 a miss moves on to the NEXT member in the same run",
      len(big) == 2 and big[0] == "big4" and big[1] != "big4", str(big))
svc2 = Service(s, miss={"big4"})
run(R.run_representative_pass(svc2, gateway=s, consent=yes, state_dir=sd))
check("arm4 a later run never retries the member that missed", "big4" not in svc2.lookups)
s = scenario()
svc = Service(s, error_ids={"big4"})
sd = TMP / "state-err"
run(R.run_representative_pass(svc, gateway=s, consent=yes, batch_size=1, state_dir=sd))
try:
    ledger = json.loads((sd / R.LEDGER_NAME).read_text())["missed"]
except OSError:
    ledger = {}
check("arm4 an errored chunk is not a verdict (nothing ledgered)", "big4" not in ledger, str(ledger))

# ---------------------------------------------------------------- arm 5
SRCFILE = Path(R.__file__)
TEXT = SRCFILE.read_text()


def mutant(old, new):
    assert old in TEXT, f"mutation did not apply: {old[:50]!r}"
    mod = types.ModuleType("src.derive.representatives_mutant")
    mod.__package__ = "src.derive"
    mod.__file__ = str(SRCFILE)
    sys.modules[mod.__name__] = mod
    exec(compile(TEXT.replace(old, new, 1), "representatives_mutant", "exec"), mod.__dict__)
    return mod


m = mutant("key=lambda g: (-len(groups[g]), -sum(s for s, _, _ in groups[g]), g[0], g[1]),",
           "key=lambda g: (len(groups[g]), sum(s for s, _, _ in groups[g]), g[0], g[1]),")
mids = [r["id"] for r in plan_of(m, scenario()).reps]
check("arm5 MUTANT ordering inverted: arm 1 goes red", mids[:1] != ["big4"], str(mids))
m = mutant("if ids & tagged[gid[0]]:", "if False:")
mids = [r["id"] for r in plan_of(m, scenario()).reps]
check("arm5 MUTANT covered-check removed: a tagged group is wrongly owed a lookup",
      any(i.startswith("done") for i in mids), str(mids))
m = mutant("    if not allowed():\n        stats.state = \"consent_declined\"\n        _write_json(status_path, stats.as_status())\n        return stats\n",
           "    if False:\n        return stats\n")
answer("declined")
urllib.request.urlopen = boom
calls.clear()
try:
    run(m.run_representative_pass(Service(scenario()), state_dir=TMP / "state-mut"))
finally:
    urllib.request.urlopen = real_urlopen
check("arm5 MUTANT consent removed: a declined owner reaches urlopen", len(calls) > 0, f"calls={len(calls)}")

# ---------------------------------------------------------------- arm 6
order_seen = []


class Svc:
    CATEGORY_CLIENTS = {}

    @classmethod
    def enrichable_categories(cls):
        return ["music"]

    @classmethod
    def categories_missing_credentials(cls):
        return {}

    async def enrich_all(self, **k):
        order_seen.append("tail")
        return cli_module.EnrichmentStats()

    async def enrich_categories(self, **k):
        order_seen.append("tail")
        return cli_module.EnrichmentStats()

    def get_client_stats(self):
        return {}

    async def close(self):
        pass


async def fake_pass(service, **k):
    order_seen.append("reps")
    return R.RepStats(state="ran")


cli_module.EnrichmentService = Svc
R.run_representative_pass = fake_pass
answer("accepted")   # the agent's shape: env unset, the answer only in config/.env
res = CliRunner().invoke(cli_module.cli, ["enrich", "--all"])
check("arm6 enrich --all runs the representative pass BEFORE the tail",
      res.exit_code == 0 and order_seen == ["reps", "tail"], f"rc={res.exit_code} {order_seen} {res.output[-200:]}")
order_seen.clear()
res = CliRunner().invoke(cli_module.cli, ["enrich", "--all", "--no-representative-first"])
check("arm6 --no-representative-first skips it",
      res.exit_code == 0 and order_seen == ["tail"], f"rc={res.exit_code} {order_seen}")

print(f"\n{len(FAILS)} FAIL")
sys.exit(1 if FAILS else 0)
