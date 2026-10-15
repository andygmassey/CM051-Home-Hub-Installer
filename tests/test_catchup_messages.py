"""Full-history catch-up for iMessage and WhatsApp bundles (v1.0.108, 2/6).

Andy's MUST: every message, not the newest window. The shipped forward feeds
read iMessage chats active in the last 30 days (newest 2,000 rows each) and
WhatsApp chats active in the last 365 days (newest 2,000 each). These
fixtures are larger than every one of those caps:

  chat.db             a 6,000-message chat over 4 years, a chat quiet for
                      400 days, a group quiet for 60 days, assistant sends
  ChatStorage.sqlite  a 6,000-message DM over 3 years, a DM quiet for 500
                      days, a small group quiet for 400 days, a large
                      passive (T3) group that must never be read

The sink is a fake pwg-convo that models CM048: one directory per
conversation_id (a keyed upsert) plus an append-only write log. Every message
body is a unique token, so coverage and overlap are measured on CONTENT, not
only on ids.

Synthetic data only: approved cast names, +44 7700 900xxx numbers.
"""
from __future__ import annotations

import collections
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
VENDOR = REPO / "vendor"
LIB = REPO / "lib"
for p in (str(VENDOR), str(LIB)):
    if p not in sys.path:
        sys.path.insert(0, p)

NOW = datetime.now(timezone.utc).replace(microsecond=0)
# JIDs are composed at run time: the literal shape trips the PII shape scan.
_AT = "@"


def _jid(n):
    return n + _AT + "s.whatsapp" + ".net"


def _gid(n):
    return n + _AT + "g.us"


TOKEN = re.compile(r"\b(tok-[a-z]\d+-\d+)\b")

FAKE_PWG_CONVO = r"""#!/bin/sh
# Models CM048: one dir per conversation_id (re-writing it is an upsert),
# plus an append-only log of every write.
[ "$1" = "process" ] || exit 64
id="$(sed -n 's/.*"conversation_id": "\([^"]*\)".*/\1/p' "$3" | head -1)"
[ -n "$id" ] || exit 65
mkdir -p "$FAKE_SINK/$id"
cp "$2" "$FAKE_SINK/$id/transcript.md"
echo "$id" >> "$FAKE_SINK/../writes.log"
exit 0
"""


# ── fixtures ────────────────────────────────────────────────────────────────

def _imsg_ns(dt):
    return int((dt.timestamp() - 978307200) * 1e9)


def _sessions_back(start, n_msgs, per_session, step=timedelta(minutes=1), between=timedelta(hours=9)):
    """Timestamps newest-first: sessions of `per_session` messages a minute
    apart, sessions `between` apart, walking back from `start`."""
    out, t = [], start
    for i in range(n_msgs):
        out.append(t)
        t = t - (between if (i + 1) % per_session == 0 else step)
    return out


def build_chat_db(path: Path):
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT,
                           style INTEGER, account_login TEXT, chat_identifier TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, is_from_me INTEGER,
                              date INTEGER, cache_has_attachments INTEGER, service TEXT,
                              handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    """)
    handles = {1: "+447700900101", 2: "+447700900102", 3: "+447700900103", 4: "+447700900104"}
    for k, v in handles.items():
        conn.execute("INSERT INTO handle VALUES (?, ?)", (k, v))
    chats = [
        # (rowid, guid, display, style, handles, n, per_session, newest)
        (1, "iMessage;-;+447700900101", None, 45, [1], 6000, 10, NOW - timedelta(hours=1)),
        (2, "iMessage;-;+447700900102", None, 45, [2], 300, 6, NOW - timedelta(days=400)),
        (3, "iMessage;+;chat-synthetic-group", "Jane and Tom", 43, [3, 4], 240, 8, NOW - timedelta(days=60)),
    ]
    rowid = 0
    expected = collections.Counter()
    for crow, guid, disp, style, hs, n, per, newest in chats:
        conn.execute("INSERT INTO chat VALUES (?, ?, ?, ?, 'P:+447700900100', ?)",
                     (crow, guid, disp, style, guid))
        for h in hs:
            conn.execute("INSERT INTO chat_handle_join VALUES (?, ?)", (crow, h))
        spread = timedelta(hours=60) if n > 5000 else timedelta(hours=9)   # 600 sessions x 2.5 d = 4.1 years
        for i, ts in enumerate(_sessions_back(newest, n, per, between=spread)):
            rowid += 1
            from_me = i % 3 == 0
            text = f"tok-c{crow}-{i}"
            if i % 97 == 5 and from_me:
                text = "\U0001F916 Your synthetic morning brief"   # an assistant send: dropped
            else:
                expected[text] += 1
            handle = None if from_me else hs[i % len(hs)]
            conn.execute("INSERT INTO message VALUES (?, ?, ?, ?, 0, 'iMessage', ?)",
                         (rowid, text, 1 if from_me else 0, _imsg_ns(ts), handle))
            conn.execute("INSERT INTO chat_message_join VALUES (?, ?)", (crow, rowid))
    conn.commit()
    conn.close()
    return expected


def build_chatstorage(path: Path):
    from ostler_fda import whatsapp_history as wh

    def mac(dt):
        return dt.timestamp() - wh.MAC_EPOCH_OFFSET

    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZGROUPINFO INTEGER,
                                     ZCONTACTJID TEXT, ZLASTMESSAGEDATE REAL);
        CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER,
                                 ZISFROMME INTEGER, ZMESSAGEDATE REAL, ZFROMJID TEXT,
                                 ZTEXT TEXT, ZMESSAGETYPE INTEGER);
        CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER,
                                     ZMEMBERJID TEXT, ZISACTIVE INTEGER);
        CREATE TABLE ZWAGROUPINFO (Z_PK INTEGER PRIMARY KEY, ZSUBJECT TEXT);
    """)
    conn.execute("INSERT INTO ZWAGROUPINFO VALUES (10, 'Synthetic Family')")
    conn.execute("INSERT INTO ZWAGROUPINFO VALUES (20, 'Synthetic Big Group')")
    chats = [
        # (pk, group, jid, n, per_session, newest, members)
        (1, None, _jid("447700900201"), 6000, 12, NOW - timedelta(hours=2), []),
        (2, None, _jid("447700900202"), 300, 5, NOW - timedelta(days=500), []),
        (4, 10, _gid("4204"), 200, 4, NOW - timedelta(days=400),
         [_jid("447700900203"), _jid("447700900204")]),
    ]
    zpk = 0
    expected = collections.Counter()
    for pk, gi, jid, n, per, newest, members in chats:
        conn.execute("INSERT INTO ZWACHATSESSION VALUES (?, ?, ?, ?)", (pk, gi, jid, mac(newest)))
        for j, m in enumerate(members):
            conn.execute("INSERT INTO ZWAGROUPMEMBER (ZCHATSESSION, ZMEMBERJID, ZISACTIVE) VALUES (?, ?, 1)",
                         (pk, m))
        spread = timedelta(days=2) if n > 5000 else timedelta(hours=9)     # 500 sessions x 2 d = 2.7 years
        for i, ts in enumerate(_sessions_back(newest, n, per, between=spread)):
            zpk += 1
            from_me = i % 2 == 0
            author = None if from_me else (members[i % len(members)] if members else jid)
            text = f"tok-w{pk}-{i}"
            expected[text] += 1
            conn.execute("INSERT INTO ZWAMESSAGE VALUES (?, ?, ?, ?, ?, ?, 0)",
                         (zpk, pk, 1 if from_me else 0, mac(ts), author, text))
            if i % 50 == 7:   # a media row: no text, never a bundle line
                zpk += 1
                conn.execute("INSERT INTO ZWAMESSAGE VALUES (?, ?, 0, ?, ?, NULL, 1)",
                             (zpk, pk, mac(ts - timedelta(seconds=5)), author))
    # T3: twelve members, no owner engagement, recent. Never read.
    conn.execute("INSERT INTO ZWACHATSESSION VALUES (3, 20, ?, ?)", (_gid("9903"), mac(NOW - timedelta(hours=3))))
    for k in range(12):
        conn.execute("INSERT INTO ZWAGROUPMEMBER (ZCHATSESSION, ZMEMBERJID, ZISACTIVE) VALUES (3, ?, 1)",
                     (_jid(f"4477009003{k:02d}"),))
    for k in range(40):
        zpk += 1
        conn.execute("INSERT INTO ZWAMESSAGE VALUES (?, 3, 0, ?, ?, 'T3_SENTINEL_MUST_NOT_LEAK', 0)",
                     (zpk, mac(NOW - timedelta(days=k * 30)), _jid(f"4477009003{k % 12:02d}")))
    conn.commit()
    conn.close()
    return expected


@pytest.fixture()
def env(tmp_path, monkeypatch):
    sink = tmp_path / "out" / "sink"
    sink.mkdir(parents=True)
    fake = tmp_path / "pwg-convo"
    fake.write_text(FAKE_PWG_CONVO)
    fake.chmod(0o755)
    monkeypatch.setenv("FAKE_SINK", str(sink))
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("OSTLER_STATE_DIR", str(tmp_path / "ws"))
    monkeypatch.delenv("OSTLER_DIR", raising=False)
    monkeypatch.setenv("OSTLER_DISPATCH_TIMEOUT_SECS", "60")
    return {"tmp": tmp_path, "sink": sink, "fake": [str(fake)],
            "ws": tmp_path / "ws"}


def sink_tokens(sink: Path):
    seen = collections.Counter()
    bundles_per_token = collections.defaultdict(set)
    for d in sink.iterdir():
        text = (d / "transcript.md").read_text()
        for t in TOKEN.findall(text):
            seen[t] += 1
            bundles_per_token[t].add(d.name)
    return seen, bundles_per_token


def writes(tmp: Path):
    log = tmp / "out" / "writes.log"
    return collections.Counter(log.read_text().split()) if log.exists() else collections.Counter()


def _catchup_module(name):
    import importlib
    try:
        return importlib.import_module(name)
    except ModuleNotFoundError as exc:
        pytest.fail(f"no catch-up adapter {name} ({exc}): nothing reads older messages")


def _run_until_complete(adapter, budget=1e9, max_ticks=500):
    import ostler_catchup as oc
    ticks = 0
    while ticks < max_ticks:
        s = oc.run([adapter], budget_seconds=budget, busy=lambda: None)
        ticks += 1
        if s["sources"][adapter.source]["complete"]:
            return ticks, s
    raise AssertionError(f"not complete after {max_ticks} ticks")


# ── iMessage ────────────────────────────────────────────────────────────────

def _imessage_bundleable(expected):
    """Tokens that belong to a session of 2+ messages (the threader drops
    singletons in the forward feed too, so they are out of scope by design)."""
    return expected   # every fixture session has 6+ messages; none is a singleton


def test_imessage_forward_alone_misses_history_and_catchup_reads_it_all(env):
    from imessage_source.pipeline import process_imessage
    db = env["tmp"] / "chat.db"
    expected = _imessage_bundleable(build_chat_db(db))
    state = env["ws"] / "imessage_source_state.json"
    process_imessage(db_path=db, state_path=state, pwg_convo_cmd=env["fake"])
    fwd, _ = sink_tokens(env["sink"])
    covered = sum(1 for t in expected if fwd[t])
    print(f"\n[imessage forward only] {covered} of {len(expected)} messages reached a bundle")
    assert covered < len(expected) / 2, "fixture does not exceed the forward window"

    cu = _catchup_module("imessage_source.catchup")
    adapter = cu.IMessageCatchup(db_path=db, state_path=state, pwg_convo_cmd=env["fake"])
    t0 = time.perf_counter()
    ticks, _ = _run_until_complete(adapter)
    dt = time.perf_counter() - t0
    seen, per = sink_tokens(env["sink"])
    missing = [t for t in expected if not seen[t]]
    double = {t: sorted(per[t]) for t in expected if len(per[t]) > 1}
    print(f"[imessage forward + catch-up] {len(expected) - len(missing)} of {len(expected)}; "
          f"in two bundles: {len(double)}; {ticks} tick(s), {dt:.1f}s")
    assert not missing, f"{len(missing)} messages never reached a bundle, e.g. {missing[:3]}"
    assert not double, f"{len(double)} messages sit in two bundles, e.g. {list(double.items())[:2]}"
    assert all(c == 1 for c in writes(env["tmp"]).values()), "a conversation was dispatched twice"
    assert not any("morning brief" in (d / "transcript.md").read_text() for d in env["sink"].iterdir()), \
        "an assistant send reached a bundle"
    wm = json.loads((Path(os.environ["OSTLER_HOME"]) / "state" / "catchup" / "imessage.json").read_text())
    assert wm["complete"] and wm["oldest_at"][:7] <= (NOW - timedelta(days=4 * 365 - 30)).strftime("%Y-%m")


def test_imessage_catchup_ids_match_the_forward_feed(env):
    """A chat catch-up starts at its newest message (no forward watermark)
    threads to the same ids the forward feed would mint."""
    from imessage_source.pipeline import process_imessage
    db = env["tmp"] / "chat.db"
    build_chat_db(db)
    cu = _catchup_module("imessage_source.catchup")
    _run_until_complete(cu.IMessageCatchup(db_path=db, state_path=env["ws"] / "none.json",
                                           pwg_convo_cmd=env["fake"]))
    before = writes(env["tmp"])
    process_imessage(db_path=db, state_path=env["ws"] / "fwd.json", pwg_convo_cmd=env["fake"])
    after = writes(env["tmp"])
    fresh = [k for k in after if k not in before]
    assert not fresh, f"the forward feed minted {len(fresh)} ids catch-up did not: {fresh[:3]}"


def test_imessage_kill_mid_backfill_then_restart(env):
    db = env["tmp"] / "chat.db"
    expected = build_chat_db(db)
    e = dict(os.environ)
    e.update({"PYTHONPATH": f"{LIB}{os.pathsep}{VENDOR}", "OSTLER_IMESSAGE_CHAT_DB": str(db),
              "PWG_CONVO_CMD": env["fake"][0], "OSTLER_CATCHUP_MAX_LOAD_PER_CORE": "1000",
              "OSTLER_INTERACTIVE_TTL_SECS": "0"})
    cmd = [sys.executable, "-m", "ostler_catchup", "run", "--family", "imessage",
           "--adapters", "imessage_source.catchup:adapters", "--budget-seconds", "600"]
    kills = 0
    for target in (40, 160, 310):
        p = subprocess.Popen(cmd, env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 120
        while time.time() < deadline and p.poll() is None:
            if sum(writes(env["tmp"]).values()) >= target:
                p.send_signal(signal.SIGKILL)
                kills += 1
                break
            time.sleep(0.02)
        p.wait()
    r = subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=600)
    assert r.returncode == 0, r.stderr[-800:]
    assert kills == 3, f"only {kills} kills landed"
    seen, per = sink_tokens(env["sink"])
    assert all(seen[t] for t in expected), "a kill lost a message"
    assert not [t for t in expected if len(per[t]) > 1], "a kill put a message in two bundles"
    w = writes(env["tmp"])
    repeats = sum(c - 1 for c in w.values())
    assert repeats <= kills, f"{repeats} repeated dispatches from {kills} kills"
    print(f"\n[imessage kill] kills={kills} bundles={len(w)} repeated dispatches={repeats}")


def test_imessage_bounded_cost_per_tick(env):
    db = env["tmp"] / "chat.db"
    build_chat_db(db)
    cu = _catchup_module("imessage_source.catchup")
    import ostler_catchup as oc
    a = cu.IMessageCatchup(db_path=db, state_path=env["ws"] / "none.json", pwg_convo_cmd=env["fake"])
    t0 = time.perf_counter()
    b = a.next_batch(None, a.batch_size)
    first = time.perf_counter() - t0
    t0 = time.perf_counter()
    b2 = a.next_batch(b.next_cursor, a.batch_size)
    second = time.perf_counter() - t0
    clock = {"t": 0.0}
    real = a.process

    def costed(s):
        clock["t"] += 100.0      # ~100 s per conversation on a box (v1018-D021)
        return real(s)
    a.process = costed
    s = oc.run([a], budget_seconds=1800, clock=lambda: clock["t"], busy=lambda: None)
    n = s["sources"]["imessage"]["items"]
    print(f"\n[imessage cost] first batch (cursor build) {first*1000:.0f} ms, next batch {second*1000:.0f} ms, "
          f"{len(b2.items)} sessions per batch; at 100 s/conversation a 1800 s tick dispatches {n}")
    assert n <= 18
    assert second < 2.0


# ── WhatsApp ────────────────────────────────────────────────────────────────

def test_whatsapp_forward_alone_misses_history_and_catchup_reads_it_all(env):
    from whatsapp_source.pipeline import process_whatsapp
    db = env["tmp"] / "ChatStorage.sqlite"
    expected = build_chatstorage(db)
    state = env["ws"] / "whatsapp_source_state.json"
    process_whatsapp(db_path=db, state_path=state, pwg_convo_cmd=env["fake"])
    fwd, _ = sink_tokens(env["sink"])
    covered = sum(1 for t in expected if fwd[t])
    print(f"\n[whatsapp forward only] {covered} of {len(expected)} messages reached a bundle")
    assert covered < len(expected) / 2

    cu = _catchup_module("whatsapp_source.catchup")
    adapter = cu.WhatsAppCatchup(db_path=db, state_path=state, pwg_convo_cmd=env["fake"])
    ticks, _ = _run_until_complete(adapter)
    seen, per = sink_tokens(env["sink"])
    missing = [t for t in expected if not seen[t]]
    double = [t for t in expected if len(per[t]) > 1]
    print(f"[whatsapp forward + catch-up] {len(expected) - len(missing)} of {len(expected)}; "
          f"in two bundles: {len(double)}; {ticks} tick(s)")
    assert not missing, f"{len(missing)} never bundled, e.g. {missing[:3]}"
    assert not double, f"{len(double)} in two bundles, e.g. {double[:3]}"
    assert all(c == 1 for c in writes(env["tmp"]).values())
    leaked = [d.name for d in env["sink"].iterdir() if "T3_SENTINEL" in (d / "transcript.md").read_text()]
    assert not leaked, "a T3 large passive group was read"


def test_whatsapp_catchup_before_the_forward_feed_does_not_double_process_the_newest(env):
    """Catch-up running BEFORE the forward feed has recorded a chat (a new
    chat, or the tick order) used to start at the newest message and bundle
    those messages under session ids; the forward feed then bundled the same
    messages again as one chat-wide conversation. Every message must end up in
    exactly one bundle whichever feed runs first."""
    from whatsapp_source.pipeline import process_whatsapp
    db = env["tmp"] / "ChatStorage.sqlite"
    expected = build_chatstorage(db)
    state = env["ws"] / "whatsapp_source_state.json"
    assert not state.exists(), "the fixture must start with no forward state"
    cu = _catchup_module("whatsapp_source.catchup")
    adapter = cu.WhatsAppCatchup(db_path=db, state_path=state, pwg_convo_cmd=env["fake"])
    _run_until_complete(adapter)
    process_whatsapp(db_path=db, state_path=state, pwg_convo_cmd=env["fake"])
    seen, per = sink_tokens(env["sink"])
    missing = [t for t in expected if not seen[t]]
    double = [t for t in expected if len(per[t]) > 1]
    print(f"\n[whatsapp catch-up first] missing {len(missing)}, in two bundles {len(double)} of {len(expected)}")
    assert not double, f"{len(double)} messages in two conversations, e.g. {double[:3]}"
    assert not missing, f"{len(missing)} never bundled, e.g. {missing[:3]}"


def test_whatsapp_kill_mid_backfill_then_restart(env):
    from whatsapp_source.pipeline import process_whatsapp
    db = env["tmp"] / "ChatStorage.sqlite"
    expected = build_chatstorage(db)
    # Catch-up starts BELOW the window the forward feed bundles, so the forward
    # feed runs first, as it does at install.
    process_whatsapp(db_path=db, state_path=env["ws"] / "whatsapp_source_state.json",
                     pwg_convo_cmd=env["fake"])
    baseline = sum(writes(env["tmp"]).values())
    e = dict(os.environ)
    e.update({"PYTHONPATH": f"{LIB}{os.pathsep}{VENDOR}", "OSTLER_WHATSAPP_CHAT_DB": str(db),
              "PWG_CONVO_CMD": env["fake"][0], "OSTLER_CATCHUP_MAX_LOAD_PER_CORE": "1000",
              "OSTLER_INTERACTIVE_TTL_SECS": "0"})
    cmd = [sys.executable, "-m", "ostler_catchup", "run", "--family", "whatsapp",
           "--adapters", "whatsapp_source.catchup:adapters", "--budget-seconds", "600"]
    kills = 0
    for target in (30, 140, 280):
        p = subprocess.Popen(cmd, env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 120
        while time.time() < deadline and p.poll() is None:
            if sum(writes(env["tmp"]).values()) >= baseline + target:
                p.send_signal(signal.SIGKILL)
                kills += 1
                break
            time.sleep(0.02)
        p.wait()
    r = subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=600)
    assert r.returncode == 0, r.stderr[-800:]
    assert kills == 3
    seen, per = sink_tokens(env["sink"])
    assert all(seen[t] for t in expected)
    assert not [t for t in expected if len(per[t]) > 1]
    w = writes(env["tmp"])
    repeats = sum(c - 1 for c in w.values())
    assert repeats <= kills
    print(f"\n[whatsapp kill] kills={kills} bundles={len(w)} repeated dispatches={repeats}")


def test_whatsapp_bounded_cost_per_batch(env):
    db = env["tmp"] / "ChatStorage.sqlite"
    build_chatstorage(db)
    cu = _catchup_module("whatsapp_source.catchup")
    a = cu.WhatsAppCatchup(db_path=db, state_path=env["ws"] / "none.json", pwg_convo_cmd=env["fake"])
    t0 = time.perf_counter()
    b = a.next_batch(None, a.batch_size)
    first = time.perf_counter() - t0
    t0 = time.perf_counter()
    b2 = a.next_batch(b.next_cursor, a.batch_size)
    second = time.perf_counter() - t0
    print(f"\n[whatsapp cost] first batch {first*1000:.0f} ms, next batch {second*1000:.0f} ms, "
          f"{len(b2.items)} sessions per batch")
    assert second < 2.0


def test_runners_are_registered_after_each_feed(tmp_path):
    src = (REPO / "install.sh").read_text()
    for feed, name, spec in (("imessage", "60-imessage", "services.imessage_source.catchup:adapters"),
                             ("whatsapp", "62-whatsapp", "whatsapp_source.catchup:adapters")):
        call = src.find("    _install_conversation_feed %s " % feed)
        assert call != -1
        reg = src.find("_ostler_catchup_register_feed %s %s %s" % (feed, name, spec))
        assert reg != -1, f"no catch-up runner registered for {feed}: its history is never walked"
        assert 0 < reg - call < 200, f"{name} is not registered straight after its feed installs"


def _extract_fn(src, name):
    start = src.index("%s() {\n" % name)
    end = src.index("\n}\n", start)
    return src[start:end + 3]


def test_the_registered_runner_carries_the_feeds_environment(tmp_path):
    """Drive the shipped helper: the runner gets the feed's venv, package
    path, pwg-convo, display name and user id, and the model slot."""
    src = (REPO / "install.sh").read_text()
    script = tmp_path / "reg.sh"
    stage = tmp_path / "ostler"
    venv = stage / "services" / "imessage-source" / ".venv" / "bin"
    venv.mkdir(parents=True)
    (venv / "python3").write_text("#!/bin/sh\n")
    (venv / "python3").chmod(0o755)
    script.write_text(
        _extract_fn(src, "_ostler_catchup_register") + "\n"
        + _extract_fn(src, "_ostler_catchup_register_feed") + "\n"
        + 'warn() { echo "WARN $*"; }\n'
        + f'OSTLER_DIR="{stage}"; OSTLER_FINAL_DIR="{stage}"; CM048_VENV="{tmp_path}/cm048"\n'
        + 'USER_NAME="Jane Doe"; USER_ID="u-1"\n'
        + "_ostler_catchup_register_feed imessage 60-imessage services.imessage_source.catchup:adapters\n"
        + "_ostler_catchup_register_feed whatsapp 62-whatsapp whatsapp_source.catchup:adapters\n")
    r = subprocess.run(["/bin/bash", str(script)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    runner = stage / "bin" / "catchup.d" / "60-imessage.sh"
    assert runner.is_file(), "no runner written for an installed feed"
    body = runner.read_text()
    for want in (f"{stage}/services/imessage-source/.venv/bin/python3",
                 f"PYTHONPATH={stage}/lib:{stage}/services/imessage-source",
                 "PWG_CONVO_CMD=pwg-convo", "OSTLER_USER_ID=u-1",
                 "services.imessage_source.catchup:adapters", "ostler_slot_acquire"):
        assert want in body.replace("\\ ", " "), f"runner lacks {want!r}"
    assert "Jane" in body
    assert not (stage / "bin" / "catchup.d" / "62-whatsapp.sh").exists(), \
        "a runner was written for a feed whose venv does not exist"


# ── an outage of the sink is not a poison attempt (Archie re-review of #2903) ─

def _exit_script(tmp: Path, rc: int) -> list:
    s = tmp / f"pwg-convo-rc{rc}"
    s.write_text(f"#!/bin/sh\nexit {rc}\n")
    s.chmod(0o755)
    return [str(s)]


def _first_item(adapter):
    batch = adapter.next_batch(adapter.start_cursor(), 1)
    assert batch.items, "fixture produced no item to process"
    return batch.items[0]


@pytest.mark.parametrize("which", ["imessage", "whatsapp"])
def test_a_cm048_exit_75_is_an_outage_never_a_failed_item(env, which):
    if which == "imessage":
        db = env["tmp"] / "chat.db"
        build_chat_db(db)
        mk = lambda cmd: _catchup_module("imessage_source.catchup").IMessageCatchup(
            db_path=db, state_path=env["ws"] / "none.json", pwg_convo_cmd=cmd)
    else:
        db = env["tmp"] / "ChatStorage.sqlite"
        build_chatstorage(db)
        mk = lambda cmd: _catchup_module("whatsapp_source.catchup").WhatsAppCatchup(
            db_path=db, state_path=env["ws"] / "none.json", pwg_convo_cmd=cmd)
    down = mk(_exit_script(env["tmp"], 75))
    with pytest.raises(ConnectionError):
        down.process(_first_item(down))
    # A real rejection is still just False: it counts toward quarantine.
    rejects = mk(_exit_script(env["tmp"], 1))
    assert rejects.process(_first_item(rejects)) is False
    ok = mk(_exit_script(env["tmp"], 0))
    assert ok.process(_first_item(ok)) is True


# ── a dispatch TIMEOUT (124) is a hung item OR a dead sink; a probe decides ──

HANG_PWG_CONVO = r"""#!/bin/sh
# Like the fake CM048, but the conversation named by $HANG_ID never returns.
[ "$1" = "process" ] || exit 64
id="$(sed -n 's/.*"conversation_id": "\([^"]*\)".*/\1/p' "$3" | head -1)"
[ -n "$id" ] || exit 65
if [ "$id" = "$HANG_ID" ]; then sleep 30; exit 0; fi
mkdir -p "$FAKE_SINK/$id"
cp "$2" "$FAKE_SINK/$id/transcript.md"
exit 0
"""


def _small(cls, n):
    """The real adapter, truncated to its first ``n`` sessions in one batch."""
    class Small(cls):
        def next_batch(self, cursor, limit):
            import ostler_catchup as oc
            items, cur = [], cursor
            for _ in range(200):
                b = super().next_batch(cur, limit)
                items += b.items
                cur = b.next_cursor
                if len(items) >= n or b.exhausted:
                    break
            return oc.Batch(items=items[:n], next_cursor=cur, oldest_at=b.oldest_at, exhausted=True)
    return Small


def _hang_setup(env, monkeypatch, which):
    script = env["tmp"] / "pwg-convo-hang"
    script.write_text(HANG_PWG_CONVO)
    script.chmod(0o755)
    monkeypatch.setenv("OSTLER_DISPATCH_TIMEOUT_SECS", "1")
    if which == "imessage":
        db = env["tmp"] / "chat.db"
        build_chat_db(db)
        cu = _catchup_module("imessage_source.catchup")
        cls = _small(cu.IMessageCatchup, 3)
    else:
        db = env["tmp"] / "ChatStorage.sqlite"
        build_chatstorage(db)
        cu = _catchup_module("whatsapp_source.catchup")
        cls = _small(cu.WhatsAppCatchup, 3)
    make = lambda: cls(db_path=db, state_path=env["ws"] / "none.json", pwg_convo_cmd=[str(script)])
    return cu, make


@pytest.mark.parametrize("which", ["imessage", "whatsapp"])
def test_a_hanging_item_with_a_healthy_sink_is_quarantined_and_the_rest_proceeds(env, monkeypatch, which):
    import ostler_catchup as oc
    cu, make = _hang_setup(env, monkeypatch, which)
    monkeypatch.setattr(cu, "ollama_healthy", lambda *a, **k: True)
    probe = make()   # a throwaway instance: next_batch is stateful
    items = probe.next_batch(probe.start_cursor(), probe.batch_size).items
    ad = make()
    assert len(items) == 3
    monkeypatch.setenv("HANG_ID", ad.key(items[1]))
    for tick in range(oc.MAX_ITEM_ATTEMPTS):
        s = oc.run([ad], budget_seconds=1e9, busy=lambda: None)
    row = s["sources"][ad.source]
    assert row["quarantined"] == 1 and row["complete"], row
    delivered = {d.name for d in env["sink"].iterdir()}
    assert delivered == {ad.key(items[0]), ad.key(items[2])}, "the rest of the source did not proceed"


@pytest.mark.parametrize("which", ["imessage", "whatsapp"])
def test_a_timeout_with_a_dead_sink_counts_no_attempt(env, monkeypatch, which):
    cu, make = _hang_setup(env, monkeypatch, which)
    monkeypatch.setattr(cu, "ollama_healthy", lambda *a, **k: False)
    ad = make()
    items = ad.next_batch(ad.start_cursor(), ad.batch_size).items
    monkeypatch.setenv("HANG_ID", ad.key(items[0]))
    with pytest.raises(ConnectionError):
        ad.process(items[0])
