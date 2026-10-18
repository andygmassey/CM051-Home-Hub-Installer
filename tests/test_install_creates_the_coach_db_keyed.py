"""The coach database exists, encrypted, with its schema, from install onward.

Walk #31 (v1.0.108). CM048 created ~/.ostler/coach/observations.db lazily, on
the first coaching row. Since #2931 a one-speaker capture is a memo and is
never coached, so on many fresh installs the db never existed. Then:

  (a) the walk probe's forget connected to the path, created a 0-byte file and
      failed "no such table: observations";
  (b) GET /api/v1/coach/recent returned HTTP 500 once that stray file existed;
  (c) context-refresh exited 3 (EXIT_DEGRADED) on every tick.

What this proves, each through the REAL component:

  1. install.sh's _ostler_init_coach_db (lifted from install.sh, run under
     /bin/bash) creates the db KEYED: it is not openable as plain SQLite,
     while a plaintext control db IS, and the keyed open shows the table.
  2. a re-run keeps a row the REAL CM048 writer (_write_coach) put there.
  3. the installer DDL equals the writer's DDL (sqlite_master, normalised).
  4. no key means no file at all, never a plaintext one.
  5. the REAL ical-server, on a fresh install, answers /api/v1/coach/recent
     200 empty: with no file, with a 0-byte stray, with the installed db.
  6. the REAL probe forget on a fresh install creates no file and prints a
     clean result (no "error").

Synthetic data only.
"""
from __future__ import annotations

import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parent.parent
INSTALL_SH = ROOT / "install.sh"
STRINGS = ROOT / "install.sh.strings.en-GB.sh"
SERVER = ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
PROBE = ROOT / "scripts" / "box_walk_probes" / "lib" / "db_key_probe.py"
KEY = "a1" * 32
TOKEN = "fixture-service-token"
USER = "fixtureowner"
PLAIN_HEADER = b"SQLite format 3\x00"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _require_sqlcipher():
    try:
        from sqlcipher3 import dbapi2  # noqa: F401
    except ImportError:
        pytest.fail("CANNOT-RUN (harness, not product): sqlcipher3 is not installed, "
                    "so encryption cannot be graded")


def _env(home: Path, key: str | None = KEY) -> dict:
    env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
    for k in ("OSTLER_DB_KEY", "OSTLER_DB_KEY_FILE", "OSTLER_COACH_DB", "OSTLER_DIR",
              "OSTLER_HOME", "PWG_HOME"):
        env.pop(k, None)
    env.update({"HOME": str(home), "NO_PROXY": "*", "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONPATH": os.pathsep.join([str(ROOT / "vendor" / "cm041"),
                                               str(ROOT / "vendor")])})
    if key:
        env["OSTLER_DB_KEY"] = key
    return env


def _lift_init() -> str:
    text = INSTALL_SH.read_text()
    m = re.search(r"# BEGIN _ostler_init_coach_db\n(.*?)\n\s*# END _ostler_init_coach_db", text, re.S)
    assert m, "install.sh no longer carries the _ostler_init_coach_db block"
    return m.group(1)


def run_init(home: Path, db: Path, key: str | None = KEY) -> subprocess.CompletedProcess:
    script = "\n".join([
        "set -eE", "trap 'echo ERR-TRAP-FIRED; exit 99' ERR",
        f"source '{STRINGS}'",
        'info() { echo "INFO:$*"; }', 'warn() { echo "WARN:$*"; }',
        _lift_init(),
        f"_ostler_init_coach_db '{sys.executable}' '{db}' ''",
        "echo RETURNED",
    ])
    return subprocess.run(["/bin/bash", "-c", script], env=_env(home, key),
                          capture_output=True, text=True, timeout=60)


def raw_plain_open(db: Path):
    """True when stdlib sqlite3 (no key) can read the schema."""
    conn = sqlite3.connect(str(db))
    try:
        conn.execute("SELECT count(*) FROM sqlite_master").fetchone()
        return True
    except sqlite3.DatabaseError:
        return False
    finally:
        conn.close()


def keyed(db: Path):
    sys.path.insert(0, str(ROOT / "vendor"))
    from ostler_security.database import get_db_connection
    return get_db_connection(str(db), KEY)


def _schema(db: Path) -> str:
    conn = keyed(db)
    try:
        sql = conn.execute("SELECT sql FROM sqlite_master WHERE name='observations'").fetchone()[0]
    finally:
        conn.close()
    return " ".join(sql.split())


@pytest.fixture
def home():
    _require_sqlcipher()
    with tempfile.TemporaryDirectory() as d:
        yield Path(d)


def _db(home: Path) -> Path:
    return home / ".ostler" / "coach" / "observations.db"


# ── 1-4: the installer ────────────────────────────────────────────────

def test_control_a_plaintext_db_is_openable_without_a_key(home):
    p = home / "plain.db"
    c = sqlite3.connect(str(p))
    c.execute("CREATE TABLE t (x)")
    c.commit()
    c.close()
    assert p.read_bytes()[:16] == PLAIN_HEADER
    assert raw_plain_open(p) is True


def test_install_creates_an_encrypted_db_with_the_observations_table(home):
    db = _db(home)
    r = run_init(home, db)
    assert "RETURNED" in r.stdout and "ERR-TRAP-FIRED" not in r.stdout, r.stdout + r.stderr
    assert "INFO:" in r.stdout and "created rows=0" in r.stdout, r.stdout
    assert db.exists() and db.stat().st_size > 0
    assert db.read_bytes()[:16] != PLAIN_HEADER
    assert raw_plain_open(db) is False, "the coach db opened as plain SQLite with no key"
    conn = keyed(db)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(observations)")]
    conn.close()
    assert "conversation_id" in cols and "user_id" in cols, cols


def _writer():
    sys.path.insert(0, str(ROOT / "vendor" / "cm048_pipeline"))
    sys.path.insert(0, str(ROOT / "vendor"))
    os.environ.setdefault("OSTLER_DB_KEY", KEY)
    from src import ingest  # noqa: E402
    return ingest


def _write_one(home: Path, db: Path, cid: str):
    ingest = _writer()
    state = home / "state" / cid
    state.mkdir(parents=True)
    (state / "04_coaching.json").write_text(json.dumps({
        "tone": "warm", "tip": {"text": "a synthetic tip"}, "confidence": 0.5}))
    saved = ingest._ENCRYPTION_KEY
    ingest._ENCRYPTION_KEY = KEY
    try:
        n = ingest._write_coach(state, cid, SimpleNamespace(coach_db_path=db, user_id=USER), False)
    finally:
        ingest._ENCRYPTION_KEY = saved
    assert n == 1


def test_a_rerun_keeps_the_writers_rows(home):
    db = _db(home)
    assert "created" in run_init(home, db).stdout
    _write_one(home, db, "conv-synthetic-1")
    r = run_init(home, db)
    assert "kept rows=1" in r.stdout, r.stdout + r.stderr
    conn = keyed(db)
    assert conn.execute("SELECT count(*) FROM observations").fetchone()[0] == 1
    conn.close()


def test_the_installer_ddl_is_the_writers_ddl(home):
    inst = _db(home)
    run_init(home, inst)
    w = home / "writer" / "observations.db"
    _write_one(home, w, "conv-synthetic-2")
    assert _schema(inst) == _schema(w)


def test_no_key_creates_no_file_and_never_a_plaintext_one(home):
    db = _db(home)
    r = run_init(home, db, key=None)
    assert "RETURNED" in r.stdout and "WARN:" in r.stdout and "no database key" in r.stdout, r.stdout
    assert not db.exists()


def test_a_zero_byte_stray_is_encrypted_by_the_installer(home):
    db = _db(home)
    db.parent.mkdir(parents=True)
    db.write_bytes(b"")
    r = run_init(home, db)
    assert "created rows=0" in r.stdout, r.stdout + r.stderr
    assert raw_plain_open(db) is False


# ── 5: the real ical-server ───────────────────────────────────────────

def _port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _coach_recent(home: Path, db: Path):
    port = _port()
    env = _env(home)
    env.update({"OSTLER_API_PORT": str(port), "OSTLER_SERVICE_TOKEN": TOKEN,
                "USER_ID": USER, "USER_NAME": "Sam Smith", "OSTLER_COACH_DB": str(db),
                "PWG_HOME": str(home / "pwg"), "WIKI_BASE_URL": "http://wiki.example",
                "OXIGRAPH_URL": "http://127.0.0.1:9", "QDRANT_URL": "http://127.0.0.1:9",
                "EMBED_OLLAMA_URL": "http://127.0.0.1:9"})
    proc = subprocess.Popen([sys.executable, str(SERVER)], env=env, cwd=str(SERVER.parent),
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    url = "http://127.0.0.1:%d" % port
    try:
        for _ in range(150):
            if proc.poll() is not None:
                pytest.fail("ical-server exited: " + proc.stderr.read().decode()[-800:])
            try:
                OPENER.open(url + "/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.1)
        else:
            pytest.fail("ical-server did not come up")
        req = urllib.request.Request(url + "/api/v1/coach/recent?user_id=" + USER,
                                     headers={"Authorization": "Bearer " + TOKEN})
        try:
            with OPENER.open(req, timeout=15) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()
    finally:
        proc.kill()
        proc.wait(5)


def test_coach_recent_fresh_install_no_file_is_200_empty(home):
    code, body = _coach_recent(home, _db(home))
    assert code == 200, body
    assert body["observations"] == [] and body["db_state"] == "absent"


def test_coach_recent_zero_byte_stray_is_200_empty(home):
    db = _db(home)
    db.parent.mkdir(parents=True)
    db.write_bytes(b"")
    code, body = _coach_recent(home, db)
    assert code == 200, body
    assert body["observations"] == [] and body["db_state"] == "empty"


def test_coach_recent_keyed_db_without_the_table_is_200_empty(home):
    db = _db(home)
    db.parent.mkdir(parents=True)
    c = keyed(db)
    c.execute("CREATE TABLE unrelated (x)")
    c.commit()
    c.close()
    code, body = _coach_recent(home, db)
    assert code == 200, body
    assert body["observations"] == [] and body["db_state"] == "no_table"


def test_coach_recent_after_install_is_200_empty(home):
    db = _db(home)
    run_init(home, db)
    code, body = _coach_recent(home, db)
    assert code == 200, body
    assert body["observations"] == [] and body.get("count") == 0


def test_coach_recent_wrong_key_stays_loud(home):
    """Negative control: tolerance must not swallow a real read failure."""
    db = _db(home)
    db.parent.mkdir(parents=True)
    sys.path.insert(0, str(ROOT / "vendor"))
    from ostler_security.database import get_db_connection
    c = get_db_connection(str(db), "b2" * 32)
    c.execute("CREATE TABLE observations (x)")
    c.commit()
    c.close()
    code, _ = _coach_recent(home, db)
    assert code == 500


# ── 6: the real probe forget ──────────────────────────────────────────

def _forget(home: Path):
    r = subprocess.run([sys.executable, str(PROBE), "forget", "--token", "synthetic-token"],
                       env=_env(home), capture_output=True, text=True, timeout=60)
    return json.loads(r.stdout.strip().splitlines()[-1])


def test_forget_on_a_fresh_install_creates_no_file_and_is_clean(home):
    out = _forget(home)
    assert not _db(home).exists(), "forget created a file at the coach db path"
    assert "error" not in out and out["db_state"] == "absent", out


def test_forget_against_the_installed_db_deletes_cleanly(home):
    run_init(home, _db(home))
    out = _forget(home)
    assert out.get("deleted") is True and out["before"] == 0 and out["after"] == 0, out
    assert raw_plain_open(_db(home)) is False


def test_forget_with_the_coach_dir_present_leaves_no_stray_file(home):
    """The walk #31 shape: the coach directory exists, the db does not."""
    _db(home).parent.mkdir(parents=True)
    out = _forget(home)
    assert not _db(home).exists(), "forget created a stray file at the coach db path"
    assert "error" not in out and out["db_state"] == "absent", out
