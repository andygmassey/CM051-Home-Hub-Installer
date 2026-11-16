"""followup_keys_match_chat_threads: can "mark a reminder done when the owner
follows up" ever fire on this box?

ostler-assistant #509 completes a pushed reminder when the owner messages the
reminder's own thread. It matches CM048's `thread_key` (CM051 #2802,
`reminders_push.thread_key_for`: a hash of the conversation's counterpart
identities) against the same hash of each chat.db chat's handles. If CM048
built its keys from display names instead of handles, nothing ever matches and
the feature is silently dead. This probe measures exactly that.

READ-ONLY, and never seeds. It reads one thing: the daemon's own measurement in
`GET /api/status` -> `followup` (the daemon has Full Disk Access to chat.db;
the ssh user usually does not, so the daemon does the matching and publishes
counts only: never a key, handle or name).

Two halves, as every probe here:
  BOX side (`box`) runs ON the box over loopback and prints ONE JSON line of
  counts and booleans.
  JUDGE side (`judge FILE`) prints ok/FAIL/CANNOT/ADVISORY lines and exits
  0 pass, 1 fail, 78 cannot-run.

Verdicts:
  PASS        at least one keyed map row matches a chat.db chat (denominator
              printed).
  FAIL        3 or more keyed rows and none match (the handle-versus-display-
              name case), or the sweep is not enabled in the running daemon.
  CANNOT-RUN  no keyed rows, fewer than 3 with none matching, the daemon has
              no Full Disk Access to chat.db, the daemon does not publish
              `followup` (build without #509), or the daemon did not answer.
  ADVISORY    rows Ostler completed on a follow-up, from real activity only.

Walk residue: rows the walk's own cleanup left behind (source_session_id
ostler-walk-todo-*) are subtracted from the census, counted and printed. Nothing
else is excluded. Zero rows left after exclusion is CANNOT-RUN, never PASS.

`--self-test` drives the judge over a good capture and one mutant per verdict;
every mutant must land on its own verdict.

Python 3.9 compatible (the box's /usr/bin/python3).
"""
import json
import os
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
HOME = os.path.expanduser("~")
SECRETS = os.environ.get("OSTLER_SECRETS_DIR", os.path.join(HOME, ".ostler", "secrets"))
GATEWAY = os.environ.get("OSTLER_PROBE_GATEWAY", "http://127.0.0.1:8000").rstrip("/")
CHAT_DB = os.path.join(HOME, "Library", "Messages", "chat.db")
FAIL_FLOOR = 3

# Walk residue. A walk whose cleanup fails leaves reminders_map rows whose
# source_session_id is ostler-walk-todo-<pid>-<ts> (and its -1to1 twin). Their
# synthetic keys can never match chat.db, so they are excluded by that prefix
# and by nothing wider. The daemon's census has no source filter (pinned daemon
# d323c07c), so the exclusion is made here, on the box, read-only.
WALK_GLOB = "ostler-walk-todo-*"
KEYED_SQL = "status IN ('pushed', 'completed') AND thread_key IS NOT NULL AND thread_key != ''"

COUNT_FIELDS = ("keyed_rows", "keys_matching_one_to_one", "keys_matching_group",
                "completed_by_followup", "reopened", "chat_keyed_rows")
BOOL_FIELDS = ("available", "measured", "enabled", "chat_db_readable")


def _secret(name):
    try:
        with open(os.path.join(SECRETS, name), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _ssh_user_can_read_chat_db():
    """Informational only: can THIS (ssh) user read chat.db? A plain open of
    the header, never sqlite, so nothing (no -shm, no -wal) is ever written."""
    try:
        with open(CHAT_DB, "rb") as fh:
            return "yes" if fh.read(16).startswith(b"SQLite format 3") else "no (not a SQLite file)"
    except OSError as e:
        return "no (%s)" % (e.strerror or e.__class__.__name__)


def _walk_residue():
    """Read reminders_map.db READ-ONLY (a mode=ro URI, never written) and count
    the walk-synthetic rows the daemon's census also counts. Counts and
    booleans only: never a key, source id or name."""
    path = os.path.join(HOME, ".ostler", "reminders_map.db")
    if not os.path.exists(path):
        return {"walk_db_readable": False, "walk_db_reason": "no reminders_map.db under the ssh user's ~/.ostler"}
    import sqlite3
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5.0)
    except sqlite3.Error as e:
        return {"walk_db_readable": False, "walk_db_reason": "read-only open failed (%s)" % e.__class__.__name__}
    try:
        cols = set(r[1] for r in conn.execute("PRAGMA table_info(reminders_map)"))
        if not {"source_session_id", "status", "thread_key"} <= cols:
            return {"walk_db_readable": False, "walk_db_reason": "reminders_map has no thread_key column"}
        excl = conn.execute("SELECT COUNT(*) FROM reminders_map WHERE source_session_id GLOB ? AND " + KEYED_SQL,
                            (WALK_GLOB,)).fetchone()[0]
        total = conn.execute("SELECT COUNT(*) FROM reminders_map WHERE " + KEYED_SQL).fetchone()[0]
        # A walk key equal to a real row's key cannot be excluded by key.
        collide = conn.execute(
            "SELECT COUNT(*) FROM reminders_map w WHERE w.source_session_id GLOB ? "
            "AND w.status IN ('pushed', 'completed') AND w.thread_key IS NOT NULL AND w.thread_key != '' "
            "AND EXISTS (SELECT 1 FROM reminders_map r WHERE r.thread_key = w.thread_key "
            "AND NOT (r.source_session_id GLOB ?) AND r.status IN ('pushed', 'completed'))",
            (WALK_GLOB, WALK_GLOB)).fetchone()[0]
    except sqlite3.Error as e:
        return {"walk_db_readable": False, "walk_db_reason": "query failed (%s)" % e.__class__.__name__}
    finally:
        conn.close()
    return {"walk_db_readable": True, "walk_synthetic_keyed": excl,
            "walk_synthetic_collisions": collide, "db_keyed_rows": total}


def box():
    """Read GET /api/status.followup. Counts and booleans only."""
    import urllib.request
    import urllib.error
    out = {"ssh_user_reads_chat_db": _ssh_user_can_read_chat_db()}
    tok = _secret("zeroclaw_admin_token")
    if not tok:
        out["cannot"] = "no admin token at ~/.ostler/secrets/zeroclaw_admin_token; the daemon's status was not read"
        return out
    req = urllib.request.Request(GATEWAY + "/api/status", headers={"Authorization": "Bearer " + tok})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=20) as r:
            body = json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        out["cannot"] = "the daemon refused GET /api/status (HTTP %d)" % e.code
        return out
    except (OSError, ValueError) as e:
        out["cannot"] = "the daemon did not answer GET /api/status (%s)" % e.__class__.__name__
        return out
    fu = (body or {}).get("followup") if isinstance(body, dict) else None
    if not isinstance(fu, dict):
        out["cannot"] = "GET /api/status has no `followup` block: this daemon predates ostler-assistant #509"
        return out
    for k in BOOL_FIELDS:
        if k in fu:
            out[k] = bool(fu[k])
    for k in COUNT_FIELDS:
        if isinstance(fu.get(k), int):
            out[k] = fu[k]
    out.update(_walk_residue())
    return out


def judge(c):
    """-> (lines, rc)."""
    lines = []
    if "ssh_user_reads_chat_db" in c:
        lines.append("  note  the ssh user can read chat.db: %s (not needed: the daemon reads it)"
                     % c["ssh_user_reads_chat_db"])
    if c.get("cannot"):
        lines.append("  CANNOT %s" % c["cannot"])
        return lines, EX_CANNOT
    if c.get("available") is False:
        lines.append("  CANNOT this daemon build has no Reminders push (followup.available=false)")
        return lines, EX_CANNOT
    if not c.get("measured"):
        lines.append("  CANNOT the reminders watcher has not measured yet (followup.measured=false): "
                     "not running, or no tick since start")
        return lines, EX_CANNOT
    if not c.get("enabled"):
        lines.append("  FAIL  the running daemon has the follow-up sweep switched off (followup.enabled=false)")
        return lines, EX_FAIL
    if not c.get("chat_db_readable"):
        lines.append("  CANNOT the daemon cannot read chat.db (no Full Disk Access), so no follow-up can be seen; "
                     "grant it at the console")
        return lines, EX_CANNOT
    missing = [k for k in ("keyed_rows", "keys_matching_one_to_one", "keys_matching_group") if k not in c]
    if missing:
        lines.append("  CANNOT followup block is missing %s" % ", ".join(missing))
        return lines, EX_CANNOT
    # Walk residue: the daemon counts it, the map says how much of it there is.
    # The two reads must agree, or the subtraction is not of the same rows.
    walk_missing = [k for k in ("walk_synthetic_keyed", "walk_synthetic_collisions", "db_keyed_rows") if k not in c]
    if c.get("walk_db_readable") is not True:
        lines.append("  CANNOT cannot read reminders_map.db read-only, so walk-synthetic residue cannot be separated "
                     "from real rows (%s)" % c.get("walk_db_reason", "not measured"))
        return lines, EX_CANNOT
    if walk_missing:
        lines.append("  CANNOT walk-residue exclusion not measured (%s)" % ", ".join(walk_missing))
        return lines, EX_CANNOT
    if c["db_keyed_rows"] != c["keyed_rows"]:
        lines.append("  CANNOT the daemon's census (%d keyed) and the map (%d keyed) disagree: a write landed "
                     "between the two reads; re-run" % (c["keyed_rows"], c["db_keyed_rows"]))
        return lines, EX_CANNOT
    if c["walk_synthetic_collisions"] > 0:
        lines.append("  CANNOT %d walk-synthetic key(s) are shared with a real row, so the exclusion cannot be made "
                     "by key" % c["walk_synthetic_collisions"])
        return lines, EX_CANNOT
    n_all = c["keyed_rows"]
    excl = c["walk_synthetic_keyed"]
    n = n_all - excl
    one, grp = c["keys_matching_one_to_one"], c["keys_matching_group"]
    matched = one + grp
    # v1.0.122: an email or WhatsApp row is keyed from other identities and
    # can never match a chat, so counting it made "0 of 7" read as broken
    # keys. A daemon that reports chat_keyed_rows gives the honest
    # denominator: the keyed rows that came from an iMessage chat. The walk
    # exclusion is not defined for that count (the walk's voice rows are not
    # iMessage), so it refuses rather than guess.
    if "chat_keyed_rows" in c:
        if excl:
            lines.append("  CANNOT this daemon reports chat_keyed_rows, and the walk exclusion is not defined for it "
                         "(%d walk-synthetic row(s) present)" % excl)
            return lines, EX_CANNOT
        n = c["chat_keyed_rows"]
        if n == 0 and n_all > 0:
            lines.append("  CANNOT no keyed reminder came from an iMessage chat yet (%d keyed from other "
                         "sources, which never match a chat by design)" % n_all)
            return lines, EX_CANNOT
    lines.append("  note  EXAMINED %d keyed row(s) after excluding %d walk-synthetic row(s) "
                 "(source_session_id ostler-walk-todo-*; %d keyed in all); %d match a 1:1 chat, %d a group chat"
                 % (n, excl, n_all, one, grp))
    if "chat_keyed_rows" not in c:
        # The pinned daemon (d323c07c) does not report chat_keyed_rows, so the
        # denominator above is every keyed row, not only iMessage ones.
        lines.append("  note  this daemon does not report chat_keyed_rows, so rows from email or WhatsApp "
                     "are counted too in the EXAMINED line above")
    if "completed_by_followup" in c:
        lines.append("  ADVISORY %d reminder(s) completed on a follow-up so far, %d reopened by the owner "
                     "(real activity only; never seeded)"
                     % (c["completed_by_followup"], c.get("reopened", 0)))
    if n <= 0:
        lines.append("  CANNOT zero denominator after excluding walk residue: no real pushed reminder carries a "
                     "thread_key yet (%d examined)" % max(n, 0))
        return lines, EX_CANNOT
    if matched > n:
        lines.append("  FAIL  impossible census: %d matches out of %d rows" % (matched, n))
        return lines, EX_FAIL
    if matched >= 1:
        lines.append("  ok    %d of %d keyed row(s) match a chat.db thread" % (matched, n))
        return lines, EX_PASS
    if n >= FAIL_FLOOR:
        lines.append("  FAIL  0 of %d keyed rows match any chat.db thread, so none of those reminders can "
                     "complete on a follow-up (the cause is not measured here: read the map's sources and keys)" % n)
        return lines, EX_FAIL
    lines.append("  CANNOT 0 of %d keyed row(s) match, below the %d needed to call it" % (n, FAIL_FLOOR))
    return lines, EX_CANNOT


def self_test():
    good = {"ssh_user_reads_chat_db": "no (Operation not permitted)", "available": True, "measured": True,
            "enabled": True, "chat_db_readable": True, "keyed_rows": 5, "keys_matching_one_to_one": 2,
            "keys_matching_group": 1, "completed_by_followup": 0, "reopened": 0,
            "walk_db_readable": True, "walk_synthetic_keyed": 0, "walk_synthetic_collisions": 0}
    nomatch = dict(keys_matching_one_to_one=0, keys_matching_group=0)
    cases = [
        ("a matching row passes", good, EX_PASS),
        ("only a group match still passes", dict(good, keys_matching_one_to_one=0), EX_PASS),
        ("display-name keys: 5 rows, 0 match", dict(good, keys_matching_one_to_one=0, keys_matching_group=0), EX_FAIL),
        ("exactly 3 rows, 0 match", dict(good, keyed_rows=3, keys_matching_one_to_one=0, keys_matching_group=0),
         EX_FAIL),
        ("sweep switched off in the daemon", dict(good, enabled=False), EX_FAIL),
        ("more matches than rows", dict(good, keyed_rows=1), EX_FAIL),
        ("denominator 0", dict(good, keyed_rows=0, keys_matching_one_to_one=0, keys_matching_group=0), EX_CANNOT),
        ("2 rows, 0 match: below the floor", dict(good, keyed_rows=2, keys_matching_one_to_one=0,
                                                  keys_matching_group=0), EX_CANNOT),
        ("daemon has no FDA to chat.db", dict(good, chat_db_readable=False), EX_CANNOT),
        ("watcher never measured", dict(good, measured=False), EX_CANNOT),
        ("build without reminders push", dict(good, available=False), EX_CANNOT),
        ("daemon predates #509", {"cannot": "no followup block"}, EX_CANNOT),
        ("counts missing", {k: v for k, v in good.items() if k != "keyed_rows"}, EX_CANNOT),
        # v1.0.122: email rows in the denominator. 4 keyed, none from a chat.
        ("only email-keyed rows: nothing to judge", dict(good, keyed_rows=4, chat_keyed_rows=0,
                                                         keys_matching_one_to_one=0, keys_matching_group=0),
         EX_CANNOT),
        ("chat rows that all fail to match", dict(good, keyed_rows=7, chat_keyed_rows=4,
                                                  keys_matching_one_to_one=0, keys_matching_group=0), EX_FAIL),
        ("chat rows with a match", dict(good, keyed_rows=7, chat_keyed_rows=4), EX_PASS),
        ("more matches than chat rows", dict(good, keyed_rows=7, chat_keyed_rows=2), EX_FAIL),
        # Walk residue (ostler-walk-todo-*). Mutant (a): 2 real + 2 walk rows.
        ("walk residue excluded: 2 real rows left, below the floor",
         dict(good, keyed_rows=4, db_keyed_rows=4, walk_synthetic_keyed=2, **nomatch), EX_CANNOT),
        ("walk residue NOT excluded: the same 4 rows FAIL",
         dict(good, keyed_rows=4, db_keyed_rows=4, walk_synthetic_keyed=0, **nomatch), EX_FAIL),
        # Mutant (b): real non-iMessage rows still graded behind the exclusion.
        ("3 real rows still FAIL behind 2 walk rows",
         dict(good, keyed_rows=5, db_keyed_rows=5, walk_synthetic_keyed=2, **nomatch), EX_FAIL),
        # Mutant (c): only walk rows, zero denominator after exclusion.
        ("only walk rows: zero after exclusion is CANNOT",
         dict(good, keyed_rows=2, db_keyed_rows=2, walk_synthetic_keyed=2, **nomatch), EX_CANNOT),
        ("a walk key shared with a real row cannot be excluded by key",
         dict(good, keyed_rows=4, db_keyed_rows=4, walk_synthetic_keyed=1, walk_synthetic_collisions=1, **nomatch),
         EX_CANNOT),
        ("the census and the map disagree", dict(good, keyed_rows=5, db_keyed_rows=4), EX_CANNOT),
        ("reminders_map.db not readable", dict(good, walk_db_readable=False, walk_db_reason="absent"), EX_CANNOT),
        ("walk exclusion not measured", {k: v for k, v in good.items() if k != "walk_synthetic_keyed"}, EX_CANNOT),
        ("walk residue beside a chat_keyed daemon",
         dict(good, chat_keyed_rows=5, walk_synthetic_keyed=1, **nomatch), EX_CANNOT),
    ]
    ok = True
    names = {EX_PASS: "PASS", EX_FAIL: "FAIL", EX_CANNOT: "CANNOT-RUN"}
    for name, cap, want in cases:
        # A case that moves keyed_rows and says nothing about the map is a case
        # where the map agrees with the census.
        if "keyed_rows" in cap and "db_keyed_rows" not in cap:
            cap = dict(cap, db_keyed_rows=cap["keyed_rows"])
        _, rc = judge(cap)
        good_rc = rc == want
        ok &= good_rc
        print("  %s  %s -> %s (want %s)" % ("ok   " if good_rc else "FAIL ", name, names.get(rc, rc), names[want]))
    # The denominator caveat: the pinned daemon does not report chat_keyed_rows,
    # so an EXAMINED line over its keyed rows counts email and WhatsApp rows too.
    # The caveat must say so when the field is absent, and must not when it is there.
    caveat = "rows from email or WhatsApp are counted too"
    no_chat_field = dict(good, db_keyed_rows=good["keyed_rows"])
    with_chat_field = dict(good, db_keyed_rows=good["keyed_rows"], chat_keyed_rows=good["keyed_rows"])
    caveat_absent_ok = any(caveat in line for line in judge(no_chat_field)[0])
    caveat_present_ok = not any(caveat in line for line in judge(with_chat_field)[0])
    print("  %s  caveat printed when chat_keyed_rows is absent" % ("ok   " if caveat_absent_ok else "FAIL "))
    print("  %s  caveat not printed when chat_keyed_rows is present" % ("ok   " if caveat_present_ok else "FAIL "))
    ok &= caveat_absent_ok and caveat_present_ok
    print("every case landed on its own verdict" if ok else "SELF-TEST BROKEN")
    return 0 if ok else 1


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) >= 2 and argv[1] == "box":
        print(json.dumps(box()))
        return 0
    if len(argv) >= 3 and argv[1] == "judge":
        with open(argv[2], encoding="utf-8") as fh:
            lines, rc = judge(json.load(fh))
        print("\n".join(lines))
        return rc
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
