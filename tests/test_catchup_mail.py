"""Full-history catch-up for Apple Mail (v1.0.108): every correspondent, not the top 50.

The install-time correspondent pass (extract_all's apple_mail arm) reads five
years, at most 100,000 messages, and keeps the top 50 senders. This builds a
synthetic Envelope Index that is larger than every one of those caps (125,000+
messages over nine years, 330+ correspondents) and proves:

  * RED on origin/main: the shipped install path alone reaches only a fraction
    of the correspondents who qualify (>= MAIL_CONTACT_MIN_COUNT messages);
  * install + catch-up reaches every one of them, each exactly once, and still
    applies the owner and machine-sender skips;
  * a SIGKILL mid-walk (inside the ingest, and at random from outside) then a
    restart: nobody is created twice and no message is counted twice;
  * the email-ingest body sweep is mirrored into Doctor without a second walk;
  * bounded cost, measured on the fixture.

Synthetic data only: approved cast names on example.com / example.org.
"""
from __future__ import annotations

import importlib
import json
import os
import random
import re
import signal
import sqlite3
import subprocess
import sys
import textwrap
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))
sys.path.insert(0, str(REPO / "lib"))

GIVEN = ["jane", "john", "bob", "alex", "mary", "raj", "sam", "ana", "ben", "tom"]
FAMILY = ["smith", "jones", "doe", "patel"]
DOMAINS = ["example.com", "example.org"]
AT = "@"
OWNER = "jane.doe" + AT + "example.com"
MACHINE = "no-reply" + AT + "shop.example.com"
NOW = datetime.now(timezone.utc)

N_HEAVY = 20          # senders who write most of the mail, every year
N_LIGHT = 310         # occasional correspondents, 3 to 12 messages each
N_RARE = 15           # two messages each: never qualify (negative control)
HEAVY_TOTAL = 122_000
YEARS = 9


def _addr(i: int) -> str:
    g = GIVEN[i % len(GIVEN)]
    f = FAMILY[(i // len(GIVEN)) % len(FAMILY)]
    return f"{g}.{f}.{i:03d}{AT}{DOMAINS[i % 2]}"


def build_envelope(path: Path, seed: int = 7) -> dict:
    """Sequoia-shape Envelope Index. Returns the expected qualifying set."""
    rng = random.Random(seed)
    con = sqlite3.connect(path)
    con.executescript(
        "CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);"
        "CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);"
        "CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);"
        "CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, sender INTEGER,"
        " date_sent INTEGER, date_received INTEGER, read INTEGER, flagged INTEGER,"
        " message_id TEXT, mailbox INTEGER);"
        "CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER);"
        "CREATE INDEX m_dr ON messages(date_received);"
        "INSERT INTO subjects VALUES (1, 'Planning'), (2, 'Dinner'), (3, '');"
        "INSERT INTO mailboxes VALUES (1, 'imap://ACCT/INBOX'), (2, 'imap://ACCT/Sent');"
    )
    ids: dict = {}

    def aid(a):
        if a not in ids:
            ids[a] = len(ids) + 1
            con.execute("INSERT INTO addresses VALUES (?, ?, '')", (ids[a], a))
        return ids[a]

    span = YEARS * 365 * 86400
    rows = []

    def msg(sender, when, subject=1, display=True):
        s = f"{sender.split(AT)[0].replace('.', ' ').title()} <{sender}>" if display else sender
        rows.append((subject, aid(s), when, when, 1, 0, None, 1))

    now = int(NOW.timestamp())
    heavy = [_addr(i) for i in range(N_HEAVY)]
    for k in range(HEAVY_TOTAL):
        msg(heavy[k % N_HEAVY], now - rng.randrange(span))
    light = [_addr(100 + i) for i in range(N_LIGHT)]
    for i, a in enumerate(light):
        # A third of the light correspondents wrote only in years 6 to 9.
        lo = 6 * 365 * 86400 if i % 3 == 0 else 0
        for _ in range(3 + (i % 10)):
            msg(a, now - lo - rng.randrange(span - lo))
    rare = [_addr(700 + i) for i in range(N_RARE)]
    for a in rare:
        for _ in range(2):
            msg(a, now - rng.randrange(span))
    for _ in range(40):
        msg(OWNER, now - rng.randrange(span))          # the owner's own sent mail
        msg(MACHINE, now - rng.randrange(span))        # a machine sender
    msg(_addr(900), now - 10, subject=3)               # subject-less rows are not counted
    msg(_addr(900), now - 20, subject=3)
    msg(_addr(900), now - 30, subject=3)
    rows.sort(key=lambda r: r[2])
    con.executemany(
        "INSERT INTO messages (subject, sender, date_sent, date_received, read, flagged, message_id, mailbox)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?)", rows)
    con.commit()
    total = con.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
    oldest = con.execute("SELECT MIN(date_received) FROM messages").fetchone()[0]
    con.close()
    people = set(heavy) | set(light)
    return {"people": people, "total": total, "oldest": oldest,
            "years": (now - oldest) / (365 * 86400)}


def write_skip_files(fda: Path):
    fda.mkdir(parents=True, exist_ok=True)
    (fda / "owner_addresses.json").write_text(json.dumps({"addresses": {OWNER: "mail"}}))
    (fda / "machine_senders.json").write_text(json.dumps({"machine": {MACHINE: "no-reply"},
                                                          "correspondents": []}))


# A keyed fake people store. Persisted to a log so a separate (killed)
# process and its restart share it: a Person is "found" if any earlier write
# created it, exactly like the identifier lookup ingest_mail_contacts runs.
STORE_PATCH = textwrap.dedent('''
    import re
    from pathlib import Path
    from ostler_fda import pwg_ingest as m

    def install_fake_store(log_path):
        log = Path(log_path)

        def created():
            return set(log.read_text().split()) if log.exists() else set()

        def update(sparql):
            if "a pwg:Person" in sparql:
                for v in re.findall(r'pwg:identifierValue "([^"]+)"', sparql):
                    with open(log, "a") as fh:
                        fh.write(v + "\\n")

        def lookup(value):
            return m._person_uri(m._person_id_from_identifier(value)) if value in created() else None

        m._sparql_update = update
        m._sparql_query = lambda q: []
        m._person_uri_by_identifier_value = lookup
        m._live_person = lambda uri: (uri, False)
        m._is_forgotten = lambda *a, **k: False
        m._upsert_display_name = lambda *a, **k: None
        return log
''')


@pytest.fixture(scope="module")
def envelope(tmp_path_factory):
    d = tmp_path_factory.mktemp("mail")
    info = build_envelope(d / "Envelope Index")
    info["path"] = d / "Envelope Index"
    assert info["total"] > 120_000 and info["years"] > 8
    assert len(info["people"]) > 300
    return info


def _fake_store(tmp_path):
    mod_dir = tmp_path / "fakestore"
    mod_dir.mkdir(exist_ok=True)
    (mod_dir / "fake_mail_store.py").write_text(STORE_PATCH)
    sys.path.insert(0, str(mod_dir))
    fs = importlib.import_module("fake_mail_store")
    return fs.install_fake_store(tmp_path / "creates.log")


def _created(log: Path) -> Counter:
    return Counter(log.read_text().split()) if log.exists() else Counter()


def _install_path(envelope, fda: Path):
    """The shipped install-time arm: extract_all's apple_mail block."""
    from ostler_fda import apple_mail, pwg_ingest
    msgs = apple_mail.extract_messages(db_path=envelope["path"], since_days=1825, limit=100000)
    (fda / "apple_mail_contacts.json").write_text(json.dumps(apple_mail.frequent_contacts(msgs)))
    return pwg_ingest.ingest_mail_contacts(fda)


def test_install_path_alone_misses_most_correspondents_and_catchup_reaches_all(envelope, tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "home"))
    log = _fake_store(tmp_path)
    fda = tmp_path / "fda"
    write_skip_files(fda)
    _install_path(envelope, fda)
    after_install = set(_created(log))
    want = envelope["people"]
    print(f"\n[install path] {len(after_install & want)} of {len(want)} qualifying correspondents "
          f"(5 y, 100,000 messages, top 50) from {envelope['total']} messages over {envelope['years']:.1f} y")

    try:
        from ostler_fda import catchup_mail
    except ImportError:
        pytest.fail(f"no catch-up: the install path reached {len(after_install & want)} of {len(want)} "
                    "qualifying correspondents and nothing ever reads the rest")
    import ostler_catchup as oc

    monkeypatch.setenv("OSTLER_CATCHUP_FDA_DIR", str(fda))
    monkeypatch.setenv("OSTLER_MAIL_ENVELOPE_INDEX", str(envelope["path"]))
    ticks, t0 = 0, time.perf_counter()
    for _ in range(50):
        ticks += 1
        s = oc.run([catchup_mail.MailContacts()], budget_seconds=1e9, busy=lambda: None)
        if s["sources"]["mail_contacts"]["complete"]:
            break
    created = _created(log)
    assert want <= set(created), f"missing {len(want - set(created))} correspondents after catch-up"
    assert all(c == 1 for c in created.values()), \
        f"a Person was created twice: {[a for a, c in created.items() if c > 1][:3]}"
    assert OWNER not in created, "the owner's own address became a Person"
    assert MACHINE not in created, "a machine sender became a Person"
    assert not any(a.startswith("jane.doe.7") for a in created) and \
        not any(_addr(700 + i) in created for i in range(N_RARE)), "a two-message sender qualified"
    assert _addr(900) not in created, "subject-less rows were counted"
    wm = json.loads((oc.state_dir() / "mail_contacts.json").read_text())
    assert wm["complete"] and wm["doctor_row"] == "email"
    assert wm["oldest_at"] == oc.to_iso(envelope["oldest"]), "the walk did not reach the oldest message"
    led = oc.Ledger()
    n_counted = led._db.execute("SELECT COUNT(*) FROM done WHERE source='mail_contacts.msg'").fetchone()[0]
    assert n_counted == envelope["total"] - 3, f"{n_counted} messages counted of {envelope['total'] - 3}"
    print(f"[catch-up] {len(set(created) & want)} of {len(want)} after {ticks} tick(s), "
          f"{time.perf_counter() - t0:.1f}s for the whole mailbox")


def test_bounded_cost_messages_per_batch(envelope, tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "home"))
    _fake_store(tmp_path)
    fda = tmp_path / "fda"
    write_skip_files(fda)
    from ostler_fda import catchup_mail
    import ostler_catchup as oc
    a = catchup_mail.MailContacts(envelope_index=envelope["path"], fda_dir=fda)
    times, cursor = [], None
    for _ in range(10):
        t0 = time.perf_counter()
        b = a.next_batch(cursor, a.batch_size)
        for item in b.items:
            a.process(item)
        times.append(time.perf_counter() - t0)
        cursor = b.next_cursor
    mean = sum(times) / len(times)
    per_tick = int(1800 / mean) * a.batch_size
    print(f"\n[bounded cost] batch={a.batch_size} messages, mean {mean * 1000:.0f} ms per batch "
          f"(read + count + ingest, store stubbed); a 1800 s tick bounds at ~{per_tick:,} messages")
    assert mean < 30


def test_mail_bodies_mirror_reports_the_sweep_and_never_self_completes(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "home"))
    from ostler_fda import catchup_mail
    import ostler_catchup as oc
    ck = tmp_path / "home" / "state" / "apple_mail_mbox_checkpoint.json"
    ck.parent.mkdir(parents=True, exist_ok=True)
    ck.write_text(json.dumps({"schema_version": 2, "oldest_processed": "2021-03-04T00:00:00+00:00",
                              "backfill_complete": False}))
    t0 = time.monotonic()
    for _ in range(3):   # the SAME checkpoint three ticks running
        s = oc.run([catchup_mail.MailBodies()], budget_seconds=60, busy=lambda: None)
    assert time.monotonic() - t0 < 5, "the mirror spun until the budget ran out"
    wm = json.loads((oc.state_dir() / "mail_bodies.json").read_text())
    assert wm["complete"] is False, "an unchanged checkpoint was read as a finished walk"
    assert wm["oldest_at"].startswith("2021-03-04") and wm["doctor_row"] == "email"
    assert wm["items_done"] == 0
    ck.write_text(json.dumps({"schema_version": 2, "oldest_processed": "2012-01-01T00:00:00+00:00",
                              "backfill_complete": True}))
    s = oc.run([catchup_mail.MailBodies()], budget_seconds=60, busy=lambda: None)
    assert s["sources"]["mail_bodies"]["complete"] is True


def test_kill_inside_the_ingest_then_restart(envelope, tmp_path):
    """SIGKILL after the store created a Person and before the ledger knew."""
    fda = tmp_path / "fda"
    write_skip_files(fda)
    runner = tmp_path / "run_catchup.py"
    mod_dir = tmp_path / "fakestore"
    mod_dir.mkdir()
    (mod_dir / "fake_mail_store.py").write_text(STORE_PATCH)
    runner.write_text(textwrap.dedent(f'''
        import os, signal, sys
        sys.path[:0] = [{str(REPO / "vendor")!r}, {str(REPO / "lib")!r}, {str(mod_dir)!r}]
        import fake_mail_store
        from ostler_fda import pwg_ingest
        log = fake_mail_store.install_fake_store(os.environ["FAKE_LOG"])
        kill_at = int(os.environ.get("KILL_AT_CREATE", "-1"))
        real = pwg_ingest._sparql_update
        def update(sparql):
            real(sparql)
            if kill_at > 0 and "a pwg:Person" in sparql and \\
                    sum(1 for _ in open(log)) == kill_at:
                os.kill(os.getpid(), signal.SIGKILL)
        pwg_ingest._sparql_update = update
        import ostler_catchup
        sys.exit(ostler_catchup.main(["run", "--family", "mail",
                                      "--adapters", "ostler_fda.catchup_mail:adapters",
                                      "--budget-seconds", "600"]))
    '''))
    def env_for(home):
        e = dict(os.environ, OSTLER_HOME=str(home), OSTLER_CATCHUP_FDA_DIR=str(fda),
                 OSTLER_MAIL_ENVELOPE_INDEX=str(envelope["path"]), FAKE_LOG=str(home / "creates.log"),
                 OSTLER_CATCHUP_MAX_LOAD_PER_CORE="1000", OSTLER_INTERACTIVE_TTL_SECS="0")
        e.pop("OSTLER_DIR", None)
        return e

    def check(home, label, kills):
        created = _created(home / "creates.log")
        want = envelope["people"]
        assert want <= set(created), f"{label}: {len(want - set(created))} correspondents lost across the kills"
        dup = {a: c for a, c in created.items() if c > 1}
        assert not dup, f"{label}: a Person was created twice across a kill: {list(dup)[:3]}"
        led = sqlite3.connect(home / "state" / "catchup" / "ledger.sqlite")
        counted = led.execute("SELECT COUNT(*) FROM done WHERE source='mail_contacts.msg'").fetchone()[0]
        sums = led.execute("SELECT SUM(n) FROM counts WHERE source='mail_contacts'").fetchone()[0]
        assert counted == envelope["total"] - 3, f"{label}: {counted} messages counted, wanted {envelope['total'] - 3}"
        assert sums == counted, f"{label}: counters sum to {sums} over {counted} messages: a re-read batch counted twice"
        print(f"\n[kill] {label}: {kills} kill(s), {len(set(created) & want)} of {len(want)} people, "
              f"0 created twice, {counted} messages counted once each")

    # A. The worst moment: the store has the Person, the ledger does not.
    home_a = tmp_path / "home_a"
    r1 = subprocess.run([sys.executable, str(runner)], env=dict(env_for(home_a), KILL_AT_CREATE="137"),
                        capture_output=True, text=True, timeout=600)
    assert r1.returncode == -signal.SIGKILL, f"the kill did not land: {r1.returncode} {r1.stderr[-500:]}"
    assert len(_created(home_a / "creates.log")) == 137
    r2 = subprocess.run([sys.executable, str(runner)], env=env_for(home_a),
                        capture_output=True, text=True, timeout=600)
    assert r2.returncode == 0, r2.stderr[-800:]
    check(home_a, "inside the ingest", 1)

    # B. Random SIGKILLs from outside, until the walk completes.
    home_b = tmp_path / "home_b"
    rng = random.Random(15)
    kills = 0
    for _ in range(200):
        p = subprocess.Popen([sys.executable, str(runner)], env=env_for(home_b),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            p.wait(timeout=rng.uniform(0.15, 0.6))
        except subprocess.TimeoutExpired:
            p.send_signal(signal.SIGKILL)
            p.wait()
            kills += 1
            continue
        wmf = home_b / "state" / "catchup" / "mail_contacts.json"
        if wmf.exists() and json.loads(wmf.read_text()).get("complete"):
            break
    assert kills >= 2, f"only {kills} random kills landed"
    check(home_b, "random external", kills)


def test_install_registers_the_mail_runner_after_the_helper_exists():
    src = (REPO / "install.sh").read_text(encoding="utf-8").splitlines()
    defn = [i for i, l in enumerate(src) if l.startswith("_ostler_catchup_register() {")]
    calls = [i for i, l in enumerate(src) if "_ostler_catchup_register 40-mail" in l]
    assert defn, "install.sh defines no _ostler_catchup_register"
    assert calls, "install.sh never registers the mail catch-up runner"
    assert calls[0] > defn[0], "the mail runner is registered before the helper is defined"
    block = "\n".join(src[calls[0]:calls[0] + 5])
    assert "ostler_fda.catchup_mail:adapters" in block and "email-ingest/.venv/bin/python3" in block
    guard = "\n".join(src[calls[0] - 3:calls[0]])
    assert 'EMAIL_INGEST_VENV_PYTHON' in guard, "registered without checking the venv exists"
    from ostler_fda import catchup_mail
    names = sorted(a.source for a in catchup_mail.adapters())
    assert names == ["mail_bodies", "mail_contacts"], names
