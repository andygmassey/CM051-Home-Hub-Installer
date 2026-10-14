"""v1.0.108 catch-up: every Google Takeout part and every mailbox, read to the
first message, with no thread sent twice.

The install reads ONE mailbox (install.sh 9.4 keeps the first takeout-*.zip
`find` returns and extracts the first .mbox member of it) and reads that one
through universal_import._dispatch_mbox, which stops at five years, 250,000
messages and 20,000 threads. This file proves, on a synthetic multi-part
Takeout larger than every one of those caps, that:

  * the shipped install path reaches N of M threads (printed: the RED);
  * install + catch-up reaches every thread and every correspondent, and the
    messages across all bundles add up to exactly the mailbox (none twice,
    none lost), with the install's partly-sent threads finished by ONE
    continuation each;
  * a SIGKILL during the index phase and during dispatch, then a restart,
    sends no thread twice and loses none;
  * bounded cost: messages indexed per second, threads per tick, measured.

FIXTURE GENERATION (synthetic only, generated at test time, never committed):
  part 001  Takeout/Chrome/History.json only (no mailbox)
  part 002  Takeout/Mail/All mail Including Spam and Trash.mbox
            262,000 messages, 21,600 threads, spanning 7.5 years:
              1,000 threads / 7,000 messages older than 5.3 years
              20,600 threads / 255,000 messages in the last 4.9 years
  part 003  Takeout/Mail/Archive.mbox, 320 messages in 40 threads
Display names are the approved cast only; every address is @example.com.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import random
import re
import signal
import subprocess
import sys
import time
import zipfile
from collections import Counter
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib"
VENDOR = REPO / "vendor"
INSTALL = REPO / "install.sh"

FIRST = ["Jane", "John", "Bob", "Alex", "Mary", "Raj", "Sam", "Ana", "Ben", "Tom"]
LAST = ["Smith", "Jones", "Doe", "Patel"]
NOW = datetime.now(timezone.utc).replace(microsecond=0)
YEAR = 365.25 * 86400

OLD_THREADS, OLD_PER = 1_000, 7
RECENT_THREADS, RECENT_MSGS = 20_600, 255_000
ARCH_THREADS, ARCH_PER = 40, 8
BIG_TOTAL = OLD_THREADS * OLD_PER + RECENT_MSGS
BIG_THREADS = OLD_THREADS + RECENT_THREADS


def _name(k):
    return f"{FIRST[k % len(FIRST)]} {LAST[(k // len(FIRST)) % len(LAST)]}"


def _write_mbox(path: Path, rows):
    """rows: (epoch, tid, i, subject_root, sender_addr, sender_k). Written in
    date order (Gmail's own order), each Date strictly later than the last."""
    rows.sort(key=lambda r: (r[0], r[1], r[2]))
    prev = 0
    with open(path, "wb") as fh:
        for epoch, tid, i, root, addr, k in rows:
            epoch = max(int(epoch), prev + 1)
            prev = epoch
            dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
            subj = root if i == 0 else "Re: " + root
            mid = f"t{tid}.m{i}@{root.split()[0].lower()}.example.com"
            hdr = [
                f"From {addr} {dt.strftime('%a %b %d %H:%M:%S %Y')}",
                f"Message-ID: <{mid}>",
            ]
            if i > 0:
                parent = f"t{tid}.m{i - 1}@{root.split()[0].lower()}.example.com"
                hdr += [f"In-Reply-To: <{parent}>", f"References: <{parent}>"]
            hdr += [
                f"From: {_name(k)} <{addr}>",
                "To: Owner <owner@example.com>",
                f"Subject: {subj}",
                f"Date: {format_datetime(dt)}",
                "X-Gmail-Labels: Inbox",
                "",
                f"note {i} for thread {tid}",
                "",
            ]
            fh.write(("\n".join(hdr) + "\n").encode())


def _big_rows():
    rng = random.Random(1015)
    rows = []
    # old threads: 7.5 y .. 5.3 y ago, senders old0000..old0199 (35 messages each)
    for t in range(OLD_THREADS):
        start = NOW.timestamp() - rng.uniform(5.35 * YEAR, 7.5 * YEAR)
        k = t % 200
        for i in range(OLD_PER):
            rows.append((start + i * 3600, t, i, f"Topic {t:05d}", f"old{k:04d}@example.com", k))
    # recent threads: 4.9 y .. 20 days ago, senders pal0000..pal0999
    per = [RECENT_MSGS // RECENT_THREADS] * RECENT_THREADS
    for j in range(RECENT_MSGS - sum(per)):
        per[j] += 1
    for j in range(RECENT_THREADS):
        t = OLD_THREADS + j
        start = NOW.timestamp() - rng.uniform(20 * 86400 + 30 * 86400, 4.9 * YEAR)
        k = j % 1000
        for i in range(per[j]):
            rows.append((start + i * 1800, t, i, f"Topic {t:05d}", f"pal{k:04d}@example.com", k))
    return rows


def _arch_rows():
    rows = []
    for t in range(ARCH_THREADS):
        start = NOW.timestamp() - (6 * YEAR) + t * 86400 * 30
        for i in range(ARCH_PER):
            rows.append((start + i * 600, t, i, f"Archive note {t:03d}", f"arch{t % 10:02d}@example.com", t))
    return rows


def _expected_keys(n_threads, fmt):
    return {hashlib.sha1(fmt.format(t).lower().encode()).hexdigest()[:12] for t in range(n_threads)}


@pytest.fixture(scope="module")
def takeout(tmp_path_factory):
    root = tmp_path_factory.mktemp("takeout")
    gen = root / "gen"
    gen.mkdir()
    t0 = time.perf_counter()
    big, arch = gen / "big.mbox", gen / "arch.mbox"
    _write_mbox(big, _big_rows())
    _write_mbox(arch, _arch_rows())
    dl = root / "user" / "Downloads"
    dl.mkdir(parents=True)
    stamp = "takeout-20261001T000000Z"
    with zipfile.ZipFile(dl / f"{stamp}-1-001.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("Takeout/Chrome/History.json", "{}")
    with zipfile.ZipFile(dl / f"{stamp}-1-002.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.write(big, "Takeout/Mail/All mail Including Spam and Trash.mbox")
    with zipfile.ZipFile(dl / f"{stamp}-1-003.zip", "w", zipfile.ZIP_DEFLATED) as z:
        z.write(arch, "Takeout/Mail/Archive.mbox")
    print(f"\n[fixture] generated {BIG_TOTAL + ARCH_THREADS * ARCH_PER} messages in 3 parts "
          f"in {time.perf_counter() - t0:.1f}s")
    return {"root": root, "user": root / "user", "downloads": dl, "big": big, "arch": arch}


def _load_modules(monkeypatch, home: Path):
    monkeypatch.setenv("OSTLER_HOME", str(home))
    monkeypatch.delenv("OSTLER_DIR", raising=False)
    monkeypatch.delenv("OSTLER_CATCHUP_STATE_DIR", raising=False)
    monkeypatch.setenv("OSTLER_PROCESSING_DIR", str(home / "processing"))
    monkeypatch.delenv("OSTLER_USER_EMAIL", raising=False)
    for p in (str(LIB), str(VENDOR)):
        if p not in sys.path:
            sys.path.insert(0, p)
    for m in [m for m in sys.modules if m.startswith("ostler_fda") or m == "ostler_catchup"]:
        del sys.modules[m]
    try:
        import ostler_catchup as oc
    except ImportError:
        oc = None     # origin/main: no catch-up core; the install path still runs
    import ostler_fda.universal_import as ui
    return oc, ui


class Sinks:
    """Keyed fakes for the two sinks the install path drives: CM048 (one
    state dir per conversation id; the first raw transcript is kept for ever)
    and the people graph (one person per address, count >= 3 as
    ingest_mail_contacts requires)."""

    def __init__(self, home: Path):
        self.proc = home / "processing"
        self.proc.mkdir(parents=True, exist_ok=True)
        self.calls = Counter()
        self.bundles = {}
        self.people = set()

    def persist_conversations(self, payloads, *, source):
        n = 0
        for p in payloads:
            cid = p["conversation_id"]
            self.calls[cid] += 1
            d = self.proc / cid
            if not d.exists():
                d.mkdir()
                (d / "00_metadata.json").write_text(json.dumps(p["metadata"]))
                self.bundles[cid] = p["metadata"]["message_count"]
            n += 1
        return {"persist_status": "ok", "persisted": n, "persist_failed": 0}

    def persist_contacts(self, contacts, *, source):
        self.people |= {a for a, c in contacts.items() if c >= 3}
        return {"persist_status": "ok", "people_created": 0}


def _base_hash(cid):
    return cid.rsplit("_", 1)[-1]


def _install_extracts(takeout, home):
    """install.sh 9.4, the shipped text: the first takeout-*.zip `find`
    returns, then the first .mbox member of it."""
    src = INSTALL.read_text(encoding="utf-8")
    m = re.search(r'(EXTRACTED_MBOX=\$\(python3 -c ".*?" 2>/dev/null\) \|\| EXTRACTED_MBOX="")', src, re.S)
    assert m, "install.sh 9.4's extraction snippet was not found"
    find = subprocess.run(["find", str(takeout["downloads"]), "-maxdepth", "2", "-name", "takeout-*.zip"],
                          capture_output=True, text=True).stdout.split("\n")
    first = next(l for l in find if l)
    dest = home / "imports" / "takeout"
    dest.mkdir(parents=True, exist_ok=True)
    script = f'TAKEOUT_ZIP_PATH="{first}"; TAKEOUT_EXTRACT_DIR="{dest}"\n{m.group(1)}\nprintf "%s" "$EXTRACTED_MBOX"'
    out = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True).stdout.strip()
    return Path(first).name, (Path(out) if out else None)


def test_install_plus_catchup_reads_every_thread_once(takeout, tmp_path, monkeypatch):
    home = tmp_path / "home"
    oc, ui = _load_modules(monkeypatch, home)
    sinks = Sinks(home)
    monkeypatch.setattr(ui, "_persist_conversations", sinks.persist_conversations)
    monkeypatch.setattr(ui, "_persist_mail_contacts", sinks.persist_contacts)
    monkeypatch.setenv("OSTLER_TAKEOUT_HOME", str(takeout["user"]))

    # ── the shipped install path ──
    first_zip, extracted = _install_extracts(takeout, home)
    install_mailboxes = 1 if extracted else 0
    # Even when 9.4 found the right part, the import of that mailbox is
    # capped. Drive universal_import exactly as ostler-import does, on the big
    # mailbox, so the caps are measured rather than assumed.
    loose = home / "imports" / "takeout" / "loose" / "All mail.mbox"
    loose.parent.mkdir(parents=True, exist_ok=True)
    loose.write_bytes(takeout["big"].read_bytes())
    t0 = time.perf_counter()
    ui._dispatch_mbox(ui.Detection("mbox", 1.0, "fixture", route_path=loose), output_dir=tmp_path / "fda")
    install_s = time.perf_counter() - t0
    install_keys = {_base_hash(c) for c in sinks.bundles}
    big_keys = _expected_keys(BIG_THREADS, "topic {:05d}")
    arch_keys = _expected_keys(ARCH_THREADS, "archive note {:03d}")
    all_keys = big_keys | arch_keys
    print(f"\n[install] 9.4 picked {first_zip}; mailboxes extracted: {install_mailboxes} of 2; "
          f"capped import reached {len(install_keys & all_keys)} of {len(all_keys)} threads, "
          f"{sum(sinks.bundles.values())} of {BIG_TOTAL + ARCH_THREADS * ARCH_PER} messages "
          f"({install_s:.0f}s)")
    assert install_mailboxes <= 1
    assert len(install_keys) < len(all_keys)

    # ── catch-up ──
    try:
        assert oc is not None
        from ostler_fda import catchup_mbox
    except (ImportError, AssertionError):
        pytest.fail(f"no catch-up for mailboxes: the install's {len(install_keys & all_keys)} of "
                    f"{len(all_keys)} threads is all there will ever be")
    adapters = catchup_mbox.adapters()
    assert len(adapters) == 2, f"expected the big mailbox and the archive once each, got {len(adapters)}"
    ticks, per_tick, t0 = 0, [], time.perf_counter()
    while True:
        before = len(sinks.calls)
        s = oc.run(adapters, budget_seconds=1e9, busy=lambda: None)
        ticks += 1
        per_tick.append(len(sinks.calls) - before)
        if all(v["complete"] for v in s["sources"].values()) or ticks > 5:
            break
    catchup_s = time.perf_counter() - t0

    keys = Counter()
    for cid in sinks.bundles:
        keys[_base_hash(cid)] += 1
    reached = {k for k in keys} & all_keys
    assert reached == all_keys, f"{len(all_keys - reached)} threads never reached the conversation sink"
    assert all(c == 1 for c in sinks.calls.values()), "a conversation id was sent twice"
    total_msgs = sum(sinks.bundles.values())
    want_msgs = BIG_TOTAL + ARCH_THREADS * ARCH_PER
    assert total_msgs == want_msgs, (
        f"bundles hold {total_msgs} messages, the mailboxes {want_msgs}: "
        f"{'duplicated' if total_msgs > want_msgs else 'lost'} {abs(total_msgs - want_msgs)}")
    continuations = len(sinks.bundles) - len(all_keys)
    expected_people = {f"old{k:04d}@example.com" for k in range(200)} | \
                      {f"pal{k:04d}@example.com" for k in range(1000)} | \
                      {f"arch{k:02d}@example.com" for k in range(10)}
    assert expected_people <= sinks.people, f"{len(expected_people - sinks.people)} correspondents missing"
    wm = json.loads((home / "state" / "catchup" / f"{adapters[0].source}.json").read_text())
    print(f"[catch-up] {len(reached)} of {len(all_keys)} threads, {total_msgs} of {want_msgs} messages, "
          f"{continuations} continuation bundle(s) for threads the install cut short, "
          f"{len(sinks.people)} correspondents; {ticks} unbounded tick(s) in {catchup_s:.0f}s; "
          f"back to {wm['oldest_at']}")


def test_bounded_cost_measured(takeout, tmp_path, monkeypatch):
    """Messages indexed per second, and threads per tick at a fixed per-thread
    cost, on the big mailbox."""
    home = tmp_path / "home"
    oc, ui = _load_modules(monkeypatch, home)
    sinks = Sinks(home)
    monkeypatch.setattr(ui, "_persist_conversations", sinks.persist_conversations)
    monkeypatch.setattr(ui, "_persist_mail_contacts", sinks.persist_contacts)
    from ostler_fda import catchup_mbox
    a = catchup_mbox.MailboxAdapter(takeout["big"], catchup_mbox.mailbox_identity(takeout["big"]))
    # index only: stop once the cursor leaves the index phase
    t0 = time.perf_counter()
    while True:
        cur = a.start_cursor() if not (home / "state" / "catchup" / f"{a.source}.json").exists() else \
            json.loads((home / "state" / "catchup" / f"{a.source}.json").read_text()).get("cursor", a.start_cursor())
        if cur.get("phase") != "index":
            break
        b = a.next_batch(cur, a.batch_size)
        for it in b.items:
            a.process(it)
        w = oc.Watermark.load(a.source)
        w.cursor = b.next_cursor
        w.save()
    idx_s = time.perf_counter() - t0
    rate = BIG_TOTAL / idx_s
    # dispatch at a modelled 100 s per thread (the on-box CM048 figure in
    # imessage_source/pipeline.py, v1018-D021) on the default 1800 s budget
    clock = {"t": 0.0}
    real = ui._persist_conversations

    def costly(payloads, *, source):
        clock["t"] += 100.0
        return real(payloads, source=source)
    monkeypatch.setattr(ui, "_persist_conversations", costly)
    before = len(sinks.calls)
    oc.run([a], budget_seconds=1800, clock=lambda: clock["t"], busy=lambda: None)
    per_tick = len(sinks.calls) - before
    print(f"\n[bounded cost] index {BIG_TOTAL} messages in {idx_s:.1f}s = {rate:,.0f} msg/s; "
          f"{per_tick} threads per 1800 s tick at 100 s per thread; "
          f"at 6 ticks a day {BIG_THREADS} threads take {BIG_THREADS / (per_tick * 6):.0f} days")
    assert per_tick <= 18
    assert rate > 1000


# ── kill tests: a real CLI process, SIGKILLed ────────────────────────────────

_SHIM = '''
import json, os
from pathlib import Path
import ostler_fda.universal_import as ui
from ostler_fda import catchup_mbox
PEOPLE = Path(os.environ["FX_PEOPLE"])
def _contacts(contacts, *, source):
    PEOPLE.mkdir(parents=True, exist_ok=True)
    for a, c in contacts.items():
        if c >= 3:
            (PEOPLE / a).write_text(str(c))
    return {"persist_status": "ok", "people_created": 0}
ui._persist_mail_contacts = _contacts
def adapters():
    return catchup_mbox.adapters()
'''

_FAKE_CONVO = r'''#!/usr/bin/env python3
import json, os, signal, sys
from pathlib import Path
meta = json.loads(Path(sys.argv[3]).read_text())
cid = meta["conversation_id"]
proc = Path(os.environ["OSTLER_PROCESSING_DIR"]) / cid
if not proc.exists():
    proc.mkdir(parents=True)
    (proc / "00_metadata.json").write_text(json.dumps(meta))
log = Path(os.environ["FX_LOG"])
with open(log, "a") as fh:
    fh.write(cid + "\n")
n = sum(1 for _ in open(log))
if n == int(os.environ.get("FX_KILL_PARENT_AT", "-1")):
    os.kill(os.getppid(), signal.SIGKILL)   # sink has it, ledger does not
'''


def _kill_env(tmp_path, takeout_home):
    shim = tmp_path / "shim"
    shim.mkdir(exist_ok=True)
    (shim / "takeout_shim.py").write_text(_SHIM)
    fake = tmp_path / "pwg-convo"
    fake.write_text(_FAKE_CONVO)
    fake.chmod(0o755)
    home = tmp_path / "home"
    env = dict(os.environ)
    env.pop("OSTLER_DIR", None)
    env.update({
        "PYTHONPATH": os.pathsep.join([str(LIB), str(VENDOR), str(shim)]),
        "OSTLER_HOME": str(home), "OSTLER_PROCESSING_DIR": str(home / "processing"),
        "OSTLER_PWG_CONVO_CMD": str(fake), "FX_LOG": str(tmp_path / "convo.log"),
        "FX_PEOPLE": str(tmp_path / "people"), "OSTLER_TAKEOUT_HOME": str(takeout_home),
        "OSTLER_CATCHUP_MAX_LOAD_PER_CORE": "1000", "OSTLER_INTERACTIVE_TTL_SECS": "0",
        # 100 messages per index slice, 2,500 per batch: the index phase
        # spans a dozen watermark writes, so a random kill can land inside it.
        "OSTLER_CATCHUP_MBOX_SLICE": "100",
    })
    return env, home


def _cli(env, timeout=None):
    return subprocess.Popen(
        [sys.executable, "-m", "ostler_catchup", "run", "--family", "takeout",
         "--adapters", "takeout_shim:adapters", "--budget-seconds", "100000"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def _small_takeout(tmp_path):
    user = tmp_path / "user"
    dl = user / "Downloads"
    dl.mkdir(parents=True)
    rows = []
    rng = random.Random(7)
    for t in range(1500):
        start = NOW.timestamp() - rng.uniform(30 * 86400, 9 * YEAR)
        for i in range(20):
            rows.append((start + i * 900, t, i, f"Topic {t:05d}", f"pal{t % 300:04d}@example.com", t))
    mbox = tmp_path / "small.mbox"
    _write_mbox(mbox, rows)
    with zipfile.ZipFile(dl / "takeout-20261002T000000Z-1-002.zip", "w") as z:
        z.write(mbox, "Takeout/Mail/All mail Including Spam and Trash.mbox")
    return user, 1500, 30_000


def _phase(home):
    for f in (home / "state" / "catchup").glob("mbox_*.json"):
        return (json.loads(f.read_text()).get("cursor") or {}).get("phase", "start")
    return "start"


def test_sigkill_in_index_and_dispatch_never_duplicates_or_loses(tmp_path):
    user, n_threads, n_msgs = _small_takeout(tmp_path)
    env, home = _kill_env(tmp_path, user)
    rng = random.Random(20261015)
    kills, phases = 0, Counter()
    # 1. random external kills, mostly landing in the index phase
    for _ in range(40):
        p = _cli(env)
        try:
            p.wait(timeout=rng.uniform(0.25, 1.5))
        except subprocess.TimeoutExpired:
            phases[_phase(home)] += 1
            p.send_signal(signal.SIGKILL)
            p.wait()
            kills += 1
        if _phase(home) == "threads":
            break
    # 2. the worst moment in dispatch: the sink has the thread, the ledger not
    for at in (25, 140):
        env2 = dict(env, FX_KILL_PARENT_AT=str(at))
        p = _cli(env2)
        p.wait(timeout=600)
        if p.returncode == -signal.SIGKILL:
            kills += 1
            phases["threads"] += 1
    # 3. finish
    for _ in range(20):
        p = _cli(env)
        p.wait(timeout=900)
        assert p.returncode == 0, p.stderr.read()[-800:]
        st = next((home / "state" / "catchup").glob("mbox_*.json"))
        if json.loads(st.read_text()).get("complete"):
            break
    log = Counter((tmp_path / "convo.log").read_text().split())
    dirs = [d.name for d in (home / "processing").iterdir()]
    per_key = Counter(_base_hash(d) for d in dirs)
    want = _expected_keys(n_threads, "topic {:05d}")
    assert set(per_key) == want, f"{len(want - set(per_key))} threads lost after {kills} kills"
    assert all(c == 1 for c in per_key.values()), "a thread holds two bundles"
    repeats = sum(c - 1 for c in log.values())
    assert repeats <= kills, f"{repeats} repeated sends from {kills} kills"
    people = {p.name for p in (tmp_path / "people").iterdir()}
    assert people == {f"pal{k:04d}@example.com" for k in range(300)}
    assert phases.get("index", 0) >= 1, f"no kill landed in the index phase: {phases}"
    assert phases.get("threads", 0) >= 1, f"no kill landed in dispatch: {phases}"
    print(f"\n[kill] kills={kills} by phase {dict(phases)}; threads {len(per_key)}/{n_threads}, "
          f"each one bundle; repeated keyed sends={repeats}")


def test_discovery_finds_every_part_once_and_does_not_re_extract(takeout, tmp_path, monkeypatch):
    home = tmp_path / "home"
    _load_modules(monkeypatch, home)
    monkeypatch.setenv("OSTLER_TAKEOUT_HOME", str(takeout["user"]))
    from ostler_fda import catchup_mbox
    parts = catchup_mbox.find_takeout_parts()
    assert [p.name.rsplit("-", 1)[-1] for p in parts] == ["001.zip", "002.zip", "003.zip"]
    a1 = catchup_mbox.adapters()
    assert len(a1) == 2
    mt = {p: p.stat().st_mtime_ns for p in (home / "imports" / "takeout").rglob("*.mbox")}
    # the same mailbox also queued by the importer at another path: still one walk
    copy = home / "imports" / "takeout" / "elsewhere" / "copy.mbox"
    copy.parent.mkdir(parents=True)
    copy.write_bytes(takeout["arch"].read_bytes())
    catchup_mbox.queue_mailbox(copy)
    a2 = catchup_mbox.adapters()
    assert sorted(a.source for a in a1) == sorted(a.source for a in a2)
    assert all(p.stat().st_mtime_ns == m for p, m in mt.items()), "a mailbox was extracted twice"
    # CONTROL: a declined Takeout on the Desktop is not read
    desk = takeout["user"] / "Desktop"
    desk.mkdir(exist_ok=True)
    assert all("Desktop" not in str(p) for p in catchup_mbox.find_takeout_parts())


def test_the_install_caps_are_unchanged():
    src = (VENDOR / "ostler_fda" / "universal_import.py").read_text(encoding="utf-8")
    assert "_MBOX_MESSAGE_CAP = 250_000" in src
    assert "_EMAIL_MAX_THREADS = 20_000" in src
    assert src.count("since_days=365 * 5") >= 2
    assert "_EMAIL_BODY_CHARS_DEFAULT = 4000" in src


def test_a_thread_the_install_cut_short_is_finished_by_one_continuation(tmp_path, monkeypatch):
    """A thread that began 5.4 years ago and is still going: the install's
    five-year window sends only its recent half. Catch-up sends the older
    half as ONE continuation bundle, and no message lands twice."""
    home = tmp_path / "home"
    oc, ui = _load_modules(monkeypatch, home)
    sinks = Sinks(home)
    monkeypatch.setattr(ui, "_persist_conversations", sinks.persist_conversations)
    monkeypatch.setattr(ui, "_persist_mail_contacts", sinks.persist_contacts)
    start = NOW.timestamp() - 5.4 * YEAR
    rows = [(start + i * (0.2 * YEAR), 1, i, "Topic 00001", "pal0001@example.com", 1) for i in range(10)]
    rows += [(NOW.timestamp() - 86400 * 40 + i * 60, 2, i, "Topic 00002", "pal0002@example.com", 2)
             for i in range(5)]
    mbox = home / "imports" / "takeout" / "loose" / "one.mbox"
    mbox.parent.mkdir(parents=True)
    _write_mbox(mbox, rows)
    ui._dispatch_mbox(ui.Detection("mbox", 1.0, "fixture", route_path=mbox), output_dir=tmp_path / "fda")
    sent_install = dict(sinks.bundles)
    assert sum(sent_install.values()) < 15, "the fixture did not straddle the install's window"
    from ostler_fda import catchup_mbox
    s = oc.run(catchup_mbox.adapters(), budget_seconds=1e9, busy=lambda: None)
    assert all(v["complete"] for v in s["sources"].values())
    assert sum(sinks.bundles.values()) == 15, f"bundles hold {sum(sinks.bundles.values())} of 15 messages"
    assert len(sinks.bundles) == 3, sinks.bundles     # two threads + one continuation
    assert all(c == 1 for c in sinks.calls.values())
    print(f"\n[continuation] install sent {sum(sent_install.values())} of 15 messages; "
          f"catch-up added {sum(sinks.bundles.values()) - sum(sent_install.values())} in "
          f"{len(sinks.bundles) - len(sent_install)} continuation bundle(s)")
