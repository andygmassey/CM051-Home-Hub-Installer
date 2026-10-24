"""Photos and AI chats walk back past the install's first year (v1.0.108).

The install reads Photos and AI chats with a 365-day clamp
(extract_all.py photos arm; cm052 cli --since-days 365) and nothing ever read
further back. These tests drive the SHIPPED install paths on fixtures larger
than that clamp, print how much they cover (RED on origin/main, where nothing
else exists), then run the catch-up adapters through the shared core and
require every item to reach the keyed sink exactly once, including across a
SIGKILL mid-walk.

Synthetic data only: integer-keyed photos at made-up coordinates, and chat
titles built from the approved cast. No real place, person or conversation.
"""
from __future__ import annotations

import importlib.util
import json
import os
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
from unittest import mock

import pytest

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "lib"
VENDOR = REPO / "vendor"
CM052 = VENDOR / "cm052_ai_conversations"
for p in (str(LIB), str(VENDOR), str(CM052)):
    if p not in sys.path:
        sys.path.insert(0, p)

MAC_EPOCH = 978307200
NOW = datetime.now(timezone.utc)
N_PHOTOS = 6_500          # over 7 years: > 6,000 assets, > 6 years
PHOTO_YEARS = 7
N_CHATS = 450             # over 5 years: > 400 conversations, > 4 years
CHAT_YEARS = 5
CAST = ["Jane", "John", "Bob", "Alex", "Mary", "Raj", "Sam", "Ana", "Ben", "Tom"]


def _need(module: str):
    try:
        return importlib.import_module(module)
    except ImportError as exc:
        pytest.fail(f"{module} is absent: nothing walks this source back past the install window ({exc})")


import importlib  # noqa: E402


# ── fixtures ────────────────────────────────────────────────────────────────

def _photo_when(i: int) -> datetime:
    """Asset 0 is an hour old; asset N-1 is PHOTO_YEARS back."""
    return NOW - timedelta(hours=1) - timedelta(
        seconds=int(i * (PHOTO_YEARS * 365 * 86400) / N_PHOTOS))


def build_photos_db(path: Path) -> None:
    c = sqlite3.connect(path)
    c.executescript("""
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZDATECREATED REAL,
            ZLATITUDE REAL, ZLONGITUDE REAL, ZTRASHEDSTATE INTEGER);
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY,
            ZASSET INTEGER, ZREVERSELOCATIONDATA BLOB);
        CREATE TABLE ZDETECTEDFACE (Z_PK INTEGER PRIMARY KEY,
            ZASSETFORFACE INTEGER, ZPERSONFORFACE INTEGER);
        CREATE TABLE ZPERSON (Z_PK INTEGER PRIMARY KEY, ZFULLNAME TEXT);
        INSERT INTO ZPERSON VALUES (1, 'Jane Doe');
    """)
    rows = []
    for i in range(N_PHOTOS):
        mac = _photo_when(i).timestamp() - MAC_EPOCH
        rows.append((i + 1, mac, 10.0 + i / 1e4, 20.0 + i / 1e4, 0))
    c.executemany("INSERT INTO ZASSET VALUES (?,?,?,?,?)", rows)
    # Every tenth photo carries the face, so the faces rule is exercised.
    c.executemany("INSERT INTO ZDETECTEDFACE (ZASSETFORFACE, ZPERSONFORFACE) VALUES (?, 1)",
                  [(i + 1,) for i in range(0, N_PHOTOS, 10)])
    # A trashed photo older than everything: never read, never the floor.
    c.execute("INSERT INTO ZASSET VALUES (?,?,?,?,1)",
              (N_PHOTOS + 1, _photo_when(N_PHOTOS * 2).timestamp() - MAC_EPOCH, 1.0, 1.0))
    c.commit()
    c.close()


def _chat_when(i: int) -> datetime:
    return NOW - timedelta(hours=2) - timedelta(
        seconds=int(i * (CHAT_YEARS * 365 * 86400) / N_CHATS))


def build_chatgpt_export(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    convs = []
    for i in range(N_CHATS):
        t = _chat_when(i).timestamp()
        who = CAST[i % len(CAST)]
        convs.append({
            "id": f"fixture-{i:05d}",
            "title": f"Picnic plan {i} with {who}",
            "create_time": t - 600, "update_time": t,
            "default_model_slug": "fixture-model",
            "mapping": {
                "root": {"id": "root", "parent": None, "children": ["u"], "message": None},
                "u": {"id": "u", "parent": "root", "children": ["a"], "message": {
                    "id": "mu", "author": {"role": "user"},
                    "content": {"content_type": "text", "parts": [f"Where should {who} and I meet?"]},
                    "create_time": t - 600}},
                "a": {"id": "a", "parent": "u", "children": [], "message": {
                    "id": "ma", "author": {"role": "assistant"},
                    "content": {"content_type": "text", "parts": ["By the bandstand at noon."]},
                    "create_time": t}},
            },
        })
    (root / "conversations.json").write_text(json.dumps(convs))


@pytest.fixture()
def env(tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / ".ostler" / "state" / "hydrate").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("OSTLER_HOME", str(home / ".ostler"))
    monkeypatch.delenv("OSTLER_DIR", raising=False)
    monkeypatch.delenv("OSTLER_FDA_SOURCES", raising=False)
    monkeypatch.setenv("CM052_STATE_DIR", str(tmp_path / "cm052state"))
    monkeypatch.setenv("CM052_USER_EMAIL", "jane@example.com")
    monkeypatch.setenv("OSTLER_CHATGPT_IMPORT_DIR", str(tmp_path / "chatgpt"))
    monkeypatch.setenv("CM052_CLAUDE_CODE_PROJECTS_DIR", str(tmp_path / "no-claude-code"))
    db = tmp_path / "Photos.sqlite"
    build_photos_db(db)
    build_chatgpt_export(tmp_path / "chatgpt")
    return {"tmp": tmp_path, "home": home, "db": db}


def _photo_sink():
    """Records every pwg:PhotoEvent URI the real ingest writes."""
    writes: Counter = Counter()

    def fake_update(q):
        for uri in re.findall(r"<(https://schema\.ostler\.ai/ontology#photo_event_[0-9a-f-]+)> a pwg:PhotoEvent", q):
            writes[uri] += 1
    return writes, fake_update


# ── Photos ──────────────────────────────────────────────────────────────────

def test_photos_install_path_alone_covers_one_year_then_catchup_covers_all(env, monkeypatch):
    from ostler_fda import extract_all, photos_metadata, pwg_ingest
    monkeypatch.setattr(photos_metadata, "DEFAULT_PHOTOS_PATH", env["db"])
    writes, fake_update = _photo_sink()
    monkeypatch.setattr(pwg_ingest, "_sparql_update", fake_update)

    out = env["tmp"] / "fda"
    extract_all.run_all(out, enabled_sources={"photos_metadata"})
    pwg_ingest.ingest_photo_events(out)
    install = len(writes)
    print(f"\n[photos] install path (extract_all, 365 d) covered {install} of {N_PHOTOS}")
    assert 0 < install < N_PHOTOS

    cp = _need("ostler_fda.catchup_photos")
    oc = _need("ostler_catchup")
    (env["home"] / ".ostler" / "state" / "hydrate" / "photos.done").write_text("status=ok\n")
    adapters = cp.adapters()
    assert [a.source for a in adapters] == ["photos"]
    a = adapters[0]
    a.db_path = env["db"]
    ticks, per_tick = 0, []
    while True:
        before = len(writes)
        s = oc.run([a], budget_seconds=1e9, busy=lambda: None)
        per_tick.append(len(writes) - before)
        ticks += 1
        if s["sources"]["photos"]["complete"] or ticks > 50:
            break
    assert len(writes) == N_PHOTOS, f"install + catch-up covered {len(writes)} of {N_PHOTOS}"
    assert set(writes.values()) == {1}, "a PhotoEvent was written twice"
    wm = json.loads((oc.state_dir() / "photos.json").read_text())
    assert wm["complete"] and wm["doctor_row"] == "photos"
    oldest = photos_metadata.oldest_asset_date(env["db"])
    assert wm["oldest_at"] == oc.to_iso(oldest), (wm["oldest_at"], oldest)


def test_photos_faces_off_strips_names_and_faces_on_keeps_extract_alls_rule(env, monkeypatch):
    cp = _need("ostler_fda.catchup_photos")
    seen = []

    def capture(d):
        rows = json.loads((d / "photos_events.json").read_text())
        seen.append((rows, (d / "photos_people.json").exists()))
        return {"status": "ok"}

    edge = (NOW - timedelta(days=365)).timestamp()
    item = {"lower": int(edge - 400 * 86400), "upper": int(edge)}
    cp.PhotosAdapter(env["db"], ingest=capture, faces=False).process(item)
    cp.PhotosAdapter(env["db"], ingest=capture, faces=True).process(item)
    off, on = seen
    assert off[0] and not off[1] and all(r["people"] == [] for r in off[0])
    assert on[1] and on[0] and all(r["people"] == ["Jane Doe"] for r in on[0])
    assert len(on[0]) < len(off[0]), "faces on must read only photos with a face, as extract_all does"


def test_photos_declined_at_install_is_never_walked(env, monkeypatch):
    cp = _need("ostler_fda.catchup_photos")
    assert cp.adapters() == [], "Photos was never chosen, yet catch-up would read it"
    (env["home"] / ".ostler" / "state" / "hydrate" / "photos.done").write_text("status=ok\n")
    monkeypatch.setenv("OSTLER_FDA_SOURCES", "safari_history,calendar")
    assert cp.adapters() == [], "OSTLER_FDA_SOURCES without photos_metadata still walked Photos"


def test_photos_windows_are_contiguous_and_end_at_the_oldest_asset(env):
    cp = _need("ostler_fda.catchup_photos")
    a = cp.PhotosAdapter(env["db"])
    cur = a.start_cursor()
    uppers, lowers = [], []
    for _ in range(200):
        b = a.next_batch(cur, 7)
        for w in b.items:
            uppers.append(w["upper"]); lowers.append(w["lower"])
        cur = b.next_cursor
        if b.exhausted:
            break
    assert all(lowers[i] == uppers[i + 1] for i in range(len(lowers) - 1)), "a gap or overlap between windows"
    from ostler_fda import photos_metadata
    assert lowers[-1] < photos_metadata.oldest_asset_date(env["db"]).timestamp() <= uppers[-1]


def test_photos_bounded_cost_measured(env, monkeypatch):
    from ostler_fda import pwg_ingest
    cp = _need("ostler_fda.catchup_photos")
    writes, fake_update = _photo_sink()
    monkeypatch.setattr(pwg_ingest, "_sparql_update", fake_update)
    a = cp.PhotosAdapter(env["db"])
    cur = a.start_cursor()
    b = a.next_batch(cur, a.batch_size)
    t0 = time.perf_counter()
    for w in b.items:
        assert a.process(w)
    dt = time.perf_counter() - t0
    per_window = dt / len(b.items)
    events = len(writes)
    print(f"\n[photos cost] batch={a.batch_size} windows of {cp.WINDOW_DAYS} d; "
          f"{events} events in {dt:.3f}s = {per_window * 1000:.1f} ms/window "
          f"(~{events // len(b.items)} events/window; SPARQL stubbed, real store adds one INSERT per event)")
    assert per_window < 5


# ── AI chats ────────────────────────────────────────────────────────────────

def _cli_args(cli, since):
    return cli._build_arg_parser().parse_args(["--since-days", str(since), "--source", "all", "--json"])


def test_ai_install_path_alone_covers_one_year_then_catchup_covers_all(env, monkeypatch):
    from src.cm052 import cli, wire
    sink: Counter = Counter()

    def fake_post(conv, **kw):
        sink[conv.conversation_id] += 1
        return {"job_id": "j", "status": "queued"}
    monkeypatch.setattr(wire, "post", fake_post)
    monkeypatch.setattr(cli, "_DEFAULT_SINCE_DAYS", 365)

    assert cli.run(_cli_args(cli, 365)) == 0
    install = len(sink)
    print(f"\n[ai chats] install path (pwg-ai-convo --since-days 365) covered {install} of {N_CHATS}")
    assert 0 < install < N_CHATS

    cu = _need("src.cm052.catchup")
    oc = _need("ostler_catchup")
    state_before = Path(os.environ["CM052_STATE_DIR"], "cli_state.json").read_bytes()
    s = oc.run(cu.adapters(), budget_seconds=1e9, busy=lambda: None)
    assert s["sources"]["ai_conversations"]["complete"], s
    assert len(sink) == N_CHATS, f"install + catch-up covered {len(sink)} of {N_CHATS}"
    assert set(sink.values()) == {1}, "a conversation was posted twice"
    assert Path(os.environ["CM052_STATE_DIR"], "cli_state.json").read_bytes() == state_before, \
        "catch-up wrote the forward feed's watermark (the aiconv tick owns it)"
    wm = json.loads((oc.state_dir() / "ai_conversations.json").read_text())
    assert wm["oldest_at"] and wm["oldest_at"][:4] == str(_chat_when(N_CHATS - 1).year)


def test_ai_paused_subscription_holds_the_walk(env, monkeypatch):
    from src.cm052 import wire
    cu = _need("src.cm052.catchup")
    oc = _need("ostler_catchup")
    monkeypatch.setattr(wire, "post", lambda conv, **kw: {"status": "paused",
                                                          "reason": "subscription_inactive"})
    s = oc.run(cu.adapters(), budget_seconds=1e9, busy=lambda: None)
    assert s["sources"]["ai_conversations"]["items"] == 0
    assert s["sources"]["ai_conversations"]["reason"] == "cannot_run:subscription_paused"
    wm = json.loads((oc.state_dir() / "ai_conversations.json").read_text())
    assert "cursor" not in wm and not wm["complete"]


def test_forward_cli_counts_are_unchanged_by_the_shared_step(env, monkeypatch):
    """process_one is the forward feed's own step now; its tallies must not move."""
    from src.cm052 import cli, wire
    outcomes = iter([{"status": "skipped", "reason": "privacy_level_l3"},
                     {"status": "paused", "reason": "subscription_inactive"}] +
                    [{"status": "queued"}] * N_CHATS)
    monkeypatch.setattr(wire, "post", lambda conv, **kw: next(outcomes))
    lines = []
    monkeypatch.setattr(cli, "_emit_json", lambda counts, enabled: lines.append(counts))
    assert cli.run(_cli_args(cli, 0)) == 0
    c = lines[-1]
    # v1.0.111 (CM052 #18 watermark backport): the paused conversation is
    # counted as paused and is NOT handled. This line used to assert
    # written == N_CHATS - 1 and ingested == N_CHATS, i.e. it pinned the defect
    # that counted (and watermarked) a paused conversation as delivered.
    assert c["l3_skipped"] == 1 and c["paused"] == 1, c
    assert c["written"] == N_CHATS - 2 and c["ingested"] == N_CHATS - 1, c


# ── SIGKILL mid-walk, real processes ────────────────────────────────────────

_KILL_PHOTOS = textwrap.dedent('''
    import os, re, signal
    from pathlib import Path
    from ostler_fda import catchup_photos, pwg_ingest
    SINK = Path(os.environ["FX_SINK"]); KILL_AT = int(os.environ.get("FX_KILL_AT_WRITE", "-1"))
    def fake_update(q):
        for uri in re.findall(r"photo_event_([0-9a-f-]+)> a pwg:PhotoEvent", q):
            SINK.mkdir(parents=True, exist_ok=True)
            (SINK / uri).write_text("x")
            with open(SINK.parent / "writes.log", "a") as fh:
                fh.write(uri + "\\n")
            if sum(1 for _ in open(SINK.parent / "writes.log")) == KILL_AT:
                os.kill(os.getpid(), signal.SIGKILL)
    pwg_ingest._sparql_update = fake_update
    def adapters():
        return [catchup_photos.PhotosAdapter(Path(os.environ["FX_DB"]), faces=False)]
''')

_KILL_AI = textwrap.dedent('''
    import os, signal
    from pathlib import Path
    from src.cm052 import catchup, wire
    SINK = Path(os.environ["FX_SINK"]); KILL_AT = int(os.environ.get("FX_KILL_AT_WRITE", "-1"))
    def fake_post(conv, **kw):
        SINK.mkdir(parents=True, exist_ok=True)
        (SINK / conv.conversation_id).write_text("x")
        with open(SINK.parent / "writes.log", "a") as fh:
            fh.write(conv.conversation_id + "\\n")
        if sum(1 for _ in open(SINK.parent / "writes.log")) == KILL_AT:
            os.kill(os.getpid(), signal.SIGKILL)
        return {"status": "queued"}
    wire.post = fake_post
    def adapters():
        return [catchup.AIConversationsAdapter()]
''')


def _kill_env(env, name, body, kill_at):
    fx = env["tmp"] / "fxmod"
    fx.mkdir(exist_ok=True)
    (fx / f"{name}.py").write_text(body)
    e = dict(os.environ)
    e.update({
        "PYTHONPATH": os.pathsep.join([str(LIB), str(VENDOR), str(CM052), str(fx)]
                                      + [p for p in sys.path if p and "site-packages" in p]),
        "FX_SINK": str(env["tmp"] / name / "sink"), "FX_DB": str(env["db"]),
        "FX_KILL_AT_WRITE": str(kill_at),
        "OSTLER_CATCHUP_MAX_LOAD_PER_CORE": "1000", "OSTLER_INTERACTIVE_TTL_SECS": "0",
    })
    return e


def _run_cli(e, name):
    return subprocess.run([sys.executable, "-m", "ostler_catchup", "run", "--family", name,
                           "--adapters", f"{name}:adapters", "--budget-seconds", "600"],
                          env=e, capture_output=True, text=True, timeout=600)


@pytest.mark.parametrize("name,body,kill_at,expected", [
    ("killphotos", _KILL_PHOTOS, 1234, None),
    ("killai", _KILL_AI, 211, None),
], ids=["photos", "ai_chats"])
def test_sigkill_mid_walk_then_restart_has_no_duplicates(env, name, body, kill_at, expected):
    _need("ostler_catchup")
    r1 = _run_cli(_kill_env(env, name, body, kill_at), name)
    assert r1.returncode == -signal.SIGKILL, f"the kill did not land: rc={r1.returncode} {r1.stderr[-500:]}"
    r2 = _run_cli(_kill_env(env, name, body, -1), name)
    assert r2.returncode == 0, r2.stderr[-800:]
    sink = {p.name for p in (env["tmp"] / name / "sink").iterdir()}
    writes = Counter((env["tmp"] / name / "writes.log").read_text().split())
    # Everything older than the 365-day edge is what the catch-up owns.
    edge = (NOW - timedelta(days=365)).timestamp()
    if name == "killphotos":
        expected = sum(1 for i in range(N_PHOTOS) if _photo_when(i).timestamp() <= edge)
    else:
        expected = sum(1 for i in range(N_CHATS) if _chat_when(i).timestamp() < edge)
    assert len(sink) == expected, f"{len(sink)} of {expected} keys after a kill"
    repeated = sum(c - 1 for c in writes.values())
    # The keyed sink holds no duplicate; the repeated WRITES are bounded by one
    # item in flight (a whole window for Photos, one conversation for AI chats).
    assert repeated <= 400 if name == "killphotos" else repeated == 1, repeated
    print(f"\n[{name}] sink={len(sink)} distinct of {expected}; repeated keyed writes={repeated}")


# ── wired: install.sh registers both runners, and their specs resolve ───────

@pytest.mark.parametrize("name,spec,venv", [
    ("30-photos", "ostler_fda.catchup_photos:adapters", "/.venv/bin/python3"),
    ("35-aichats", "src.cm052.catchup:adapters", "/services/cm052/.venv/bin/python3"),
])
def test_install_registers_the_runner_and_its_spec_resolves(name, spec, venv):
    text = (REPO / "install.sh").read_text(encoding="utf-8")
    m = re.search(r"_ostler_catchup_register %s \\\n\s+\"[^\"]*%s\" \\\n\s+\"%s\" 0"
                  % (re.escape(name), re.escape(venv), re.escape(spec)), text)
    assert m, f"install.sh does not register {name} with {spec} on {venv}"
    mod, _, attr = spec.partition(":")
    assert callable(getattr(_need(mod), attr)), f"{spec} does not resolve"


# ── cannot_run is never "all of your history is read" ───────────────────────

class _DeniedConn:
    """A sqlite connection that opens fine and refuses every query, as macOS
    does when Full Disk Access is withdrawn after the file was opened."""

    def __init__(self, real):
        self._real = real
        self.row_factory = None

    def execute(self, *a, **k):
        raise sqlite3.OperationalError("authorization denied")

    def close(self):
        self._real.close()


def _run_photos(oc, adapter, state_dir, monkeypatch):
    monkeypatch.setenv("OSTLER_CATCHUP_STATE_DIR", str(state_dir))
    return oc.run([adapter], budget_seconds=1e9, busy=lambda: None)["sources"]["photos"]


def test_photos_denied_read_is_cannot_run_never_an_empty_library_or_done(env, monkeypatch):
    import ostler_catchup as oc
    from ostler_fda import photos_metadata as pm
    cp = _need("ostler_fda.catchup_photos")
    real_connect = sqlite3.connect
    import types
    # Shim only photos_metadata's view of sqlite3; the catch-up ledger keeps the real one.
    shim = types.SimpleNamespace(**{k: getattr(sqlite3, k) for k in dir(sqlite3) if not k.startswith("__")})
    shim.connect = lambda *a, **k: _DeniedConn(real_connect(*a, **k))
    monkeypatch.setattr(pm, "sqlite3", shim)
    with pytest.raises(pm.PhotosCannotRead):
        pm.oldest_asset_date(env["db"])
    row = _run_photos(oc, cp.PhotosAdapter(env["db"]), env["tmp"] / "st", monkeypatch)
    assert not row["complete"], "a denied read was reported as a finished walk (Doctor: All of your history is read)"
    assert row["reason"] == "cannot_run:read_denied"
    wm = json.loads((env["tmp"] / "st" / "photos.json").read_text())
    assert wm["complete"] is False and wm["cannot_run"] == "read_denied"


def test_photos_genuinely_empty_library_is_still_complete(env, monkeypatch):
    """Control: the fix must not turn a real empty library into a permanent cannot-run."""
    import ostler_catchup as oc
    cp = _need("ostler_fda.catchup_photos")
    empty = env["tmp"] / "Empty.sqlite"
    c = sqlite3.connect(empty)
    c.executescript("CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZDATECREATED REAL, "
                    "ZLATITUDE REAL, ZLONGITUDE REAL, ZTRASHEDSTATE INTEGER);")
    c.commit(); c.close()
    row = _run_photos(oc, cp.PhotosAdapter(empty), env["tmp"] / "st", monkeypatch)
    assert row["complete"] and row["reason"] == "complete"


def test_photos_unrecognised_layout_is_cannot_run_not_a_done_window(env, monkeypatch):
    import ostler_catchup as oc
    from ostler_fda import photos_metadata as pm
    cp = _need("ostler_fda.catchup_photos")
    # (a) no known asset table at all
    alien = env["tmp"] / "Alien.sqlite"
    c = sqlite3.connect(alien)
    c.executescript("CREATE TABLE ZSOMETHINGNEW (Z_PK INTEGER PRIMARY KEY);")
    c.commit(); c.close()
    with pytest.raises(pm.PhotosCannotRead):
        pm.oldest_asset_date(alien)
    row = _run_photos(oc, cp.PhotosAdapter(alien), env["tmp"] / "st_a", monkeypatch)
    assert not row["complete"] and row["reason"].startswith("cannot_run:")
    # (b) the asset table reads, but none of the event layouts match: every
    # window used to come back [] and be written down as done.
    half = env["tmp"] / "Half.sqlite"
    c = sqlite3.connect(half)
    c.executescript("CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZDATECREATED REAL, "
                    "ZLATITUDE REAL, ZLONGITUDE REAL, ZTRASHEDSTATE INTEGER);")
    c.execute("INSERT INTO ZASSET VALUES (1, ?, 0, 0, 0)",
              ((NOW - timedelta(days=900)).timestamp() - MAC_EPOCH,))
    c.commit(); c.close()
    assert pm.extract_photo_events(half, since_days=3650) == [], "default behaviour must stay [] for the install path"
    row = _run_photos(oc, cp.PhotosAdapter(half), env["tmp"] / "st_b", monkeypatch)
    assert not row["complete"], "unrecognised event layout was recorded as done windows"
    assert row["reason"] == "cannot_run:schema_unrecognised"
    ledger_db = env["tmp"] / "st_b" / "ledger.sqlite"
    n = sqlite3.connect(ledger_db).execute("SELECT COUNT(*) FROM done").fetchone()[0]
    assert n == 0, f"{n} windows were written to the ledger as done"


# ── an outage of the sink is not a poison attempt (Archie re-review of #2903) ─

def test_photos_an_oxigraph_outage_is_not_a_failed_window(env):
    import httpx
    cp = _need("ostler_fda.catchup_photos")
    req = httpx.Request("POST", "http://127.0.0.1:1/update")

    def ingest_down(d):
        raise httpx.ConnectError("synthetic", request=req)

    def ingest_503(d):
        raise httpx.HTTPStatusError("synthetic", request=req, response=httpx.Response(503, request=req))

    def ingest_400(d):
        raise httpx.HTTPStatusError("synthetic", request=req, response=httpx.Response(400, request=req))

    def item_for(a):
        return a.next_batch(a.start_cursor(), 1).items[0]

    for ingest in (ingest_down, ingest_503):
        a = cp.PhotosAdapter(env["db"], ingest=ingest)
        with pytest.raises(ConnectionError):
            a.process(item_for(a))
    # control: the store answered and refused this window (400): not an outage
    a = cp.PhotosAdapter(env["db"], ingest=ingest_400)
    with pytest.raises(httpx.HTTPStatusError):
        a.process(item_for(a))


def test_ai_a_gateway_outage_is_not_a_failed_conversation(env, monkeypatch):
    import httpx
    from src.cm052 import wire
    cu = _need("src.cm052.catchup")
    req = httpx.Request("POST", "http://127.0.0.1:1/")
    a = cu.adapters()[0]
    item = a.next_batch(None, 1).items[0]

    def raiser(exc):
        def post(conv, **kw):
            raise exc
        return post

    monkeypatch.setattr(wire, "post", raiser(httpx.ConnectError("synthetic", request=req)))
    with pytest.raises(ConnectionError):
        a.process(item)
    monkeypatch.setattr(wire, "post", raiser(httpx.HTTPStatusError(
        "synthetic", request=req, response=httpx.Response(503, request=req))))
    with pytest.raises(ConnectionError):
        a.process(item)
    # control: a 400 is the gateway refusing THIS conversation
    monkeypatch.setattr(wire, "post", raiser(httpx.HTTPStatusError(
        "synthetic", request=req, response=httpx.Response(400, request=req))))
    with pytest.raises(httpx.HTTPStatusError):
        a.process(item)


def test_ai_a_paused_subscription_never_counts_toward_quarantine(env, monkeypatch):
    from src.cm052 import wire
    cu = _need("src.cm052.catchup")
    oc = _need("ostler_catchup")
    monkeypatch.setattr(wire, "post", lambda conv, **kw: {"status": "paused",
                                                          "reason": "subscription_inactive"})
    for _ in range(oc.MAX_ITEM_ATTEMPTS + 2):
        s = oc.run(cu.adapters(), budget_seconds=1e9, busy=lambda: None)
    row = s["sources"]["ai_conversations"]
    assert row["quarantined"] == 0 and row["reason"] == "cannot_run:subscription_paused", row
