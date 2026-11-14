#!/usr/bin/env python3
"""End-to-end: every writer in the channel manifest finishes, and the CM044
reader shows EXACTLY 100.

Runs each REAL writer over a tiny synthetic input, in a temp HOME:

  contacts  lib/settling_progress.sh   settling_complete / settling_skip
  emails    lib/settling_progress.sh   settling_complete / settling_skip
  calendar  vendor/ostler_fda/calendar.py          extract_events
  messages  vendor/ostler_fda/imessage.py          extract_conversations
  messages  vendor/ostler_fda/whatsapp_history.py  extract_conversations

and then reads the shards with CM044 compiler/hydration.py (read_progress +
settling_progress), the code that draws the Setting-up bar. The channel set is
lib/settling_channels.json, the same file the reader uses on a box.

Scenarios
  complete   every source has data; each writer completes            -> 100
  nothing    no calendar, no chat.db, no WhatsApp, no contacts/mail  -> 100
             (every channel skipped with a plain reason code)
  control    the same shards with the markers stripped (done==total) -> NOT 100
             (proves the reader assertion can fail)
  partial    all writers but one                                     -> NOT 100

CM044 reader: $CM044_ROOT (a checkout holding compiler/hydration.py). Absent =
CANNOT-RUN for the reader assertions, printed loudly, exit 3 (0 only when
SETTLING_E2E_READER_OPTIONAL=1, which the CI wrapper sets, with a ::warning::). Never a
PASS. The tree under test is $SETTLING_TREE (default: this checkout).

Exit 0 all pass, 1 any fail, 3 CANNOT-RUN.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = Path(os.environ.get("SETTLING_TREE") or REPO)
CM044 = os.environ.get("CM044_ROOT", "")

passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  [PASS] {msg}")


def bad(msg):
    global failed
    failed += 1
    print(f"  [FAIL] {msg}")


def check(cond, msg):
    (ok if cond else bad)(msg)


MAC = 978307200


def mac_now(days_ago=0):
    return time.time() - MAC - days_ago * 86400


# ---- synthetic inputs ------------------------------------------------------
def make_calendar(path, n):
    c = sqlite3.connect(path)
    c.executescript("""
        CREATE TABLE CalendarItem(ROWID INTEGER PRIMARY KEY, summary TEXT,
          start_date REAL, end_date REAL, all_day INT, description TEXT,
          location_id INT, calendar_id INT, has_recurrences INT);
        CREATE TABLE Location(ROWID INTEGER PRIMARY KEY, title TEXT);
        CREATE TABLE Calendar(ROWID INTEGER PRIMARY KEY, title TEXT);
        INSERT INTO Calendar VALUES (1, 'Home');
    """)
    for i in range(n):
        c.execute("INSERT INTO CalendarItem VALUES (?,?,?,?,0,NULL,NULL,1,0)",
                  (i + 1, f"Event {i}", mac_now(2 + i), mac_now(2 + i) + 3600))
    c.commit()
    c.close()


def make_chatdb(path):
    """Two chats in the window (3 + 2 messages) and one OUTSIDE it (4 messages),
    so done < total for the run: the B3 case."""
    c = sqlite3.connect(path)
    c.executescript("""
        CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, style INT);
        CREATE TABLE message(ROWID INTEGER PRIMARY KEY, date INT);
        CREATE TABLE chat_message_join(chat_id INT, message_id INT);
        CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE chat_handle_join(chat_id INT, handle_id INT);
        INSERT INTO handle VALUES (1, 'a@example.test'), (2, 'b@example.test'), (3, 'c@example.test');
    """)
    mid = 0
    for chat, (nmsg, age) in enumerate([(3, 3), (2, 5), (4, 900)], start=1):
        c.execute("INSERT INTO chat VALUES (?,?,?,45)", (chat, f"g{chat}", None))
        c.execute("INSERT INTO chat_handle_join VALUES (?,?)", (chat, chat))
        for _ in range(nmsg):
            mid += 1
            c.execute("INSERT INTO message VALUES (?,?)", (mid, int(mac_now(age))))
            c.execute("INSERT INTO chat_message_join VALUES (?,?)", (chat, mid))
    c.commit()
    c.close()


def make_whatsapp(path):
    """Two DM sessions in the window (3 + 2 messages), one outside (4)."""
    c = sqlite3.connect(path)
    c.executescript("""
        CREATE TABLE ZWACHATSESSION(Z_PK INTEGER PRIMARY KEY, ZGROUPINFO INT,
          ZCONTACTJID TEXT, ZLASTMESSAGEDATE REAL);
        CREATE TABLE ZWAMESSAGE(Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INT,
          ZMESSAGEDATE REAL, ZISFROMME INT);
        CREATE TABLE ZWAGROUPMEMBER(Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INT,
          ZMEMBERJID TEXT, ZISACTIVE INT);
    """)
    mid = 0
    for pk, (nmsg, age) in enumerate([(3, 3), (2, 5), (4, 900)], start=1):
        c.execute("INSERT INTO ZWACHATSESSION VALUES (?,?,?,?)",
                  (pk, None, f"4470000000{pk}@s.whatsapp.net", mac_now(age)))
        for _ in range(nmsg):
            mid += 1
            c.execute("INSERT INTO ZWAMESSAGE VALUES (?,?,?,0)", (mid, pk, mac_now(age)))
    c.commit()
    c.close()


# ---- runners -----------------------------------------------------------------
def env_for(home):
    e = dict(os.environ)
    e["HOME"] = str(home)
    e["OSTLER_STATE_DIR"] = str(Path(home) / ".ostler" / "state")
    e.pop("PYTHONPATH", None)
    return e


def run_py(home, code):
    r = subprocess.run(
        [sys.executable, "-I", "-c",
         "import sys; sys.path.insert(0, %r)\n%s" % (str(TREE / "vendor"), code)],
        env=env_for(home), capture_output=True, text=True)
    return r


def run_sh(home, body):
    return subprocess.run(
        ["bash", "-c", 'source "%s"\n%s' % (TREE / "lib" / "settling_progress.sh", body)],
        env=env_for(home), capture_output=True, text=True)


def shards(home):
    d = Path(home) / ".ostler" / "state" / "settling_progress.d"
    return {p.name: json.loads(p.read_text()) for p in sorted(d.glob("*.json"))} if d.is_dir() else {}


def run_writers(home, scenario, only=None):
    """Run the writers; `only` restricts to a set of names. Returns failures."""
    home = Path(home)
    full = scenario == "complete"
    if full:
        (home / "Library/Messages").mkdir(parents=True, exist_ok=True)
        (home / "Library/Group Containers/group.net.whatsapp.WhatsApp.shared").mkdir(parents=True, exist_ok=True)
        if not (home / "cal.sqlitedb").exists():
            make_calendar(home / "cal.sqlitedb", 3)
            make_chatdb(home / "Library/Messages/chat.db")
            make_whatsapp(home / "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
    wa = home / "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    cal = home / ("cal.sqlitedb" if full else "absent.sqlitedb")
    steps = {
        "calendar": "from pathlib import Path\nfrom ostler_fda import calendar as m\n"
                    "try: m.extract_events(db_path=Path(%r))\nexcept (FileNotFoundError, PermissionError): pass\n" % str(cal),
        "imessage": "from pathlib import Path\nfrom ostler_fda import imessage as m\n"
                    "try: m.extract_conversations(db_path=Path(%r), since_days=365, min_messages=2)\n"
                    "except (FileNotFoundError, PermissionError): pass\n" % str(home / "Library/Messages/chat.db"),
        "whatsapp": "from pathlib import Path\nfrom ostler_fda import whatsapp_history as m\n"
                    "try: m.extract_conversations(db_path=Path(%r), since_days=365)\n"
                    "except (FileNotFoundError, PermissionError): pass\n" % str(wa),
        "contacts": None, "emails": None,
    }
    bad_runs = []
    for name, code in steps.items():
        if only is not None and name not in only:
            continue
        if code is not None:
            r = run_py(home, code)
        elif name == "contacts":
            r = run_sh(home, "settling_report_measured contacts 7 false; settling_complete contacts" if full
                       else "settling_skip contacts no_contacts")
        else:
            r = run_sh(home, "settling_report_measured emails 5 false; settling_complete emails" if full
                       else "settling_skip emails no_messages")
        if r.returncode != 0:
            bad_runs.append((name, r.returncode, (r.stderr or r.stdout)[-300:]))
    return bad_runs


# ---- reader ------------------------------------------------------------------
def load_reader():
    if not CM044 or not (Path(CM044) / "compiler" / "hydration.py").is_file():
        return None
    os.environ["SETTLING_CHANNELS_MANIFEST"] = str(TREE / "lib" / "settling_channels.json")
    sys.path.insert(0, CM044)
    import importlib
    return importlib.import_module("compiler.hydration")


cannot_run = 0


def rcheck(hyd, cond, msg):
    """A reader assertion: PASS/FAIL with the reader, CANNOT-RUN (never PASS) without."""
    global cannot_run
    if hyd is None:
        cannot_run += 1
        print(f"  [CANNOT-RUN] {msg}")
    else:
        check(cond, msg)


def pct_of(hyd, home):
    if hyd is None:
        return None, None
    prog = hyd.read_progress(Path(home) / ".ostler" / "state")
    res = hyd.settling_progress(prog)
    return None if res is None else res["pct"], res


def main():
    print("== test_settling_writers_end_to_end ==")
    print(f"  tree: {TREE}")
    hyd = load_reader()
    if hyd is None:
        print("  [CANNOT-RUN] CM044 reader not found (set CM044_ROOT to a checkout holding "
              "compiler/hydration.py). Writer and shard assertions still run; the bar "
              "assertions below are CANNOT-RUN, which is not a PASS.")

    # complete scenario
    with tempfile.TemporaryDirectory() as home:
        errs = run_writers(home, "complete", only={"calendar", "imessage", "whatsapp", "contacts"})
        check(not errs, f"scenario complete: four writers ran clean {errs or ''}")
        p_partial, _ = pct_of(hyd, home)
        rcheck(hyd, p_partial is not None and p_partial < 100,
              f"partial (emails not yet finished): bar is {p_partial}, not 100")
        errs = run_writers(home, "complete", only={"emails"})
        check(not errs, f"emails writer ran clean {errs or ''}")
        sh = shards(home)
        names = sorted(sh)
        check(names == ["calendar.json", "contacts.json", "emails.json",
                        "messages.imessage.json", "messages.whatsapp.json"],
              f"one shard per writer: {names}")
        for n, s in sh.items():
            check(s.get("complete") is True, f"{n}: complete marker set (done={s['done']} total={s['total']})")
        # B3: the windowed messages shards carry a marker although old chats exist
        pct, res = pct_of(hyd, home)
        rcheck(hyd, pct == 100, f"scenario complete: CM044 reader shows exactly 100 (got {pct})")

        # control: strip the markers, keep every count. Must NOT be 100.
        d = Path(home) / ".ostler" / "state" / "settling_progress.d"
        for f in d.glob("*.json"):
            s = json.loads(f.read_text())
            s["complete"] = False
            s["skip_reason"] = ""
            s["done"] = s["total"] = max(s["total"], 1)
            f.write_text(json.dumps(s))
        pct_c, _ = pct_of(hyd, home)
        rcheck(hyd, pct_c is not None and pct_c < 100,
              f"control: done==total with no marker reads {pct_c}, not 100 (the assertion can fail)")

    # nothing-available scenario
    with tempfile.TemporaryDirectory() as home:
        errs = run_writers(home, "nothing")
        check(not errs, f"scenario nothing: all writers ran clean {errs or ''}")
        sh = shards(home)
        check(sorted(sh) == ["calendar.json", "contacts.json", "emails.json",
                             "messages.imessage.json", "messages.whatsapp.json"],
              f"nothing: one shard per writer: {sorted(sh)}")
        for n, s in sh.items():
            check(bool(s.get("skip_reason")) and not s.get("needs_source"),
                  f"{n}: skipped with reason {s.get('skip_reason')!r}")
        pct, _ = pct_of(hyd, home)
        rcheck(hyd, pct == 100, f"scenario nothing: CM044 reader shows exactly 100 (got {pct})")

    print(f"\n{passed} passed, {failed} failed, {cannot_run} CANNOT-RUN")
    if failed:
        return 1
    if cannot_run:
        if os.environ.get("SETTLING_E2E_READER_OPTIONAL") == "1":
            print("::warning::settling e2e: CM044 reader absent on this runner; "
                  "bar assertions CANNOT-RUN (run locally with CM044_ROOT)")
            return 0
        return 3
    return 0


sys.exit(main())
